import SwiftUI
import GRDB

struct TreeCanvasView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var layout: TreeLayout?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var selectedPerson: Person?
    @State private var showAddPerson = false
    @State private var searchText = ""

    var body: some View {
        ZStack {
            if let layout = layout, !layout.nodes.isEmpty {
                treeCanvas(layout)
            } else {
                emptyTreeView
            }
        }
        .navigationTitle("My Tree")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Person", systemImage: "person.badge.plus") {
                        showAddPerson = true
                    }
                    if layout != nil {
                        Button("Fit All", systemImage: "arrow.up.left.and.arrow.down.right") {
                            withAnimation { scale = 0.5; offset = .zero }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Find person")
        .onAppear(perform: refreshLayout)
        .sheet(item: $selectedPerson) { person in
            NavigationStack {
                PersonProfileView(person: person)
            }
        }
        .sheet(isPresented: $showAddPerson) {
            NavigationStack {
                PersonEditView(person: nil, onSave: {
                    appState.refreshPeople()
                    refreshLayout()
                    showAddPerson = false
                })
            }
        }
    }

    // MARK: - Tree Canvas

    private func treeCanvas(_ layout: TreeLayout) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    // Connection lines
                    Canvas { context, size in
                        let nodeMap = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.personId, $0) })
                        let centerX = size.width / 2
                        let offsetY: CGFloat = 60

                        for connection in layout.connections {
                            guard let from = nodeMap[connection.fromId],
                                  let to = nodeMap[connection.toId] else { continue }

                            let fromPoint = CGPoint(x: centerX + from.x * scale, y: (from.y + 40) * scale + offsetY)
                            let toPoint = CGPoint(x: centerX + to.x * scale, y: (to.y + 40) * scale + offsetY)

                            var path = Path()
                            if connection.type == .spouse {
                                // Horizontal line for spouses
                                path.move(to: fromPoint)
                                path.addLine(to: toPoint)
                                context.stroke(path, with: .color(.pink.opacity(0.6)), lineWidth: 2)
                            } else {
                                // Vertical + horizontal lines for parent-child
                                let midY = (fromPoint.y + toPoint.y) / 2
                                path.move(to: fromPoint)
                                path.addLine(to: CGPoint(x: fromPoint.x, y: midY))
                                path.addLine(to: CGPoint(x: toPoint.x, y: midY))
                                path.addLine(to: toPoint)
                                context.stroke(path, with: .color(.gray.opacity(0.4)), lineWidth: 1.5)
                            }
                        }
                    }

                    // Person cards
                    let centerX = layout.totalSize.width / 2

                    ForEach(layout.nodes, id: \.personId) { node in
                        if let person = appState.people.first(where: { $0.id == node.personId }) {
                            let matchesSearch = searchText.isEmpty ||
                                person.displayName.localizedCaseInsensitiveContains(searchText)

                            PersonCardView(
                                person: person,
                                isRoot: person.id == appState.rootPersonId,
                                onTap: { selectedPerson = person },
                                onGenerateFlashcards: { generateFlashcards(for: person) },
                                onEdit: { selectedPerson = person },
                                onDelete: { deletePerson(person) }
                            )
                            .scaleEffect(scale)
                            .position(
                                x: centerX + node.x * scale,
                                y: (node.y + 40) * scale + 60
                            )
                            .opacity(matchesSearch ? 1 : 0.3)
                        }
                    }
                }
                .frame(
                    width: max(layout.totalSize.width * scale + 100, geo.size.width),
                    height: max(layout.totalSize.height * scale + 120, geo.size.height)
                )
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = max(0.3, min(3.0, value.magnification))
                    }
            )
        }
    }

    // MARK: - Empty State

    private var emptyTreeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tree")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Family Tree Yet")
                .font(.title2.bold())

            Text("Start building your tree by adding people or importing a GEDCOM file.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Add Person") {
                showAddPerson = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func refreshLayout() {
        guard let db = appState.databaseManager,
              let rootId = appState.rootPersonId ?? appState.people.first?.id else {
            layout = nil
            return
        }
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        do {
            layout = try engine.computeLayout(rootPersonId: rootId)
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func generateFlashcards(for person: Person) {
        // Handled via context menu in PersonCardView
    }

    private func deletePerson(_ person: Person) {
        guard let service = appState.treeService else { return }
        do {
            try service.deletePerson(id: person.id)
            appState.refreshPeople()
            refreshLayout()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}

extension Person: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Person, rhs: Person) -> Bool {
        lhs.id == rhs.id
    }
}
