import SwiftUI
import GRDB

@main
struct KinFlashApp: App {
    @State private var appState = AppState()

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("=== KinFlash v\(version) build \(build) ===")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

@Observable
final class AppState {
    var databaseManager: DatabaseManager?
    var treeService: TreeService?
    var attachmentManager: AttachmentManager?
    var selectedPersonId: UUID?
    var hasCompletedOnboarding: Bool = false
    var rootPersonId: UUID?
    var people: [Person] = []
    var errorMessage: String?

    init() {
        do {
            let db = try DatabaseManager()
            self.databaseManager = db
            self.treeService = TreeService(dbQueue: db.dbQueue)
            self.attachmentManager = AttachmentManager(dbQueue: db.dbQueue)

            let settings = try db.dbQueue.read { database in
                try AppSettings.current(database)
            }
            self.hasCompletedOnboarding = settings.hasCompletedOnboarding
            self.rootPersonId = settings.rootPersonId
            refreshPeople()
        } catch {
            self.errorMessage = "Failed to initialize database: \(error.localizedDescription)"
        }
    }

    func refreshPeople() {
        guard let service = treeService else { return }
        do {
            people = try service.fetchAllPeople()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeOnboarding() {
        guard let db = databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                var settings = try AppSettings.current(database)
                settings.hasCompletedOnboarding = true
                settings.updatedAt = Date()
                try settings.update(database)
            }
            hasCompletedOnboarding = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRootPerson(_ id: UUID) {
        guard let db = databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                var settings = try AppSettings.current(database)
                settings.rootPersonId = id
                settings.updatedAt = Date()
                try settings.update(database)
            }
            rootPersonId = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        MainTabView()
            .onAppear {
                // Skip onboarding — the interview tab is always available
                if !appState.hasCompletedOnboarding {
                    appState.completeOnboarding()
                }
            }
    }
}

// MARK: - Adaptive Main View

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            // iPad / Mac Catalyst: sidebar + tree + interview side-by-side
            iPadLayout
        } else {
            // iPhone: tab bar
            iPhoneLayout
        }
    }

    // MARK: - iPad: NavigationSplitView + interview panel

    @State private var sidebarSelection: String? = "tree"
    @State private var showInterviewPanel = true

    private var iPadLayout: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("My Tree", systemImage: "tree")
                    .tag("tree")
                Label("People", systemImage: "person.3")
                    .tag("people")
                Label("Flashcard Decks", systemImage: "rectangle.stack")
                    .tag("decks")
                Label("Settings", systemImage: "gear")
                    .tag("settings")
            }
            .navigationTitle("KinFlash")
            .toolbar {
                ToolbarItem {
                    Button {
                        withAnimation { showInterviewPanel.toggle() }
                    } label: {
                        Label(
                            showInterviewPanel ? "Hide Interview" : "Show Interview",
                            systemImage: showInterviewPanel ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                        )
                    }
                }
            }
        } content: {
            // Main content area
            Group {
                switch sidebarSelection {
                case "tree":
                    TreeCanvasView()
                case "people":
                    PeopleListView()
                case "decks":
                    DeckListView()
                case "settings":
                    SettingsView()
                default:
                    TreeCanvasView()
                }
            }
        } detail: {
            // Interview panel (always available on iPad)
            if showInterviewPanel {
                InterviewView(embedded: true)
                    .navigationTitle("Interview")
            } else {
                Text("Tap the chat icon in the sidebar to show the interview panel.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - iPhone: TabView

    @State private var selectedTab = 0

    private var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            Tab("My Tree", systemImage: "tree", value: 0) {
                NavigationStack {
                    TreeCanvasView()
                }
            }
            Tab("People", systemImage: "person.3", value: 1) {
                NavigationStack {
                    PeopleListView()
                }
            }
            Tab("Interview", systemImage: "bubble.left.and.bubble.right", value: 2) {
                NavigationStack {
                    InterviewView(embedded: true)
                }
            }
            Tab("Decks", systemImage: "rectangle.stack", value: 3) {
                NavigationStack {
                    DeckListView()
                }
            }
            Tab("Settings", systemImage: "gear", value: 4) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
