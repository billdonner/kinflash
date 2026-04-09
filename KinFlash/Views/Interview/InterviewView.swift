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
    @State private var extractedCount = 0
    @State private var hasLoadedHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // Messages
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
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // Input area
            HStack(spacing: 8) {
                TextField("Type a message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendMessage)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            .padding()
            .background(.ultraThinMaterial)
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
                    Button("Clear History", systemImage: "trash", role: .destructive) {
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
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let db = appState.databaseManager else { return }
        do {
            let saved = try db.dbQueue.read { database in
                try PersistedMessage.order(Column("createdAt").asc).fetchAll(database)
            }

            if saved.isEmpty {
                // First time — add the greeting
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
                try database.execute(sql: "DELETE FROM interviewMessage")
            }
        }
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

        var fullResponse = ""
        streamingText = ""

        do {
            let stream = service.streamMessage(
                userMessage: text,
                conversationHistory: conversationHistory
            )

            for try await chunk in stream {
                fullResponse += chunk
                streamingText = cleanResponse(fullResponse)
            }

            // Streaming complete — persist and finalize
            let finalText = cleanResponse(fullResponse)
            streamingText = ""
            let assistantMsg = persistMessage(role: .assistant, content: finalText)
            messages.append(assistantMsg)
            conversationHistory.append(AIMessage(role: .assistant, content: fullResponse))

            // Extract ALL person JSON blocks
            let allExtracted = extractAllPersonJSON(from: fullResponse)
            for person in allExtracted where person.isComplete {
                do {
                    let saved = try service.saveExtractedPerson(person)
                    extractedCount += 1
                    if appState.rootPersonId == nil {
                        appState.setRootPerson(saved.id)
                    }
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
            if !allExtracted.isEmpty {
                appState.refreshPeople()
            }

            isLoading = false
        } catch {
            streamingText = ""
            if !fullResponse.isEmpty {
                let msg = persistMessage(role: .assistant, content: cleanResponse(fullResponse))
                messages.append(msg)
            }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func extractAllPersonJSON(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match -> ExtractedPerson? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            guard let data = String(text[range]).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
        }
    }

    private func cleanResponse(_ text: String) -> String {
        let pattern = #"```json[\s\S]*?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
