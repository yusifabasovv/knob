import AppKit
import Foundation

@MainActor
final class MonitorModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case ready
        case noMonitor            // no external display with a DDC service
        case noReply              // display found but it doesn't answer DDC/CI
        case switchedInput(String) // we moved the monitor to another input; it can't hear us now
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var values: [UInt8: Int] = [:]
    @Published private(set) var maxima: [UInt8: Int] = [:]
    @Published private(set) var caps = Capabilities(parsing: "")
    @Published private(set) var profile = MonitorProfile.generic
    @Published private(set) var screenName = "Monitor"
    @Published private(set) var refreshing = false
    /// Spinner flag: only turns on if a refresh runs past 0.7 s. A panel-open refresh takes
    /// ~0.37 s (measured), so normal ones never flash a spinner.
    @Published private(set) var showBusy = false
    /// Codes whose last write the monitor refused (verified read-back never matched).
    @Published private(set) var rejected: Set<UInt8> = []

    /// Picture settings, most visible first so the sliders update first. Read on every panel open.
    private let pictureCodes: [UInt8] = [
        VCP.brightness, VCP.contrast, VCP.pictureMode, VCP.colorPreset, VCP.redGain, VCP.greenGain, VCP.blueGain,
    ]
    /// Only change with the cable, input or display mode: read on full refreshes only.
    private let linkCodes: [UInt8] = [VCP.inputSource, VCP.verticalFrequency]

    private var device: DDCDevice?
    /// EDID UUID of the monitor whose settings are loaded (nil if the registry doesn't say).
    private var displayID: String?
    private let capsCache = CapabilitiesCache()
    private var capsFromCache = false
    private var pending: [UInt8: Int] = [:]
    private var draining: Set<UInt8> = []
    private var lastRefresh = Date.distantPast

    /// `autoStart: false` is for --bench/--snapshot, which drive their own model.
    init(autoStart: Bool = true) {
        if autoStart { Task { await refresh(force: true) } }
    }

    // MARK: Reading

    /// Re-read the monitor's settings. Panel opens call this (throttled to 1/s, picture settings
    /// only); `force` (launch, Refresh, Try Again) ignores the throttle and reads everything.
    /// `rescan` (the Refresh button) also re-reads the capabilities list instead of trusting the
    /// cached one, so a stale cache is always one click from fixed.
    func refresh(force: Bool = false, rescan: Bool = false) async {
        guard !refreshing, force || Date().timeIntervalSince(lastRefresh) > 1 else { return }
        if case .switchedInput = state, !force { return } // keep the message until the user retries
        refreshing = true
        let spinner = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { showBusy = true }
        }
        defer { spinner.cancel(); showBusy = false; refreshing = false; lastRefresh = Date() }

        if device == nil {
            guard DDCDevice.externalCount > 0, let d = DDCDevice(index: 0) else {
                state = .noMonitor
                return
            }
            if let old = displayID, let new = d.displayID, old != new {
                forgetMonitor() // a different monitor is plugged in now
            }
            device = d
            displayID = d.displayID ?? displayID
            screenName = Self.externalScreenName() ?? "Monitor"
        }
        guard let device else { return }

        if caps.vcp.isEmpty || rescan {
            if !rescan, let id = displayID, let raw = capsCache.load(id), Capabilities(parsing: raw).isComplete {
                caps = Capabilities(parsing: raw)
                capsFromCache = true
            } else if let raw = await device.capabilities() {
                let fresh = Capabilities(parsing: raw)
                // On a rescan, keep what we have unless the new read is at least as good.
                if caps.vcp.isEmpty || fresh.isComplete {
                    caps = fresh
                    capsFromCache = false
                }
                if fresh.isComplete, let id = displayID { capsCache.save(raw, for: id) }
            } else if caps.vcp.isEmpty {
                self.device = nil // re-create the service next time (cable/input may have changed)
                state = .noReply
                return
            }
            profile = MonitorProfile.match(caps)
        }

        var gotAny = false
        var misses = 0
        let codes = pictureCodes + (force || values[VCP.inputSource] == nil ? linkCodes : [])
        reading: for code in codes where caps.supports(code) && pending[code] == nil {
            switch await device.read(code) {
            case let .value(cur, max):
                if pending[code] == nil {
                    values[code] = cur
                    maxima[code] = max
                }
                gotAny = true
            case .unsupported:
                cachedCapsContradicted(code)
                continue
            case .noReply:
                // Two misses before any answer: the link is dead (DDC/CI off, other input), so stop
                // rather than spend ~0.5 s on each remaining code. A single miss can just be a
                // collision with another DDC app on the bus.
                misses += 1
                if !gotAny && misses >= 2 { break reading }
            }
        }
        if gotAny {
            state = .ready
        } else {
            self.device = nil
            state = .noReply
        }
    }

    // MARK: Writing

    /// Set a value. Rapid calls (slider drags) coalesce: only the latest pending value is sent.
    func set(_ code: UInt8, _ value: Int) {
        guard lockNote(code) == nil else { return }
        rejected.remove(code)
        log.notice("set \(String(format: "0x%02X", code), privacy: .public)=\(value) device=\(self.device != nil) state=\(String(describing: self.state), privacy: .public)")
        values[code] = value
        pending[code] = value
        guard !draining.contains(code) else { return }
        draining.insert(code)
        Task { await drain(code) }
    }

    private func drain(_ code: UInt8) async {
        defer { draining.remove(code) }
        guard let device else { log.error("drain: no device, dropping write"); pending[code] = nil; return }
        while let v = pending.removeValue(forKey: code) {
            let wrote = await device.write(code, v)
            log.debug("write \(String(format: "0x%02X", code), privacy: .public)=\(v) ok=\(wrote)")
            // A newer slider value arrived mid-write: don't verify this superseded one.
            guard pending[code] == nil else { continue }
            // Final value: wait until the monitor reports it (a mode change takes ~0.1 s to apply).
            // The I2C bus is shared with any other DDC client and a collision silently drops
            // writes, so if it never shows up, re-send.
            if await device.confirm(code, v) { continue }
            guard pending[code] == nil else { continue }
            let ok = await device.writeVerified(code, v)
            log.notice("verified rewrite \(String(format: "0x%02X", code), privacy: .public)=\(v) ok=\(ok)")
            if !ok, pending[code] == nil { rejected.insert(code) }
        }
        // Re-read only what this change can affect (a preset carries its own brightness etc.),
        // plus the code itself if the monitor refused it, so the UI shows what it really kept.
        var codes = VCP.sideEffects(of: code)
        if rejected.contains(code) { codes.insert(code, at: 0) }
        await reread(codes)
    }

    private func reread(_ codes: [UInt8]) async {
        guard let device else { return }
        for code in codes where caps.supports(code) && pending[code] == nil {
            switch await device.read(code) {
            case let .value(cur, max):
                guard pending[code] == nil else { continue }
                values[code] = cur
                maxima[code] = max
            case .unsupported:
                cachedCapsContradicted(code)
            case .noReply:
                continue
            }
        }
    }

    /// The cached capabilities listed `code` but the monitor says it's unsupported: the cache is
    /// stale (a firmware update, say). Drop it so the next launch reads the real list.
    private func cachedCapsContradicted(_ code: UInt8) {
        guard capsFromCache, let id = displayID else { return }
        log.notice("cached capabilities contradicted by 0x\(String(format: "%02X", code), privacy: .public); dropping cache")
        capsCache.remove(id)
        capsFromCache = false
    }

    /// Clear everything learned about the previous monitor.
    private func forgetMonitor() {
        caps = Capabilities(parsing: "")
        profile = .generic
        values = [:]
        maxima = [:]
        rejected = []
        capsFromCache = false
    }

    func switchInput(to value: Int) {
        guard let device else { return }
        let name = label(VCP.inputSource, value)
        state = .switchedInput(name)
        Task {
            await device.write(VCP.inputSource, value)
            self.device = nil
            self.values[VCP.inputSource] = value
        }
    }

    // MARK: Presentation helpers

    func value(_ code: UInt8) -> Int? { values[code] }
    func maximum(_ code: UInt8) -> Int { max(maxima[code] ?? 100, 1) }
    func supports(_ code: UInt8) -> Bool { caps.supports(code) }
    func options(_ code: UInt8) -> [Int] { caps.values(for: code).map(Int.init) }
    func label(_ code: UInt8, _ value: Int) -> String { profile.label(for: code, value: UInt16(value)) }

    /// Why `code` can't be changed right now (a known monitor lock), or nil.
    func lockNote(_ code: UInt8) -> String? {
        guard let lock = profile.lock(on: code, current: values) else { return nil }
        let name = lock.code == VCP.colorPreset ? "color" : "mode"
        return "Fixed by the monitor in \(label(lock.code, Int(lock.value))). Choose another \(name) to adjust."
    }

    /// True while a write is draining or a refresh is running.
    var isBusy: Bool { refreshing || !draining.isEmpty }

    var isUserColor: Bool {
        guard let user = profile.userColorPreset, let cur = values[VCP.colorPreset] else { return false }
        return cur == Int(user)
    }

    var brand: String { profile.brand }
    var model: String { profile.model ?? screenName }

    var headerDetail: String {
        var parts: [String] = []
        if let input = values[VCP.inputSource] {
            parts.append(profile.label(for: VCP.inputSource, value: UInt16(input)))
        }
        if let v = values[VCP.verticalFrequency], v > 0 {
            parts.append("\(Int((Double(v) / 100).rounded())) Hz")
        }
        return parts.joined(separator: " · ")
    }

    private static func externalScreenName() -> String? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }?.localizedName
    }
}
