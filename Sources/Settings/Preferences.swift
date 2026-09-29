import Foundation

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("LightNotchPreferencesDidChange")

    enum AccentSource: String, CaseIterable {
        case cover, spotify, white
    }

    enum Equalizer: String, CaseIterable {
        case live, animated, hidden
    }

    enum Duration: String, CaseIterable {
        case short, medium, long
    }

    private let defaults = UserDefaults.standard

    private init() {}

    var accent: AccentSource {
        get { value("accent", default: .cover) }
        set { set("accent", newValue.rawValue) }
    }

    var equalizer: Equalizer {
        get { value("equalizer", default: .live) }
        set { set("equalizer", newValue.rawValue) }
    }

    var hoverBounce: Bool {
        get { bool("hoverBounce", default: true) }
        set { set("hoverBounce", newValue) }
    }

    var trackNotice: Bool {
        get { bool("trackNotice", default: true) }
        set { set("trackNotice", newValue) }
    }

    var scrollVolume: Bool {
        get { bool("scrollVolume", default: true) }
        set { set("scrollVolume", newValue) }
    }

    var keepWhilePaused: Bool {
        get { bool("keepWhilePaused", default: true) }
        set { set("keepWhilePaused", newValue) }
    }

    var openOnHover: Bool {
        get { bool("openOnHover", default: false) }
        set { set("openOnHover", newValue) }
    }

    var noticeDuration: Duration {
        get { value("noticeDuration", default: .medium) }
        set { set("noticeDuration", newValue.rawValue) }
    }

    var peekDelay: TimeInterval {
        switch noticeDuration {
        case .short: 1.5
        case .medium: 2.5
        case .long: 4
        }
    }

    var volumeDelay: TimeInterval {
        switch noticeDuration {
        case .short: 0.8
        case .medium: 1.2
        case .long: 2
        }
    }

    private func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Preferences.didChange, object: self)
    }
}
