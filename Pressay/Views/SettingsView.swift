import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateService: UpdateService
    @ObservedObject private var metrics = PerformanceMetricsService.shared
    @ObservedObject private var modes = ModeStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var localTranscription = WhisperKitTranscriptionService.shared
    @ObservedObject private var account = AccountService.shared

    @State private var apiKeyInput = ""
    @State private var isValidatingAPIKey = false
    @State private var apiKeyValidationMessage: ValidationMessage?
    @State private var diagnosticsMessage: String?
    @State private var selectedPage = SettingsPage.general
    @State private var settingsSearch = ""

    @AppStorage(Constants.transcriptionLanguageKey)
    private var language = Constants.defaultTranscriptionLanguage
    @AppStorage(Constants.processingModelKey)
    private var processingModel = Constants.defaultProcessingModel
    @AppStorage(Constants.acceleratedTextProcessingEnabledKey)
    private var acceleratedTextProcessingEnabled = false
    @AppStorage(Constants.translationTargetLanguageKey)
    private var translationTargetLanguage = Constants.defaultTranslationTargetLanguage
    @AppStorage(Constants.transcriptionEngineKey)
    private var transcriptionEngine = TranscriptionEngine.openAI.rawValue
    @AppStorage(Constants.vocabularyProfileKey)
    private var vocabularyProfile = "development"
    @AppStorage(Constants.technicalVocabularyKey)
    private var customVocabulary = ""
    @AppStorage(Constants.activationModeKey)
    private var activationMode = Constants.defaultActivationMode
    @AppStorage(Constants.historyEnabledKey)
    private var historyEnabled = true
    @AppStorage(Constants.historyRetentionDaysKey)
    private var historyRetentionDays = 1
    @AppStorage(Constants.inboxEnabledKey)
    private var inboxEnabled = false
    @AppStorage(Constants.inboxRetentionDaysKey)
    private var inboxRetentionDays = 30
    @AppStorage(Constants.metricsEnabledKey)
    private var metricsEnabled = false
    @AppStorage(Constants.remoteTelemetryEnabledKey)
    private var remoteTelemetryEnabled = false
    @AppStorage(Constants.hudPositionKey)
    private var hudPosition = HUDPosition.bottomCenter.rawValue
    @AppStorage(Constants.hudSizeKey)
    private var hudSize = HUDSize.comfortable.rawValue
    @AppStorage(Constants.hudResultDurationKey)
    private var hudResultDuration = HUDResultDuration.fast.rawValue
    @AppStorage(Constants.hudShowsResultActionsKey)
    private var hudShowsResultActions = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                TextField("Rechercher", text: $settingsSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                List(filteredPages, selection: $selectedPage) { page in
                    Label(page.label, systemImage: page.icon)
                        .tag(page)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    selectedPageContent
                        .padding(24)
                }
                footer
            }
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 640, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { appState.refreshPermissions() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            appState.refreshPermissions()
        }
        .onChange(of: historyEnabled) { _, _ in HistoryService.shared.applyPreferences() }
        .onChange(of: historyRetentionDays) { _, _ in HistoryService.shared.applyPreferences() }
        .onChange(of: inboxEnabled) { _, _ in VoiceInboxService.shared.applyPreferences() }
        .onChange(of: inboxRetentionDays) { _, _ in VoiceInboxService.shared.applyPreferences() }
        .onChange(of: transcriptionEngine) { _, engine in
            guard engine == TranscriptionEngine.whisperKit.rawValue,
                  localTranscription.isReady else { return }
            Task { try? await localTranscription.prepare() }
        }
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        VStack(spacing: 18) {
            switch selectedPage {
            case .account:
                accountSection
            case .general:
                permissionsSection
                launchAtLoginSection
                recognitionSection
                hudSection
            case .providers:
                providersSection
            case .modes:
                modesSection
            case .shortcuts:
                shortcutSection
            case .data:
                privacySection
            case .updates:
                if DistributionChannel.current.usesSparkle { updatesSection }
            case .about:
                aboutSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var availablePages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            if page == .account {
                return DistributionChannel.current == .direct
            }
            if page == .shortcuts {
                return DistributionChannel.current.supportsGlobalShortcuts
            }
            if page == .updates { return DistributionChannel.current.usesSparkle }
            return true
        }
    }

    private var filteredPages: [SettingsPage] {
        let query = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availablePages }
        return availablePages.filter {
            $0.searchTerms.localizedCaseInsensitiveContains(query)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .shadow(color: .accentColor.opacity(0.22), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pressay")
                        .font(.system(size: 18, weight: .bold))
                    Text("Ta barre de commande vocale sur macOS")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider().opacity(0.5)
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: "DÉMARRAGE", icon: "checkmark.shield") {
            VStack(spacing: 12) {
                permissionRow(
                    title: "Microphone",
                    detail: "Nécessaire pour enregistrer la dictée.",
                    granted: appState.hasMicrophonePermission,
                    action: appState.requestMicrophonePermission
                )
                if DistributionChannel.current.supportsAccessibility {
                    Divider().opacity(0.45)
                    permissionRow(
                        title: "Accessibilité",
                        detail: "Identifie la cible, protège les champs sensibles et remplace une sélection.",
                        granted: appState.hasAccessibilityPermission,
                        action: appState.requestAccessibilityPermission
                    )
                } else {
                    Divider().opacity(0.45)
                    Label(
                        "Version App Store : copie et Voice Inbox, sans contrôle des autres applications.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var launchAtLoginSection: some View {
        SettingsSection(title: "OUVERTURE", icon: "power") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Lancer Pressay à l’ouverture de session",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .font(.system(size: 12, weight: .medium))
                Text("Pressay reste disponible dans la barre des menus après le démarrage du Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var providersSection: some View {
        SettingsSection(title: "TRANSCRIPTION", icon: "waveform") {
            VStack(alignment: .leading, spacing: 13) {
                Text("Deux chemins simples : OpenAI avec ta clé, ou WhisperKit entièrement local.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Picker("Moteur", selection: $transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    TranscriptionEngine(rawValue: transcriptionEngine)?.detail
                        ?? TranscriptionEngine.openAI.detail
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                Divider().opacity(0.45)
                if transcriptionEngine == TranscriptionEngine.openAI.rawValue {
                    openAICredentialRow
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Modèle local WhisperKit")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(WhisperKitTranscriptionService.modelLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            localModelStatus
                        }

                        localModelActions
                        Text("Le premier chargement peut prendre quelques secondes. Les dictées suivantes réutilisent le modèle déjà en mémoire.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var openAICredentialRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI")
                        .font(.system(size: 12, weight: .semibold))
                    Text("gpt-4o-mini-transcribe · rapide et économique")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    appState.hasAPIKey ? "Configuré" : "Non configuré",
                    systemImage: appState.hasAPIKey
                        ? "checkmark.circle.fill"
                        : "circle.dashed"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(appState.hasAPIKey ? .green : .secondary)
            }
            HStack(spacing: 9) {
                SecureField("sk-…", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button(isValidatingAPIKey ? "Validation…" : "Valider") {
                    validateOpenAIKey()
                }
                .disabled(
                    apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isValidatingAPIKey
                )
            }
            HStack {
                if appState.hasAPIKey {
                    Button("Supprimer la clé") {
                        appState.clearAPIKey()
                        apiKeyValidationMessage = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Link(
                    "Créer une clé ↗",
                    destination: URL(string: "https://platform.openai.com/api-keys")!
                )
                .font(.system(size: 10))
            }
            if let apiKeyValidationMessage {
                Text(apiKeyValidationMessage.text)
                    .font(.system(size: 10))
                    .foregroundStyle(apiKeyValidationMessage.success ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private var localModelStatus: some View {
        switch localTranscription.modelState {
        case .notDownloaded:
            Label("À télécharger", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            Text("\(Int(progress * 100)) %")
                .foregroundStyle(.blue)
        case .loading:
            Label("Chargement…", systemImage: "cpu")
                .foregroundStyle(.blue)
        case .ready:
            Label("Prêt", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Erreur", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var localModelActions: some View {
        switch localTranscription.modelState {
        case .notDownloaded, .failed:
            Button("Télécharger le modèle local") {
                Task { await localTranscription.downloadModel() }
            }
            .buttonStyle(.borderedProminent)
        case .downloading(let progress):
            ProgressView(value: progress)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button("Supprimer le modèle") {
                do {
                    try localTranscription.removeModel()
                    transcriptionEngine = TranscriptionEngine.openAI.rawValue
                } catch {
                    diagnosticsMessage = error.localizedDescription
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }


    private var recognitionSection: some View {
        SettingsSection(title: "RECONNAISSANCE", icon: "waveform.badge.magnifyingglass") {
            VStack(alignment: .leading, spacing: 13) {
                settingPicker(title: "Langue", detail: "Une langue explicite réduit latence et erreurs.", selection: $language) {
                    Text("Français").tag("fr")
                    Text("Anglais").tag("en")
                    Text("Automatique").tag("")
                }
                Divider().opacity(0.45)
                if transcriptionEngine == TranscriptionEngine.openAI.rawValue {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcription OpenAI")
                                .font(.system(size: 12, weight: .medium))
                            Text("Un seul appel de fichier après le relâchement de Fn.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("GPT-4o Mini")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    Text(OpenAITranscriptionProfile.mini.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    Text(
                        "Pressay ferme le fichier audio au relâchement, l’envoie une seule fois à GPT-4o Mini Transcribe, puis envoie immédiatement le résultat final à l’application active. Aucune session temps réel n’est ouverte."
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Link(
                            "Fichiers ↗",
                            destination: URL(
                                string: "https://developers.openai.com/api/docs/guides/speech-to-text"
                            )!
                        )
                        Link(
                            "Tarifs ↗",
                            destination: URL(
                                string: "https://developers.openai.com/api/docs/pricing"
                            )!
                        )
                    }
                    .font(.system(size: 9.5))
                }
                Divider().opacity(0.45)
                settingPicker(title: "Profil de vocabulaire", detail: "Seul le profil actif est envoyé avec l’audio.", selection: $vocabularyProfile) {
                    Text("Développement").tag("development")
                    Text("Général").tag("general")
                    Text("Personnalisé").tag("custom")
                }
                if vocabularyProfile == "custom" {
                    TextEditor(text: $customVocabulary)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 70)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Text("Noms propres, produits et acronymes séparés par des virgules.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcutSection: some View {
        SettingsSection(title: "DÉCLENCHEMENT", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 13) {
                LabeledContent {
                    ShortcutRecorderField(
                        router: appState.keyboardService,
                        action: .dictate
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictée")
                            .font(.system(size: 12, weight: .medium))
                        Text("Un modificateur seul ou une combinaison globale.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.45)
                LabeledContent {
                    ShortcutRecorderField(
                        router: appState.keyboardService,
                        action: .correctLastInsertion
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corriger la dernière insertion")
                            .font(.system(size: 12, weight: .medium))
                        Text("Sélection sûre, instruction vocale puis aperçu.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.45)
                LabeledContent {
                    ShortcutRecorderField(
                        router: appState.keyboardService,
                        action: .transformSelection
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transformation")
                            .font(.system(size: 12, weight: .medium))
                        Text("Parle pour transformer la sélection courante.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.45)
                settingPicker(title: "Mode", detail: activationMode == ActivationMode.hold.rawValue
                    ? "Maintiens le modificateur pour parler, relâche pour envoyer. Une combinaison classique bascule début/fin."
                    : "Appuie une fois pour démarrer, une fois pour envoyer.", selection: $activationMode) {
                    ForEach(ActivationMode.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
            }
        }
    }

    private var modesSection: some View {
        SettingsSection(title: "MODES", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 13) {
                settingPicker(
                    title: "Mode par défaut",
                    detail: "Fidèle reste local au pipeline ; les autres transforment le texte après transcription.",
                    selection: selectedModeBinding
                ) {
                    ForEach(modes.visibleModes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                if modes.selectedModeID == NativeModeCatalog.translationID {
                    Divider().opacity(0.45)
                    settingPicker(
                        title: "Langue de traduction",
                        detail: "Cible explicite utilisée par la traduction directe et son repli.",
                        selection: $translationTargetLanguage
                    ) {
                        Text("Anglais").tag("en")
                        Text("Français").tag("fr")
                    }
                }
                Divider().opacity(0.45)
                settingPicker(
                    title: "Traitement cloud",
                    detail: "Modèle rapide pour nettoyage, structure et transformation.",
                    selection: $processingModel
                ) {
                    Text("GPT-5.6 Luna").tag("gpt-5.6-luna")
                    Text("GPT-5.6 Terra").tag("gpt-5.6-terra")
                    Text("GPT-5.6 Sol").tag("gpt-5.6-sol")
                }
                Toggle(
                    "Traitement texte prioritaire (coût API supérieur)",
                    isOn: $acceleratedTextProcessingEnabled
                )
                .font(.system(size: 11, weight: .medium))
                Text(
                    "Utilise le niveau de service Fast pour Traduction et les autres styles. La transcription Fidèle n’est pas concernée."
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                Label(
                    "Les modes « Cloud autorisé » s’exécutent directement. Seules leurs sources autorisées sont envoyées et store: false désactive leur conservation comme état applicatif.",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                Button(
                    DistributionChannel.current.supportsApplicationProfiles
                        ? "Gérer les modes et profils d’app…"
                        : "Gérer les modes…"
                ) {
                    ModesWindowController.shared.show(
                        shortcutRouter: appState.keyboardService
                    )
                }
            }
        }
    }

    private var hudSection: some View {
        SettingsSection(title: "HUD", icon: "rectangle.inset.filled") {
            VStack(alignment: .leading, spacing: 13) {
                settingPicker(
                    title: "Position",
                    detail: "Écran qui contient le pointeur au début de la dictée.",
                    selection: $hudPosition
                ) {
                    ForEach(HUDPosition.allCases) { position in
                        Text(position.label).tag(position.rawValue)
                    }
                }
                Divider().opacity(0.45)
                settingPicker(
                    title: "Taille",
                    detail: "Compacte ou confortable selon ton espace de travail.",
                    selection: $hudSize
                ) {
                    ForEach(HUDSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                Divider().opacity(0.45)
                settingPicker(
                    title: "Résultat",
                    detail: "Durée avant disparition ; le survol met le délai en pause.",
                    selection: $hudResultDuration
                ) {
                    ForEach(HUDResultDuration.allCases) { duration in
                        Text(duration.label).tag(duration.rawValue)
                    }
                }
                Toggle(
                    "Afficher Copier, Retranscrire, Brut/Final et Annuler",
                    isOn: $hudShowsResultActions
                )
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "CONFIDENTIALITÉ ET MESURES", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("Conserver un historique local chiffré", isOn: $historyEnabled)
                    .font(.system(size: 12, weight: .medium))
                if historyEnabled {
                    settingPicker(title: "Rétention", detail: "Suppression automatique sur ce Mac.", selection: $historyRetentionDays) {
                        Text("24 heures").tag(1)
                        Text("7 jours").tag(7)
                        Text("30 jours").tag(30)
                    }
                }
                Divider().opacity(0.45)
                Toggle(
                    "Conserver les dictées sans cible dans la Voice Inbox",
                    isOn: $inboxEnabled
                )
                .font(.system(size: 12, weight: .medium))
                if inboxEnabled {
                    settingPicker(
                        title: "Rétention Inbox",
                        detail: "Stockage local chiffré, distinct de l’historique.",
                        selection: $inboxRetentionDays
                    ) {
                        Text("7 jours").tag(7)
                        Text("30 jours").tag(30)
                        Text("90 jours").tag(90)
                    }
                }
                Divider().opacity(0.45)
                Toggle("Mesurer les temps de traitement localement", isOn: $metricsEnabled)
                    .font(.system(size: 12, weight: .medium))
                Text("Optionnel : uniquement des durées agrégées, jamais l’audio ni le texte, aucun envoi.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if metricsEnabled {
                    HStack(spacing: 12) {
                        ForEach(MetricStep.allCases, id: \.rawValue) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.label).font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(metricText(step)).font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                        }
                        Spacer()
                        Button("Réinitialiser") { metrics.reset() }
                            .font(.system(size: 10))
                    }
                    .id(metrics.revision)
                    if let trace = metrics.recentSessionTraces().first {
                        Divider().opacity(0.35)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Dernière dictée")
                                    .font(.system(size: 10, weight: .semibold))
                                Spacer()
                                Text(trace.transcriptionProvider)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Text(traceSummary(trace))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                        }
                        .id("trace-\(metrics.revision)")
                    }
                }
                Divider().opacity(0.45)
                Toggle(
                    "Partager des métadonnées produit minimales",
                    isOn: $remoteTelemetryEnabled
                )
                .font(.system(size: 12, weight: .medium))
                Text(
                    "Optionnel : version majeure de macOS, architecture, version Pressay, moteur et modèle local. Jamais l’audio, la dictée, le contexte, le presse-papiers ni ta clé API."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                Divider().opacity(0.45)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics exportables")
                            .font(.system(size: 12, weight: .medium))
                        Text("Versions, configuration non sensible et durées agrégées uniquement.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Exporter…", action: exportDiagnostics)
                        .accessibilityHint(
                            "Crée un fichier JSON sans audio, texte, sélection ni clé API"
                        )
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(diagnosticsMessage)
                }
            }
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "À PROPOS", icon: "info.circle") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(DistributionChannel.current.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Audio temporaire · Historique AES-256 · Télémétrie distante facultative")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Confidentialité", destination: URL(string: "https://press-say.app/fr/privacy")!)
                    .font(.system(size: 10))
            }
        }
    }

    private var accountSection: some View {
        VStack(spacing: 18) {
            SettingsSection(title: "COMPTE PRESSAY", icon: "person.crop.circle") {
                VStack(alignment: .leading, spacing: 13) {
                    switch account.state {
                    case .unavailable:
                        Label(
                            "Les paramètres de connexion ne sont pas inclus dans cette build.",
                            systemImage: "wrench.and.screwdriver"
                        )
                        .foregroundStyle(.secondary)
                    case .signedOut:
                        Text("Connecte l’app Direct à ton compte Pressay pour synchroniser tes droits et gérer tes Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Se connecter à Pressay") {
                            Task { await account.signIn() }
                        }
                        .buttonStyle(.borderedProminent)
                    case .signingIn:
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Connexion sécurisée dans le navigateur…")
                        }
                    case .loading:
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Vérification du compte et des droits…")
                        }
                    case .signedIn:
                        signedInAccountContent
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        HStack {
                            Button("Réessayer") { Task { await account.refresh() } }
                            Button("Se déconnecter") { account.signOut() }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsSection(title: "CONFIDENTIALITÉ", icon: "hand.raised.fill") {
                Text("Le compte reçoit uniquement les métadonnées commerciales et techniques affichées ici. L’audio, les transcriptions, l’historique, les sélections, les fichiers, le presse-papiers et la clé OpenAI restent exclus.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var signedInAccountContent: some View {
        if let user = account.account {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.displayName ?? user.email ?? "Compte Pressay")
                        .font(.system(size: 13, weight: .semibold))
                    if let email = user.email, user.displayName != nil {
                        Text(email).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let entitlement = account.entitlement {
                    Text(planLabel(entitlement.effectivePlan))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            if let entitlement = account.entitlement {
                Divider().opacity(0.45)
                LabeledContent("Source du droit", value: entitlement.effectiveSource)
                    .font(.system(size: 11))
                if let end = entitlement.grantEnd ?? entitlement.subscriptionEnd {
                    LabeledContent("Valide jusqu’au", value: end.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                }
                LabeledContent(
                    "Accès hors ligne",
                    value: entitlement.offlineValidUntil.formatted(date: .abbreviated, time: .omitted)
                )
                .font(.system(size: 11))
            }
            Divider().opacity(0.45)
            HStack {
                Link("Gérer l’abonnement ↗", destination: URL(string: "https://press-say.app/account")!)
                Spacer()
                Button("Actualiser") { Task { await account.refresh() } }
                Button("Se déconnecter") { account.signOut() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }

        if !account.devices.isEmpty {
            Divider().opacity(0.45)
            Text("MAC ACTIFS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(account.devices) { device in
                HStack {
                    Image(systemName: "desktopcomputer")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pressay \(device.appVersion) · \(device.architecture ?? "Mac")")
                            .font(.system(size: 11, weight: .medium))
                        Text("Dernier contact \(device.lastSeenAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Révoquer") {
                        Task { await account.revokeDevice(device.id) }
                    }
                    .font(.system(size: 10))
                }
            }
        }
        if let requestID = account.requestID {
            Text("Request ID : \(requestID)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func planLabel(_ plan: String) -> String {
        switch plan {
        case "lifetime_byok": "Lifetime"
        case "pro_byok": "Pro BYOK"
        case "pro_cloud": "Pro Cloud"
        default: "Free"
        }
    }

    private var updatesSection: some View {
        SettingsSection(title: "MISES À JOUR", icon: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Inclure les versions bêta",
                    isOn: $updateService.includeBetaUpdates
                )
                .font(.system(size: 12, weight: .medium))
                Text(
                    updateService.includeBetaUpdates
                        ? "Les bêtas peuvent être instables. Les versions stables restent toujours proposées."
                        : "Seules les versions stables sont proposées."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                Button("Rechercher une mise à jour") {
                    updateService.checkForUpdates()
                }
                .disabled(!updateService.canCheckForUpdates)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack {
                Text("Prêt pour les dictées courtes comme longues.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Autoriser", action: action)
            } else {
                Text("Accordée").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
            }
        }
    }

    private func settingPicker<Value: Hashable, Content: View>(
        title: String,
        detail: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .frame(width: 160)
        }
    }

    private var selectedModeBinding: Binding<UUID> {
        Binding(
            get: { modes.selectedModeID },
            set: { modes.selectedModeID = $0 }
        )
    }

    private func validateOpenAIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidatingAPIKey = true
        apiKeyValidationMessage = nil
        Task {
            let valid = await appState.updateAPIKey(key)
            isValidatingAPIKey = false
            apiKeyValidationMessage = ValidationMessage(
                success: valid,
                text: valid
                    ? "Clé vérifiée et enregistrée dans le Trousseau."
                    : "Clé invalide ou accès API indisponible."
            )
            if valid { apiKeyInput = "" }
        }
    }

    private func metricText(_ step: MetricStep) -> String {
        guard let p50 = metrics.percentile(for: step, percentile: 0.5),
              let p95 = metrics.percentile(for: step, percentile: 0.95) else {
            return "—"
        }
        return "\(compactDuration(p50)) / p95 \(compactDuration(p95))"
    }

    private func traceSummary(_ trace: SessionPerformanceTrace) -> String {
        let audio = compactDuration(trace.audioDurationSeconds)
        let transcription = compactDuration(trace.transcriptionSeconds)
        let processing = compactDuration(trace.processingSeconds)
        let insertion = compactDuration(trace.insertionSeconds)
        return "Audio \(audio) · API \(transcription) · Traitement \(processing) · Insertion \(insertion)"
    }

    private func compactDuration(_ value: TimeInterval) -> String {
        value < 1 ? "\(Int(value * 1_000)) ms" : String(format: "%.1f s", value)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "pressay-diagnostics.json"
        panel.title = "Exporter les diagnostics Pressay"
        panel.message = "Le fichier ne contient ni audio, ni texte dicté, ni sélection, ni clé API."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = DiagnosticReport.make(
                metricsService: metrics,
                permissions: DiagnosticPermissions(
                    microphone: appState.hasMicrophonePermission,
                    accessibility: appState.hasAccessibilityPermission
                ),
                customModeCount: modes.customModes.count,
                applicationProfileCount: modes.applicationProfiles.count,
                betaUpdatesEnabled: updateService.includeBetaUpdates
            )
            try report.encoded().write(to: url, options: [.atomic])
            diagnosticsMessage = "Diagnostics exportés : \(url.lastPathComponent)"
        } catch {
            diagnosticsMessage = "Échec de l’export : \(error.localizedDescription)"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2"
    }

    private struct ValidationMessage {
        let success: Bool
        let text: String
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case account
    case general
    case providers
    case modes
    case shortcuts
    case data
    case updates
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .account: "Compte"
        case .general: "Général"
        case .providers: "Fournisseurs"
        case .modes: "Modes"
        case .shortcuts: "Raccourcis"
        case .data: "Données"
        case .updates: "Mises à jour"
        case .about: "À propos"
        }
    }

    var icon: String {
        switch self {
        case .account: "person.crop.circle"
        case .general: "gearshape"
        case .providers: "key.fill"
        case .modes: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .data: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }

    var searchTerms: String {
        switch self {
        case .account: "compte connexion abonnement plan appareils droits facturation"
        case .general: "général microphone accessibilité langue reconnaissance HUD démarrage ouverture"
        case .providers: "transcription OpenAI WhisperKit local clé API hors ligne"
        case .modes: "modes profils applications fidèle propre email message"
        case .shortcuts: "raccourcis clavier fn globe maintenir bascule"
        case .data: "données confidentialité historique inbox métriques diagnostic export"
        case .updates: "mises à jour beta version sparkle"
        case .about: "à propos version confidentialité support"
        }
    }
}

@MainActor
private final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Impossible de modifier l’ouverture automatique : \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(0.06), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(
            UpdateService(
                canCheckForUpdates: true,
                checkForUpdatesAction: {}
            )
        )
}
