import SwiftUI

struct AddRelationshipView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let onDone: () -> Void

    @State private var selectedType: RelationshipType = .parent
    @State private var selectedSubtype: RelationshipSubtype? = nil
    @State private var selectedPersonId: UUID?
    @State private var errorMessage: String?

    var availablePeople: [Person] {
        appState.people.filter { $0.id != person.id }
    }

    var body: some View {
        Form {
            Section("Relationship Type") {
                Picker("Type", selection: $selectedType) {
                    Text("Parent of \(person.firstName)").tag(RelationshipType.parent)
                    Text("Spouse of \(person.firstName)").tag(RelationshipType.spouse)
                    Text("Sibling of \(person.firstName)").tag(RelationshipType.sibling)
                }
                .pickerStyle(.segmented)

                Picker("Subtype", selection: $selectedSubtype) {
                    Text("None").tag(RelationshipSubtype?.none)
                    Text("Biological").tag(RelationshipSubtype?.some(.biological))
                    Text("Step").tag(RelationshipSubtype?.some(.step))
                    Text("Adoptive").tag(RelationshipSubtype?.some(.adoptive))
                    if selectedType == .sibling {
                        Text("Half").tag(RelationshipSubtype?.some(.half))
                    }
                }
            }

            Section("Select Person") {
                if availablePeople.isEmpty {
                    Text("No other people in the tree")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availablePeople) { p in
                        Button {
                            selectedPersonId = p.id
                        } label: {
                            HStack {
                                Text(p.displayName)
                                Spacer()
                                if selectedPersonId == p.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Relationship")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { addRelationship() }
                    .disabled(selectedPersonId == nil)
            }
        }
    }

    private func addRelationship() {
        guard let service = appState.treeService,
              let targetId = selectedPersonId else { return }

        do {
            // "Parent of person" means selected person is parent, person is child
            switch selectedType {
            case .parent:
                try service.addRelationship(from: targetId, to: person.id, type: .parent, subtype: selectedSubtype)
            case .spouse:
                try service.addRelationship(from: person.id, to: targetId, type: .spouse, subtype: selectedSubtype)
            case .sibling:
                try service.addRelationship(from: person.id, to: targetId, type: .sibling, subtype: selectedSubtype)
            }
            appState.refreshPeople()
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
