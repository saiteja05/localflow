import Foundation
import Observation

@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "settings.json")
        settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL)))
            ?? AppSettings()
    }

    public func update(_ newValue: AppSettings) {
        settings = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
