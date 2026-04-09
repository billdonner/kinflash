import SwiftUI

/// Shows a fun animation while Apple Intelligence warms up.
/// Sends a trivial prompt to pre-load the on-device model,
/// then transitions to the interview.
struct AIWarmupView: View {
    @Environment(AppState.self) private var appState
    @State private var isReady = false
    @State private var statusText = "Waking up Apple Intelligence..."
    @State private var dotCount = 0
    @State private var funFacts: [String] = [
        "The average family tree has 127 people going back 5 generations",
        "The word 'genealogy' comes from Greek: genea (generation) + logos (knowledge)",
        "Your 10th-generation ancestors number 1,024 people",
        "The oldest known family tree belongs to Confucius — 2,500 years",
        "You share 12.5% of your DNA with first cousins",
        "Queen Elizabeth II and Prince Philip were third cousins",
        "Everyone alive today shares a common ancestor from ~3,000 years ago",
    ]
    @State private var currentFact = ""
    @State private var rotation: Double = 0

    var body: some View {
        if isReady {
            InterviewView(embedded: true)
        } else {
            warmupContent
                .onAppear(perform: startWarmup)
        }
    }

    private var warmupContent: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated icon
            Image(systemName: "brain")
                .font(.system(size: 60))
                .foregroundStyle(.purple)
                .rotationEffect(.degrees(rotation))
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: rotation)
                .onAppear { rotation = 15 }

            Text("KinFlash")
                .font(.largeTitle.bold())

            Text(statusText)
                .font(.headline)
                .foregroundStyle(.secondary)

            // Fun fact
            if !currentFact.isEmpty {
                Text(currentFact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
            }

            Spacer()

            ProgressView()
                .controlSize(.large)

            Text("Preparing on-device AI...")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
    }

    private func startWarmup() {
        // Cycle through fun facts while waiting
        currentFact = funFacts.randomElement() ?? ""
        Task {
            while !isReady {
                try? await Task.sleep(for: .seconds(4))
                if !isReady {
                    withAnimation {
                        currentFact = funFacts.randomElement() ?? ""
                    }
                }
            }
        }

        // Warm up the model
        Task {
            print("[Warmup] Starting Apple Intelligence warm-up...")
            let provider = AppleIntelligenceProvider()

            guard provider.isAvailable else {
                print("[Warmup] Apple Intelligence not available, skipping warm-up")
                await MainActor.run {
                    isReady = true
                }
                return
            }

            do {
                await MainActor.run { statusText = "Loading on-device AI model..." }

                let warmupMessages = [
                    AIMessage(role: .user, content: "Hello")
                ]
                let _ = try await provider.chat(messages: warmupMessages)
                print("[Warmup] Model responded — warm-up complete!")
                await MainActor.run {
                    statusText = "Ready!"
                    withAnimation {
                        isReady = true
                    }
                }
            } catch {
                print("[Warmup] Warm-up failed: \(error) — proceeding anyway")
                await MainActor.run {
                    // Still go to interview — it will show retry dialog if AI fails
                    isReady = true
                }
            }
        }
    }
}
