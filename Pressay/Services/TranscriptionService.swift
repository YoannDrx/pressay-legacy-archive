import Foundation

struct TranscriptionResult: Equatable {
    let text: String
    let averageLogProbability: Double?
    let networkMetrics: NetworkRequestMetrics?
    let modelIdentifier: String?

    init(
        text: String,
        averageLogProbability: Double?,
        networkMetrics: NetworkRequestMetrics? = nil,
        modelIdentifier: String? = nil
    ) {
        self.text = text
        self.averageLogProbability = averageLogProbability
        self.networkMetrics = networkMetrics
        self.modelIdentifier = modelIdentifier
    }

    var isLowConfidence: Bool {
        guard let averageLogProbability else { return false }
        return averageLogProbability < Constants.lowConfidenceLogProbability
    }
}

enum TranscriptionResponseValidator {
    private static let knownHallucinatedEndings = [
        "faites ce que vous voulez"
    ]
    private static let wordExpression = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+"
    )

    static func validated(
        _ text: String,
        vocabulary: String,
        prompt: String? = nil
    ) throws -> String {
        let cleanText = removeKnownHallucinatedEnding(
            from: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !cleanText.isEmpty else {
            throw TranscriptionService.TranscriptionError.noSpeech
        }

        let normalizedText = normalized(cleanText)
        let rejectedEchoes = [vocabulary, prompt ?? ""]
            .map(normalized)
            .filter { !$0.isEmpty }
        if rejectedEchoes.contains(normalizedText) {
            throw TranscriptionService.TranscriptionError.noSpeech
        }
        return cleanText
    }

    private static func removeKnownHallucinatedEnding(from text: String) -> String {
        for ending in knownHallucinatedEndings {
            let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let wordMatches = wordExpression.matches(in: text, range: textRange)
            let endingWords = normalized(ending).split(separator: " ").map(String.init)
            guard wordMatches.count >= endingWords.count else { continue }

            let suffixMatches = wordMatches.suffix(endingWords.count)
            let suffixWords = suffixMatches.compactMap { match -> String? in
                guard let range = Range(match.range, in: text) else { return nil }
                return normalized(String(text[range]))
            }
            guard suffixWords == endingWords,
                  let firstMatch = suffixMatches.first,
                  let phraseRange = Range(firstMatch.range, in: text) else {
                continue
            }

            return cleanedPrefix(String(text[..<phraseRange.lowerBound]))
        }
        return text
    }

    private static func cleanedPrefix(_ prefix: String) -> String {
        var result = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let softSeparators = CharacterSet(charactersIn: ",;:\u{2013}\u{2014}-")
        while let scalar = result.unicodeScalars.last,
              softSeparators.contains(scalar) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum InstantDictationTextNormalizer {
    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class TranscriptionService: SpeechTranscribing {
    static let shared = TranscriptionService()

    private let session: URLSession
    private let apiKeyProvider: () -> String?
    private let defaults: UserDefaults

    var identifier: String { "openai" }
    var isReady: Bool { apiKeyProvider() != nil }

    init(
        session: URLSession? = nil,
        apiKeyProvider: @escaping () -> String? = {
            KeychainHelper.shared.getAPIKey()
        },
        defaults: UserDefaults = .standard
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.apiKeyProvider = apiKeyProvider
        self.defaults = defaults
        // Normalize short-lived model preferences as soon as the
        // service is created, rather than waiting for the user's next dictation.
        _ = OpenAITranscriptionProfile.current(in: defaults)
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let logprobs: [TokenLogProbability]?
    }

    private struct TokenLogProbability: Decodable {
        let logprob: Double
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorDetail
    }

    private struct ErrorDetail: Decodable {
        let message: String
    }

    private struct PreparedTranscriptionRequest {
        let request: URLRequest
        let vocabulary: String
        let prompt: String?
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        // This method is normally entered from SessionCoordinator's MainActor.
        // Keychain access and multipart assembly are synchronous, so doing them
        // inline can freeze the HUD and prevent the timeout task from firing.
        let apiKeyProvider = self.apiKeyProvider
        let apiKey = try await Task.detached(priority: .userInitiated) {
            guard let apiKey = apiKeyProvider() else {
                throw TranscriptionError.noAPIKey
            }
            return apiKey
        }.value
        let language = defaults.string(forKey: Constants.transcriptionLanguageKey)
            ?? Constants.defaultTranscriptionLanguage
        let vocabulary = Self.selectedVocabulary(preferences: defaults)
        // Pressay deliberately uses one Mini completed-file request after Fn
        // is released. This avoids a Realtime socket, finalization handshake,
        // fallback race and any unnoticed switch to a different model.
        let model = OpenAITranscriptionProfile.current(in: defaults)
            .primaryModel
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareRequest(
                audioURL: audioURL,
                apiKey: apiKey,
                language: language,
                vocabulary: vocabulary,
                model: model
            )
        }.value
        try Task.checkCancellation()

        let decoded: TranscriptionResponse
        var requestMetrics: [NetworkRequestMetrics] = []
        do {
            decoded = try await ProviderFailurePolicy.performWithOneSafeRetry {
                let collector = NetworkTaskMetricsCollector()
                let startedAt = Date()
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await self.session.data(
                        for: prepared.request,
                        delegate: collector
                    )
                } catch {
                    requestMetrics.append(
                        collector.snapshot(
                            fallbackTotal: Date().timeIntervalSince(startedAt)
                        )
                    )
                    throw error
                }
                requestMetrics.append(
                    collector.snapshot(
                        fallbackTotal: Date().timeIntervalSince(startedAt)
                    )
                )
                try Task.checkCancellation()
                return try self.decodeResponse(data: data, response: response)
            }
        } catch {
            if Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw error
            }
            let underlying: Error
            if let networkError = ProviderNetworkError(error) {
                underlying = networkError
            } else {
                underlying = error
            }
            throw ProviderRequestFailure(
                underlying: underlying,
                networkMetrics: .combined(requestMetrics)
            )
        }
        let cleanText = try TranscriptionResponseValidator.validated(
            decoded.text,
            vocabulary: prepared.vocabulary,
            prompt: prepared.prompt
        )
        let probabilities = decoded.logprobs?.map(\.logprob) ?? []
        let averageLogProbability = probabilities.isEmpty
            ? nil
            : probabilities.reduce(0, +) / Double(probabilities.count)
        return TranscriptionResult(
            text: cleanText,
            averageLogProbability: averageLogProbability,
            networkMetrics: .combined(requestMetrics),
            modelIdentifier: model
        )
    }

    private static func prepareRequest(
        audioURL: URL,
        apiKey: String,
        language: String,
        vocabulary: String,
        model: String
    ) throws -> PreparedTranscriptionRequest {
        let prompt = transcriptionPrompt(
            vocabulary: vocabulary,
            language: language,
            model: model
        )
        let body = try makeBody(
            audioURL: audioURL,
            model: model,
            language: language,
            vocabulary: vocabulary,
            prompt: prompt
        )

        var request = try makeRequest(
            apiKey: apiKey,
            boundary: body.boundary
        )
        request.httpBody = body.data
        return PreparedTranscriptionRequest(
            request: request,
            vocabulary: vocabulary,
            prompt: prompt
        )
    }

    func validateAPIKey(_ apiKey: String) async -> Bool {
        guard apiKey.hasPrefix("sk-") else { return false }

        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func makeBody(
        audioURL: URL,
        model: String,
        language: String,
        vocabulary: String,
        prompt: String?
    ) throws -> (data: Data, boundary: String) {
        let boundary = UUID().uuidString
        let audioData = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        var data = Data()
        data.appendMultipartFile(
            boundary: boundary,
            name: "file",
            filename: "audio.\(audioURL.pathExtension)",
            mimeType: Self.audioMIMEType(for: audioURL),
            contents: audioData
        )
        data.appendMultipartField(boundary: boundary, name: "model", value: model)
        data.appendMultipartField(
            boundary: boundary,
            name: "response_format",
            value: "json"
        )
        if TranscriptionRequestPolicy.supportsLogProbabilities(
            model: model
        ) {
            data.appendMultipartField(
                boundary: boundary,
                name: "include[]",
                value: "logprobs"
            )
        }
        if !language.isEmpty,
           TranscriptionRequestPolicy.supportsMultipleLanguageHints(
               model: model
           ) {
            data.appendMultipartField(
                boundary: boundary,
                name: "languages[]",
                value: language
            )
        } else if !language.isEmpty {
            data.appendMultipartField(
                boundary: boundary,
                name: "language",
                value: language
            )
        }
        if TranscriptionRequestPolicy.supportsKeywords(model: model) {
            for keyword in sanitizedKeywords(from: vocabulary) {
                data.appendMultipartField(
                    boundary: boundary,
                    name: "keywords[]",
                    value: keyword
                )
            }
        }
        if let prompt {
            data.appendMultipartField(
                boundary: boundary,
                name: "prompt",
                value: prompt
            )
        }
        data.appendUTF8("--\(boundary)--\r\n")
        return (data, boundary)
    }

    private static func audioMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        default: "audio/mp4"
        }
    }

    private static func makeRequest(apiKey: String, boundary: String) throws -> URLRequest {
        guard let url = URL(string: Constants.openAITranscriptionURL) else {
            throw TranscriptionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decodeResponse(data: Data, response: URLResponse) throws -> TranscriptionResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let retryAfter = Self.retryAfter(from: http)
            if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TranscriptionError.httpFailure(
                    status: http.statusCode,
                    message: error.error.message,
                    retryAfter: retryAfter
                )
            }
            throw TranscriptionError.httpFailure(
                status: http.statusCode,
                message: nil,
                retryAfter: retryAfter
            )
        }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func selectedVocabulary(preferences: UserDefaults) -> String {
        let explicitProfile = preferences.string(forKey: Constants.vocabularyProfileKey)
        let existingCustomVocabulary = preferences.string(forKey: Constants.technicalVocabularyKey)
        let profile = explicitProfile ?? (existingCustomVocabulary == nil ? "development" : "custom")
        switch profile {
        case "general":
            return Constants.generalVocabulary
        case "custom":
            return (existingCustomVocabulary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return Constants.defaultTechnicalVocabulary
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func sanitizedKeywords(from vocabulary: String) -> [String] {
        let forbidden = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'’._+#"))
            .inverted
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in vocabulary.components(
            separatedBy: CharacterSet(charactersIn: ",\n\r")
        ) {
            let scalars = rawValue.unicodeScalars.filter {
                !forbidden.contains($0)
            }
            let clean = String(String.UnicodeScalarView(scalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(64)
            guard !clean.isEmpty else { continue }
            let value = String(clean)
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == 50 { break }
        }
        return result
    }

    private static func transcriptionPrompt(
        vocabulary: String,
        language: String,
        model: String
    ) -> String? {
        if model == "whisper-1" {
            return vocabulary.isEmpty ? nil : vocabulary
        }
        // GPT Transcribe receives vocabulary through keywords[]. Repeating the
        // whole list in the prompt increases payload size and can make the
        // vocabulary itself look like dictated speech.
        let vocabularyGuidance = vocabulary.isEmpty || model == "gpt-transcribe"
            ? ""
            : language == "en"
                ? " Expected technical vocabulary: \(vocabulary)."
                : " Vocabulaire technique attendu : \(vocabulary)."
        if language == "en" {
            return "Transcribe only words actually spoken. Stop at the last spoken word; never complete trailing silence with extra text. Preserve natural punctuation.\(vocabularyGuidance)"
        }
        return "Transcris uniquement les mots réellement prononcés. Arrête-toi au dernier mot prononcé ; ne complète jamais le silence final par du texte. Conserve une ponctuation naturelle.\(vocabularyGuidance)"
    }

    enum TranscriptionError: LocalizedError, Equatable {
        case noAPIKey
        case invalidURL
        case invalidResponse
        case noSpeech
        case apiError(String)
        case httpError(Int)
        case httpFailure(
            status: Int,
            message: String?,
            retryAfter: TimeInterval?
        )

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Clé API non configurée"
            case .invalidURL:
                return "URL invalide"
            case .invalidResponse:
                return "Réponse invalide du serveur"
            case .noSpeech:
                return "Aucune parole détectée — rien n’a été collé"
            case .apiError(let message):
                return "Erreur API : \(message)"
            case .httpError(let code):
                return "Erreur HTTP : \(code)"
            case .httpFailure(let status, let message, _):
                if let message, !message.isEmpty {
                    return "OpenAI (HTTP \(status)) : \(message)"
                }
                return "OpenAI a répondu avec l’erreur HTTP \(status)"
            }
        }
    }
}

enum TranscriptionRequestPolicy {
    static func supportsLogProbabilities(model: String) -> Bool {
        model.hasPrefix("gpt-4o-")
            && model.contains("transcribe")
            && !model.contains("diarize")
    }

    static func supportsMultipleLanguageHints(model: String) -> Bool {
        model == "gpt-transcribe"
    }

    static func supportsKeywords(model: String) -> Bool {
        model == "gpt-transcribe"
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendMultipartField(
        boundary: String,
        name: String,
        value: String
    ) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendUTF8("\(value)\r\n")
    }

    mutating func appendMultipartFile(
        boundary: String,
        name: String,
        filename: String,
        mimeType: String,
        contents: Data
    ) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        append(contents)
        appendUTF8("\r\n")
    }
}
