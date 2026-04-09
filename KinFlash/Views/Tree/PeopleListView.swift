import SwiftUI

struct PeopleListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedPerson: Person?
    @State private var showAddPerson = false

    var filteredPeople: [Person] {
        if searchText.isEmpty { return appState.people }
        return appState.people.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ForEach(filteredPeople) { person in
                Button {
                    selectedPerson = person
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(person.id == appState.rootPersonId ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "person.fill")
                                .foregroundStyle(person.id == appState.rootPersonId ? .blue : .gray)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName)
                                .font(.body)
                            if let years = person.displayYears {
                                Text(years)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if person.id == appState.rootPersonId {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("People (\(appState.people.count))")
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    showAddPerson = true
                }
            }
        }
        .sheet(item: $selectedPerson) { person in
            NavigationStack {
                PersonProfileView(person: person)
            }
        }
        .sheet(isPresented: $showAddPerson) {
            NavigationStack {
                PersonEditView(person: nil, onSave: {
                    appState.refreshPeople()
                    showAddPerson = false
                })
            }
        }
        .onAppear {
            appState.refreshPeople()
        }
    }
}
