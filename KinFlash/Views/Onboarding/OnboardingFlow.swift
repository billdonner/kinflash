import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppState.self) private var appState
    @State private var step: OnboardingStep = .welcome

    enum OnboardingStep {
        case welcome
        case aiSetup
        case start
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .welcome:
                WelcomeView(onContinue: { step = .aiSetup })
            case .aiSetup:
                AISetupView(onContinue: { step = .start })
            case .start:
                StartView()
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "tree")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("KinFlash")
                .font(.largeTitle.bold())

            Text("Build, explore, and learn your family tree with AI-powered tools.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 16) {
                featureRow(icon: "person.3.fill", title: "Family Tree", description: "Visual, interactive family tree")
                featureRow(icon: "bubble.left.fill", title: "AI Interview", description: "Build your tree through conversation")
                featureRow(icon: "rectangle.stack.fill", title: "Flashcards", description: "Learn family relationships")
                featureRow(icon: "lock.shield.fill", title: "Privacy First", description: "All data stays on your device")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - AI Setup

struct AISetupView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 60))
                .foregroundStyle(.purple)

            Text("AI Setup")
                .font(.largeTitle.bold())

            Text("KinFlash uses AI to help you build your tree and generate flashcards. You can configure AI providers in Settings anytime.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                aiOption(name: "Apple Intelligence", detail: "On-device, free, no setup needed", recommended: true)
                aiOption(name: "Anthropic (Claude)", detail: "Requires API key", recommended: false)
                aiOption(name: "OpenAI (GPT)", detail: "Requires API key", recommended: false)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)

            Text("You can skip this for now. Tree building and GEDCOM import work without AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private func aiOption(name: String, detail: String, recommended: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).font(.headline)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Start

struct StartView: View {
    @Environment(AppState.self) private var appState
    @State private var showInterviewSheet = false
    @State private var showGEDCOMImporter = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("How would you like to start?")
                .font(.title2.bold())

            VStack(spacing: 16) {
                Button(action: { showInterviewSheet = true }) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Build My Tree").font(.headline)
                            Text("AI-guided interview").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .foregroundStyle(.primary)

                Button(action: { showGEDCOMImporter = true }) {
                    HStack {
                        Image(systemName: "doc.badge.arrow.up.fill")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Import .ged File").font(.headline)
                            Text("From another genealogy app").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .foregroundStyle(.primary)

                Button(action: {
                    appState.completeOnboarding()
                }) {
                    Text("Skip — I'll add people manually")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .sheet(isPresented: $showInterviewSheet) {
            NavigationStack {
                InterviewView(onComplete: {
                    showInterviewSheet = false
                    appState.refreshPeople()
                    appState.completeOnboarding()
                })
            }
        }
        .sheet(isPresented: $showGEDCOMImporter) {
            GEDCOMImportView(onComplete: {
                showGEDCOMImporter = false
                appState.refreshPeople()
                appState.completeOnboarding()
            })
        }
    }
}
