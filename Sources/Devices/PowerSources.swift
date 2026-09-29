import Foundation
import IOKit.ps

struct BatteryPart: Equatable {
    var level: Int
    var charging: Bool
}

struct Accessory: Equatable {
    enum Kind { case earbuds, headphones, keyboard, mouse, trackpad, gamepad, other }

    var id: String
    var name: String
    var kind: Kind
    var productID: Int
    var lowWarnLevel: Int
    var left: BatteryPart?
    var right: BatteryPart?
    var batteryCase: BatteryPart?
    var single: BatteryPart?

    var isAudio: Bool { kind == .earbuds || kind == .headphones }

    var lowestLevel: Int? {
        [left, right, single].compactMap { $0?.level }.min()
    }
}

struct MacBattery: Equatable {
    var level: Int
    var charging: Bool
    var pluggedIn: Bool
}

enum PowerSources {
    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?

    private static let copyAll: CopyByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyByType.self)
    }()

    static func snapshot() -> (accessories: [Accessory], mac: MacBattery?) {
        guard let info = copyAll?(0)?.takeRetainedValue() ?? IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return ([], nil) }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }

        var mac: MacBattery?
        var groups: [String: Accessory] = [:]
        var order: [String] = []
        for d in descriptions {
            let type = d[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType {
                mac = MacBattery(level: capacity(d), charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                 pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
                continue
            }
            guard type == "Accessory Source", d[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let id = d["Group Identifier"] as? String ?? d["Accessory Identifier"] as? String ?? d[kIOPSNameKey] as? String ?? ""
            let category = d["Accessory Category"] as? String ?? ""
            let productID = d["Product ID"] as? Int ?? 0
            var accessory = groups[id] ?? Accessory(
                id: id, name: d[kIOPSNameKey] as? String ?? "", kind: kind(category: category, productID: productID),
                productID: productID, lowWarnLevel: d["Low Warn Level"] as? Int ?? 20)
            if groups[id] == nil { order.append(id) }

            switch d["Part Identifier"] as? String {
            case "Case":
                accessory.batteryCase = part(d)
            case "Combined":
                accessory.name = d[kIOPSNameKey] as? String ?? accessory.name
                accessory.kind = kind(category: category, productID: productID)
                accessory.lowWarnLevel = d["Low Warn Level"] as? Int ?? accessory.lowWarnLevel
                for sub in d["Combined Parts"] as? [[String: Any]] ?? [] {
                    switch sub["Part Identifier"] as? String {
                    case "Left": accessory.left = part(sub)
                    case "Right": accessory.right = part(sub)
                    default: break
                    }
                }
                if accessory.left == nil && accessory.right == nil { accessory.single = part(d) }
            case "Left":
                accessory.left = part(d)
            case "Right":
                accessory.right = part(d)
            default:
                accessory.name = d[kIOPSNameKey] as? String ?? accessory.name
                accessory.single = part(d)
            }
            groups[id] = accessory
        }
        return (order.compactMap { groups[$0] }, mac)
    }

    private static func capacity(_ d: [String: Any]) -> Int {
        let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        return max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
    }

    private static func part(_ d: [String: Any]) -> BatteryPart {
        BatteryPart(level: capacity(d), charging: d[kIOPSIsChargingKey] as? Bool ?? false)
    }

    private static func kind(category: String, productID: Int) -> Accessory.Kind {
        switch category {
        case "Headset", "Audio Battery Case":
            return AirPodsModel(productID: productID)?.isOverEar == true ? .headphones : .earbuds
        case "Headphones": return .headphones
        case "Keyboard": return .keyboard
        case "Mouse": return .mouse
        case "Trackpad": return .trackpad
        case "Game Controller", "Gamepad": return .gamepad
        default: return .other
        }
    }
}

enum AirPodsModel {
    case airpods, airpods3, airpods4, pro, pro2, max

    init?(productID: Int) {
        switch productID {
        case 0x2002, 0x200F: self = .airpods
        case 0x2013: self = .airpods3
        case 0x2019, 0x201B: self = .airpods4
        case 0x200E: self = .pro
        case 0x2014, 0x2024, 0x2027: self = .pro2
        case 0x200A, 0x201F: self = .max
        default: return nil
        }
    }

    var isOverEar: Bool { self == .max }

    var symbol: String {
        switch self {
        case .airpods: "airpods"
        case .airpods3, .airpods4: "airpods.gen3"
        case .pro, .pro2: "airpodspro"
        case .max: "airpodsmax"
        }
    }
}
