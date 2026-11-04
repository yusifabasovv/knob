import CDDC
import Foundation

/// One external monitor's DDC/CI channel. Every I2C transaction on the machine goes through
/// a single serial queue: the bus is slow (~100 ms per round trip) and does not tolerate overlap.
final class DDCDevice: @unchecked Sendable {
    enum ReadResult: Equatable {
        case value(current: Int, max: Int)
        case unsupported
        case noReply
    }

    private static let queue = DispatchQueue(label: "knob.ddc", qos: .userInitiated)
    private let ref: DDCServiceRef

    static var externalCount: Int { Int(ddc_external_count()) }

    /// The display's EDID UUID (identifies the monitor model), when the registry exposes it.
    let displayID: String?

    init?(index: Int = 0) {
        var uuid = [CChar](repeating: 0, count: 64)
        guard let r = ddc_copy_external_service(Int32(index), &uuid, Int32(uuid.count)) else { return nil }
        ref = r
        let id = String(cString: uuid)
        displayID = id.isEmpty ? nil : id
    }

    deinit { ddc_release(ref) }

    func read(_ code: UInt8) async -> ReadResult {
        await run {
            var cur: UInt16 = 0, max: UInt16 = 0
            switch ddc_get_vcp(self.ref, code, &cur, &max) {
            case Int32(DDC_OK): return .value(current: Int(cur), max: Int(max))
            case Int32(DDC_UNSUPPORTED): return .unsupported
            default: return .noReply
            }
        }
    }

    @discardableResult
    func write(_ code: UInt8, _ value: Int) async -> Bool {
        await run { ddc_set_vcp(self.ref, code, UInt16(clamping: value)) == Int32(DDC_OK) }
    }

    /// Wait until the monitor reports `value` (it may still be applying a mode change).
    func confirm(_ code: UInt8, _ value: Int, timeoutMs: Int = 400) async -> Bool {
        await run { ddc_await_vcp(self.ref, code, UInt16(clamping: value), Int32(timeoutMs)) == Int32(DDC_OK) }
    }

    /// Write and confirm by read-back, re-sending if the value didn't stick (shared I2C bus).
    @discardableResult
    func writeVerified(_ code: UInt8, _ value: Int, attempts: Int = 4) async -> Bool {
        await run { ddc_set_vcp_verified(self.ref, code, UInt16(clamping: value), Int32(attempts)) == Int32(DDC_OK) }
    }

    func capabilities() async -> String? {
        await run {
            var buf = [CChar](repeating: 0, count: 4096)
            let n = ddc_read_capabilities(self.ref, &buf, Int32(buf.count))
            return n > 0 ? String(cString: buf) : nil
        }
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DDCDevice.queue.async { cont.resume(returning: work()) }
        }
    }
}
