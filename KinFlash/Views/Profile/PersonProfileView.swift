import SwiftUI
import GRDB

struct PersonProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let person: Person

    @State private var currentPerson: Person?
    @State private var relationships: [(label: String, person: Person)] = []
    @State private var photos: [Attachment] = []
    @State private var documents: [Attachment] = []
    @State private var showEditPerson = false
    @State private var showAddRelationship = false
    @State private var showFlashcardGeneration = false
    @State private var showPhotoSheet = false
    @State private var navigateToPerson: Person?

    /// The live version of the person, refreshed after edits.
    private var displayPerson: Person { currentPerson ?? person }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Relationships
                relationshipsSection

                // Photos
                photosSection

                // Documents
                documentsSection

                // Notes
                if let notes = displayPerson.notes, !notes.isEmpty {
                    notesSection(notes)
                }
            }
            .padding()
        }
        .navigationTitle(displayPerson.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit", systemImage: "pencil") { showEditPerson = true }
                    Button("Generate Flashcards", systemImage: "sparkles") { showFlashcardGeneration = true }
                    Button("Set as Root Person", systemImage: "star") {
                        appState.setRootPerson(person.id)
                    }
                    Button("Add Relationship", systemImage: "link") { showAddRelationship = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: loadData)
        .sheet(isPresented: $showEditPerson) {
            NavigationStack {
                PersonEditView(person: displayPerson, onSave: {
                    appState.refreshPeople()
                    reloadPerson()
                    loadData()
                    showEditPerson = false
                })
            }
        }
        .sheet(isPresented: $showAddRelationship) {
            NavigationStack {
                AddRelationshipView(person: person, onDone: {
                    showAddRelationship = false
                    loadData()
                })
            }
        }
        .sheet(isPresented: $showFlashcardGeneration) {
            NavigationStack {
                FlashcardGenerationView(person: person)
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayPerson.displayName)
                    .font(.title2.bold())

                if let nickname = displayPerson.nickname {
                    Text("\"\(nickname)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let birthDate = displayPerson.birthDate {
                    let formatted = birthDate.formatted(date: .long, time: .omitted)
                    HStack(spacing: 4) {
                        Text("Born: \(formatted)")
                        if let place = displayPerson.birthPlace {
                            Text("- \(place)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let year = displayPerson.birthYear {
                    HStack(spacing: 4) {
                        Text("Born: \(String(year))")
                        if let place = displayPerson.birthPlace {
                            Text("- \(place)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let deathDate = displayPerson.deathDate {
                    Text("Died: \(deathDate.formatted(date: .long, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let deathYear = displayPerson.deathYear {
                    Text("Died: \(String(deathYear))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private var relationshipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Relationships")
                    .font(.headline)
                Spacer()
                Button("Add", systemImage: "plus.circle") {
                    showAddRelationship = true
                }
                .font(.caption)
            }

            if relationships.isEmpty {
                Text("No relationships yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(relationships, id: \.person.id) { rel in
                    Button {
                        navigateToPerson = rel.person
                    } label: {
                        HStack {
                            Text(rel.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(rel.person.displayName)
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .sheet(item: $navigateToPerson) { person in
            NavigationStack {
                PersonProfileView(person: person)
            }
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photos")
                    .font(.headline)
                Spacer()
                Button("Add", systemImage: "plus.circle") {
                    showPhotoSheet = true
                }
                .font(.caption)
            }

            if photos.isEmpty {
                Text("No photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { attachment in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.gray.opacity(0.2))
                                .frame(width: 80, height: 80)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }
            }
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Documents")
                    .font(.headline)
                Spacer()
                Button("Add", systemImage: "plus.circle") {
                    // TODO: document picker
                }
                .font(.caption)
            }

            if documents.isEmpty {
                Text("No documents")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(documents) { doc in
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.blue)
                        Text(doc.label ?? doc.filename)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            Text(notes)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data Loading

    private func reloadPerson() {
        guard let service = appState.treeService else { return }
        currentPerson = try? service.fetchPerson(id: person.id)
    }

    private func loadData() {
        guard let db = appState.databaseManager else { return }

        // Load relationships
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        do {
            let labels = try resolver.resolveAll(from: person.id)
            relationships = labels.compactMap { (targetId, label) in
                guard let targetPerson = appState.people.first(where: { $0.id == targetId }) else { return nil }
                return (label: label.label, person: targetPerson)
            }
            .sorted { $0.label < $1.label }
        } catch {
            appState.errorMessage = error.localizedDescription
        }

        // Load attachments
        if let am = appState.attachmentManager {
            photos = (try? am.fetchAttachments(personId: person.id, type: .photo)) ?? []
            documents = (try? am.fetchAttachments(personId: person.id, type: .document)) ?? []
        }
    }
}
