import AppKit

/// Detects a quick double-tap of a modifier key (Command by default) by
/// watching the keyboard's modifier state.
final class DoubleTap {
    enum Key: String, CaseIterable {
        case command, shift
        var flag: NSEvent.ModifierFlags {
            switch self { case .command: return .command; case .shift: return .shift }
        }
        var title: String {
            switch self { case .command: return "Double-tap Command (⌘ ⌘)"; case .shift: return "Double-tap Shift (⇧ ⇧)" }
        }
    }

    var onTrigger: (() -> Void)?
    var key: Key {
        get { Key(rawValue: UserDefaults.standard.string(forKey: "tapKey") ?? "") ?? .command }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tapKey") }
    }

    private var timer: Timer?
    private var wasDown = false
    private var downAt: TimeInterval = 0
    private var lastTap: TimeInterval = 0
    private var dirty = false
    private var keyMonitor: Any?

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Any real key press in between (like ⌘C) cancels the gesture.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.dirty = true
            self?.lastTap = 0
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let all: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = NSEvent.modifierFlags.intersection(all)
        let flag = key.flag
        let down = mods == flag
        if !mods.subtracting(flag).isEmpty { dirty = true; lastTap = 0 }

        if down && !wasDown {
            downAt = now
            dirty = false
        } else if !down && wasDown {
            let quick = now - downAt < 0.3
            if quick && !dirty && mods.isEmpty && NSEvent.pressedMouseButtons == 0 {
                if lastTap > 0 && now - lastTap < 0.42 {
                    lastTap = 0
                    onTrigger?()
                } else {
                    lastTap = now
                }
            } else {
                lastTap = 0
            }
        }
        wasDown = down
    }
}
