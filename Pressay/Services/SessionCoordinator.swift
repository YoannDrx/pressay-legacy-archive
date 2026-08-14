import Foundation
import OSLog

struct SessionTimeoutPolicy {
    var cloudTranscription: TimeInterval = 30
    var localPreparation: TimeInterval = 75
    var localTranscription: TimeInterval = 75
    var textProcessing: TimeInterval = 45
}

@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var captureSession: VoiceSession?
    @Published private(set) var processingSession: VoiceSession?
    @Published private(set) var lastSession: VoiceSession?
    @Published private(set) var pendingPreview: TextPreview?
    @Published private(set) var preparingIntent: VoiceIntent?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastNotice: String?
    @Published private(set) var lastDeliveryReceipt: DeliveryReceipt?
    @Published private(set) var lastTranscriptionModel: String?

    var isRecording: Bool { captureSession?.state == .capturing }
    var isPreparingCapture: Bool { preparingIntent != nil }
    var isTranscribing: Bool {
        guard let processingSession else { return false }
        return processingSession.state == .transcribing
            || processingSession.state == .processing
            || processingSession.state == .delivering
    }

    private struct PendingSession {
        var session: VoiceSession
        let audio: CapturedAudio
        let target: TextInjectionTarget?
        let mode: ModeDefinition
        let deliveryPolicy: ApplicationDeliveryPolicy
        let replayOriginalText: String?
        let transcriber: any SpeechTranscribing
        let preparationTask: Task<Void, Error>?
    }

    private struct ReplayDescriptor {
        let target: TextInjectionTarget?
        let mode: ModeDefinition
        let context: ContextSnapshot
        let duration: TimeInterval
        let fileExtension: String
        let deliveryPolicy: ApplicationDeliveryPolicy
        let transcriber: any SpeechTranscribing
    }

    private struct PreviewDelivery {
        var session: VoiceSession
        let target: TextInjectionTarget?
        let rawText: String
        let providerIdentifier: String
        let transcriptionProviderIdentifier: String
        let contextManifest: [String]
        let audioDuration: TimeInterval
    }

    private let audioCapturer: AudioCapturing
    private let transcriber: SpeechTranscribing
    private let textProcessor: TextProcessing
    private let transcriptionRouter: TranscriptionRouting?
    private let processingRouter: ProcessingRouting?
    private let capabilities: CapabilityMatrix
    private let cloudConsent: CloudConsentRequesting
    private let contextCapturer: ContextCapturing
    private let modeResolver: ModeResolving
    private let textDeliverer: TextDelivering
    private let previewPresenter: TextPreviewPresenting
    private let history: HistoryRepository
    private let inbox: VoiceInboxRepository?
    private let sounds: SoundFeedback
    private let metrics: MetricsRecording
    private let hud: HUDPresenting
    private let replayBuffer: ReplayBuffer
    private let timeoutPolicy: SessionTimeoutPolicy
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "fr.yodev.pressay",
        category: "SessionPerformance"
    )

    private var processingTask: Task<Void, Never>?
    private var captureTarget: TextInjectionTarget?
    private var captureMode: ModeDefinition?
    private var captureDeliveryPolicy: ApplicationDeliveryPolicy?
    private var captureTranscriber: (any SpeechTranscribing)?
    private var captureTranscriberPreparationTask: Task<Void, Error>?
    private var previewDelivery: PreviewDelivery?
    private var capturePreparationTask: Task<Void, Never>?
    private var targetRecoveryTask: Task<Void, Never>?
    private var replayDescriptors: [UUID: ReplayDescriptor] = [:]
    private var networkMetricsBySession: [UUID: [NetworkRequestMetrics]] = [:]

    init(
        audioCapturer: AudioCapturing,
        transcriber: SpeechTranscribing,
        textProcessor: TextProcessing,
        cloudConsent: CloudConsentRequesting = AllowingCloudConsentService(),
        transcriptionRouter: TranscriptionRouting? = nil,
        processingRouter: ProcessingRouting? = nil,
        capabilities: CapabilityMatrix = .current,
        contextCapturer: ContextCapturing,
        modeResolver: ModeResolving,
        textDeliverer: TextDelivering,
        previewPresenter: TextPreviewPresenting,
        history: HistoryRepository,
        inbox: VoiceInboxRepository? = nil,
        sounds: SoundFeedback,
        metrics: MetricsRecording,
        hud: HUDPresenting,
        replayBuffer: ReplayBuffer? = nil,
        timeoutPolicy: SessionTimeoutPolicy = SessionTimeoutPolicy()
    ) {
        self.audioCapturer = audioCapturer
        self.transcriber = transcriber
        self.textProcessor = textProcessor
        self.transcriptionRouter = transcriptionRouter
        self.processingRouter = processingRouter
        self.capabilities = capabilities
        self.cloudConsent = cloudConsent
        self.contextCapturer = contextCapturer
        self.modeResolver = modeResolver
        self.textDeliverer = textDeliverer
        self.previewPresenter = previewPresenter
        self.history = history
        self.inbox = inbox
        self.sounds = sounds
        self.metrics = metrics
        self.hud = hud
        self.replayBuffer = replayBuffer ?? InMemoryReplayBuffer.shared
        self.timeoutPolicy = timeoutPolicy

        audioCapturer.onLevelUpdate = { [weak hud] level in
            Task { @MainActor in
                hud?.updateAudioLevel(level)
            }
        }
        hud.onUndo = { [weak self] in
            self?.undoLastInsertion()
        }
    }

    func startCapture(
        intent: VoiceIntent = .dictate,
        explicitModeID: UUID? = nil
    ) {
        guard captureSession == nil else { return }
        guard processingTask == nil, pendingPreview == nil else { return }
        guard audioCapturer.hasPermission else {
            fail("Autorise le microphone dans les préférences")
            return
        }

        guard capturePreparationTask == nil else { return }
        let capturedContext = contextCapturer.capture()
        let mode = modeResolver.resolveMode(
            explicitModeID: explicitModeID,
            applicationBundleIdentifier: capturedContext.context.applicationBundleIdentifier,
            intent: intent
        )
        let deliveryPolicy = modeResolver.deliveryPolicy(
            for: capturedContext.context.applicationBundleIdentifier
        )
        guard deliveryPolicy != .excluded else {
            fail("Pressay est désactivé pour cette application")
            return
        }
        let activeTranscriber: any SpeechTranscribing
        do {
            activeTranscriber = try transcriptionRouter?
                .provider(for: mode, capabilities: capabilities)
                ?? transcriber
            guard activeTranscriber.isReady else {
                fail(
                    activeTranscriber.locality == .cloud
                        ? "Configure ta clé API dans les préférences"
                        : "Le moteur de transcription choisi n’est pas prêt"
                )
                return
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard capturedContext.target?.snapshot.isSecure != true else {
            fail("Pressay est désactivé dans les champs sécurisés")
            return
        }
        if intent == .transformSelection,
           capturedContext.context.selectedText?.isEmpty != false {
            preparingIntent = intent
            hud.show(
                .transcribing,
                detail: "Lecture de la sélection…",
                autoHide: false
            )
            capturePreparationTask = Task { [weak self] in
                guard let self else { return }
                let fallback = await self.contextCapturer.captureSelectionFallback(
                    from: capturedContext
                )
                guard !Task.isCancelled else { return }
                self.capturePreparationTask = nil
                self.preparingIntent = nil
                guard fallback.context.selectedText?.isEmpty == false else {
                    self.fail("Sélectionne d’abord le texte à transformer")
                    return
                }
                self.beginCapture(
                    capturedContext: fallback,
                    mode: mode,
                    intent: intent,
                    deliveryPolicy: deliveryPolicy,
                    activeTranscriber: activeTranscriber
                )
                self.recoverCaptureTargetIfNeeded(
                    from: fallback,
                    deliveryPolicy: deliveryPolicy
                )
            }
            return
        }
        beginCapture(
            capturedContext: capturedContext,
            mode: mode,
            intent: intent,
            deliveryPolicy: deliveryPolicy,
            activeTranscriber: activeTranscriber
        )
        recoverCaptureTargetIfNeeded(
            from: capturedContext,
            deliveryPolicy: deliveryPolicy
        )
    }

    private func recoverCaptureTargetIfNeeded(
        from initialCapture: ContextCaptureResult,
        deliveryPolicy: ApplicationDeliveryPolicy
    ) {
        guard deliveryPolicy != .copyOnly,
              let initialTarget = initialCapture.target,
              !initialTarget.snapshot.isSecure,
              !initialTarget.snapshot.isEditable,
              let sessionID = captureSession?.id else {
            return
        }
        targetRecoveryTask?.cancel()
        targetRecoveryTask = Task { [weak self] in
            guard let self else { return }
            let recovered = await self.contextCapturer.recoverEditableTarget(
                from: initialCapture
            )
            guard !Task.isCancelled,
                  recovered.target?.snapshot.isEditable == true,
                  var session = self.captureSession,
                  session.id == sessionID else {
                self.targetRecoveryTask = nil
                return
            }
            self.captureTarget = recovered.target
            session.target = recovered.target?.snapshot
            session.context = recovered.context
            self.captureSession = session
            self.targetRecoveryTask = nil
        }
    }

    private func beginCapture(
        capturedContext: ContextCaptureResult,
        mode: ModeDefinition,
        intent: VoiceIntent,
        deliveryPolicy: ApplicationDeliveryPolicy,
        activeTranscriber: any SpeechTranscribing
    ) {
        captureTranscriberPreparationTask = Task {
            try await activeTranscriber.prepare()
        }
        do {
            try audioCapturer.startRecording()

            var timings = SessionTimings()
            timings.captureStartedAt = Date()
            var session = VoiceSession(
                intent: intent,
                target: capturedContext.target?.snapshot,
                context: capturedContext.context,
                modeIdentifier: mode.id,
                timings: timings
            )
            _ = session.transition(to: .capturing)
            captureTarget = capturedContext.target
            captureMode = mode
            captureDeliveryPolicy = deliveryPolicy
            captureTranscriber = activeTranscriber
            captureSession = session
            lastError = nil
            lastNotice = nil
            sounds.playStartSound()
            hud.show(
                .listening,
                detail: listeningDetail(modeName: mode.name),
                autoHide: false
            )
            if intent == .dictate {
                let options = modeResolver.availableModes().map {
                    HUDModeOption(
                        id: $0.id,
                        name: $0.name,
                        symbolName: $0.symbolName
                    )
                }
                hud.configureModeSelection(
                    currentModeID: mode.id,
                    options: options,
                    onSelect: { [weak self] modeID in
                        self?.updateCaptureMode(modeID)
                    }
                )
            }
        } catch {
            cancelCaptureAcceleration()
            fail(error.localizedDescription)
        }
    }

    func stopCaptureAndQueue() {
        guard var session = captureSession,
              let mode = captureMode,
              let deliveryPolicy = captureDeliveryPolicy else {
            return
        }
        captureSession = nil
        targetRecoveryTask?.cancel()
        targetRecoveryTask = nil
        captureMode = nil
        captureDeliveryPolicy = nil
        let activeTranscriber = captureTranscriber ?? transcriber
        captureTranscriber = nil
        let preparationTask = captureTranscriberPreparationTask
        captureTranscriberPreparationTask = nil
        let target = captureTarget
        captureTarget = nil

        // Reflect the physical release immediately. Audio finalization happens
        // synchronously just below, but the HUD must never continue to say that
        // Pressay is listening once Fn is up.
        hud.show(.transcribing, detail: "Finalisation…", autoHide: false)

        let audioFinalizationStartedAt = Date()
        guard let audio = audioCapturer.stopRecording() else {
            preparationTask?.cancel()
            session.transition(to: .failed("Aucun enregistrement trouvé"))
            lastSession = session
            fail("Aucun enregistrement trouvé")
            return
        }
        logger.notice(
            "Audio finalized: duration=\(Date().timeIntervalSince(audioFinalizationStartedAt), format: .fixed(precision: 3), privacy: .public)s, audioDuration=\(audio.duration, format: .fixed(precision: 3), privacy: .public)s"
        )
        sounds.playStopSound()
        session.timings.captureEndedAt = Date()
        session.audioURL = audio.url
        session.audioDuration = audio.duration
        _ = session.transition(to: .captured)
        metrics.record(.capture, duration: audio.duration)

        guard audio.containsSpeech else {
            preparationTask?.cancel()
            audioCapturer.cleanup(url: audio.url)
            _ = session.transition(to: .cancelled)
            lastSession = session
            lastError = nil
            lastNotice = "Aucune parole détectée — rien n’a été collé"
            hud.show(.cancelled, detail: lastNotice, autoHide: true)
            return
        }

        let item = PendingSession(
            session: session,
            audio: audio,
            target: target ?? textTarget(for: session),
            mode: mode,
            deliveryPolicy: deliveryPolicy,
            replayOriginalText: nil,
            transcriber: activeTranscriber,
            preparationTask: preparationTask
        )
        // Replay and comparison are useful for advanced modes, but loading and
        // retaining the audio is not part of instant faithful dictation.
        if !isInstantDictation(item),
           let data = try? Data(contentsOf: audio.url) {
            replayBuffer.retain(data, for: session.id)
            replayDescriptors[session.id] = ReplayDescriptor(
                target: target ?? textTarget(for: session),
                mode: mode,
                context: session.context,
                duration: audio.duration,
                fileExtension: audio.url.pathExtension,
                deliveryPolicy: deliveryPolicy,
                transcriber: activeTranscriber
            )
            trimReplayDescriptors()
        }
        pendingCount = 0
        process(item)
    }

    private func updateCaptureMode(_ modeID: UUID) {
        guard var session = captureSession,
              session.intent == .dictate,
              let mode = modeResolver.availableModes().first(where: {
                $0.id == modeID && $0.isEnabled
              }) else { return }
        captureMode = mode
        session.modeIdentifier = mode.id
        captureSession = session
        hud.show(
            .listening,
            detail: listeningDetail(modeName: mode.name),
            autoHide: false
        )
    }

    func cancelCurrentSession() {
        if capturePreparationTask != nil {
            capturePreparationTask?.cancel()
            capturePreparationTask = nil
            preparingIntent = nil
            lastError = nil
            lastNotice = "Capture annulée"
            hud.show(.cancelled, detail: lastNotice, autoHide: true)
            return
        }
        if var session = captureSession {
            targetRecoveryTask?.cancel()
            targetRecoveryTask = nil
            captureTranscriber = nil
            cancelCaptureAcceleration()
            audioCapturer.cleanupCurrentRecording()
            captureSession = nil
            captureTarget = nil
            captureMode = nil
            captureDeliveryPolicy = nil
            _ = session.transition(to: .cancelled)
            lastSession = session
            lastError = nil
            lastNotice = "Dictée annulée"
            hud.show(.cancelled, detail: lastNotice, autoHide: true)
            return
        }
        if pendingPreview != nil {
            cancelPreview()
            return
        }
        cancelProcessing()
    }

    func cancelProcessing() {
        guard processingTask != nil else { return }
        processingTask?.cancel()
        lastNotice = "Traitement annulé"
        lastError = nil
        hud.show(.cancelled, detail: lastNotice, autoHide: true)
    }

    func clearMessages() {
        lastError = nil
        lastNotice = nil
    }

    func undoLastInsertion() {
        guard textDeliverer.undoLastInsertion() else {
            lastNotice = "L’insertion ne peut plus être annulée"
            hud.isUndoAvailable = false
            hud.show(.cancelled, detail: lastNotice, autoHide: true)
            return
        }
        lastError = nil
        lastNotice = "Insertion annulée"
        hud.isUndoAvailable = false
        hud.show(.cancelled, detail: lastNotice, autoHide: true)
    }

    func startCorrectionCapture() {
        guard captureSession == nil, processingTask == nil else {
            fail("Attends la fin du traitement en cours")
            return
        }
        guard textDeliverer.prepareRecentInsertionForReplacement() else {
            fail("La dernière insertion n’est plus sélectionnable en toute sécurité")
            return
        }
        startCapture(intent: .transformSelection)
    }

    func copyLastResult() {
        guard let text = lastSession?.finalText ?? lastSession?.rawText else {
            return
        }
        textDeliverer.copyToPasteboard(text)
        lastNotice = "Texte copié"
    }

    func retranscribeLastResult() {
        replayLastResult(retryOriginalDelivery: false)
    }

    func retryLastFailedResult() {
        replayLastResult(retryOriginalDelivery: true)
    }

    private func replayLastResult(retryOriginalDelivery: Bool) {
        guard processingTask == nil, pendingPreview == nil else { return }
        guard let previous = lastSession,
              let data = replayBuffer.audio(for: previous.id),
              let descriptor = replayDescriptors[previous.id] else {
            lastNotice = "L’audio de cette dictée a expiré"
            return
        }
        let suffix = descriptor.fileExtension.isEmpty
            ? "m4a"
            : descriptor.fileExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressay-replay-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            fail("Impossible de préparer la retranscription")
            return
        }

        var session = VoiceSession(
            intent: previous.intent,
            state: .captured,
            target: descriptor.target?.snapshot,
            context: descriptor.context,
            modeIdentifier: descriptor.mode.id
        )
        session.audioURL = url
        session.audioDuration = descriptor.duration
        let audio = CapturedAudio(
            url: url,
            duration: descriptor.duration,
            detection: SpeechDetectionResult(
                containsSpeech: true,
                threshold: 0,
                voicedDuration: descriptor.duration
            )
        )
        replayBuffer.retain(data, for: session.id)
        replayDescriptors[session.id] = descriptor
        let item = PendingSession(
            session: session,
            audio: audio,
            target: descriptor.target,
            mode: descriptor.mode,
            deliveryPolicy: retryOriginalDelivery
                ? descriptor.deliveryPolicy
                : .preview,
            replayOriginalText: retryOriginalDelivery
                ? nil
                : previous.finalText ?? previous.rawText,
            transcriber: descriptor.transcriber,
            preparationTask: Task {
                try await descriptor.transcriber.prepare()
            }
        )
        pendingCount = 0
        process(item)
    }

    func compareRawAndFinalResult() {
        guard let session = lastSession,
              let rawText = session.rawText,
              let finalText = session.finalText,
              rawText != finalText else {
            return
        }
        let preview = TextPreview(
            sessionID: session.id,
            originalText: rawText,
            proposedText: finalText,
            modeName: "Brut / Final",
            providerIdentifier: "Pressay",
            contextManifest: [],
            isReadOnly: true
        )
        hud.hide()
        previewPresenter.show(
            preview,
            onApply: { _ in },
            onCancel: {}
        )
    }

    private func process(_ pendingItem: PendingSession) {
        guard processingTask == nil, pendingPreview == nil else { return }
        if isInstantDictation(pendingItem) {
            processInstantDictation(pendingItem)
            return
        }
        var item = pendingItem
        pendingCount = 0
        item.session.timings.transcriptionStartedAt = Date()
        _ = item.session.transition(to: .transcribing)
        processingSession = item.session
        hud.show(.transcribing, detail: nil, autoHide: false)

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.audioCapturer.cleanup(url: item.audio.url)
                self.processingTask = nil
                if self.pendingPreview?.sessionID != item.session.id {
                    self.processingSession = nil
                }
            }

            do {
                let activeTranscriber = item.transcriber
                self.logger.notice(
                    "Fn release processing started: profile=\(activeTranscriber.identifier, privacy: .public), mode=\(item.mode.name, privacy: .public), audioDuration=\(item.audio.duration, format: .fixed(precision: 3), privacy: .public)s"
                )
                self.hud.show(
                    .transcribing,
                    detail: "\(activeTranscriber.locality == .local ? "Local" : "Cloud") · \(activeTranscriber.identifier)",
                    autoHide: false
                )
                let transcriptionStartedAt = Date()
                let transcription = try await self.transcription(for: item)
                self.lastTranscriptionModel = transcription.modelIdentifier
                self.appendNetworkMetrics(
                    transcription.networkMetrics,
                    sessionID: item.session.id
                )
                self.metrics.record(
                    .transcription,
                    duration: Date().timeIntervalSince(transcriptionStartedAt)
                )
                self.logger.notice(
                    "Transcription completed: model=\(transcription.modelIdentifier ?? activeTranscriber.identifier, privacy: .public), mode=\(item.mode.name, privacy: .public), duration=\(Date().timeIntervalSince(transcriptionStartedAt), format: .fixed(precision: 3), privacy: .public)s"
                )
                try Task.checkCancellation()
                let transcriptionText = try TranscriptionResponseValidator.validated(
                    transcription.text,
                    vocabulary: ""
                )

                item.session.timings.transcriptionEndedAt = Date()
                item.session.rawText = transcriptionText
                _ = item.session.transition(to: .processing)
                self.processingSession = item.session

                let processed = try await self.processText(
                    transcriptionText,
                    item: item
                )
                try Task.checkCancellation()
                item.session.finalText = processed.text
                item.session.timings.processingEndedAt = Date()

                if item.session.intent == .transformSelection
                    || item.deliveryPolicy == .preview
                    || item.replayOriginalText != nil {
                    self.presentPreview(
                        item: item,
                        rawText: transcriptionText,
                        processed: (
                            text: processed.text,
                            providerIdentifier: processed.providerIdentifier,
                            contextManifest: processed.contextManifest
                        ),
                        transcriptionProviderIdentifier: transcription.modelIdentifier
                            ?? activeTranscriber.identifier
                    )
                    self.scheduleAPIUsageRecording(
                        transcription: transcription,
                        audioDuration: item.audio.duration,
                        processingUsage: processed.tokenUsage,
                        processingModel: processed.processingModel
                    )
                    return
                }

                _ = item.session.transition(to: .delivering)
                self.processingSession = item.session
                await self.deliver(
                    text: processed.text,
                    item: item,
                    rawText: transcriptionText,
                    providerIdentifier: processed.providerIdentifier,
                    transcriptionProviderIdentifier: transcription.modelIdentifier
                        ?? activeTranscriber.identifier,
                    contextManifest: processed.contextManifest,
                    lowConfidence: transcription.isLowConfidence
                )
                self.scheduleAPIUsageRecording(
                    transcription: transcription,
                    audioDuration: item.audio.duration,
                    processingUsage: processed.tokenUsage,
                    processingModel: processed.processingModel
                )
            } catch {
                self.finish(item: &item, with: error)
            }
        }
    }

    /// The default Fn path intentionally mirrors the original small app:
    /// transcribe once, paste once, finish. Modes that rewrite text continue
    /// through the richer coordinator below.
    private func processInstantDictation(_ pendingItem: PendingSession) {
        var item = pendingItem
        pendingCount = 0
        item.session.timings.transcriptionStartedAt = Date()
        _ = item.session.transition(to: .transcribing)
        processingSession = item.session
        hud.show(
            .transcribing,
            detail: item.transcriber.locality == .local ? "Local" : "OpenAI",
            autoHide: false
        )

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.audioCapturer.cleanup(url: item.audio.url)
                self.processingTask = nil
                self.processingSession = nil
            }

            do {
                let transcriptionStartedAt = Date()
                self.logger.notice(
                    "Fn release processing started: profile=\(item.transcriber.identifier, privacy: .public), audioDuration=\(item.audio.duration, format: .fixed(precision: 3), privacy: .public)s"
                )
                let transcription = try await self.transcription(for: item)
                let transcriptionDuration = Date().timeIntervalSince(
                    transcriptionStartedAt
                )
                self.lastTranscriptionModel = transcription.modelIdentifier
                self.appendNetworkMetrics(
                    transcription.networkMetrics,
                    sessionID: item.session.id
                )
                self.metrics.record(
                    .transcription,
                    duration: transcriptionDuration
                )
                self.logger.notice(
                    "Transcription completed: model=\(transcription.modelIdentifier ?? item.transcriber.identifier, privacy: .public), duration=\(transcriptionDuration, format: .fixed(precision: 3), privacy: .public)s"
                )
                try Task.checkCancellation()
                let transcriptionText = InstantDictationTextNormalizer.normalized(
                    try TranscriptionResponseValidator.validated(
                        transcription.text,
                        vocabulary: ""
                    )
                )

                item.session.timings.transcriptionEndedAt = Date()
                item.session.timings.processingEndedAt = Date()
                item.session.rawText = transcriptionText
                item.session.finalText = transcriptionText
                _ = item.session.transition(to: .processing)
                _ = item.session.transition(to: .delivering)
                self.processingSession = item.session

                let insertionStartedAt = Date()
                let inserted = await self.textDeliverer.injectDictation(
                    text: transcriptionText,
                    target: item.target
                )
                let insertionDuration = Date().timeIntervalSince(
                    insertionStartedAt
                )
                self.metrics.record(
                    .insertion,
                    duration: insertionDuration
                )
                self.logger.notice(
                    "Delivery returned: inserted=\(inserted, privacy: .public), strategy=\(String(describing: self.textDeliverer.lastDeliveryStrategy), privacy: .public), duration=\(insertionDuration, format: .fixed(precision: 3), privacy: .public)s"
                )

                item.session.timings.deliveryEndedAt = Date()
                _ = item.session.transition(to: .completed)
                self.complete(
                    session: item.session,
                    rawText: transcriptionText,
                    finalText: transcriptionText,
                    processingProvider: nil,
                    transcriptionProviderIdentifier: transcription.modelIdentifier
                        ?? item.transcriber.identifier,
                    contextManifest: [],
                    audioDuration: item.audio.duration,
                    inserted: inserted,
                    lowConfidence: transcription.isLowConfidence
                )
                self.scheduleAPIUsageRecording(
                    transcription: transcription,
                    audioDuration: item.audio.duration,
                    processingUsage: nil,
                    processingModel: nil
                )
            } catch {
                self.finish(item: &item, with: error)
            }
        }
    }

    private func isInstantDictation(_ item: PendingSession) -> Bool {
        item.session.intent == .dictate
            && item.mode.cleaningLevel == .faithful
            && item.deliveryPolicy == .automatic
            && item.replayOriginalText == nil
    }

    private func transcription(
        for item: PendingSession
    ) async throws -> TranscriptionResult {
        if let preparationTask = item.preparationTask {
            if item.transcriber.locality == .local {
                try await withPhaseTimeout(
                    seconds: timeoutPolicy.localPreparation,
                    error: .localPreparation(timeoutPolicy.localPreparation)
                ) {
                    try await preparationTask.value
                }
            } else {
                try await preparationTask.value
            }
        }

        let timeout = item.transcriber.locality == .local
            ? timeoutPolicy.localTranscription
            : timeoutPolicy.cloudTranscription
        let timeoutError: PhaseTimeoutError = item.transcriber.locality == .local
            ? .localTranscription(timeout)
            : .cloudTranscription(timeout)
        return try await withPhaseTimeout(
            seconds: timeout,
            error: timeoutError
        ) {
            try await item.transcriber.transcribe(audioURL: item.audio.url)
        }
    }

    private func withPhaseTimeout<T>(
        seconds: TimeInterval,
        error: PhaseTimeoutError,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw error
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }

    private func processText(
        _ transcription: String,
        item: PendingSession
    ) async throws -> (
        text: String,
        providerIdentifier: String?,
        contextManifest: [String],
        tokenUsage: OpenAITokenUsage?,
        processingModel: String?
    ) {
        guard item.mode.cleaningLevel != .faithful
                || item.session.intent == .transformSelection else {
            return (transcription, nil, [], nil, nil)
        }
        if item.mode.providerPolicy == .localOnly, processingRouter == nil {
            throw CoordinatorError.localProcessorUnavailable
        }
        let activeProcessor = try processingRouter?
            .provider(for: item.mode, capabilities: capabilities)
            ?? textProcessor

        let restrictedContext = item.session.context.restricted(
            to: item.mode.allowedContextSources
        )
        let manifest = restrictedContext.cloudManifest
        let isCloudProcessing = activeProcessor.locality == .cloud
        if item.mode.providerPolicy == .localOnly, isCloudProcessing {
            throw CoordinatorError.localProcessorUnavailable
        }
        let requiresCloudConfirmation = item.mode.providerPolicy == .askBeforeCloud
            || item.mode.providerPolicy == .preferLocal
        if isCloudProcessing, requiresCloudConfirmation {
            let preflight = cloudPreflight(
                transcription: transcription,
                sessionID: item.session.id,
                mode: item.mode,
                context: restrictedContext,
                processor: activeProcessor
            )
            var confirmationSession = item.session
            _ = confirmationSession.transition(to: .awaitingConfirmation)
            processingSession = confirmationSession
            hud.show(
                .processing,
                detail: "Confirmation cloud · \(item.mode.name)",
                autoHide: false
            )
            let decision = await cloudConsent.requestConsent(
                for: preflight,
                allowsRawTranscription: item.session.intent != .transformSelection,
                requiresExplicitChoice: true
            )
            try Task.checkCancellation()
            switch decision {
            case .sendOnce, .alwaysAllowMode:
                _ = confirmationSession.transition(to: .processing)
                processingSession = confirmationSession
            case .useRawTranscription:
                guard item.session.intent != .transformSelection else {
                    throw CoordinatorError.rawUnavailableForSelection
                }
                return (transcription, nil, [], nil, nil)
            case .cancel:
                throw CancellationError()
            }
        }

        let sourceLabel = manifest.isEmpty ? "sans contexte" : manifest.joined(separator: ", ")
        hud.show(
            .processing,
            detail: "\(isCloudProcessing ? "Cloud" : "Local") · \(item.mode.name) · \(sourceLabel)",
            autoHide: false
        )
        let startedAt = Date()
        let processingRequest = TextProcessingRequest(
            text: transcription,
            mode: item.mode,
            context: restrictedContext
        )
        let result = try await withPhaseTimeout(
            seconds: timeoutPolicy.textProcessing,
            error: .textProcessing(timeoutPolicy.textProcessing)
        ) {
            try await activeProcessor.process(processingRequest)
        }
        appendNetworkMetrics(
            result.networkMetrics,
            sessionID: item.session.id
        )
        let processingDuration = Date().timeIntervalSince(startedAt)
        metrics.record(.processing, duration: processingDuration)
        logger.notice(
            "Text processing completed: model=\(activeProcessor.modelIdentifier, privacy: .public), mode=\(item.mode.name, privacy: .public), duration=\(processingDuration, format: .fixed(precision: 3), privacy: .public)s"
        )
        return (
            result.text,
            result.providerIdentifier,
            manifest,
            result.tokenUsage,
            activeProcessor.modelIdentifier
        )
    }

    private func scheduleAPIUsageRecording(
        transcription: TranscriptionResult,
        audioDuration: TimeInterval,
        processingUsage: OpenAITokenUsage?,
        processingModel: String?
    ) {
        guard let transcriptionModel = transcription.modelIdentifier else {
            return
        }
        // Schedule after the current MainActor turn so persisting the local
        // estimate can never delay target activation or the paste shortcut.
        Task { @MainActor in
            APIUsageLedger.shared.recordTranscription(
                model: transcriptionModel,
                audioDurationSeconds: audioDuration
            )
            if let processingUsage, let processingModel {
                APIUsageLedger.shared.recordProcessing(
                    model: processingModel,
                    usage: processingUsage
                )
            }
        }
    }

    private func cloudPreflight(
        transcription: String,
        sessionID: UUID,
        mode: ModeDefinition,
        context: ContextSnapshot,
        processor: TextProcessing
    ) -> CloudPreflight {
        var payload: [ContextSource: String] = [:]
        if context.sources.contains(.application) {
            let application = [
                context.applicationName,
                context.applicationBundleIdentifier
            ].compactMap { $0 }.joined(separator: " · ")
            if !application.isEmpty { payload[.application] = application }
        }
        if context.sources.contains(.windowTitle),
           let title = context.windowTitle,
           !title.isEmpty {
            payload[.windowTitle] = title
        }
        if context.sources.contains(.selection),
           let selection = context.selectedText,
           !selection.isEmpty {
            payload[.selection] = selection
        }
        if context.sources.contains(.surroundingText) {
            let surrounding = [
                context.textBeforeSelection.map { "AVANT : \($0)" },
                context.textAfterSelection.map { "APRÈS : \($0)" }
            ].compactMap { $0 }.joined(separator: "\n")
            if !surrounding.isEmpty {
                payload[.surroundingText] = surrounding
            }
        }
        if context.sources.contains(.project),
           let project = context.projectIdentifier {
            payload[.project] = project.uuidString
        }
        let orderedSources = mode.contextSources.filter {
            payload[$0]?.isEmpty == false
        }
        return CloudPreflight(
            sessionID: sessionID,
            modeID: mode.id,
            providerID: processor.identifier,
            modelID: processor.modelIdentifier,
            spokenText: transcription,
            sources: orderedSources,
            characterCounts: Dictionary(
                uniqueKeysWithValues: orderedSources.map {
                    ($0, payload[$0]?.count ?? 0)
                }
            ),
            exactPayloadPreview: payload
        )
    }

    private func presentPreview(
        item: PendingSession,
        rawText: String,
        processed: (
            text: String,
            providerIdentifier: String?,
            contextManifest: [String]
        ),
        transcriptionProviderIdentifier: String
    ) {
        var session = item.session
        _ = session.transition(to: .awaitingPreview)
        processingSession = session
        let original = item.replayOriginalText
            ?? session.context.selectedText
            ?? (item.deliveryPolicy == .preview ? rawText : "")
        let providerIdentifier = processed.providerIdentifier ?? textProcessor.identifier
        let preview = TextPreview(
            sessionID: session.id,
            originalText: original,
            proposedText: processed.text,
            modeName: item.mode.name,
            providerIdentifier: providerIdentifier,
            contextManifest: processed.contextManifest
        )
        previewDelivery = PreviewDelivery(
            session: session,
            target: item.target,
            rawText: rawText,
            providerIdentifier: providerIdentifier,
            transcriptionProviderIdentifier: transcriptionProviderIdentifier,
            contextManifest: processed.contextManifest,
            audioDuration: item.audio.duration
        )
        pendingPreview = preview
        hud.hide()
        previewPresenter.show(
            preview,
            onApply: { [weak self] editedText in
                self?.applyPreview(editedText)
            },
            onCancel: { [weak self] in
                self?.cancelPreview()
            }
        )
    }

    private func applyPreview(_ text: String) {
        guard pendingPreview != nil,
              var delivery = previewDelivery else {
            return
        }
        pendingPreview = nil
        previewDelivery = nil
        _ = delivery.session.transition(to: .delivering)
        processingSession = delivery.session

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.processingTask = nil
                self.processingSession = nil
            }
            let insertionStartedAt = Date()
            let inserted = await self.textDeliverer.inject(
                text: text,
                target: delivery.target
            )
            self.metrics.record(
                .insertion,
                duration: Date().timeIntervalSince(insertionStartedAt)
            )
            delivery.session.finalText = text
            delivery.session.timings.deliveryEndedAt = Date()
            _ = delivery.session.transition(to: .completed)
            self.complete(
                session: delivery.session,
                rawText: delivery.rawText,
                finalText: text,
                processingProvider: delivery.providerIdentifier,
                transcriptionProviderIdentifier: delivery.transcriptionProviderIdentifier,
                contextManifest: delivery.contextManifest,
                audioDuration: delivery.audioDuration,
                inserted: inserted,
                lowConfidence: false
            )
        }
    }

    private func cancelPreview() {
        previewPresenter.hide()
        pendingPreview = nil
        guard var delivery = previewDelivery else { return }
        previewDelivery = nil
        _ = delivery.session.transition(to: .cancelled)
        processingSession = nil
        lastSession = delivery.session
        lastError = nil
        lastNotice = "Transformation annulée"
        hud.show(.cancelled, detail: lastNotice, autoHide: true)
    }

    private func deliver(
        text: String,
        item: PendingSession,
        rawText: String,
        providerIdentifier: String?,
        transcriptionProviderIdentifier: String,
        contextManifest: [String],
        lowConfidence: Bool
    ) async {
        if item.deliveryPolicy == .copyOnly {
            textDeliverer.copyToPasteboard(text)
            var session = item.session
            session.finalText = text
            session.timings.deliveryEndedAt = Date()
            _ = session.transition(to: .completed)
            complete(
                session: session,
                rawText: rawText,
                finalText: text,
                processingProvider: providerIdentifier,
                transcriptionProviderIdentifier: transcriptionProviderIdentifier,
                contextManifest: contextManifest,
                audioDuration: item.audio.duration,
                inserted: false,
                lowConfidence: lowConfidence,
                textAlreadyCopied: true
            )
            return
        }
        hud.show(
            .delivering,
            detail: item.target == nil ? "Copie de secours" : "Cible initiale",
            autoHide: false
        )
        let insertionStartedAt = Date()
        let inserted = if item.session.intent == .dictate {
            await textDeliverer.injectDictation(text: text, target: item.target)
        } else {
            await textDeliverer.inject(text: text, target: item.target)
        }
        metrics.record(
            .insertion,
            duration: Date().timeIntervalSince(insertionStartedAt)
        )
        logger.notice(
            "Delivery returned: inserted=\(inserted, privacy: .public), strategy=\(String(describing: self.textDeliverer.lastDeliveryStrategy), privacy: .public), mode=\(item.mode.name, privacy: .public), duration=\(Date().timeIntervalSince(insertionStartedAt), format: .fixed(precision: 3), privacy: .public)s"
        )
        var session = item.session
        session.finalText = text
        session.timings.deliveryEndedAt = Date()
        _ = session.transition(to: .completed)
        complete(
            session: session,
            rawText: rawText,
            finalText: text,
            processingProvider: providerIdentifier,
            transcriptionProviderIdentifier: transcriptionProviderIdentifier,
            contextManifest: contextManifest,
            audioDuration: item.audio.duration,
            inserted: inserted,
            lowConfidence: lowConfidence
        )
    }

    private func complete(
        session: VoiceSession,
        rawText: String,
        finalText: String,
        processingProvider: String?,
        transcriptionProviderIdentifier: String? = nil,
        contextManifest: [String],
        audioDuration: TimeInterval,
        inserted: Bool,
        lowConfidence: Bool,
        textAlreadyCopied: Bool = false
    ) {
        logger.notice(
            "Session completed: inserted=\(inserted, privacy: .public), transcription=\(transcriptionProviderIdentifier ?? self.transcriber.identifier, privacy: .public), processing=\(processingProvider ?? "none", privacy: .public), total=\(Date().timeIntervalSince(session.timings.createdAt), format: .fixed(precision: 3), privacy: .public)s"
        )
        metrics.record(
            .total,
            duration: Date().timeIntervalSince(session.timings.createdAt)
        )
        metrics.recordSession(
            performanceTrace(
                session: session,
                audioDuration: audioDuration,
                transcriptionProvider: transcriptionProviderIdentifier
                    ?? transcriber.identifier,
                processingProvider: processingProvider,
                inserted: inserted
            )
        )
        networkMetricsBySession.removeValue(forKey: session.id)
        lastSession = session
        let undoDeadline = inserted && textDeliverer.canUndoLastInsertion
            ? Date().addingTimeInterval(8)
            : nil
        lastDeliveryReceipt = DeliveryReceipt(
            sessionID: session.id,
            strategy: inserted ? textDeliverer.lastDeliveryStrategy : .copied,
            originalText: session.context.selectedText,
            rawText: rawText,
            finalText: finalText,
            undoDeadline: undoDeadline
        )
        let record = HistoryRecord(
                sessionID: session.id,
                rawText: rawText,
                finalText: finalText,
                applicationBundleIdentifier: session.target?.bundleIdentifier,
                modeIdentifier: session.modeIdentifier,
                transcriptionProvider: transcriptionProviderIdentifier
                    ?? transcriber.identifier,
                processingProvider: processingProvider,
                language: UserDefaults.standard.string(
                    forKey: Constants.transcriptionLanguageKey
                ),
                audioDuration: audioDuration,
                contextManifest: contextManifest,
                deliveryStatus: inserted ? .inserted : .copied
        )
        history.append(record)
        if !inserted,
           let failure = textDeliverer.lastDeliveryFailure,
           failure == .missingTarget || failure == .nonEditableTarget {
            inbox?.append(record)
        }

        lastError = nil
        if inserted {
            let deliveryLabel = textDeliverer.lastDeliveryStrategy == .paste
                ? "Texte envoyé"
                : "Texte inséré"
            lastNotice = lowConfidence
                ? "\(deliveryLabel) — vérifie cette transcription incertaine"
                : deliveryLabel
        } else {
            let deliveryFailure = textDeliverer.lastDeliveryFailure
            if !textAlreadyCopied {
                textDeliverer.copyToPasteboard(finalText)
            }
            if textAlreadyCopied {
                lastNotice = "Texte copié"
            } else if let failure = deliveryFailure {
                lastNotice = "Texte copié — \(failure.userMessage)"
            } else {
                lastNotice = "Texte copié — la cible initiale n’est plus disponible"
            }
        }
        hud.isUndoAvailable = inserted && textDeliverer.canUndoLastInsertion
        hud.configureResultActions(
            canRetranscribe: replayBuffer.audio(for: session.id) != nil,
            retranscribeLabel: "Retranscrire",
            canCompareRawAndFinal: rawText != finalText,
            canCorrect: inserted && textDeliverer.canUndoLastInsertion,
            onCopy: { [weak self] in self?.copyLastResult() },
            onRetranscribe: { [weak self] in self?.retranscribeLastResult() },
            onCompareRawAndFinal: {
                [weak self] in self?.compareRawAndFinalResult()
            },
            onCorrect: { [weak self] in self?.startCorrectionCapture() }
        )
        hud.show(inserted ? .success : .copied, detail: lastNotice, autoHide: true)
    }

    private func performanceTrace(
        session: VoiceSession,
        audioDuration: TimeInterval,
        transcriptionProvider: String,
        processingProvider: String?,
        inserted: Bool
    ) -> SessionPerformanceTrace {
        let timings = session.timings
        return SessionPerformanceTrace(
            id: session.id,
            createdAt: timings.createdAt,
            audioDurationSeconds: audioDuration,
            transcriptionProvider: transcriptionProvider,
            processingProvider: processingProvider,
            transcriptionSeconds: duration(
                from: timings.transcriptionStartedAt,
                to: timings.transcriptionEndedAt
            ),
            processingSeconds: duration(
                from: timings.transcriptionEndedAt,
                to: timings.processingEndedAt
            ),
            insertionSeconds: duration(
                from: timings.processingEndedAt,
                to: timings.deliveryEndedAt
            ),
            totalSeconds: duration(
                from: timings.createdAt,
                to: timings.deliveryEndedAt
            ),
            deliveryStatus: inserted ? .inserted : .copied,
            deliveryFailure: inserted
                ? nil
                : textDeliverer.lastDeliveryFailure?.rawValue,
            networkRequests: networkMetricsBySession[session.id] ?? []
        )
    }

    private func duration(from start: Date?, to end: Date?) -> TimeInterval {
        guard let start, let end else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    private func trimReplayDescriptors() {
        let retainedIDs = Set(
            [captureSession?.id, processingSession?.id, lastSession?.id]
                .compactMap { $0 }
        )
        if replayDescriptors.count > 6 {
            replayDescriptors = replayDescriptors.filter {
                retainedIDs.contains($0.key)
                    || replayBuffer.audio(for: $0.key) != nil
            }
        }
    }

    private func finish(item: inout PendingSession, with error: Error) {
        if let failure = error as? ProviderRequestFailure {
            appendNetworkMetrics(
                failure.networkMetrics,
                sessionID: item.session.id
            )
        }
        let underlyingError = (error as? ProviderRequestFailure)?.underlying
            ?? error
        let failedStep: MetricStep = switch item.session.state {
        case .processing, .awaitingConfirmation:
            .processing
        default:
            .transcription
        }
        let phaseStartedAt = failedStep == .processing
            ? item.session.timings.transcriptionEndedAt
            : item.session.timings.transcriptionStartedAt
        if Task.isCancelled
            || underlyingError is CancellationError
            || (underlyingError as? URLError)?.code == .cancelled {
            _ = item.session.transition(to: .cancelled)
            lastError = nil
            lastNotice = "Traitement annulé"
        } else {
            let message = error.localizedDescription
            _ = item.session.transition(to: .failed(message))
            lastError = message
            lastNotice = nil
            sounds.playErrorSound()
            retainReplayIfNeeded(for: item)
            let now = Date()
            let phaseDuration = phaseStartedAt.map {
                max(0, now.timeIntervalSince($0))
            } ?? 0
            metrics.recordFailure(
                failedStep,
                error: underlyingError,
                duration: phaseDuration
            )
            metrics.recordSession(
                SessionPerformanceTrace(
                    id: item.session.id,
                    createdAt: item.session.timings.createdAt,
                    audioDurationSeconds: item.audio.duration,
                    transcriptionProvider: item.transcriber.identifier,
                    processingProvider: failedStep == .processing
                        ? textProcessor.identifier
                        : nil,
                    transcriptionSeconds: duration(
                        from: item.session.timings.transcriptionStartedAt,
                        to: item.session.timings.transcriptionEndedAt ?? now
                    ),
                    processingSeconds: failedStep == .processing
                        ? phaseDuration
                        : 0,
                    insertionSeconds: 0,
                    totalSeconds: max(
                        0,
                        now.timeIntervalSince(item.session.timings.createdAt)
                    ),
                    deliveryStatus: .failed,
                    deliveryFailure: nil,
                    networkRequests: networkMetricsBySession[item.session.id] ?? [],
                    failurePhase: failedStep.rawValue,
                    failureCategory: MetricFailureClassifier.category(
                        for: underlyingError
                    )
                )
            )
        }
        let terminalState = String(describing: item.session.state)
        let terminalMode = item.mode.name
        let terminalCategory = MetricFailureClassifier.category(
            for: underlyingError
        )
        logger.notice(
            "Session ended: state=\(terminalState, privacy: .public), mode=\(terminalMode, privacy: .public), category=\(terminalCategory, privacy: .public)"
        )
        lastSession = item.session
        networkMetricsBySession.removeValue(forKey: item.session.id)
        let canRetry = replayBuffer.audio(for: item.session.id) != nil
        hud.configureResultActions(
            canRetranscribe: canRetry,
            retranscribeLabel: "Réessayer",
            canCompareRawAndFinal: false,
            canCorrect: false,
            onCopy: {},
            onRetranscribe: { [weak self] in self?.retryLastFailedResult() },
            onCompareRawAndFinal: {},
            onCorrect: {}
        )
        hud.show(
            .cancelled,
            detail: lastError ?? lastNotice,
            autoHide: true
        )
    }

    private func retainReplayIfNeeded(for item: PendingSession) {
        guard replayBuffer.audio(for: item.session.id) == nil,
              let data = try? Data(contentsOf: item.audio.url) else { return }
        replayBuffer.retain(data, for: item.session.id)
        replayDescriptors[item.session.id] = ReplayDescriptor(
            target: item.target,
            mode: item.mode,
            context: item.session.context,
            duration: item.audio.duration,
            fileExtension: item.audio.url.pathExtension,
            deliveryPolicy: item.deliveryPolicy,
            transcriber: item.transcriber
        )
        trimReplayDescriptors()
    }

    private func appendNetworkMetrics(
        _ metrics: NetworkRequestMetrics?,
        sessionID: UUID
    ) {
        guard let metrics else { return }
        networkMetricsBySession[sessionID, default: []].append(metrics)
        logger.notice(
            "Network timing: attempts=\(metrics.attempts, privacy: .public), reused=\(metrics.reusedConnection, privacy: .public), dns=\(metrics.dnsSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, connect=\(metrics.connectionSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, tls=\(metrics.tlsSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, request=\(metrics.requestSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, ttfb=\(metrics.timeToFirstByteSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, response=\(metrics.responseSeconds ?? 0, format: .fixed(precision: 3), privacy: .public)s, total=\(metrics.totalSeconds, format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    private func cancelCaptureAcceleration() {
        captureTranscriberPreparationTask?.cancel()
        captureTranscriberPreparationTask = nil
    }

    private func textTarget(for session: VoiceSession) -> TextInjectionTarget? {
        guard let snapshot = session.target else { return nil }
        return TextInjectionTarget(snapshot: snapshot, focusedElement: nil)
    }

    private func fail(_ message: String) {
        lastError = message
        lastNotice = nil
        sounds.playErrorSound()
        hud.show(.cancelled, detail: message, autoHide: true)
    }

    private func listeningDetail(modeName: String) -> String {
        let language = UserDefaults.standard.string(
            forKey: Constants.transcriptionLanguageKey
        ) ?? Constants.defaultTranscriptionLanguage
        let languageLabel: String
        switch language {
        case "fr": languageLabel = "Français"
        case "en": languageLabel = "English"
        default: languageLabel = "Auto"
        }
        return "\(languageLabel) · \(modeName)"
    }

    private enum CoordinatorError: LocalizedError {
        case localProcessorUnavailable
        case rawUnavailableForSelection

        var errorDescription: String? {
            switch self {
            case .localProcessorUnavailable:
                return "Ce mode exige un moteur local qui n’est pas encore installé"
            case .rawUnavailableForSelection:
                return "Le texte brut ne peut pas remplacer une sélection"
            }
        }
    }

    private enum PhaseTimeoutError: LocalizedError {
        case cloudTranscription(TimeInterval)
        case localPreparation(TimeInterval)
        case localTranscription(TimeInterval)
        case textProcessing(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .cloudTranscription(let seconds):
                "Transcription OpenAI interrompue après \(Int(seconds)) s — tu peux réessayer"
            case .localPreparation(let seconds):
                "Chargement de WhisperKit interrompu après \(Int(seconds)) s"
            case .localTranscription(let seconds):
                "Transcription locale interrompue après \(Int(seconds)) s"
            case .textProcessing(let seconds):
                "Transformation OpenAI interrompue après \(Int(seconds)) s — tu peux réessayer"
            }
        }
    }
}
