import SwiftUI
import GRDB

struct InterviewMessage: Identifiable {
    let id: UUID
    let role: AIRole
    let content: String
    let createdAt: Date
}

struct InterviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}
    /// When true, hides the Done toolbar button (used in side-by-side iPad mode)
    var embedded: Bool = false

    @State private var messages: [InterviewMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var streamingText = ""
    @State private var conversationHistory: [AIMessage] = []
    @State private var errorMessage: String?
    @State private var showRetryAlert = false
    @State private var retryErrorDetail = ""
    @State private var pendingRetryText: String?
    @State private var extractedCount = 0
    @State private var hasLoadedHistory = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }

                    if !streamingText.isEmpty {
                        MessageBubble(message: InterviewMessage(
                            id: UUID(), role: .assistant, content: streamingText, createdAt: Date()
                        ))
                        .id("streaming")
                    }

                    if isLoading && streamingText.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) {
                withAnimation {
                    proxy.scrollTo(messages.last?.id, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    Divider()
                    TextField("Type a message...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(sendMessage)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("Interview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onComplete()
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Start Over (clears tree)", systemImage: "trash", role: .destructive) {
                        clearHistory()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if extractedCount > 0 {
                ToolbarItem(placement: .principal) {
                    Text("\(extractedCount) people added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if !hasLoadedHistory {
                loadHistory()
                hasLoadedHistory = true
            }
        }
        .alert("AI Error", isPresented: $showRetryAlert) {
            Button("Retry") {
                if let text = pendingRetryText {
                    isLoading = true
                    Task { @MainActor in
                        await processWithAI(text)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRetryText = nil
            }
        } message: {
            Text(retryErrorDetail)
        }
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let db = appState.databaseManager else { return }

        // Auto-clear stale history if tree is empty (no people = fresh start)
        if appState.people.isEmpty {
            try? db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM interviewMessage")
            }
        }

        do {
            let saved = try db.dbQueue.read { database in
                try PersistedMessage.order(Column("createdAt").asc).fetchAll(database)
            }

            if saved.isEmpty {
                // First time or auto-cleared — add the greeting
                let greeting = "Hi! I'm going to help you build your family tree. Let's start with you. What's your full name?"
                let msg = persistMessage(role: .assistant, content: greeting)
                messages = [msg]
            } else {
                // Restore previous conversation
                messages = saved.map { pm in
                    InterviewMessage(
                        id: pm.id,
                        role: AIRole(rawValue: pm.role) ?? .assistant,
                        content: pm.content,
                        createdAt: pm.createdAt
                    )
                }
                // Rebuild conversation history for AI context
                conversationHistory = messages.map { msg in
                    AIMessage(role: msg.role, content: msg.content)
                }
            }
        } catch {
            // Fresh start on error
            let greeting = "Hi! I'm going to help you build your family tree. Let's start with you. What's your full name?"
            messages = [InterviewMessage(id: UUID(), role: .assistant, content: greeting, createdAt: Date())]
        }
    }

    @discardableResult
    private func persistMessage(role: AIRole, content: String) -> InterviewMessage {
        let now = Date()
        let id = UUID()
        let msg = InterviewMessage(id: id, role: role, content: content, createdAt: now)

        if let db = appState.databaseManager {
            let persisted = PersistedMessage(id: id, role: role.rawValue, content: content, createdAt: now)
            try? db.dbQueue.write { database in
                try persisted.insert(database)
            }
        }

        return msg
    }

    private func clearHistory() {
        if let db = appState.databaseManager {
            try? db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM flashcard")
                try database.execute(sql: "DELETE FROM flashcardDeck")
                try database.execute(sql: "DELETE FROM attachment")
                try database.execute(sql: "DELETE FROM relationship")
                try database.execute(sql: "DELETE FROM person")
                try database.execute(sql: "DELETE FROM interviewMessage")
                var settings = try AppSettings.current(database)
                settings.rootPersonId = nil
                settings.updatedAt = Date()
                try settings.update(database)
            }
        }
        appState.rootPersonId = nil
        appState.refreshPeople()
        messages = []
        conversationHistory = []
        extractedCount = 0
        hasLoadedHistory = false
        loadHistory()
    }

    // MARK: - Message Handling

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""

        let userMsg = persistMessage(role: .user, content: text)
        messages.append(userMsg)
        conversationHistory.append(AIMessage(role: .user, content: text))

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            await processWithAI(text)
        }
    }

    @MainActor
    private func processWithAI(_ text: String) async {
        guard let db = appState.databaseManager else {
            let msg = persistMessage(role: .assistant, content: "AI is not configured. You can add people manually from the People tab.")
            messages.append(msg)
            isLoading = false
            return
        }

        let router = AIProviderRouter()
        let settings: AppSettings? = {
            try? db.dbQueue.read { database in
                try AppSettings.current(database)
            }
        }()

        let provider = router.provider(for: settings?.selectedAIProvider, model: settings?.selectedModel)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        print("[Interview] User said: \"\(text)\"")
        print("[Interview] Conversation has \(conversationHistory.count) prior messages")

        do {
            // Use chat() not chatStream() — the on-device model is fast enough
            // (<2s) and chat() preserves the system prompt context correctly.
            // Streaming caused the model to lose instructions and hallucinate.
            let (fullResponse, firstExtracted) = try await service.processMessage(
                userMessage: text,
                conversationHistory: conversationHistory
            )
            print("[Interview] Response: \(fullResponse.count) chars")
            print("[Interview] RAW response: \(fullResponse)")

            var finalText = cleanResponse(fullResponse)
            if finalText.isEmpty {
                finalText = "Got it! Tell me more about your family."
            }
            let assistantMsg = persistMessage(role: .assistant, content: finalText)
            messages.append(assistantMsg)
            conversationHistory.append(AIMessage(role: .assistant, content: fullResponse))
            print("[Interview] Display: \(finalText.prefix(120))...")

            // Extract ALL person JSON blocks from full response
            let allExtracted = extractAllPersonJSON(from: fullResponse)
            print("[Interview] Extracted \(allExtracted.count) person(s)")

            for person in allExtracted where person.isPersonComplete {
                print("[Interview] Saving: \(person.firstName) \(person.lastName ?? "") role:\(person.role ?? "nil")")
                do {
                    let saved = try service.saveExtractedPerson(person)
                    extractedCount += 1
                    print("[Interview] Saved \(saved.displayName)")
                    if appState.rootPersonId == nil {
                        appState.setRootPerson(saved.id)
                    }
                } catch {
                    print("[Interview] Save failed: \(error)")
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
            if !allExtracted.isEmpty {
                appState.refreshPeople()
                print("[Interview] Tree now has \(appState.people.count) people")
            }

            isLoading = false
        } catch {
            print("[Interview] ERROR: \(error)")
            isLoading = false
            pendingRetryText = text
            retryErrorDetail = error.localizedDescription
            showRetryAlert = true
        }
    }

    private func extractAllPersonJSON(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json[^\n]*\n([\s\S]*?)\n\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        var results: [ExtractedPerson] = []

        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let jsonStr = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = jsonStr.data(using: .utf8) else { continue }

            // Try single object
            if let person = try? JSONDecoder().decode(ExtractedPerson.self, from: data) {
                results.append(person)
            }
            // Try JSON array [{...}, {...}]
            else if let people = try? JSONDecoder().decode([ExtractedPerson].self, from: data) {
                results.append(contentsOf: people)
            }
            // Try JSON Lines: multiple objects on separate lines (no array brackets)
            else {
                for line in jsonStr.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("{"), let lineData = trimmed.data(using: .utf8) else { continue }
                    if let person = try? JSONDecoder().decode(ExtractedPerson.self, from: lineData) {
                        results.append(person)
                    }
                }
            }
        }
        return results
    }

    private func cleanResponse(_ text: String) -> String {
        var cleaned = text

        // Remove complete JSON blocks: ```json ... ```
        if let regex = try? NSRegularExpression(pattern: #"```json[^\n]*\n[\s\S]*?```"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        // Remove incomplete/partial JSON blocks (started but no closing fence)
        if let regex = try? NSRegularExpression(pattern: #"```json[^\n]*[\s\S]*$"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        // Remove stray opening/closing fences
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")

        // Remove meta-references to JSON that the model sometimes adds
        let metaPhrases = [
            "Here's your JSON block:", "Here's the JSON block:",
            "Here are your JSON blocks:", "Here are the JSON blocks:",
            "I've extracted the following family members:",
            "I've extracted the following:",
            "Here's the extracted data:",
            "Here's the first entry:",
            "Let's start by extracting",
            "Based on the extracted information,",
        ]
        for phrase in metaPhrases {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "")
        }

        // Remove markdown headers and step-by-step reasoning
        if let regex = try? NSRegularExpression(pattern: #"#{1,4}\s+.+\n?"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        // Remove numbered lists that look like reasoning steps
        if let regex = try? NSRegularExpression(pattern: #"\d+\.\s+\*\*.+?\*\*:?\s*.+\n?"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: InterviewMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
