import Foundation

/// Where downloaded ML models are stored.
public enum ModelStorage {
    /// `Application Support/LectureAssistant/Models`, created if needed and
    /// excluded from backups (models can be downloaded again).
    ///
    /// Model libraries often default to `Documents`, which iOS backs up to iCloud
    /// and which on macOS (outside the sandbox) is the user's Documents folder.
    public static func directory() throws -> URL {
        var directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LectureAssistant/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }
}
