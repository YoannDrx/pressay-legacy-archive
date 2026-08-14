import AppKit
import SwiftUI

enum HUDState: Equatable {
    case listening
    case transcribing
    case processing
    case delivering
    case success
    case copied
    case cancelled

    var title: String {
        switch self {
        case .listening: return "J’écoute…"
        case .transcribing: return "Transcription…"
        case .processing: return "Transformation…"
        case .delivering: return "Insertion…"
        case .success: return "Texte envoyé"
        case .copied: return "Texte copié"
        case .cancelled: return "Annulé"
        }
    }

    var icon: String {
        switch self {
        case .listening: return "waveform"
        case .transcribing: return "ellipsis"
        case .processing: return "wand.and.stars"
        case .delivering: return "arrow.down.doc"
        case .success: return "checkmark"
        case .copied: return "doc.on.clipboard"
        case .cancelled: return "xmark"
        }
    }

    var color: Color {
        switch self {
        case .listening: return .red
        case .transcribing: return .blue
        case .processing: return .purple
        case .delivering: return .teal
        case .success: return .green
        case .copied: return .orange
        case .cancelled: return .secondary
        }
    }
}

@MainActor
final class StatusHUDController: ObservableObject {
    static let shared = StatusHUDController()

    @Published private(set) var state: HUDState = .listening
    @Published private(set) var detail: String?
    @Published private(set) var listeningStartedAt: Date?
    @Published private(set) var audioLevel: Float = 0
    @Published var isUndoAvailable = false
    @Published private(set) var canRetranscribe = false
    @Published private(set) var retranscribeLabel = "Retranscrire"
    @Published private(set) var canCompareRawAndFinal = false
    @Published private(set) var canCorrect = false
    @Published private(set) var hudSize: HUDSize = .comfortable
    @Published private(set) var showsResultActions = true
    @Published private(set) var selectedModeID: UUID?
    @Published private(set) var modeOptions: [HUDModeOption] = []
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    private var onCopy: (() -> Void)?
    private var onRetranscribe: (() -> Void)?
    private var onCompareRawAndFinal: (() -> Void)?
    private var onCorrect: (() -> Void)?
    private var onSelectMode: ((UUID) -> Void)?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var terminalHardHideTask: Task<Void, Never>?
    private var autoHideRequested = false
    private var pointerIsInside = false

    func show(
        _ state: HUDState,
        detail: String? = nil,
        autoHide: Bool = false
    ) {
        hideTask?.cancel()
        terminalHardHideTask?.cancel()
        terminalHardHideTask = nil
        refreshPreferences()
        autoHideRequested = autoHide
        self.state = state
        self.detail = detail
        if state == .listening {
            listeningStartedAt = Date()
            isUndoAvailable = false
            canRetranscribe = false
            canCompareRawAndFinal = false
            canCorrect = false
            retranscribeLabel = "Retranscrire"
            onCopy = nil
            onRetranscribe = nil
            onCompareRawAndFinal = nil
            onCorrect = nil
        } else if state == .success || state == .copied || state == .cancelled {
            listeningStartedAt = nil
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(panelSize)
        position(panel)
        panel.orderFrontRegardless()

        scheduleAutoHideIfNeeded()
    }

    func updateAudioLevel(_ level: Float) {
        audioLevel = max(0, min(1, level))
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        terminalHardHideTask?.cancel()
        terminalHardHideTask = nil
        autoHideRequested = false
        pointerIsInside = false
        panel?.orderOut(nil)
    }

    func setPointerInside(_ isInside: Bool) {
        pointerIsInside = isInside
        // A terminal result is informational: hovering it must not leave the
        // HUD pinned on screen after the text has already been delivered.
        if state == .success || state == .copied || state == .cancelled {
            scheduleAutoHideIfNeeded()
            return
        }
        if isInside {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleAutoHideIfNeeded()
        }
    }

    func configureResultActions(
        canRetranscribe: Bool,
        retranscribeLabel: String,
        canCompareRawAndFinal: Bool,
        canCorrect: Bool,
        onCopy: @escaping () -> Void,
        onRetranscribe: @escaping () -> Void,
        onCompareRawAndFinal: @escaping () -> Void,
        onCorrect: @escaping () -> Void
    ) {
        self.canRetranscribe = canRetranscribe
        self.retranscribeLabel = retranscribeLabel
        self.canCompareRawAndFinal = canCompareRawAndFinal
        self.canCorrect = canCorrect
        self.onCopy = onCopy
        self.onRetranscribe = onRetranscribe
        self.onCompareRawAndFinal = onCompareRawAndFinal
        self.onCorrect = onCorrect
    }

    func configureModeSelection(
        currentModeID: UUID,
        options: [HUDModeOption],
        onSelect: @escaping (UUID) -> Void
    ) {
        selectedModeID = currentModeID
        modeOptions = options
        onSelectMode = onSelect
    }

    func selectMode(_ id: UUID) {
        selectedModeID = id
        onSelectMode?(id)
    }

    func copyResult() {
        onCopy?()
    }

    func retranscribeResult() {
        onRetranscribe?()
    }

    func compareRawAndFinalResult() {
        onCompareRawAndFinal?()
    }

    func correctResult() {
        onCorrect?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: StatusHUDView(controller: self))
        return panel
    }

    private func scheduleAutoHideIfNeeded() {
        guard autoHideRequested else { return }
        scheduleTerminalHardHideIfNeeded()
        let isTerminal = state == .success || state == .copied
            || state == .cancelled
        guard isTerminal || !pointerIsInside else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            let delay: Duration
            if self?.state == .success || self?.state == .copied
                || (self?.state == .cancelled && self?.canRetranscribe == true) {
                guard let resultDelay = self?.resultDuration.delay else { return }
                delay = resultDelay
            } else {
                delay = .milliseconds(600)
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func scheduleTerminalHardHideIfNeeded() {
        guard terminalHardHideTask == nil,
              resultDuration.delay != nil,
              state == .success || state == .copied else {
            return
        }
        // Hover still gives time to use result actions, but a completed HUD
        // must never remain stuck forever because an enter/exit event was
        // missed while the panel was resized or repositioned.
        terminalHardHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin: NSPoint
        switch hudPosition {
        case .bottomCenter:
            origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 72
            )
        case .topCenter:
            origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - panel.frame.height - 54
            )
        case .pointer:
            origin = NSPoint(
                x: min(
                    max(pointer.x + 14, visible.minX + 8),
                    visible.maxX - panel.frame.width - 8
                ),
                y: min(
                    max(pointer.y - panel.frame.height - 18, visible.minY + 8),
                    visible.maxY - panel.frame.height - 8
                )
            )
        }
        panel.setFrameOrigin(origin)
    }

    private var hudPosition: HUDPosition {
        HUDPosition(
            rawValue: UserDefaults.standard.string(forKey: Constants.hudPositionKey) ?? ""
        ) ?? .bottomCenter
    }

    private var resultDuration: HUDResultDuration {
        HUDResultDuration(
            rawValue: UserDefaults.standard.string(
                forKey: Constants.hudResultDurationKey
            ) ?? ""
        ) ?? .fast
    }

    fileprivate var panelSize: NSSize {
        if hudSize == .compact {
            return NSSize(width: 380, height: 52)
        }
        return NSSize(width: 430, height: 60)
    }

    private func refreshPreferences() {
        hudSize = HUDSize(
            rawValue: UserDefaults.standard.string(forKey: Constants.hudSizeKey) ?? ""
        ) ?? .comfortable
        showsResultActions = UserDefaults.standard.object(
            forKey: Constants.hudShowsResultActionsKey
        ) as? Bool ?? true
    }

    func elapsedText(at date: Date) -> String {
        guard let listeningStartedAt else { return "" }
        let elapsed = max(0, Int(date.timeIntervalSince(listeningStartedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

extension StatusHUDController: HUDPresenting {}

private struct StatusHUDView: View {
    @ObservedObject var controller: StatusHUDController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: controller.hudSize == .compact ? 8 : 10) {
            ZStack {
                Circle()
                    .fill(controller.state.color.opacity(0.16))
                    .frame(
                        width: controller.hudSize == .compact ? 26 : 30,
                        height: controller.hudSize == .compact ? 26 : 30
                    )
                Image(systemName: controller.state.icon)
                    .font(
                        .system(
                            size: controller.hudSize == .compact ? 11 : 13,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(controller.state.color)
                    .symbolEffect(
                        .pulse,
                        isActive: !reduceMotion
                            && (controller.state == .transcribing
                                || controller.state == .processing
                                || controller.state == .delivering)
                    )
                    .symbolEffect(
                        .variableColor.iterative,
                        isActive: !reduceMotion
                            && controller.state == .listening
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.title)
                    .font(
                        .system(
                            size: controller.hudSize == .compact ? 11 : 12,
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if controller.state == .listening {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(controller.elapsedText(at: context.date))
                        }
                    }
                    if let detail = controller.detail {
                        Text(detail)
                            .lineLimit(1)
                    }
                }
                .font(
                    .system(
                        size: controller.hudSize == .compact ? 8 : 9,
                        design: .rounded
                    )
                )
                .foregroundStyle(.secondary)

                if controller.state == .listening {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.secondary.opacity(0.16))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(controller.state.color)
                                    .frame(
                                        width: max(
                                            2,
                                            proxy.size.width * CGFloat(controller.audioLevel)
                                        )
                                    )
                            }
                    }
                    .frame(height: 2)
                    .accessibilityElement()
                    .accessibilityLabel("Niveau du microphone")
                    .accessibilityValue(
                        "\(Int(controller.audioLevel * 100)) pour cent"
                    )
                }

            }
            Spacer(minLength: 0)
            if controller.state == .listening,
               let selectedModeID = controller.selectedModeID,
               controller.modeOptions.count > 1 {
                Menu {
                    ForEach(controller.modeOptions) { mode in
                        Button {
                            controller.selectMode(mode.id)
                        } label: {
                            Label(mode.name, systemImage: mode.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let mode = controller.modeOptions.first(where: {
                            $0.id == selectedModeID
                        }) {
                            Image(systemName: mode.symbolName)
                            Text(mode.name)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.primary.opacity(0.07), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Changer le mode de cette dictée")
            }
            if controller.state == .success || controller.state == .copied
                || (controller.state == .cancelled && controller.canRetranscribe) {
                HStack(spacing: 7) {
                    if controller.showsResultActions {
                        if controller.state != .cancelled {
                            Button("Copier", action: controller.copyResult)
                                .accessibilityHint(
                                    "Copie le résultat visible dans le presse-papiers"
                                )
                        }
                        if controller.canRetranscribe {
                            Button(
                                controller.retranscribeLabel,
                                action: controller.retranscribeResult
                            )
                                .accessibilityHint(
                                    "Relance la transcription depuis l’audio temporaire"
                                )
                        }
                        if controller.canCompareRawAndFinal {
                            Button("Brut/Final", action: controller.compareRawAndFinalResult)
                                .accessibilityLabel(
                                    "Comparer la transcription brute et le texte final"
                                )
                        }
                        if controller.canCorrect {
                            Button("Corriger", action: controller.correctResult)
                                .accessibilityHint(
                                    "Dicte une correction pour la dernière insertion"
                                )
                        }
                        if controller.isUndoAvailable {
                            Button("Annuler") {
                                controller.onUndo?()
                            }
                            .accessibilityLabel("Annuler la dernière insertion")
                        }
                    }
                    dismissButton(
                        help: "Fermer",
                        accessibilityLabel: "Fermer le résultat"
                    )
                }
                .font(
                    .system(
                        size: controller.hudSize == .compact ? 8 : 9,
                        weight: .semibold
                    )
                )
                .buttonStyle(.plain)
            } else if controller.state == .listening
                        || controller.state == .transcribing
                        || controller.state == .processing
                        || controller.state == .delivering {
                Button(action: { controller.onCancel?() }) {
                    dismissButtonLabel
                }
                .buttonStyle(.plain)
                .help("Annuler")
                .accessibilityLabel(
                    controller.state == .listening
                        ? "Annuler l’enregistrement"
                        : "Annuler le traitement"
                )
            }
        }
        .padding(.horizontal, controller.hudSize == .compact ? 10 : 12)
        .frame(
            width: controller.panelSize.width,
            height: controller.panelSize.height
        )
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(
                cornerRadius: controller.hudSize == .compact ? 13 : 15,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: controller.hudSize == .compact ? 13 : 15,
                style: .continuous
            )
                .stroke(
                    differentiateWithoutColor
                        ? Color.primary.opacity(0.5)
                        : Color.white.opacity(0.14),
                    lineWidth: differentiateWithoutColor ? 1.5 : 0.5
                )
        )
        .onHover(perform: controller.setPointerInside)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pressay. \(controller.state.title)")
    }

    private var dismissButtonLabel: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .background(.primary.opacity(0.07), in: Circle())
    }

    private func dismissButton(
        help: String,
        accessibilityLabel: String
    ) -> some View {
        Button(action: controller.hide) {
            dismissButtonLabel
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
