import Foundation


/// VCP feature codes used by the app (MCCS 2.2 numbering).
public enum VCP {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colorPreset: UInt8 = 0x14
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let inputSource: UInt8 = 0x60
    public static let verticalFrequency: UInt8 = 0xAE
    public static let pictureMode: UInt8 = 0xDC

    /// Settings a monitor may change by itself when `code` is written: picture modes and color
    /// presets carry their own brightness, contrast and gains (AOC's sRGB also resets the picture
    /// mode). Most visible first. Input and refresh rate never follow from these.
    public static func sideEffects(of code: UInt8) -> [UInt8] {
        switch code {
        case pictureMode: return [brightness, contrast, colorPreset, redGain, greenGain, blueGain]
        case colorPreset: return [brightness, contrast, pictureMode, redGain, greenGain, blueGain]
        default: return []
        }
    }
}

/// Brand/model specific knowledge layered on top of the generic MCCS meaning of each code.
public struct MonitorProfile: Sendable, Equatable {
    public let id: String
    public let brand: String
    public let model: String?
    /// Capabilities `model(...)` strings this profile applies to.
    public let capabilityModels: [String]
    /// Per-code value labels that override the generic MCCS names.
    public let labels: [UInt8: [UInt16: String]]
    /// The color-preset value that unlocks manual RGB gain, if any.
    public let userColorPreset: UInt16?
    /// Settings the monitor refuses to change while another setting has a given value.
    public let locks: [Lock]

    /// "While `code` == `value`, the monitor ignores writes to `locked`."
    public struct Lock: Sendable, Equatable {
        public let code: UInt8
        public let value: UInt16
        public let locked: [UInt8]
        public init(code: UInt8, value: UInt16, locked: [UInt8]) {
            self.code = code; self.value = value; self.locked = locked
        }
    }

    public init(id: String, brand: String, model: String?, capabilityModels: [String],
                labels: [UInt8: [UInt16: String]], userColorPreset: UInt16?, locks: [Lock] = []) {
        self.id = id
        self.brand = brand
        self.model = model
        self.capabilityModels = capabilityModels
        self.labels = labels
        self.userColorPreset = userColorPreset
        self.locks = locks
    }

    /// Human label for a discrete value: profile override, then MCCS standard name, then a numbered fallback.
    public func label(for code: UInt8, value: UInt16) -> String {
        if let l = labels[code]?[value] { return l }
        if let l = MonitorProfile.standardLabels[code]?[value] { return l }
        return "Mode \(value)"
    }

    /// The lock currently preventing changes to `code`, given the monitor's current values.
    public func lock(on code: UInt8, current: [UInt8: Int]) -> Lock? {
        locks.first { $0.locked.contains(code) && current[$0.code] == Int($0.value) }
    }

    /// Short form for the header ("HDMI 2" -> "HDMI2").
    public func shortLabel(for code: UInt8, value: UInt16) -> String {
        label(for: code, value: value).replacingOccurrences(of: " ", with: "")
    }

    public static let generic = MonitorProfile(
        id: "generic", brand: "", model: nil, capabilityModels: [],
        labels: [:], userColorPreset: 0x0B)

    /// AOC 24G1WG4 (reports itself as `model(C24G1)`).
    /// NOTE: picture-mode (0xDC) and colour-preset (0x14) names are best guesses until
    /// confirmed against the monitor's on-screen menu — see README "Calibrating labels".
    public static let aoc24G1 = MonitorProfile(
        id: "aoc-24g1", brand: "AOC", model: "24G1WG4", capabilityModels: ["C24G1"],
        labels: [
            VCP.colorPreset: [0x01: "sRGB", 0x05: "Warm", 0x06: "Normal", 0x08: "Cool", 0x0B: "User"],
            VCP.pictureMode: [0x00: "Standard", 0x0B: "Text", 0x0C: "Internet", 0x0D: "Game",
                              0x0E: "Movie", 0x0F: "Sports", 0x10: "Reading"],
            VCP.inputSource: [0x01: "VGA", 0x0F: "DP", 0x11: "HDMI 1", 0x12: "HDMI 2"],
        ],
        userColorPreset: 0x0B,
        // Measured 2026-11-05: in sRGB the monitor ignores brightness/contrast writes;
        // every picture mode (0xDC) and every other color preset accepts them.
        locks: [Lock(code: VCP.colorPreset, value: 0x01, locked: [VCP.brightness, VCP.contrast])])

    public static let all: [MonitorProfile] = [aoc24G1]

    public static func match(_ caps: Capabilities) -> MonitorProfile {
        guard let model = caps.model?.uppercased() else { return generic }
        return all.first { $0.capabilityModels.contains { $0.uppercased() == model } } ?? generic
    }

    /// MCCS 2.2 standard value names.
    static let standardLabels: [UInt8: [UInt16: String]] = [
        VCP.colorPreset: [0x01: "sRGB", 0x02: "Native", 0x03: "4000K", 0x04: "5000K", 0x05: "6500K",
                          0x06: "7500K", 0x07: "8200K", 0x08: "9300K", 0x09: "10000K", 0x0A: "11500K",
                          0x0B: "User 1", 0x0C: "User 2", 0x0D: "User 3"],
        VCP.inputSource: [0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2", 0x05: "Composite 1",
                          0x06: "Composite 2", 0x07: "S-Video 1", 0x08: "S-Video 2", 0x09: "Tuner 1",
                          0x0A: "Tuner 2", 0x0B: "Tuner 3", 0x0C: "Component 1", 0x0D: "Component 2",
                          0x0E: "Component 3", 0x0F: "DP 1", 0x10: "DP 2", 0x11: "HDMI 1", 0x12: "HDMI 2"],
        VCP.pictureMode: [0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed", 0x03: "Movie",
                          0x04: "User", 0x05: "Games", 0x06: "Sports", 0x07: "Professional",
                          0x08: "Standard (mid power)", 0x09: "Standard (low power)", 0x0A: "Demo",
                          0xF0: "Dynamic contrast"],
    ]
}
