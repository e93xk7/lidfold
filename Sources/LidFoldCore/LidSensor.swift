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
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
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
                rawFine = UInt32(fineBuffer[1]) | (UInt32(fineBuffer[2]) << 8)
                    | (UInt32(fineBuffer[3]) << 16) | (UInt32(fineBuffer[4]) << 24)
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
