import Foundation
import HuggingFace
import MLXLMCommon

/// Downloads Hugging Face snapshots into a cache directory we choose, rather
/// than the library default (`~/.cache/huggingface`).
public struct HubDownloader: MLXLMCommon.Downloader {
    public let cacheDirectory: URL

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw HubDownloaderError.invalidRepositoryID(id) }
        let client = HubClient(
            host: URL(string: "https://huggingface.co")!,
            tokenProvider: .none,
            cache: HubCache(cacheDirectory: cacheDirectory)
        )
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { progress in progressHandler(progress) }
        )
    }
}

public enum HubDownloaderError: Error, Equatable {
    case invalidRepositoryID(String)
}
