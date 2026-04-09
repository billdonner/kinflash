import SwiftUI

struct PersonEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let person: Person?
    let onSave: () -> Void

    @State private var firstName: String = ""
    @State private var middleName: String = ""
    @State private var lastName: String = ""
    @State private var nickname: String = ""
    @State private var birthYear: String = ""
    @State private var deathYear: String = ""
    @State private var birthPlace: String = ""
    @State private var isLiving: Bool = true
    @State private var gender: Gender = .unknown
    @State private var notes: String = ""
    @State private var errorMessage: String?

    var isNew: Bool { person == nil }

    var body: some View {
        Form {
            Section("Name") {
                TextField("First Name", text: $firstName)
                TextField("Middle Name", text: $middleName)
                TextField("Last Name", text: $lastName)
                TextField("Nickname", text: $nickname)
            }

            Section("Details") {
                Picker("Gender", selection: $gender) {
                    Text("Unknown").tag(Gender.unknown)
                    Text("Male").tag(Gender.male)
                    Text("Female").tag(Gender.female)
                    Text("Non-Binary").tag(Gender.nonBinary)
                }

                TextField("Birth Year", text: $birthYear)
                    .keyboardType(.numberPad)

                TextField("Birth Place", text: $birthPlace)

                Toggle("Living", isOn: $isLiving)

                if !isLiving {
                    TextField("Death Year", text: $deathYear)
                        .keyboardType(.numberPad)
                }
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isNew ? "Add Person" : "Edit Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if let p = person {
                firstName = p.firstName
                middleName = p.middleName ?? ""
                lastName = p.lastName ?? ""
                nickname = p.nickname ?? ""
                birthYear = p.birthYear.map(String.init) ?? ""
                deathYear = p.deathYear.map(String.init) ?? ""
                birthPlace = p.birthPlace ?? ""
                isLiving = p.isLiving
                gender = p.gender ?? .unknown
                notes = p.notes ?? ""
            }
        }
    }

    private func save() {
        guard let service = appState.treeService else { return }
        let now = Date()

        var p = person ?? Person(
            id: UUID(), firstName: "", middleName: nil, lastName: nil,
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now
        )

        p.firstName = firstName.trimmingCharacters(in: .whitespaces)
        p.middleName = middleName.isEmpty ? nil : middleName
        p.lastName = lastName.isEmpty ? nil : lastName
        p.nickname = nickname.isEmpty ? nil : nickname
        p.birthYear = Int(birthYear)
        p.deathYear = isLiving ? nil : Int(deathYear)
        p.birthPlace = birthPlace.isEmpty ? nil : birthPlace
        p.isLiving = isLiving
        p.gender = gender
        p.notes = notes.isEmpty ? nil : notes

        do {
            if isNew {
                try service.addPerson(p)
                // If this is the first person, set as root
                if appState.rootPersonId == nil {
                    appState.setRootPerson(p.id)
                }
            } else {
                try service.updatePerson(p)
            }
            onSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
