import AppKit
import ApplicationServices

/// Where the selected text came from, so Replace can write back into it.
struct SelectionTarget {
    let element: AXUIElement
}

enum Selection {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Reads the selected text in whatever app is in front: first through
    /// Accessibility, then (for apps that don't expose it) by a quick copy.
    static func read(_ done: @escaping (String?, SelectionTarget?, NSRect?) -> Void) {
        if let el = focusedElement() {
            var sel: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
               let s = sel as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                done(s, SelectionTarget(element: el), bounds(of: el))
                return
            }
        }
        copyFallback { done($0, nil, nil) }
    }

    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
    }

    /// Screen rectangle of the selection (Cocoa coordinates), when the app reports it.
    private static func bounds(of el: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &boundsRef) == .success,
              let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: copy / paste fallbacks

    private typealias Saved = [[(NSPasteboard.PasteboardType, Data)]]

    private static func save(_ pb: NSPasteboard) -> Saved {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: Saved) {
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let i = NSPasteboardItem()
            for (t, d) in pairs { i.setData(d, forType: t) }
            return i
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func postCommand(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func copyFallback(_ done: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = save(pb)
        let before = pb.changeCount
        postCommand(8) // C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pb.changeCount != before else { done(nil); return }
            let text = pb.string(forType: .string)
            restore(pb, saved)
            done(text)
        }
    }

    /// Writes the translation over the original selection.
    static func replace(_ target: SelectionTarget?, with text: String, beforePaste: @escaping () -> Void) {
        if let t = target,
           AXUIElementSetAttributeValue(t.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            beforePaste()
            return
        }
        beforePaste()
        let pb = NSPasteboard.general
        let saved = save(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postCommand(9) // V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore(pb, saved) }
        }
    }
}
