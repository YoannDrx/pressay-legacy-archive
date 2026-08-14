import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var hasAPIKey: Bool
    @Published var hasMicrophonePermission = false
    @Published var hasAccessibilityPermission =
        DistributionChannel.current.supportsAccessibility
            && TextInjector.hasAccessibilityPermission()

    let audioRecorder: AudioRecorder
    let keyboardService: ShortcutRouter
    let sessionCoordinator: SessionCoordinator

    private var observations = Set<AnyCancellable>()

    var isRecording: Bool { sessionCoordinator.isRecording }
    var isTranscribing: Bool { sessionCoordinator.isTranscribing }
    var pendingCount: Int { sessionCoordinator.pendingCount }
    var lastError: String? { sessionCoordinator.lastError }
    var lastNotice: String? { sessionCoordinator.lastNotice }
    var lastTranscriptionModel: String? {
        sessionCoordinator.lastTranscriptionModel
    }

    convenience init() {
        let contextCapturer: ContextCapturing = AccessibilityContextService.shared
        self.init(
            audioRecorder: AudioRecorder(),
            keyboardService: ShortcutRouter(),
            transcriber: TranscriptionService.shared,
            textProcessor: OpenAITextProcessingService.shared,
            cloudConsent: CloudConsentController.shared,
            transcriptionRouter: TranscriptionRouter(
                registrations: SystemProviderRegistry
                    .transcriptionRegistrations(
                        openAI: TranscriptionService.shared,
                        whisperKit: WhisperKitTranscriptionService.shared
                    )
            ),
            processingRouter: ProcessingRouter(
                registrations: SystemProviderRegistry
                    .processingRegistrations(
                        openAI: OpenAITextProcessingService.shared
                    )
            ),
            contextCapturer: contextCapturer,
            modeResolver: ModeResolverService.shared,
            textDeliverer: TextInjector.shared,
            previewPresenter: TextPreviewController.shared,
            history: HistoryService.shared,
            inbox: VoiceInboxService.shared,
            sounds: SoundService.shared,
            metrics: PerformanceMetricsService.shared,
            hud: StatusHUDController.shared
        )
        if !Constants.isRunningTests,
           UserDefaults.standard.string(forKey: Constants.transcriptionEngineKey)
                == TranscriptionEngine.whisperKit.rawValue {
            Task {
                try? await WhisperKitTranscriptionService.shared.prepare()
            }
        }
    }

    init(
        audioRecorder: AudioRecorder,
        keyboardService: ShortcutRouter,
        transcriber: SpeechTranscribing,
        textProcessor: TextProcessing,
        cloudConsent: CloudConsentRequesting = AllowingCloudConsentService(),
        transcriptionRouter: TranscriptionRouting? = nil,
        processingRouter: ProcessingRouting? = nil,
        contextCapturer: ContextCapturing,
        modeResolver: ModeResolving,
        textDeliverer: TextDelivering,
        previewPresenter: TextPreviewPresenting,
        history: HistoryRepository,
        inbox: VoiceInboxRepository? = nil,
        sounds: SoundFeedback,
        metrics: MetricsRecording,
        hud: HUDPresenting
    ) {
        self.audioRecorder = audioRecorder
        self.keyboardService = keyboardService
        // A Keychain read can wait for SecurityAgent. Keep it away from the
        // main-thread construction of the SwiftUI application graph.
        self.hasAPIKey = false
        self.hasMicrophonePermission = audioRecorder.hasPermission
        self.sessionCoordinator = SessionCoordinator(
            audioCapturer: audioRecorder,
            transcriber: transcriber,
            textProcessor: textProcessor,
            cloudConsent: cloudConsent,
            transcriptionRouter: transcriptionRouter,
            processingRouter: processingRouter,
            contextCapturer: contextCapturer,
            modeResolver: modeResolver,
            textDeliverer: textDeliverer,
            previewPresenter: previewPresenter,
            history: history,
            inbox: inbox,
            sounds: sounds,
            metrics: metrics,
            hud: hud
        )

        if !Constants.isRunningTests {
            Task { [weak self] in
                let isReady = await Task.detached(priority: .utility) {
                    transcriber.isReady
                }.value
                self?.hasAPIKey = isReady
            }
        }

        sessionCoordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observations)

        keyboardService.onShortcutPressed = { [weak self] in
            Task { @MainActor in
                self?.shortcutPressed()
            }
        }
        keyboardService.onShortcutReleased = { [weak self] in
            Task { @MainActor in
                self?.sessionCoordinator.stopCaptureAndQueue()
            }
        }
        keyboardService.onCancel = { [weak self] in
            Task { @MainActor in
                self?.sessionCoordinator.cancelCurrentSession()
            }
        }
        keyboardService.onTransformationShortcut = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.sessionCoordinator.preparingIntent == .transformSelection {
                    self.sessionCoordinator.cancelCurrentSession()
                } else if self.sessionCoordinator.captureSession?.intent == .transformSelection {
                    self.sessionCoordinator.stopCaptureAndQueue()
                } else if self.sessionCoordinator.captureSession == nil {
                    self.sessionCoordinator.startCapture(intent: .transformSelection)
                }
            }
        }
        keyboardService.onCorrectionShortcut = { [weak self] in
            Task { @MainActor in
                self?.sessionCoordinator.startCorrectionCapture()
            }
        }
        keyboardService.onModeShortcut = { [weak self] modeID in
            Task { @MainActor in
                guard let self else { return }
                if self.sessionCoordinator.captureSession == nil {
                    self.sessionCoordinator.startCapture(
                        intent: .dictate,
                        explicitModeID: modeID
                    )
                }
            }
        }
        keyboardService.onDictationHotKey = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.sessionCoordinator.captureSession == nil {
                    self.sessionCoordinator.startCapture()
                } else {
                    self.sessionCoordinator.stopCaptureAndQueue()
                }
            }
        }
        keyboardService.onHandsFreeChanged = { [weak self] active in
            guard active else { return }
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
        hud.onCancel = { [weak self] in
            self?.sessionCoordinator.cancelCurrentSession()
        }
        if DistributionChannel.current.supportsGlobalShortcuts {
            keyboardService.startMonitoring()
        }
    }

    func refreshPermissions() {
        audioRecorder.refreshPermission()
        hasMicrophonePermission = audioRecorder.hasPermission
        hasAccessibilityPermission =
            DistributionChannel.current.supportsAccessibility
                && TextInjector.hasAccessibilityPermission()
    }

    func requestMicrophonePermission() {
        audioRecorder.requestPermission { [weak self] granted in
            self?.hasMicrophonePermission = granted
        }
    }

    func requestAccessibilityPermission() {
        guard DistributionChannel.current.supportsAccessibility else { return }
        TextInjector.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func cancelTranscription() {
        sessionCoordinator.cancelProcessing()
    }

    func toggleCaptureFromInterface() {
        if isRecording {
            sessionCoordinator.stopCaptureAndQueue()
        } else if sessionCoordinator.captureSession == nil {
            sessionCoordinator.startCapture()
        }
    }

    func copyLastTranscription() {
        guard let text = HistoryService.shared.entries.first?.text else { return }
        TextInjector.shared.copyToPasteboard(text)
    }

    func updateAPIKey(_ key: String) async -> Bool {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = await TranscriptionService.shared.validateAPIKey(cleanKey)
        guard isValid, KeychainHelper.shared.save(apiKey: cleanKey) else {
            return false
        }
        hasAPIKey = true
        sessionCoordinator.clearMessages()
        return true
    }

    func clearAPIKey() {
        KeychainHelper.shared.delete()
        hasAPIKey = false
        sessionCoordinator.clearMessages()
    }

    private func shortcutPressed() {
        let mode = ActivationMode(
            rawValue: UserDefaults.standard.string(forKey: Constants.activationModeKey) ?? ""
        ) ?? ActivationMode(rawValue: Constants.defaultActivationMode) ?? .hold
        if mode == .toggle, isRecording {
            sessionCoordinator.stopCaptureAndQueue()
        } else {
            sessionCoordinator.startCapture()
        }
    }
}
