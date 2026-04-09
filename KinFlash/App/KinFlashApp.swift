import SwiftUI

@main
struct KinFlashApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}

@Observable
final class AppState {
    var databaseManager: DatabaseManager?
    var treeService: TreeService?
    var selectedPersonId: UUID?

    init() {
        do {
            let db = try DatabaseManager()
            self.databaseManager = db
            self.treeService = TreeService(dbQueue: db.dbQueue)
        } catch {
            print("Failed to initialize database: \(error)")
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            Text("Select an item")
                .foregroundStyle(.secondary)
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
        }
    }
}

struct SidebarView: View {
    var body: some View {
        List {
            NavigationLink("My Tree", value: "tree")
            NavigationLink("People", value: "people")
            NavigationLink("Flashcard Decks", value: "decks")
            NavigationLink("Interview", value: "interview")
            NavigationLink("Settings", value: "settings")
        }
        .navigationTitle("KinFlash")
    }
}
