import SwiftUI

struct InterviewMessage: Identifiable {
    let id = UUID()
    let role: AIRole
    let content: String
}

struct InterviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}

    @State private var messages: [InterviewMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var streamingText = ""
    @State private var conversationHistory: [AIMessage] = []
    @State private var errorMessage: String?
    @State private var extractedCount = 0

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
                            MessageBubble(message: InterviewMessage(role: .assistant, content: streamingText))
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    onComplete()
                    dismiss()
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
            if messages.isEmpty {
                addAssistantMessage("Hi! I'm going to help you build your family tree. Let's start with you. What's your full name?")
            }
        }
    }

    // MARK: - Message Handling

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""

        messages.append(InterviewMessage(role: .user, content: text))
        conversationHistory.append(AIMessage(role: .user, content: text))

        isLoading = true
        errorMessage = nil

        Task {
            await processWithAI(text)
        }
    }

    private func processWithAI(_ text: String) async {
        guard let db = appState.databaseManager else {
            addAssistantMessage("AI is not configured. You can add people manually from the People tab.")
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

        // Use streaming: collect tokens as they arrive
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

            // Streaming complete — finalize the message
            let finalText = cleanResponse(fullResponse)
            streamingText = ""
            addAssistantMessage(finalText)
            conversationHistory.append(AIMessage(role: .assistant, content: fullResponse))

            // Extract person data from the full response
            let extracted = extractPersonJSON(from: fullResponse)
            if let person = extracted, person.isComplete {
                do {
                    let saved = try service.saveExtractedPerson(person)
                    extractedCount += 1
                    if appState.rootPersonId == nil {
                        appState.setRootPerson(saved.id)
                    }
                    appState.refreshPeople()
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }

            isLoading = false
        } catch {
            streamingText = ""
            if !fullResponse.isEmpty {
                addAssistantMessage(cleanResponse(fullResponse))
            }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Extract person JSON — duplicated here so the view can process the full streamed response.
    private func extractPersonJSON(from text: String) -> ExtractedPerson? {
        let pattern = #"```json\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let jsonString = String(text[range])
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
    }

    private func addAssistantMessage(_ text: String) {
        messages.append(InterviewMessage(role: .assistant, content: text))
    }

    private func cleanResponse(_ text: String) -> String {
        // Remove JSON blocks from display
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

            Text(message.content)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
