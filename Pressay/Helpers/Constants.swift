import Foundation

enum Constants {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let bundleIdentifier = "fr.yodev.pressay"
    static let keychainService = bundleIdentifier
    static let legacyBundleIdentifiers = [
        "fr.yodev.whisper",
        "com.hyrak.whisper"
    ]
    static let keychainAPIKeyAccount = "openai-api-key"
    static let keychainHistoryKeyAccount = "history-encryption-key"
    static let keychainInboxKeyAccount = "inbox-encryption-key"
    static let keychainActionJournalKeyAccount = "action-journal-encryption-key"
    static let keychainFoundingEligibilityAccount = "founding-eligibility-v1"
    static let keychainAccountTokensAccount = "pressay-account-oauth-tokens-v1"
    static let keychainDeviceIdentifierAccount = "pressay-device-identifier-v1"
    static let cachedEntitlementSnapshotKey = "pressay-entitlement-snapshot-v1"
    static let remoteTelemetryEnabledKey = "remote-product-metrics-enabled-v1"
    static let cloudRedirectURI = URL(string: "pressay://oauth/callback")!
    static let identityMigrationCompletedKey = "pressay-identity-migration-v1-completed"
    static let applicationSupportDirectoryName = "Pressay"
    static let legacyApplicationSupportDirectoryName = "Whisper"
    static let openAITranscriptionURL = "https://api.openai.com/v1/audio/transcriptions"
    static let openAIResponsesURL = "https://api.openai.com/v1/responses"
    static let transcriptionLanguageKey = "transcription-language"
    static let transcriptionModelKey = "transcription-model"
    static let openAITranscriptionProfileKey = "openai-transcription-profile-v2"
    static let acceleratedTextProcessingEnabledKey = "accelerated-text-processing-v1"
    static let translationTargetLanguageKey = "translation-target-language-v1"
    static let technicalVocabularyKey = "technical-vocabulary"
    static let vocabularyProfileKey = "vocabulary-profile"
    static let shortcutKey = "dictation-shortcut"
    static let dictationShortcutDefinitionKey = "dictation-shortcut-definition-v1"
    static let correctionShortcutDefinitionKey = "correction-shortcut-definition-v1"
    static let activationModeKey = "dictation-activation-mode"
    static let processingModelKey = "processing-model"
    static let selectedModeIDKey = "selected-mode-id"
    static let cloudDisclosureSignaturesKey = "cloud-disclosure-signatures-v1"
    static let transcriptionEngineKey = "transcription-engine-v1"
    static let whisperKitModelPathKey = "whisperkit-model-path-v1"
    static let includeBetaUpdatesKey = "include-beta-updates"
    static let historyEnabledKey = "history-enabled"
    static let historyRetentionDaysKey = "history-retention-days"
    static let inboxEnabledKey = "voice-inbox-enabled"
    static let inboxRetentionDaysKey = "voice-inbox-retention-days"
    static let metricsEnabledKey = "local-metrics-enabled"
    static let onboardingCompletedKey = "onboarding-completed-v1"
    static let hudPositionKey = "hud-position"
    static let hudSizeKey = "hud-size"
    static let hudResultDurationKey = "hud-result-duration"
    static let hudShowsResultActionsKey = "hud-shows-result-actions"
    static let migratedPreferenceKeys = [
        transcriptionLanguageKey,
        transcriptionModelKey,
        openAITranscriptionProfileKey,
        acceleratedTextProcessingEnabledKey,
        translationTargetLanguageKey,
        technicalVocabularyKey,
        vocabularyProfileKey,
        shortcutKey,
        dictationShortcutDefinitionKey,
        correctionShortcutDefinitionKey,
        activationModeKey,
        processingModelKey,
        selectedModeIDKey,
        transcriptionEngineKey,
        includeBetaUpdatesKey,
        historyEnabledKey,
        historyRetentionDaysKey,
        inboxEnabledKey,
        inboxRetentionDaysKey,
        metricsEnabledKey,
        remoteTelemetryEnabledKey,
        hudPositionKey,
        hudSizeKey,
        hudResultDurationKey,
        hudShowsResultActionsKey
    ]
    static let defaultTranscriptionLanguage = "fr"
    static let defaultActivationMode = ActivationMode.hold.rawValue
    static let defaultTranscriptionModel = "gpt-4o-mini-transcribe"
    static let defaultOpenAITranscriptionProfile = OpenAITranscriptionProfile.mini.rawValue
    static let defaultProcessingModel = "gpt-5.6-luna"
    static let defaultTranslationTargetLanguage = "en"
    static let defaultTechnicalVocabulary = """
    API, SDK, GitHub, TypeScript, JavaScript, React, Node.js, Python, Claude, GPT, LLM, MCP, STT, TTS, Whisper, Pressay, OpenAI, Anthropic, Convex, Vercel, Next.js, SwiftUI, Xcode, iOS, macOS
    """
    static let generalVocabulary = ""

    // Le son de démarrage peut être capté par le micro. Les premiers échantillons
    // sont ignorés, puis le seuil est calibré sur le bruit propre à la dictée.
    static let audioMeteringInterval: TimeInterval = 0.05
    static let ignoredLeadingAudioDuration: TimeInterval = 0.35
    static let minimumRecordingDuration: TimeInterval = 0.45
    static let minimumVoicedDuration: TimeInterval = 0.25
    static let minimumAdaptiveThreshold: Float = -50
    static let maximumAdaptiveThreshold: Float = -32
    static let noiseMargin: Float = 10
    static let lowConfidenceLogProbability = -0.85
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter
    case pointer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter: return "Bas au centre"
        case .topCenter: return "Haut au centre"
        case .pointer: return "Près du pointeur"
        }
    }
}

enum HUDSize: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var label: String { self == .compact ? "Compacte" : "Confortable" }
}

enum HUDResultDuration: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case relaxed
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Rapide · 0,9 s"
        case .balanced: return "Normale · 1,5 s"
        case .relaxed: return "Longue · 3 s"
        case .manual: return "Manuelle"
        }
    }

    var delay: Duration? {
        switch self {
        case .fast: return .milliseconds(900)
        case .balanced: return .milliseconds(1_500)
        case .relaxed: return .seconds(3)
        case .manual: return nil
        }
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case fast = "gpt-4o-mini-transcribe"
    case accurate = "gpt-4o-transcribe"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fast: return "Rapide"
        case .accurate: return "Précision maximale"
        }
    }
}

enum OpenAITranscriptionProfile: String, CaseIterable, Identifiable {
    case mini

    var id: String { rawValue }

    var label: String {
        "GPT-4o Mini Transcribe"
    }

    var shortLabel: String { "Mini" }

    var detail: String {
        "Transcription finale rapide après le relâchement de Fn."
    }

    var primaryModel: String { "gpt-4o-mini-transcribe" }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(
            forKey: Constants.openAITranscriptionProfileKey
        ) {
            if let profile = Self(rawValue: value) {
                return profile
            }
            // The short-lived Live and GPT Transcribe preferences both return
            // to the original single Mini file-transcription path.
            if value == "live" || value == "transcribe" {
                defaults.set(
                    Self.mini.rawValue,
                    forKey: Constants.openAITranscriptionProfileKey
                )
                return .mini
            }
        }

        defaults.set(
            Self.mini.rawValue,
            forKey: Constants.openAITranscriptionProfileKey
        )
        return .mini
    }
}

enum DictationShortcut: String, CaseIterable, Identifiable {
    case function
    case rightOption
    case rightCommand

    var id: String { rawValue }
    var label: String {
        switch self {
        case .function: return "Fn / Globe"
        case .rightOption: return "⌥ droite"
        case .rightCommand: return "⌘ droite"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hold: return "Maintenir"
        case .toggle: return "Bascule"
        }
    }
}

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case whisperKit = "whisperkit"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .whisperKit: "WhisperKit local"
        }
    }

    var detail: String {
        switch self {
        case .openAI:
            "Transcription rapide avec gpt-4o-mini-transcribe et ta clé OpenAI."
        case .whisperKit:
            "Transcription hors ligne sur ce Mac ; l’audio ne quitte pas l’appareil."
        }
    }
}
