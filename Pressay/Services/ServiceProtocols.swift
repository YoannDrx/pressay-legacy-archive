import Foundation

struct NetworkRequestMetrics: Codable, Equatable, Sendable {
    let dnsSeconds: TimeInterval?
    let connectionSeconds: TimeInterval?
    let tlsSeconds: TimeInterval?
    let requestSeconds: TimeInterval?
    let timeToFirstByteSeconds: TimeInterval?
    let responseSeconds: TimeInterval?
    let totalSeconds: TimeInterval
    let attempts: Int
    let reusedConnection: Bool

    static func combined(_ values: [NetworkRequestMetrics]) -> NetworkRequestMetrics? {
        guard !values.isEmpty else { return nil }
        func sum(_ keyPath: KeyPath<NetworkRequestMetrics, TimeInterval?>) -> TimeInterval? {
            let durations = values.compactMap { $0[keyPath: keyPath] }
            return durations.isEmpty ? nil : durations.reduce(0, +)
        }
        return NetworkRequestMetrics(
            dnsSeconds: sum(\.dnsSeconds),
            connectionSeconds: sum(\.connectionSeconds),
            tlsSeconds: sum(\.tlsSeconds),
            requestSeconds: sum(\.requestSeconds),
            timeToFirstByteSeconds: sum(\.timeToFirstByteSeconds),
            responseSeconds: sum(\.responseSeconds),
            totalSeconds: values.map(\.totalSeconds).reduce(0, +),
            attempts: values.map(\.attempts).reduce(0, +),
            reusedConnection: values.allSatisfy(\.reusedConnection)
        )
    }
}

final class NetworkTaskMetricsCollector: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var collectedMetrics: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collectedMetrics = metrics
        lock.unlock()
    }

    func snapshot(fallbackTotal: TimeInterval) -> NetworkRequestMetrics {
        lock.lock()
        let metrics = collectedMetrics
        lock.unlock()
        guard let transaction = metrics?.transactionMetrics.last else {
            return NetworkRequestMetrics(
                dnsSeconds: nil,
                connectionSeconds: nil,
                tlsSeconds: nil,
                requestSeconds: nil,
                timeToFirstByteSeconds: nil,
                responseSeconds: nil,
                totalSeconds: max(0, fallbackTotal),
                attempts: 1,
                reusedConnection: false
            )
        }
        return NetworkRequestMetrics(
            dnsSeconds: Self.duration(
                transaction.domainLookupStartDate,
                transaction.domainLookupEndDate
            ),
            connectionSeconds: Self.duration(
                transaction.connectStartDate,
                transaction.connectEndDate
            ),
            tlsSeconds: Self.duration(
                transaction.secureConnectionStartDate,
                transaction.secureConnectionEndDate
            ),
            requestSeconds: Self.duration(
                transaction.requestStartDate,
                transaction.requestEndDate
            ),
            timeToFirstByteSeconds: Self.duration(
                transaction.requestEndDate,
                transaction.responseStartDate
            ),
            responseSeconds: Self.duration(
                transaction.responseStartDate,
                transaction.responseEndDate
            ),
            totalSeconds: metrics?.taskInterval.duration ?? max(0, fallbackTotal),
            attempts: 1,
            reusedConnection: transaction.isReusedConnection
        )
    }

    private static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

struct CapturedAudio {
    let url: URL
    let duration: TimeInterval
    let detection: SpeechDetectionResult

    var containsSpeech: Bool { detection.containsSpeech }
}

protocol AudioCapturing: AnyObject {
    var hasPermission: Bool { get }
    var onLevelUpdate: ((Float) -> Void)? { get set }
    func startRecording() throws
    func stopRecording() -> CapturedAudio?
    func cleanupCurrentRecording()
    func cleanup(url: URL)
}

protocol SpeechTranscribing: AnyObject {
    var identifier: String { get }
    var isReady: Bool { get }
    var locality: ProviderLocality { get }
    func prepare() async throws
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

extension SpeechTranscribing {
    var locality: ProviderLocality { .cloud }
    func prepare() async throws {}
}

struct TextProcessingRequest {
    let text: String
    let mode: ModeDefinition
    let context: ContextSnapshot
}

struct TextProcessingResult: Equatable {
    let text: String
    let providerIdentifier: String
    let networkMetrics: NetworkRequestMetrics?
    let tokenUsage: OpenAITokenUsage?

    init(
        text: String,
        providerIdentifier: String,
        networkMetrics: NetworkRequestMetrics? = nil,
        tokenUsage: OpenAITokenUsage? = nil
    ) {
        self.text = text
        self.providerIdentifier = providerIdentifier
        self.networkMetrics = networkMetrics
        self.tokenUsage = tokenUsage
    }
}

struct OpenAITokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

protocol TextProcessing: AnyObject {
    var identifier: String { get }
    var modelIdentifier: String { get }
    var locality: ProviderLocality { get }
    func process(_ request: TextProcessingRequest) async throws -> TextProcessingResult
}

extension TextProcessing {
    var modelIdentifier: String { identifier }
    var locality: ProviderLocality { .cloud }
}

protocol CloudConsentRequesting: AnyObject {
    func requestConsent(
        for preflight: CloudPreflight,
        allowsRawTranscription: Bool,
        requiresExplicitChoice: Bool
    ) async -> CloudConsentDecision
}

struct ContextCaptureResult {
    let target: TextInjectionTarget?
    let context: ContextSnapshot
}

@MainActor
protocol ContextCapturing: AnyObject {
    func capture() -> ContextCaptureResult
    func recoverEditableTarget(
        from initialCapture: ContextCaptureResult
    ) async -> ContextCaptureResult
    func captureSelectionFallback(
        from initialCapture: ContextCaptureResult
    ) async -> ContextCaptureResult
}

extension ContextCapturing {
    func recoverEditableTarget(
        from initialCapture: ContextCaptureResult
    ) async -> ContextCaptureResult {
        initialCapture
    }

    func captureSelectionFallback(
        from initialCapture: ContextCaptureResult
    ) async -> ContextCaptureResult {
        initialCapture
    }
}

@MainActor
protocol ModeResolving: AnyObject {
    func resolveMode(
        explicitModeID: UUID?,
        applicationBundleIdentifier: String?,
        intent: VoiceIntent
    ) -> ModeDefinition
    func deliveryPolicy(
        for applicationBundleIdentifier: String?
    ) -> ApplicationDeliveryPolicy
    func availableModes() -> [ModeDefinition]
}

extension ModeResolving {
    func deliveryPolicy(
        for applicationBundleIdentifier: String?
    ) -> ApplicationDeliveryPolicy {
        .automatic
    }
    func availableModes() -> [ModeDefinition] { [] }
}

@MainActor
protocol TextPreviewPresenting: AnyObject {
    func show(
        _ preview: TextPreview,
        onApply: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    )
    func hide()
}

@MainActor
protocol TextDelivering: AnyObject {
    var canUndoLastInsertion: Bool { get }
    var lastDeliveryStrategy: DeliveryStrategy { get }
    var lastDeliveryFailure: DeliveryFailureReason? { get }
    func injectDictation(text: String, target: TextInjectionTarget?) async -> Bool
    func inject(text: String, target: TextInjectionTarget?) async -> Bool
    func copyToPasteboard(_ text: String)
    func undoLastInsertion() -> Bool
    func prepareRecentInsertionForReplacement() -> Bool
}

extension TextDelivering {
    var lastDeliveryStrategy: DeliveryStrategy { .copied }
    var lastDeliveryFailure: DeliveryFailureReason? { nil }
    func injectDictation(text: String, target: TextInjectionTarget?) async -> Bool {
        await inject(text: text, target: target)
    }
    func prepareRecentInsertionForReplacement() -> Bool { false }
}

enum DeliveryFailureReason: String, Sendable {
    case emptyText
    case missingTarget
    case secureTarget
    case nonEditableTarget
    case targetApplicationUnavailable
    case targetApplicationNotFrontmost
    case accessibilityNotGranted
    case targetWindowChanged
    case focusedElementUnavailable
    case focusedElementChanged
    case selectionChanged
    case clipboardPasteFailed

    var userMessage: String {
        switch self {
        case .emptyText:
            "aucun texte à insérer"
        case .missingTarget:
            "aucun champ cible n’a été capturé"
        case .secureTarget:
            "le champ cible est protégé"
        case .nonEditableTarget:
            "le champ cible n’est pas éditable"
        case .targetApplicationUnavailable:
            "l’application cible a été fermée"
        case .targetApplicationNotFrontmost:
            "l’application cible n’a pas pu être réactivée"
        case .accessibilityNotGranted:
            "l’autorisation Accessibilité n’est pas reconnue"
        case .targetWindowChanged:
            "la fenêtre cible a changé"
        case .focusedElementUnavailable:
            "le champ cible n’est plus exposé à l’accessibilité"
        case .focusedElementChanged:
            "le champ actif ne correspond plus au champ initial"
        case .selectionChanged:
            "la sélection ou le curseur a changé"
        case .clipboardPasteFailed:
            "macOS a refusé le collage"
        }
    }
}

@MainActor
protocol ReplayBuffer: AnyObject {
    func retain(_ audio: Data, for sessionID: UUID)
    func audio(for sessionID: UUID) -> Data?
    func remove(sessionID: UUID)
    func removeAll()
}

protocol ActionProposing: AnyObject {
    func propose(
        instruction: String,
        context: ContextSnapshot
    ) async throws -> ActionProposal
}

struct ActionExecutionResult: Equatable {
    let proposalID: UUID
    let summary: String
    let didExecute: Bool
}

protocol ActionExecuting: AnyObject {
    func execute(_ proposal: ActionProposal) async throws -> ActionExecutionResult
}

@MainActor
protocol HistoryRepository: AnyObject {
    func append(_ record: HistoryRecord)
}

@MainActor
protocol VoiceInboxRepository: AnyObject {
    func append(_ record: HistoryRecord)
}

struct ModelDescriptor: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let version: String
    let checksum: String
    let downloadSize: Int64
}

enum ProviderLocality: String, Codable, Sendable {
    case local
    case cloud
}

enum ProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case requiresDownload(modelID: String)
}

struct ProviderDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let locality: ProviderLocality
    let supportedLocales: Set<String>
    let availability: ProviderAvailability
}

struct TranscriptionRequest: Sendable {
    let audioURL: URL
    let locale: Locale?
    let vocabulary: [String]
}

protocol TranscriptionRouting: AnyObject {
    func provider(
        for mode: ModeDefinition,
        capabilities: CapabilityMatrix
    ) throws -> any SpeechTranscribing
    func fallbackProvider(
        after identifier: String,
        for mode: ModeDefinition,
        capabilities: CapabilityMatrix
    ) -> (any SpeechTranscribing)?
}

extension TranscriptionRouting {
    func fallbackProvider(
        after identifier: String,
        for mode: ModeDefinition,
        capabilities: CapabilityMatrix
    ) -> (any SpeechTranscribing)? { nil }
}

enum ProviderFailurePolicy {
    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? ProviderRequestFailure {
            return isTransient(failure.underlying)
        }
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable
            ].contains(urlError.code)
        }
        if case TranscriptionService.TranscriptionError.httpError(let status) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if case TranscriptionService.TranscriptionError.httpFailure(
            let status,
            _,
            _
        ) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if case OpenAITextProcessingService.ProcessingError.httpError(let status) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if case OpenAITextProcessingService.ProcessingError.httpFailure(
            let status,
            _,
            _
        ) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return false
    }

    /// A retry is automatic only when repeating the request cannot plausibly
    /// duplicate a successful provider-side operation.
    static func isSafeToRetry(_ error: Error) -> Bool {
        if let failure = error as? ProviderRequestFailure {
            return isSafeToRetry(failure.underlying)
        }
        if let urlError = error as? URLError {
            return [
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable
            ].contains(urlError.code)
        }
        return isTransientHTTP(error)
    }

    static func retryDelay(for error: Error) -> Duration {
        if let failure = error as? ProviderRequestFailure {
            return retryDelay(for: failure.underlying)
        }
        let retryAfter: TimeInterval?
        switch error {
        case TranscriptionService.TranscriptionError.httpFailure(_, _, let delay):
            retryAfter = delay
        case OpenAITextProcessingService.ProcessingError.httpFailure(_, _, let delay):
            retryAfter = delay
        default:
            retryAfter = nil
        }
        return .milliseconds(Int(min(max(retryAfter ?? 0.35, 0.1), 3) * 1_000))
    }

    static func performWithOneSafeRetry<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isSafeToRetry(error), !Task.isCancelled else { throw error }
            try await Task.sleep(for: retryDelay(for: error))
            return try await operation()
        }
    }

    private static func isTransientHTTP(_ error: Error) -> Bool {
        switch error {
        case TranscriptionService.TranscriptionError.httpFailure(let status, _, _),
             TranscriptionService.TranscriptionError.httpError(let status),
             OpenAITextProcessingService.ProcessingError.httpFailure(let status, _, _),
             OpenAITextProcessingService.ProcessingError.httpError(let status):
            return status == 408 || status == 429 || (500...599).contains(status)
        default:
            return false
        }
    }
}

enum ProviderNetworkError: LocalizedError, Equatable {
    case cannotResolveHost
    case offline
    case cannotConnect
    case connectionLost
    case timedOut

    init?(_ error: Error) {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            self = .cannotResolveHost
        case .notConnectedToInternet:
            self = .offline
        case .cannotConnectToHost, .resourceUnavailable:
            self = .cannotConnect
        case .networkConnectionLost:
            self = .connectionLost
        case .timedOut:
            self = .timedOut
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .cannotResolveHost:
            "Impossible de joindre OpenAI — vérifie ta connexion, ton DNS ou ton VPN"
        case .offline:
            "Aucune connexion Internet — vérifie le réseau puis réessaie"
        case .cannotConnect:
            "Connexion à OpenAI impossible — vérifie le réseau, le pare-feu ou le VPN"
        case .connectionLost:
            "La connexion à OpenAI a été interrompue — tu peux réessayer"
        case .timedOut:
            "OpenAI n’a pas répondu à temps — tu peux réessayer"
        }
    }
}

struct ProviderRequestFailure: LocalizedError {
    let underlying: Error
    let networkMetrics: NetworkRequestMetrics?

    var errorDescription: String? { underlying.localizedDescription }
}

protocol ProcessingRouting: AnyObject {
    func provider(
        for mode: ModeDefinition,
        capabilities: CapabilityMatrix
    ) throws -> any TextProcessing
}

protocol ModelRepository: AnyObject {
    func installedModels() -> [ModelDescriptor]
    func install(_ model: ModelDescriptor) async throws
    func remove(_ model: ModelDescriptor) throws
}

protocol SoundFeedback: AnyObject {
    func playStartSound()
    func playStopSound()
    func playErrorSound()
}

protocol MetricsRecording: AnyObject {
    func record(_ step: MetricStep, duration: TimeInterval)
    func recordFailure(_ step: MetricStep, error: Error, duration: TimeInterval)
    func recordSession(_ trace: SessionPerformanceTrace)
}

extension MetricsRecording {
    func recordFailure(
        _ step: MetricStep,
        error: Error,
        duration: TimeInterval
    ) {}
    func recordSession(_ trace: SessionPerformanceTrace) {}
}

@MainActor
protocol HUDPresenting: AnyObject {
    var onCancel: (() -> Void)? { get set }
    var onUndo: (() -> Void)? { get set }
    var isUndoAvailable: Bool { get set }
    func updateAudioLevel(_ level: Float)
    func show(_ state: HUDState, detail: String?, autoHide: Bool)
    func hide()
    func configureResultActions(
        canRetranscribe: Bool,
        retranscribeLabel: String,
        canCompareRawAndFinal: Bool,
        canCorrect: Bool,
        onCopy: @escaping () -> Void,
        onRetranscribe: @escaping () -> Void,
        onCompareRawAndFinal: @escaping () -> Void,
        onCorrect: @escaping () -> Void
    )
    func configureModeSelection(
        currentModeID: UUID,
        options: [HUDModeOption],
        onSelect: @escaping (UUID) -> Void
    )
}

extension HUDPresenting {
    func configureResultActions(
        canRetranscribe: Bool,
        retranscribeLabel: String,
        canCompareRawAndFinal: Bool,
        canCorrect: Bool,
        onCopy: @escaping () -> Void,
        onRetranscribe: @escaping () -> Void,
        onCompareRawAndFinal: @escaping () -> Void,
        onCorrect: @escaping () -> Void
    ) {}
    func configureModeSelection(
        currentModeID: UUID,
        options: [HUDModeOption],
        onSelect: @escaping (UUID) -> Void
    ) {}
}
