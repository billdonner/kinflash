import SwiftUI
import UniformTypeIdentifiers

struct GEDCOMImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}

    @State private var showFilePicker = false
    @State private var importResult: GEDCOMParseResult?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isImported = false

    var body: some View {
        VStack(spacing: 24) {
            if let result = importResult, !isImported {
                importPreview(result)
            } else if isImported {
                importComplete
            } else {
                preImportView
            }
        }
        .padding()
        .navigationTitle("Import GEDCOM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "ged") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private var preImportView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Import GEDCOM File")
                .font(.title2.bold())

            Text("Import a .ged file from another genealogy application. GEDCOM 5.5.1 is fully supported.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Spacer()

            Button(action: { showFilePicker = true }) {
                Label("Choose File", systemImage: "folder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private func importPreview(_ result: GEDCOMParseResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("File Parsed Successfully")
                .font(.title3.bold())

            VStack(spacing: 8) {
                HStack {
                    Text("People found:")
                    Spacer()
                    Text("\(result.people.count)").bold()
                }
                HStack {
                    Text("Relationships:")
                    Spacer()
                    Text("\(result.relationships.count)").bold()
                }
                if !result.errors.isEmpty {
                    HStack {
                        Text("Parse errors:")
                        Spacer()
                        Text("\(result.errors.count)")
                            .foregroundStyle(.red)
                            .bold()
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if isImporting {
                ProgressView("Importing...")
            } else {
                Button(action: performImport) {
                    Label("Import \(result.people.count) People", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var importComplete: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Import Complete!")
                .font(.title2.bold())

            if let result = importResult {
                Text("\(result.people.count) people and \(result.relationships.count) relationships imported.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button("Continue") {
                onComplete()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let parser = GEDCOMParser()
                importResult = parser.parse(content: content)
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func performImport() {
        guard let result = importResult,
              let db = appState.databaseManager else { return }

        isImporting = true
        let parser = GEDCOMParser()

        do {
            try parser.importToDatabase(result, dbQueue: db.dbQueue)

            // Set root person to first person if none set
            if appState.rootPersonId == nil, let first = result.people.first {
                appState.setRootPerson(first.id)
            }

            appState.refreshPeople()
            isImported = true
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }

        isImporting = false
    }
}
