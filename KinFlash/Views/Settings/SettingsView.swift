import SwiftUI
import GRDB
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedProvider: String = "apple"
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var anthropicModel: String = "claude-sonnet-4-6"
    @State private var openAIModel: String = "gpt-4o"
    @State private var rootPersonId: UUID?
    @State private var showGEDCOMExport = false
    @State private var showGEDCOMImport = false
    @State private var showDeleteConfirmation = false
    @State private var deleteConfirmText = ""
    @State private var exportedGEDCOM: String?
    @State private var statusMessage: String?

    let anthropicModels = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
    let openAIModels = ["gpt-4o", "gpt-4o-mini", "o3-mini"]

    var body: some View {
        Form {
            aiProviderSection
            familyTreeSection
            dataSection
            aboutSection
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadSettings)
        .sheet(isPresented: $showGEDCOMImport) {
            GEDCOMImportView(onComplete: {
                showGEDCOMImport = false
                appState.refreshPeople()
            })
        }
        .alert("Delete All Data", isPresented: $showDeleteConfirmation) {
            TextField("Type DELETE to confirm", text: $deleteConfirmText)
            Button("Delete", role: .destructive) {
                if deleteConfirmText == "DELETE" {
                    deleteAllData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all people, relationships, flashcards, and attachments. This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var aiProviderSection: some View {
        Section("AI Provider") {
            Picker("Active Provider", selection: $selectedProvider) {
                Text("Apple Intelligence").tag("apple")
                Text("Anthropic (Claude)").tag("anthropic")
                Text("OpenAI (GPT)").tag("openai")
            }
            .onChange(of: selectedProvider) { _, newValue in
                saveProvider(newValue)
            }

            switch selectedProvider {
            case "apple":
                Text("On-device, free, no API key needed. Best for families up to ~50 people.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case "anthropic":
                Text("Cloud AI. Handles large families (500+ people), complex relationships, and natural conversation. Requires API key from console.anthropic.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case "openai":
                Text("Cloud AI. Handles large families (500+ people), complex relationships, and natural conversation. Requires API key from platform.openai.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }

            // Anthropic key — always visible so you can enter it anytime
            SecureField("Anthropic API Key", text: $anthropicKey)
                .onSubmit { saveAPIKey("anthropic_api_key", value: anthropicKey) }
                .onChange(of: anthropicKey) { _, newValue in
                    saveAPIKey("anthropic_api_key", value: newValue)
                }
            if selectedProvider == "anthropic" {
                Picker("Claude Model", selection: $anthropicModel) {
                    ForEach(anthropicModels, id: \.self) { Text($0) }
                }
                .onChange(of: anthropicModel) { _, newValue in
                    saveModel(newValue)
                }
            }

            // OpenAI key — always visible
            SecureField("OpenAI API Key", text: $openAIKey)
                .onSubmit { saveAPIKey("openai_api_key", value: openAIKey) }
                .onChange(of: openAIKey) { _, newValue in
                    saveAPIKey("openai_api_key", value: newValue)
                }
            if selectedProvider == "openai" {
                Picker("GPT Model", selection: $openAIModel) {
                    ForEach(openAIModels, id: \.self) { Text($0) }
                }
                .onChange(of: openAIModel) { _, newValue in
                    saveModel(newValue)
                }
            }
        }
    }

    private var familyTreeSection: some View {
        Section("Family Tree") {
            if !appState.people.isEmpty {
                Picker("Root Person", selection: $rootPersonId) {
                    Text("None").tag(UUID?.none)
                    ForEach(appState.people) { person in
                        Text(person.displayName).tag(UUID?.some(person.id))
                    }
                }
                .onChange(of: rootPersonId) { _, newValue in
                    if let id = newValue {
                        appState.setRootPerson(id)
                    }
                }
            }

            Button("Export as .ged") {
                exportGEDCOM()
            }

            Button("Import .ged File") {
                showGEDCOMImport = true
            }

            Button("Load Sample Family (25 people)") {
                loadSampleFamily()
            }

            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Delete All Data", role: .destructive) {
                deleteConfirmText = ""
                showDeleteConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appState.appVersion)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("People")
                Spacer()
                Text("\(appState.people.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        guard let db = appState.databaseManager else { return }
        let keychain = KeychainManager()

        do {
            let settings = try db.dbQueue.read { database in
                try AppSettings.current(database)
            }
            selectedProvider = settings.selectedAIProvider ?? "apple"
            rootPersonId = settings.rootPersonId

            if let model = settings.selectedModel {
                if anthropicModels.contains(model) { anthropicModel = model }
                if openAIModels.contains(model) { openAIModel = model }
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }

        anthropicKey = keychain.get(key: "anthropic_api_key") ?? ""
        openAIKey = keychain.get(key: "openai_api_key") ?? ""
    }

    private func saveProvider(_ provider: String) {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                var settings = try AppSettings.current(database)
                settings.selectedAIProvider = provider
                settings.updatedAt = Date()
                try settings.update(database)
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func saveModel(_ model: String) {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                var settings = try AppSettings.current(database)
                settings.selectedModel = model
                settings.updatedAt = Date()
                try settings.update(database)
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func saveAPIKey(_ key: String, value: String) {
        let keychain = KeychainManager()
        if value.isEmpty {
            keychain.delete(key: key)
        } else {
            keychain.set(key: key, value: value)
        }
    }

    private func exportGEDCOM() {
        guard let db = appState.databaseManager else { return }
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        do {
            let content = try exporter.export()
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("kinflash_export.ged")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)

            // Use UIActivityViewController
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }

            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            rootVC.present(activityVC, animated: true)

            statusMessage = "Exported \(appState.people.count) people"
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func loadSampleFamily() {
        guard let db = appState.databaseManager else { return }
        guard let url = Bundle.main.url(forResource: "SampleFamily", withExtension: "ged") else {
            appState.errorMessage = "Sample family file not found in bundle"
            return
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let parser = GEDCOMParser()
            let result = parser.parse(content: content)
            try parser.importToDatabase(result, dbQueue: db.dbQueue)

            // Set John Smith as root person (central figure)
            if let john = result.people.first(where: { $0.firstName == "John" && $0.lastName == "Smith" }) {
                appState.setRootPerson(john.id)
            } else if let first = result.people.first {
                appState.setRootPerson(first.id)
            }

            appState.refreshPeople()
            statusMessage = "Loaded \(result.people.count) people, \(result.relationships.count) relationships"
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func deleteAllData() {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM flashcard")
                try database.execute(sql: "DELETE FROM flashcardDeck")
                try database.execute(sql: "DELETE FROM attachment")
                try database.execute(sql: "DELETE FROM relationship")
                try database.execute(sql: "DELETE FROM person")
                var settings = try AppSettings.current(database)
                settings.rootPersonId = nil
                settings.updatedAt = Date()
                try settings.update(database)
            }
            appState.rootPersonId = nil
            appState.refreshPeople()
            statusMessage = "All data deleted"
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
