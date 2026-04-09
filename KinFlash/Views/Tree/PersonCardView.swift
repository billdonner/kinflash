import SwiftUI

struct PersonCardView: View {
    let person: Person
    var isRoot: Bool = false
    var onTap: () -> Void = {}
    var onGenerateFlashcards: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            // Profile photo or placeholder
            ZStack {
                Circle()
                    .fill(isRoot ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                    .frame(width: 44, height: 44)

                if let _ = person.profilePhotoFilename {
                    // TODO: Load actual photo
                    Image(systemName: "person.fill")
                        .foregroundStyle(isRoot ? .blue : .gray)
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(isRoot ? .blue : .gray)
                }
            }

            Text(person.firstName)
                .font(.caption.bold())
                .lineLimit(1)

            if let lastName = person.lastName {
                Text(lastName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let years = person.displayYears {
                Text(years)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 100, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isRoot ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("View Profile", systemImage: "person.crop.circle") {
                onTap()
            }
            Button("Generate Flashcards", systemImage: "sparkles") {
                onGenerateFlashcards()
            }
            Button("Edit Person", systemImage: "pencil") {
                onEdit()
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }
}
