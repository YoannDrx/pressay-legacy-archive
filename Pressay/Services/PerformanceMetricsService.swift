import Foundation

enum MetricStep: String, CaseIterable {
    case capture
    case transcription
    case processing
    case insertion
    case total

    var label: String {
        switch self {
        case .capture: return "Capture"
        case .transcription: return "Transcription"
        case .processing: return "Traitement"
        case .insertion: return "Insertion"
        case .total: return "Total"
        }
    }
}

struct DiagnosticMetric: Codable, Equatable {
    let count: Int
    let totalSeconds: TimeInterval
    let averageSeconds: TimeInterval?
    let p50Seconds: TimeInterval?
    let p95Seconds: TimeInterval?
    let failureCount: Int
}

struct SessionPerformanceTrace: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let audioDurationSeconds: TimeInterval
    let transcriptionProvider: String
    let processingProvider: String?
    let transcriptionSeconds: TimeInterval
    let processingSeconds: TimeInterval
    let insertionSeconds: TimeInterval
    let totalSeconds: TimeInterval
    let deliveryStatus: DeliveryStatus
    let deliveryFailure: String?
    let networkRequests: [NetworkRequestMetrics]?
    let failurePhase: String?
    let failureCategory: String?

    init(
        id: UUID,
        createdAt: Date,
        audioDurationSeconds: TimeInterval,
        transcriptionProvider: String,
        processingProvider: String?,
        transcriptionSeconds: TimeInterval,
        processingSeconds: TimeInterval,
        insertionSeconds: TimeInterval,
        totalSeconds: TimeInterval,
        deliveryStatus: DeliveryStatus,
        deliveryFailure: String?,
        networkRequests: [NetworkRequestMetrics] = [],
        failurePhase: String? = nil,
        failureCategory: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptionProvider = transcriptionProvider
        self.processingProvider = processingProvider
        self.transcriptionSeconds = transcriptionSeconds
        self.processingSeconds = processingSeconds
        self.insertionSeconds = insertionSeconds
        self.totalSeconds = totalSeconds
        self.deliveryStatus = deliveryStatus
        self.deliveryFailure = deliveryFailure
        self.networkRequests = networkRequests.isEmpty ? nil : networkRequests
        self.failurePhase = failurePhase
        self.failureCategory = failureCategory
    }
}

struct DiagnosticPermissions: Codable, Equatable {
    let microphone: Bool
    let accessibility: Bool
}

struct DiagnosticConfiguration: Codable, Equatable {
    let transcriptionLanguage: String
    let transcriptionModel: String
    let processingModel: String
    let activationMode: String
    let historyEnabled: Bool
    let historyRetentionDays: Int
    let metricsEnabled: Bool
    let betaUpdatesEnabled: Bool
    let customModeCount: Int
    let applicationProfileCount: Int
}

struct DiagnosticReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let operatingSystem: String
    let architecture: String
    let permissions: DiagnosticPermissions
    let configuration: DiagnosticConfiguration
    let metrics: [String: DiagnosticMetric]
    let failureCategories: [String: Int]
    let recentSessions: [SessionPerformanceTrace]

    static func make(
        metricsService: PerformanceMetricsService,
        permissions: DiagnosticPermissions,
        customModeCount: Int,
        applicationProfileCount: Int,
        betaUpdatesEnabled: Bool,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        now: Date = Date()
    ) -> DiagnosticReport {
        DiagnosticReport(
            schemaVersion: 3,
            generatedAt: now,
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            buildNumber: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: runtimeArchitecture,
            permissions: permissions,
            configuration: DiagnosticConfiguration(
                transcriptionLanguage: defaults.string(
                    forKey: Constants.transcriptionLanguageKey
                ) ?? Constants.defaultTranscriptionLanguage,
                transcriptionModel: defaults.string(
                    forKey: Constants.transcriptionModelKey
                ) ?? Constants.defaultTranscriptionModel,
                processingModel: defaults.string(
                    forKey: Constants.processingModelKey
                ) ?? Constants.defaultProcessingModel,
                activationMode: defaults.string(
                    forKey: Constants.activationModeKey
                ) ?? Constants.defaultActivationMode,
                historyEnabled: boolValue(
                    forKey: Constants.historyEnabledKey,
                    defaultValue: true,
                    defaults: defaults
                ),
                historyRetentionDays: integerValue(
                    forKey: Constants.historyRetentionDaysKey,
                    defaultValue: 1,
                    defaults: defaults
                ),
                metricsEnabled: boolValue(
                    forKey: Constants.metricsEnabledKey,
                    defaultValue: false,
                    defaults: defaults
                ),
                betaUpdatesEnabled: betaUpdatesEnabled,
                customModeCount: customModeCount,
                applicationProfileCount: applicationProfileCount
            ),
            metrics: metricsService.diagnosticSnapshot(),
            failureCategories: metricsService.diagnosticFailureSnapshot(),
            recentSessions: metricsService.recentSessionTraces()
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static var runtimeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func boolValue(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil
            ? defaultValue
            : defaults.bool(forKey: key)
    }

    private static func integerValue(
        forKey key: String,
        defaultValue: Int,
        defaults: UserDefaults
    ) -> Int {
        defaults.object(forKey: key) == nil
            ? defaultValue
            : defaults.integer(forKey: key)
    }
}

final class PerformanceMetricsService: ObservableObject, MetricsRecording {
    static let shared = PerformanceMetricsService()

    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let recentSessionsKey = "metric-session-traces-v1"
    private let failureCategoriesKey = "metric-failure-categories-v1"
    private let maximumRecentSessions = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ step: MetricStep, duration: TimeInterval) {
        guard defaults.bool(forKey: Constants.metricsEnabledKey), duration >= 0 else { return }
        defaults.set(total(for: step) + duration, forKey: totalKey(step))
        defaults.set(count(for: step) + 1, forKey: countKey(step))
        revision += 1
    }

    func recordFailure(
        _ step: MetricStep,
        error: Error,
        duration: TimeInterval
    ) {
        guard defaults.bool(forKey: Constants.metricsEnabledKey) else { return }
        defaults.set(failureCount(for: step) + 1, forKey: failureCountKey(step))
        var categories = diagnosticFailureSnapshot()
        let category = MetricFailureClassifier.category(for: error)
        categories[category, default: 0] += 1
        if let data = try? JSONEncoder().encode(categories) {
            defaults.set(data, forKey: failureCategoriesKey)
        }
        if duration >= 0 {
            defaults.set(
                defaults.double(forKey: failureDurationKey(step)) + duration,
                forKey: failureDurationKey(step)
            )
        }
        revision += 1
    }

    func recordSession(_ trace: SessionPerformanceTrace) {
        guard defaults.bool(forKey: Constants.metricsEnabledKey) else { return }
        var traces = recentSessionTraces()
        traces.insert(trace, at: 0)
        if traces.count > maximumRecentSessions {
            traces.removeLast(traces.count - maximumRecentSessions)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(traces) {
            defaults.set(data, forKey: recentSessionsKey)
            revision += 1
        }
    }

    func recentSessionTraces() -> [SessionPerformanceTrace] {
        guard let data = defaults.data(forKey: recentSessionsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionPerformanceTrace].self, from: data)) ?? []
    }

    func average(for step: MetricStep) -> TimeInterval? {
        let count = count(for: step)
        guard count > 0 else { return nil }
        return total(for: step) / Double(count)
    }

    func percentile(for step: MetricStep, percentile: Double) -> TimeInterval? {
        let values = recentSessionTraces()
            .compactMap { trace -> TimeInterval? in
                switch step {
                case .capture: trace.audioDurationSeconds
                case .transcription: trace.transcriptionSeconds
                case .processing: trace.processingSeconds > 0
                    ? trace.processingSeconds
                    : nil
                case .insertion: trace.insertionSeconds > 0
                    ? trace.insertionSeconds
                    : nil
                case .total: trace.totalSeconds
                }
            }
            .sorted()
        guard !values.isEmpty else { return nil }
        let position = Int(
            (Double(values.count - 1) * min(max(percentile, 0), 1)).rounded(.up)
        )
        return values[min(values.count - 1, position)]
    }

    func reset() {
        for step in MetricStep.allCases {
            defaults.removeObject(forKey: totalKey(step))
            defaults.removeObject(forKey: countKey(step))
            defaults.removeObject(forKey: failureCountKey(step))
            defaults.removeObject(forKey: failureDurationKey(step))
        }
        defaults.removeObject(forKey: recentSessionsKey)
        defaults.removeObject(forKey: failureCategoriesKey)
        revision += 1
    }

    func diagnosticSnapshot() -> [String: DiagnosticMetric] {
        Dictionary(
            uniqueKeysWithValues: MetricStep.allCases.map { step in
                let metricCount = count(for: step)
                let metricTotal = total(for: step)
                return (
                    step.rawValue,
                    DiagnosticMetric(
                        count: metricCount,
                        totalSeconds: metricTotal,
                        averageSeconds: metricCount > 0
                            ? metricTotal / Double(metricCount)
                            : nil,
                        p50Seconds: percentile(for: step, percentile: 0.5),
                        p95Seconds: percentile(for: step, percentile: 0.95),
                        failureCount: failureCount(for: step)
                    )
                )
            }
        )
    }

    func diagnosticFailureSnapshot() -> [String: Int] {
        guard let data = defaults.data(forKey: failureCategoriesKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private func total(for step: MetricStep) -> TimeInterval {
        defaults.double(forKey: totalKey(step))
    }

    private func count(for step: MetricStep) -> Int {
        defaults.integer(forKey: countKey(step))
    }

    private func totalKey(_ step: MetricStep) -> String {
        "metric-\(step.rawValue)-total"
    }

    private func countKey(_ step: MetricStep) -> String {
        "metric-\(step.rawValue)-count"
    }

    private func failureCount(for step: MetricStep) -> Int {
        defaults.integer(forKey: failureCountKey(step))
    }

    private func failureCountKey(_ step: MetricStep) -> String {
        "metric-\(step.rawValue)-failure-count"
    }

    private func failureDurationKey(_ step: MetricStep) -> String {
        "metric-\(step.rawValue)-failure-duration"
    }
}

enum MetricFailureClassifier {
    static func category(for error: Error) -> String {
        if let failure = error as? ProviderRequestFailure {
            return category(for: failure.underlying)
        }
        if let network = error as? ProviderNetworkError {
            switch network {
            case .cannotResolveHost: return "dns"
            case .offline: return "offline"
            case .cannotConnect: return "connection"
            case .connectionLost: return "connection-lost"
            case .timedOut: return "network-timeout"
            }
        }
        if let urlError = error as? URLError {
            return "url-\(urlError.code.rawValue)"
        }
        switch error {
        case TranscriptionService.TranscriptionError.httpFailure(let status, _, _),
             TranscriptionService.TranscriptionError.httpError(let status),
             OpenAITextProcessingService.ProcessingError.httpFailure(let status, _, _),
             OpenAITextProcessingService.ProcessingError.httpError(let status):
            if status == 429 { return "http-429" }
            if (500...599).contains(status) { return "http-5xx" }
            return "http-\(status)"
        default:
            let name = String(describing: type(of: error))
            return name.contains("Timeout") ? "phase-timeout" : "other"
        }
    }
}

struct APIUsageSummary: Equatable {
    let requestCount: Int
    let audioMinutes: Double
    let estimatedUSD: Double
    let unpricedRequestCount: Int
}

struct APIUsageEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case transcription
        case processing
    }

    let id: UUID
    let createdAt: Date
    let kind: Kind
    let model: String
    let audioDurationSeconds: TimeInterval?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedUSD: Double?
}

enum OpenAICostEstimator {
    // Snapshot of the public OpenAI pricing page on 2026-08-14. The panel
    // clearly labels these values as estimates and links to actual usage.
    static let pricingDate = "14 août 2026"

    static func transcriptionUSD(
        model: String,
        audioDurationSeconds: TimeInterval
    ) -> Double? {
        let perMinute: Double? = switch model {
        case "gpt-live-transcribe": 0.017
        case "gpt-transcribe": 0.0045
        case "gpt-4o-transcribe": 0.006
        case "gpt-4o-mini-transcribe": 0.003
        default: nil
        }
        guard let perMinute else { return nil }
        return max(0, audioDurationSeconds) / 60 * perMinute
    }

    static func processingUSD(
        model: String,
        usage: OpenAITokenUsage
    ) -> Double? {
        let ratesPerMillion: (input: Double, output: Double)? = switch model {
        case "gpt-5.6-luna": (0.10, 0.60)
        default: nil
        }
        guard let ratesPerMillion else { return nil }
        return Double(max(0, usage.inputTokens)) / 1_000_000
            * ratesPerMillion.input
            + Double(max(0, usage.outputTokens)) / 1_000_000
            * ratesPerMillion.output
    }
}

@MainActor
final class APIUsageLedger: ObservableObject {
    static let shared = APIUsageLedger()

    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let storageKey = "openai-api-usage-ledger-v1"
    private let maximumEntries = 1_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordTranscription(
        model: String,
        audioDurationSeconds: TimeInterval,
        at date: Date = Date()
    ) {
        guard !Constants.isRunningTests, audioDurationSeconds > 0 else { return }
        append(
            APIUsageEntry(
                id: UUID(),
                createdAt: date,
                kind: .transcription,
                model: model,
                audioDurationSeconds: audioDurationSeconds,
                inputTokens: nil,
                outputTokens: nil,
                estimatedUSD: OpenAICostEstimator.transcriptionUSD(
                    model: model,
                    audioDurationSeconds: audioDurationSeconds
                )
            )
        )
    }

    func recordProcessing(
        model: String,
        usage: OpenAITokenUsage,
        at date: Date = Date()
    ) {
        guard !Constants.isRunningTests else { return }
        append(
            APIUsageEntry(
                id: UUID(),
                createdAt: date,
                kind: .processing,
                model: model,
                audioDurationSeconds: nil,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                estimatedUSD: OpenAICostEstimator.processingUSD(
                    model: model,
                    usage: usage
                )
            )
        )
    }

    func summary(since date: Date) -> APIUsageSummary {
        let values = entries().filter { $0.createdAt >= date }
        return APIUsageSummary(
            requestCount: values.count,
            audioMinutes: values.compactMap(\.audioDurationSeconds)
                .reduce(0, +) / 60,
            estimatedUSD: values.compactMap(\.estimatedUSD).reduce(0, +),
            unpricedRequestCount: values.filter { $0.estimatedUSD == nil }.count
        )
    }

    func reset() {
        defaults.removeObject(forKey: storageKey)
        revision += 1
    }

    private func append(_ entry: APIUsageEntry) {
        var values = entries()
        values.insert(entry, at: 0)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -90,
            to: Date()
        ) ?? .distantPast
        values = Array(
            values.lazy
                .filter { $0.createdAt >= cutoff }
                .prefix(maximumEntries)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(values) {
            defaults.set(data, forKey: storageKey)
            revision += 1
        }
    }

    private func entries() -> [APIUsageEntry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([APIUsageEntry].self, from: data)) ?? []
    }
}
