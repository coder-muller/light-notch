import Foundation
import IOKit.ps
import notify

final class DeviceMonitor {
    enum Event {
        case connected(Accessory)
        case lowBattery(Accessory)
        case charging(MacBattery)
    }

    var onEvent: ((Event) -> Void)?

    private static let notifications = [
        "com.apple.system.accpowersources.attach",
        "com.apple.system.accpowersources.source",
        "com.apple.system.powersources.source",
    ]
    private static let pollInterval: TimeInterval = 10

    private var tokens: [Int32] = []
    private var timer: Timer?
    private var accessories: [String: Accessory] = [:]
    private var warned: Set<String> = []
    private var mac: MacBattery?
    private var primed = false

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        primed = false
        for name in DeviceMonitor.notifications {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, .main, { [weak self] _ in self?.refresh() }) == NOTIFY_STATUS_OK {
                tokens.append(token)
            }
        }
        let timer = Timer(timeInterval: DeviceMonitor.pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tokens.forEach { notify_cancel($0) }
        tokens.removeAll()
        accessories.removeAll()
        warned.removeAll()
        mac = nil
    }

    private func refresh() {
        let snapshot = PowerSources.snapshot()
        var current: [String: Accessory] = [:]
        for accessory in snapshot.accessories { current[accessory.id] = accessory }

        if primed {
            for accessory in snapshot.accessories where accessories[accessory.id] == nil && accessory.isAudio {
                onEvent?(.connected(accessory))
            }
            if let new = snapshot.mac, let old = mac, new.pluggedIn, !old.pluggedIn {
                onEvent?(.charging(new))
            }
        }

        for accessory in snapshot.accessories {
            guard let level = accessory.lowestLevel else { continue }
            let charging = [accessory.left, accessory.right, accessory.single].contains { $0?.charging == true }
            if level <= accessory.lowWarnLevel, !charging {
                if !warned.contains(accessory.id) {
                    warned.insert(accessory.id)
                    if primed { onEvent?(.lowBattery(accessory)) }
                }
            } else if level > accessory.lowWarnLevel + 5 || charging {
                warned.remove(accessory.id)
            }
        }
        warned.formIntersection(current.keys)

        accessories = current
        mac = snapshot.mac
        primed = true
    }
}
