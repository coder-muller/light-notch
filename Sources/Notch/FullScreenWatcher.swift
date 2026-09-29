import AppKit

final class FullScreenWatcher {
    var onChange: ((Bool) -> Void)?
    var screen: () -> NSScreen?

    private(set) var isFullScreen = false
    private var pending: [DispatchWorkItem] = []

    init(screen: @escaping () -> NSScreen?) {
        self.screen = screen
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleCheck() }
        }
        check()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func scheduleCheck() {
        pending.forEach { $0.cancel() }
        pending = [0.3, 1.0].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.check() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func check() {
        let full = coversScreen()
        guard full != isFullScreen else { return }
        isFullScreen = full
        onChange?(full)
    }

    private func coversScreen() -> Bool {
        guard let screen = screen(), let primary = NSScreen.screens.first else { return false }
        let frame = screen.frame
        let bounds = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let minHeight = frame.height - screen.safeAreaInsets.top - 1
        let own = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? pid_t != own,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return false }
            return abs(rect.minX - bounds.minX) < 1 && abs(rect.width - bounds.width) < 1
                && abs(rect.maxY - bounds.maxY) < 1 && rect.height >= minHeight
        }
    }
}
