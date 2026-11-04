// Plain test runner (compiled together with Sources/MonitorCore by ./build.sh test).
// SwiftPM/XCTest are unavailable with this machine's Command Line Tools, so no framework.

var failures = 0
var checks = 0
func expect(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("FAIL line \(line): \(msg)") }
}

/// Real capabilities string read from the AOC 24G1WG4 on 2026-11-05.
let aocCaps = "(prot(monitor)type(LCD)model(C24G1)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 0C 10 12 14(01 05 06 08 0B) 16 18 1A 52 60(01 0F 11 12) 86(01 02 05 0B 0C 0E 0F 11) AC AE B2 B6 C6 C8 CA CC(01 02 03 04 05 06 07 09 0A 0B 0D 0E 12 14 16 1E) D6(01 04 05) DC(00 0B 0C 0D 0E 0F 10) DF ED FF)mswhql(1)asset_eep(40)mccs_ver(2.2))"

@main enum Tests {
    static func main() {
        // Top-level fields
        let c = Capabilities(parsing: aocCaps)
        expect(c.model == "C24G1", "model")
        expect(c.mccsVersion == "2.2", "mccs version")
        expect(c.fields["type"] == "LCD", "type")

        // Continuous and discrete VCP codes
        expect(c.supports(VCP.brightness), "brightness supported")
        expect(c.values(for: VCP.brightness).isEmpty, "brightness continuous")
        expect(c.values(for: VCP.colorPreset) == [0x01, 0x05, 0x06, 0x08, 0x0B], "color presets")
        expect(c.values(for: VCP.inputSource) == [0x01, 0x0F, 0x11, 0x12], "inputs")
        expect(c.values(for: VCP.pictureMode) == [0x00, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10], "picture modes")
        expect(!c.supports(0x87), "sharpness not advertised")
        expect(c.vcpOrder.first == 0x02 && c.vcpOrder.last == 0xFF, "order ends")
        expect(c.vcpOrder.count == 27, "27 codes, got \(c.vcpOrder.count)")

        // No outer parens, no spaces between hex pairs
        let d = Capabilities(parsing: "model(X1)vcp(10 12 60(0F11))")
        expect(d.model == "X1", "model without outer parens")
        expect(d.values(for: VCP.inputSource) == [0x0F, 0x11], "packed values")
        expect(d.supports(0x12), "contrast")

        // Garbage does not crash
        expect(Capabilities(parsing: "").vcp.isEmpty, "empty")
        expect(Capabilities(parsing: "((((").vcp.isEmpty, "unbalanced")
        expect(!Capabilities(parsing: "vcp(10 14(01 05").supports(VCP.brightness), "truncated")

        // Profiles
        let p = MonitorProfile.match(c)
        expect(p.id == "aoc-24g1", "AOC profile matched")
        expect(p.label(for: VCP.inputSource, value: 0x12) == "HDMI 2", "input label")
        expect(p.shortLabel(for: VCP.inputSource, value: 0x12) == "HDMI2", "short input label")
        expect(p.label(for: VCP.colorPreset, value: 0x0B) == "User", "user preset")

        let g = MonitorProfile.match(Capabilities(parsing: "model(UNKNOWN)vcp(10)"))
        expect(g.id == "generic", "generic fallback")
        expect(g.label(for: VCP.colorPreset, value: 0x05) == "6500K", "MCCS standard label")
        expect(g.label(for: VCP.pictureMode, value: 0x0B) == "Mode 11", "numbered fallback")

        // Locks: AOC sRGB freezes brightness and contrast, nothing else
        expect(p.lock(on: VCP.brightness, current: [VCP.colorPreset: 0x01]) != nil, "sRGB locks brightness")
        expect(p.lock(on: VCP.contrast, current: [VCP.colorPreset: 0x01]) != nil, "sRGB locks contrast")
        expect(p.lock(on: VCP.brightness, current: [VCP.colorPreset: 0x05]) == nil, "Warm doesn't lock")
        expect(p.lock(on: VCP.redGain, current: [VCP.colorPreset: 0x01]) == nil, "sRGB doesn't lock gains via this rule")
        expect(p.lock(on: VCP.brightness, current: [:]) == nil, "unknown preset doesn't lock")
        expect(g.lock(on: VCP.brightness, current: [VCP.colorPreset: 0x01]) == nil, "generic has no locks")

        // Side effects of a write: presets/modes re-read picture settings, never input/refresh rate
        expect(VCP.sideEffects(of: VCP.pictureMode).prefix(2) == [VCP.brightness, VCP.contrast], "mode: sliders first")
        expect(VCP.sideEffects(of: VCP.colorPreset).contains(VCP.pictureMode), "sRGB can reset picture mode")
        expect(!VCP.sideEffects(of: VCP.colorPreset).contains(VCP.colorPreset), "no self re-read")
        expect(!VCP.sideEffects(of: VCP.pictureMode).contains(VCP.inputSource), "input unaffected")
        expect(VCP.sideEffects(of: VCP.brightness).isEmpty, "brightness has no side effects")

        // Completeness: only fully read strings may be cached
        expect(c.isComplete, "AOC string complete")
        expect(!Capabilities(parsing: String(aocCaps.prefix(200))).isComplete, "truncated mid-vcp")
        expect(!Capabilities(parsing: String(aocCaps.dropLast(1))).isComplete, "missing final paren")
        expect(Capabilities(parsing: "model(X1)vcp(10 12 60(0F11))").isComplete, "no outer parens is fine")
        expect(!Capabilities(parsing: "(prot(monitor)type(LCD))").isComplete, "no vcp list")
        expect(!Capabilities(parsing: "").isComplete, "empty")

        // Capabilities cache (isolated UserDefaults suite, deleted afterwards)
        let suite = "knob-tests-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        let cache = CapabilitiesCache(defaults: defaults)
        let uuid = "05E30124-0000-0000-191D-010380341D78"
        expect(cache.load(uuid) == nil, "empty cache misses")
        cache.save(aocCaps, for: uuid)
        expect(cache.load(uuid) == aocCaps, "round trip")
        expect(cache.load("OTHER-UUID") == nil, "other monitors miss")
        cache.save(aocCaps, for: "")
        expect(cache.load("") == nil, "empty id never cached")
        cache.save("", for: "X")
        expect(cache.load("X") == nil, "empty string never cached")
        cache.remove(uuid)
        expect(cache.load(uuid) == nil, "remove")
        defaults.removePersistentDomain(forName: suite)

        print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

import Foundation
