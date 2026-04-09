import SwiftUI
import GRDB

@main
struct KinFlashApp: App {
    @State private var appState = AppState()

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
        if appState.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingFlow()
        }
    }
}

// MARK: - Main Tab View (iPhone uses tabs, iPad uses sidebar)

enum AppTab: String, CaseIterable {
    case tree = "My Tree"
    case people = "People"
    case decks = "Decks"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .tree: "tree"
        case .people: "person.3"
        case .decks: "rectangle.stack"
        case .settings: "gear"
        }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: AppTab = .tree

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppTab.tree.rawValue, systemImage: "tree", value: .tree) {
                NavigationStack {
                    TreeCanvasView()
                }
            }
            Tab(AppTab.people.rawValue, systemImage: "person.3", value: .people) {
                NavigationStack {
                    PeopleListView()
                }
            }
            Tab(AppTab.decks.rawValue, systemImage: "rectangle.stack", value: .decks) {
                NavigationStack {
                    DeckListView()
                }
            }
            Tab(AppTab.settings.rawValue, systemImage: "gear", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
