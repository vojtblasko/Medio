import SwiftUI

enum EditableMetadataField: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case genre
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Year"
        }
    }
}

struct EditMetadataView: View {
    let filePaths: [String]
    let fields: [EditableMetadataField]
    let defaultValues: [EditableMetadataField: String]
    let title: String
    @State private var override: VisualMetadataOverride
    @Environment(\.dismiss) private var dismiss
    private let repository = UserDefaultsVisualMetadataOverridesRepository.shared

    init(filePath: String, currentOverride: VisualMetadataOverride?) {
        self.filePaths = [filePath]
        self.fields = EditableMetadataField.allCases
        self.defaultValues = [:]
        self.title = "Edit Metadata"
        _override = State(initialValue: currentOverride ?? VisualMetadataOverride())
    }

    init(
        title: String,
        filePaths: [String],
        currentOverride: VisualMetadataOverride?,
        defaultValues: [EditableMetadataField: String] = [:],
        fields: [EditableMetadataField]
    ) {
        self.filePaths = filePaths
        self.fields = fields
        self.defaultValues = defaultValues
        self.title = title
        _override = State(initialValue: currentOverride ?? VisualMetadataOverride())
    }

    var body: some View {
         CompatibleNavigationStack {
            Form {
                Section("Display Overrides") {
                    ForEach(fields) { field in
                        TextField(field.label, text: binding(for: field))
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func binding(for field: EditableMetadataField) -> Binding<String> {
        Binding(
            get: { value(for: field) ?? defaultValues[field] ?? "" },
            set: { setValue($0.isEmpty ? nil : $0, for: field) }
        )
    }

    private func save() {
        for path in filePaths {
            var merged = repository.loadOverride(forMediaPath: path) ?? VisualMetadataOverride()
            for field in fields {
                setValue(value(for: field), for: field, in: &merged)
            }
            repository.saveOverride(merged, forMediaPath: path)
        }
    }

    private func value(for field: EditableMetadataField) -> String? {
        switch field {
        case .title: return override.title
        case .artist: return override.artist
        case .album: return override.album
        case .genre: return override.genre
        case .year: return override.year
        }
    }

    private func setValue(_ value: String?, for field: EditableMetadataField) {
        setValue(value, for: field, in: &override)
    }

    private func setValue(_ value: String?, for field: EditableMetadataField, in target: inout VisualMetadataOverride) {
        switch field {
        case .title: target.title = value
        case .artist: target.artist = value
        case .album: target.album = value
        case .genre: target.genre = value
        case .year: target.year = value
        }
    }
}
