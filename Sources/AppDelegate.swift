import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tap = DoubleTap()
    private let services = ServiceProvider()
    private var loginItem: NSMenuItem!
    private var keyMenu = NSMenu()
    private var accessItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Tarjama")
        img?.isTemplate = true
        statusItem.button?.image = img
        buildMenu()

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        tap.onTrigger = { [weak self] in self?.translateSelection() }
        tap.start()

        // Ask for Accessibility once at launch, then confirm the moment it's switched on.
        if !Selection.trusted {
            Selection.requestTrust()
            watchForTrust()
        }

        if !UserDefaults.standard.bool(forKey: "seenIntro") {
            UserDefaults.standard.set(true, forKey: "seenIntro")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showHelp() }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Translate Selection", action: #selector(translateFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcut.submenu = keyMenu
        menu.addItem(shortcut)
        accessItem = NSMenuItem(title: "Allow Accessibility Access…", action: #selector(askAccess), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "How to Use…", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tarjama", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessItem.isHidden = Selection.trusted
        keyMenu.removeAllItems()
        for k in DoubleTap.Key.allCases {
            let item = NSMenuItem(title: k.title, action: #selector(pickKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            item.state = k == tap.key ? .on : .off
            keyMenu.addItem(item)
        }
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let k = DoubleTap.Key(rawValue: raw) { tap.key = k }
    }

    @objc private func translateFromMenu() {
        // let the menu close so focus returns to the app with the selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.translateSelection() }
    }

    private func pointerAnchor() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 6, width: 1, height: 12)
    }

    @MainActor func translateSelection() {
        let card = Card.shared
        if card.isOpen { card.close(); return }
        guard Selection.trusted else {
            card.presentPermission(near: pointerAnchor())
            watchForTrust()
            return
        }
        Selection.read { text, target, bounds in
            let anchor = bounds ?? self.pointerAnchor()
            guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                card.presentEmpty(near: anchor)
                return
            }
            card.present(text: t, near: anchor, target: target)
        }
    }

    @objc private func askAccess() {
        Selection.requestTrust()
        watchForTrust()
    }

    private var trustTimer: Timer?

    /// Polls until Accessibility is granted, then says so right away.
    private func watchForTrust() {
        guard trustTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard Selection.trusted else { return }
            timer.invalidate()
            self?.trustTimer = nil
            DispatchQueue.main.async {
                guard let s = NSScreen.main else { return }
                let f = s.visibleFrame
                Card.shared.presentInfo("Tarjama is ready. Select text anywhere and tap ⌘ twice.",
                                        near: NSRect(x: f.midX - 190, y: f.maxY - 20, width: 1, height: 1))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "How to use Tarjama"
        a.informativeText = """
        Select text in any app, then tap Command twice quickly (⌘ ⌘). A card appears under your selection with the translation.

        Arabic becomes English, English becomes Arabic. Pick English, العربية or Français at the top to change it.

        Return copies it. Replace swaps your selected text for the translation. Speak reads it aloud. Esc closes.

        The first time, allow Tarjama in System Settings › Privacy & Security › Accessibility so it can read your selection.

        No permission? Right-click selected text › Services › Translate with Tarjama.

        Translation runs on your Mac with Apple's built-in translator. Nothing is sent online.
        """
        a.addButton(withTitle: "Got it")
        if !Selection.trusted { a.addButton(withTitle: "Allow Access…") }
        if a.runModal() == .alertSecondButtonReturn { Selection.requestTrust() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}

/// Right-click › Services › Translate with Tarjama (works without Accessibility access).
final class ServiceProvider: NSObject {
    @objc func translateText(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        DispatchQueue.main.async {
            let p = NSEvent.mouseLocation
            Card.shared.present(text: text, near: NSRect(x: p.x, y: p.y - 6, width: 1, height: 12), target: nil)
        }
    }
}
