import Foundation
import IOKit.hid

/// 一筆上蓋角度樣本。
public struct LidAngleSample {
    /// 秒，單調時鐘（`ProcessInfo.systemUptime`），只拿來算 dθ/dt。
    public let timestamp: Double
    /// 角度，單位度，解析度 0.01°（report 7）。0 = 完全闔上。平常用這個。
    public let theta: Double
    /// 角度，單位度，解析度 1°（report 1）。只拿來對照／備援。
    public let thetaCoarse: Double
    /// report 7 的原始整數，單位 0.01°。
    public let rawFine: UInt32
    /// report 1 的原始整數，單位 1°。
    public let rawCoarse: UInt16

    public init(timestamp: Double, theta: Double, thetaCoarse: Double,
                rawFine: UInt32, rawCoarse: UInt16) {
        self.timestamp = timestamp
        self.theta = theta
        self.thetaCoarse = thetaCoarse
        self.rawFine = rawFine
        self.rawCoarse = rawCoarse
    }
}

public enum LidSensorError: Error, CustomStringConvertible {
    case deviceNotFound
    case openFailed(IOReturn)
    case reportFailed(IOReturn)
    case shortReport(Int)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return "找不到上蓋角度感測器（VID 0x05AC / PID 0x8104 / UsagePage 0x20 / Usage 0x8A）"
        case .openFailed(let r):
            return "IOHIDDeviceOpen 失敗：\(Self.hex(r))（0xE00002E2 = 權限不足，需要 Input Monitoring 或 sudo）"
        case .reportFailed(let r):
            return "IOHIDDeviceGetReport 失敗：\(Self.hex(r))"
        case .shortReport(let n):
            return "feature report 太短：\(n) bytes"
        }
    }

    private static func hex(_ r: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: r), radix: 16, uppercase: true)
    }
}

/// Sensor 層：用 IOKit HID 讀 MacBook 內建上蓋角度感測器。
///
/// 讀法採 (b)：`IOHIDDeviceGetReport` 讀 report，再由呼叫端輪詢。
/// 參考實作（`samhenrigold/LidAngleSensor`、`wangfu91/lid-angle-rs`、
/// `tcsenpai/pybooklid`）都只讀 report 1。
///
/// M1 讀 HID report descriptor 發現還有一個 **report 7**：32-bit、logical max 36000、
/// unit exponent 10⁻²，也就是同一個角度但解析度 0.01°（實測 report 1 = 117° 時
/// report 7 = 116.89–116.94°）。本專案以 report 7 為主、report 1 為備援。
///
/// 兩個 report 都由同一顆感測器驅動，**每 100 ms 更新一次（10 Hz）**。
/// 實測註冊 input report callback 的推送速率一樣是 10 Hz，所以換讀法救不了更新率，
/// 動畫要自己做預測／插值（M3）。
public final class LidSensor {
    public static let vendorID = 0x05AC
    public static let productID = 0x8104
    public static let usagePage = 0x0020   // Sensor
    public static let usage = 0x008A       // Orientation

    /// 感測器自己的更新週期，實測 100 ms。
    public static let sensorUpdateInterval: Double = 0.1

    private static let coarseReportID = 1   // 9-bit，1°
    private static let fineReportID = 7     // 32-bit，0.01°

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var coarseBuffer = [UInt8](repeating: 0, count: 8)
    private var fineBuffer = [UInt8](repeating: 0, count: 8)
    /// report 7 讀不到時（別的機型可能沒有）就只用 report 1。
    private var fineAvailable = true
    /// 兩個 report 兜不起來的次數，除錯用。
    public private(set) var disagreements = 0

    public init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDDeviceUsagePageKey as String: Self.usagePage,
            kIOHIDDeviceUsageKey as String: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        // 只用 manager 列舉裝置，不用它 open；open 走 device 層級。
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = set.first else {
            throw LidSensorError.deviceNotFound
        }
        device = first
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw LidSensorError.openFailed(r) }
    }

    deinit {
        stopStreaming()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - 推送模式（不輪詢）

    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferSize = 64
    private var onUpdate: ((LidAngleSample) -> Void)?
    private var scheduled = false

    /// 改用感測器主動推送，不要自己輪詢。
    ///
    /// 感測器每 100 ms 會送一次 input report（即使角度沒變也送），所以註冊 callback
    /// 等於拿到「感測器自己的節拍」—— 延遲比輪詢低，而且閒置時 CPU 幾乎是 0。
    /// M5 的過關條件是閒置 CPU < 1%，用 120 Hz 輪詢去追一個 10 Hz 的感測器過不了。
    ///
    /// 被推送的只有 report 1（1° 解析度），所以收到通知後立刻讀一次 report 7 拿細值。
    public func startStreaming(onUpdate: @escaping (LidAngleSample) -> Void) {
        guard !scheduled else { return }
        self.onUpdate = onUpdate

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        buffer.initialize(repeating: 0, count: inputBufferSize)
        inputBuffer = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, inputBufferSize,
                                               { ctx, _, _, _, _, bytes, length in
            guard let ctx else { return }
            Unmanaged<LidSensor>.fromOpaque(ctx).takeUnretainedValue()
                .handleInputReport(bytes: bytes, length: Int(length))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(),
                                       CFRunLoopMode.defaultMode.rawValue)
        scheduled = true
    }

    public func stopStreaming() {
        guard scheduled else { return }
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer!, inputBufferSize,
                                               nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(),
                                         CFRunLoopMode.defaultMode.rawValue)
        inputBuffer?.deallocate()
        inputBuffer = nil
        onUpdate = nil
        scheduled = false
    }

    /// 上一次推送帶來的粗值，用來判斷「到底有沒有在動」。
    private var lastPushedCoarse: UInt16?
    private var lastFine: UInt32 = 0

    /// 感測器主動送了一筆 report 1。
    ///
    /// 推送本身已經把粗值（1°）帶來了，不用再讀一次。只有在粗值真的變了
    /// —— 也就是上蓋在動 —— 才額外讀 report 7 拿 0.01° 的細值。
    /// 靜止時因此完全不做 IPC，閒置耗電才壓得下來（M5 的過關條件）。
    private func handleInputReport(bytes: UnsafePointer<UInt8>, length: Int) {
        let timestamp = ProcessInfo.processInfo.systemUptime

        // 推送的 buffer 含 report ID 開頭（實測是 "01 71 00"）。
        let coarse: UInt16
        if length >= 3, bytes[0] == UInt8(Self.coarseReportID) {
            coarse = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        } else if length >= 2 {
            coarse = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        } else {
            return
        }

        if coarse != lastPushedCoarse || lastPushedCoarse == nil {
            lastPushedCoarse = coarse
            // 在動：去拿細值。
            if fineAvailable,
               let len = try? getReport(Self.fineReportID, into: &fineBuffer), len >= 5 {
                let fine = UInt32(fineBuffer[1]) | (UInt32(fineBuffer[2]) << 8)
                    | (UInt32(fineBuffer[3]) << 16) | (UInt32(fineBuffer[4]) << 24)
                if abs(Double(fine) / 100.0 - Double(coarse)) <= Tuning.reportDisagreement {
                    lastFine = fine
                } else {
                    disagreements += 1
                    lastFine = UInt32(coarse) * 100
                }
            } else {
                lastFine = UInt32(coarse) * 100
            }
        }
        // 粗值沒變就沿用上次的細值：靜止時那點飄移是雜訊，不值得一次 IPC。

        onUpdate?(LidAngleSample(
            timestamp: timestamp,
            theta: Double(lastFine) / 100.0,
            thetaCoarse: Double(coarse),
            rawFine: lastFine,
            rawCoarse: coarse))
    }

    /// 讀一次目前角度。同步、阻塞（實測 < 1 ms）。
    public func read() throws -> LidAngleSample {
        let timestamp = ProcessInfo.processInfo.systemUptime

        let coarseLen = try getReport(Self.coarseReportID, into: &coarseBuffer)
        guard coarseLen >= 3 else { throw LidSensorError.shortReport(coarseLen) }
        let rawCoarse = UInt16(coarseBuffer[1]) | (UInt16(coarseBuffer[2]) << 8)
        let thetaCoarse = Double(rawCoarse)

        var rawFine = UInt32(rawCoarse) * 100
        if fineAvailable {
            if let len = try? getReport(Self.fineReportID, into: &fineBuffer), len >= 5 {
                let fine = UInt32(fineBuffer[1]) | (UInt32(fineBuffer[2]) << 8)
                    | (UInt32(fineBuffer[3]) << 16) | (UInt32(fineBuffer[4]) << 24)
                // 兩個 report 來自同一顆感測器，差太多就是這次讀壞了，退回 report 1。
                if abs(Double(fine) / 100.0 - thetaCoarse) <= Tuning.reportDisagreement {
                    rawFine = fine
                } else {
                    disagreements += 1
                }
            } else {
                fineAvailable = false
            }
        }

        return LidAngleSample(
            timestamp: timestamp,
            theta: Double(rawFine) / 100.0,
            thetaCoarse: thetaCoarse,
            rawFine: rawFine,
            rawCoarse: rawCoarse
        )
    }

    private func getReport(_ id: Int, into buffer: inout [UInt8]) throws -> Int {
        var length = CFIndex(buffer.count)
        let r = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, buf.baseAddress!, &length)
        }
        guard r == kIOReturnSuccess else { throw LidSensorError.reportFailed(r) }
        return Int(length)
    }

    /// 除錯用：兩個 report 的 hex。
    public func rawReportHex() -> String {
        let c = coarseBuffer.prefix(3).map { String(format: "%02X", $0) }.joined(separator: " ")
        let f = fineBuffer.prefix(5).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "r1[\(c)] r7[\(f)]"
    }
}
