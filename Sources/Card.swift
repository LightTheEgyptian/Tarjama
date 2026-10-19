import AppKit
import SwiftUI
import Translation
import AVFoundation

// MARK: - Model

@MainActor
final class CardModel: ObservableObject {
    enum Phase: Equatable { case working, done, failed(String), permission, empty, info(String) }

    @Published var phase: Phase = .working
    @Published var source = ""
    @Published var translation = ""
    @Published var sourceCode = "en"
    @Published var targetCode = "ar"
    @Published var config: TranslationSession.Configuration?
    @Published var visible = false
    @Published var anchorBottom = false
    @Published var canReplace = false
    @Published var copied = false

    var onClose: (() -> Void)?
    var onReplace: ((String) -> Void)?
    private let speech = AVSpeechSynthesizer()

    func start(text: String, canReplace: Bool) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 4000 { t = String(t.prefix(4000)) }
        source = t
        self.canReplace = canReplace
        copied = false
        sourceCode = Langs.detect(t)
        targetCode = Langs.defaultTarget(for: sourceCode)
        translate()
    }

    func setTarget(_ code: String) {
        guard code != targetCode else { return }
        if code == sourceCode { sourceCode = targetCode }
        targetCode = code
        translate()
    }

    func translate() {
        translation = ""
        phase = .working
        if sourceCode == targetCode { translation = source; phase = .done; return }
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: sourceCode),
                                                    target: Locale.Language(identifier: targetCode))
        if config == next { config?.invalidate() } else { config = next }
    }

    func run(_ session: TranslationSession) async {
        let text = source, target = targetCode
        do {
            let response = try await session.translate(text)
            guard text == source, target == targetCode else { return }
            translation = response.targetText
            phase = .done
        } catch {
            guard text == source else { return }
            phase = .failed("Couldn't translate this. If it keeps happening, add \(Langs.name(sourceCode)) and \(Langs.name(targetCode)) in System Settings › General › Language & Region › Translation Languages.")
        }
    }

    func copy() {
        guard phase == .done else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(translation, forType: .string)
        copied = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.onClose?() }
    }

    func replace() {
        guard phase == .done else { return }
        onReplace?(translation)
    }

    func speak() {
        guard phase == .done else { return }
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        let u = AVSpeechUtterance(string: translation)
        u.voice = AVSpeechSynthesisVoice(language: Langs.voice(targetCode))
        speech.speak(u)
    }

    func stopSpeaking() { speech.stopSpeaking(at: .immediate) }
}

// MARK: - Views

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = Card.radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Pill-shaped choice; dims the instant it's pressed.
struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

struct ActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation { .spring(response: 0.32, dampingFraction: 1) }

    var body: some View {
        VStack(spacing: 0) {
            if model.anchorBottom { Spacer(minLength: 0) }
            card
                .scaleEffect(model.visible || reduceMotion ? 1 : 0.94,
                             anchor: model.anchorBottom ? .bottomLeading : .topLeading)
                .opacity(model.visible ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 1), value: model.visible)
            if !model.anchorBottom { Spacer(minLength: 0) }
        }
        .padding(Card.margin)
        .frame(width: Card.panelSize.width, height: Card.panelSize.height, alignment: .leading)
        .translationTask(model.config) { session in
            await model.run(session)
        }
        .onExitCommand { model.onClose?() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case .permission: permission
            case .empty: emptyState
            case .info(let message):
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                sourceText
                result
                actions
            }
        }
        .padding(16)
        .frame(width: Card.width, alignment: .leading)
        .background(VisualEffect())
        .overlay(RoundedRectangle(cornerRadius: Card.radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 10)
        .animation(spring, value: model.phase)
        .animation(spring, value: model.translation)
    }

    private var isNotice: Bool {
        switch model.phase {
        case .permission, .empty, .info: return true
        default: return false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(isNotice ? "Tarjama" : "\(Langs.name(model.sourceCode)) to")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isNotice {
                ForEach(Langs.targets) { lang in
                    Button(lang.native) { model.setTarget(lang.code) }
                        .buttonStyle(ChipStyle(selected: lang.code == model.targetCode))
                }
            }
        }
    }

    private var sourceText: some View {
        let rtl = Langs.isRTL(model.sourceCode)
        return Text(model.source)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    @ViewBuilder private var result: some View {
        let rtl = Langs.isRTL(model.targetCode)
        switch model.phase {
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .transition(.opacity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            let text = Text(model.translation)
                .font(.system(size: rtl ? 19 : 17, weight: .medium))
                .lineSpacing(rtl ? 5 : 3)
                .textSelection(.enabled)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if model.translation.count > 420 {
                    ScrollView { text }.frame(height: 230)
                } else {
                    text
                }
            }
            .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.copy() } label: {
                Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ActionStyle())
            .keyboardShortcut(.defaultAction)
            if model.canReplace {
                Button { model.replace() } label: { Label("Replace", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(ActionStyle())
            }
            Button { model.speak() } label: { Label("Speak", systemImage: "speaker.wave.2") }
                .buttonStyle(ActionStyle())
            Spacer()
            Text("return copies · esc closes")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .disabled(model.phase != .done)
        .opacity(model.phase == .done ? 1 : 0.5)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow Tarjama to read the text you select")
                .font(.system(size: 15, weight: .semibold))
            Text("Turn on Tarjama in System Settings › Privacy & Security › Accessibility. It only reads your selection when you double-tap the key.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("No permission needed for the other way: right-click selected text › Services › Translate with Tarjama.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") {
                    Selection.requestTrust()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    model.onClose?()
                }
                .buttonStyle(ActionStyle())
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
    }

    private var emptyState: some View {
        Text("Select some text first, then double-tap the key again.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Panel

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Card {
    static let shared = Card()
    static let width: CGFloat = 380
    static let radius: CGFloat = 18
    static let margin: CGFloat = 28
    static let panelSize = CGSize(width: 380 + 56, height: 560)

    let model = CardModel()
    private let panel: CardPanel
    private var outsideMonitor: Any?
    private var target: SelectionTarget?
    private var generation = 0
    private(set) var isOpen = false

    private init() {
        panel = CardPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        let host = NSHostingView(rootView: CardView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host

        model.onClose = { [weak self] in self?.close() }
        model.onReplace = { [weak self] text in
            guard let self else { return }
            let t = self.target
            Selection.replace(t, with: text) { self.close() }
        }
    }

    /// Places the card just under the selection (or the pointer), flipping above it near the bottom of the screen.
    private func position(near anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.panelSize
        var x = anchor.minX - Self.margin
        x = min(max(x, vf.minX - Self.margin + 8), vf.maxX - size.width + Self.margin - 8)
        let roomBelow = anchor.minY - vf.minY
        let flip = roomBelow < 260
        model.anchorBottom = flip
        let y = flip ? anchor.maxY + 8 - Self.margin : anchor.minY - 8 - size.height + Self.margin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func present(text: String, near anchor: NSRect, target: SelectionTarget?) {
        self.target = target
        model.start(text: text, canReplace: target != nil)
        show(near: anchor)
    }

    func presentPermission(near anchor: NSRect) {
        target = nil
        model.phase = .permission
        show(near: anchor)
    }

    func presentInfo(_ message: String, near anchor: NSRect) {
        target = nil
        model.phase = .info(message)
        show(near: anchor)
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.generation == g else { return }
            self.close()
        }
    }

    func presentEmpty(near anchor: NSRect) {
        target = nil
        model.phase = .empty
        show(near: anchor)
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.generation == g else { return }
            self.close()
        }
    }

    private func show(near anchor: NSRect) {
        generation += 1
        if !isOpen { model.visible = false }
        position(near: anchor)
        panel.makeKeyAndOrderFront(nil)
        isOpen = true
        DispatchQueue.main.async { self.model.visible = true }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let g = generation
        model.visible = false
        model.stopSpeaking()
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        }
    }
}
