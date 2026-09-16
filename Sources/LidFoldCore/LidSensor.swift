import Foundation
import IOKit.hid

/// 一筆上蓋角度樣本。
public struct LidAngleSample {
    /// 秒，單調時鐘（`ProcessInfo.systemUptime`），只拿來算 dθ/dt。
    public let timestamp: Double
    /// 感測器原始 16-bit 值。
    public let raw: UInt16
    /// 角度，單位度。0 = 完全闔上。
    public let theta: Double
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
/// 讀法採 (b)：`IOHIDDeviceGetReport` 讀 feature report ID 1，再由呼叫端輪詢。
/// 出處：`samhenrigold/LidAngleSensor` (`LidAngleSensor.m`)、
/// `wangfu91/lid-angle-rs` (`src/lib.rs`)、`tcsenpai/pybooklid` (`pybooklid.py`)。
/// 三者都是讀 report 1，取 bytes[1..2] 做 little-endian UInt16。
public final class LidSensor {
    public static let vendorID = 0x05AC
    public static let productID = 0x8104
    public static let usagePage = 0x0020   // Sensor
    public static let usage = 0x008A       // Orientation

    /// 原始值 → 度 的換算。M0 實測：上蓋開到約 110° 時原始值也約 110，所以是 1 raw = 1°。
    /// （白皮書 3.1 寫 0.01°，與實測不符，以實測為準。）
    public static let degreesPerRawUnit: Double = 1.0

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var reportBuffer = [UInt8](repeating: 0, count: 8)

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
        var length = CFIndex(reportBuffer.count)
        let r = reportBuffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, buf.baseAddress!, &length)
        }
        guard r == kIOReturnSuccess else { throw LidSensorError.reportFailed(r) }
        guard length >= 3 else { throw LidSensorError.shortReport(Int(length)) }
        let raw = UInt16(reportBuffer[1]) | (UInt16(reportBuffer[2]) << 8)
        return LidAngleSample(
            timestamp: ProcessInfo.processInfo.systemUptime,
            raw: raw,
            theta: Double(raw) * Self.degreesPerRawUnit
        )
    }

    /// 除錯用：整段 feature report 的 hex。
    public func rawReportHex() -> String {
        reportBuffer.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
