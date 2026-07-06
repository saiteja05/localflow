import Foundation
import Observation
import CleanupKit

@Observable
public final class DictionaryStore {
    private struct FileModel: Codable {
        var vocabulary: [String] = []
        var replacements: [Replacement] = []
    }
    public private(set) var vocabulary: [String]
    public private(set) var replacements: [Replacement]
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "dictionary.json")
        let model = (try? JSONDecoder().decode(FileModel.self, from: Data(contentsOf: fileURL)))
            ?? FileModel()
        vocabulary = model.vocabulary
        replacements = model.replacements
    }

    public func addVocabulary(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !vocabulary.contains(where: { $0.lowercased() == trimmed.lowercased() })
        else { return }
        vocabulary.append(trimmed)
        save()
    }
    public func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
        save()
    }
    public func addReplacement(_ r: Replacement) {
        guard !r.spoken.isEmpty else { return }
        replacements.append(r)
        save()
    }
    public func removeReplacement(_ r: Replacement) {
        replacements.removeAll { $0 == r }
        save()
    }

    // Import/export (spec §6): the file format IS the on-disk format.
    public func exportData() throws -> Data {
        try JSONEncoder().encode(FileModel(vocabulary: vocabulary, replacements: replacements))
    }
    public func importData(_ data: Data) throws {
        let model = try JSONDecoder().decode(FileModel.self, from: data)
        vocabulary = model.vocabulary
        replacements = model.replacements
        save()
    }

    private func save() {
        let model = FileModel(vocabulary: vocabulary, replacements: replacements)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
