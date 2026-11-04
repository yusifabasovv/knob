import Foundation

/// Remembers each monitor model's capabilities string between launches, so startup doesn't
/// spend ~0.75 s (14 DDC round trips on the AOC 24G1WG4) re-reading something that never changes.
///
/// Keyed by the display's EDID UUID, which identifies the model, not the individual unit:
/// identical monitors report identical capabilities. Stores the raw string, so parser changes
/// apply to cached entries too.
public struct CapabilitiesCache {
    static let keyPrefix = "capabilities."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(_ displayID: String) -> String? {
        guard !displayID.isEmpty, let raw = defaults.string(forKey: Self.keyPrefix + displayID), !raw.isEmpty
        else { return nil }
        return raw
    }

    public func save(_ raw: String, for displayID: String) {
        guard !displayID.isEmpty, !raw.isEmpty else { return }
        defaults.set(raw, forKey: Self.keyPrefix + displayID)
    }

    public func remove(_ displayID: String) {
        guard !displayID.isEmpty else { return }
        defaults.removeObject(forKey: Self.keyPrefix + displayID)
    }
}
