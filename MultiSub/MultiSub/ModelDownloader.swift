//
//  ModelDownloader.swift
//  MultiSub
//
//  swift-huggingface's bundled download path gets stuck around 1% on large
//  (multi-GB) LFS files on flaky connections. Root cause: its
//  `URLSession.download(for:delegate:)` call writes partial data to a private
//  system temp file that's discarded when the connection drops, and is never
//  persisted to `incompleteBlobPath` — so every retry restarts from byte 0.
//
//  This pre-populates the on-disk Hugging Face cache ourselves with a
//  `URLSession` data-task delegate that streams straight into a `.partial`
//  file we own (resumed via `Range` headers), then hands off to `HubCache`'s
//  own public `storeFile` API to place it under the exact
//  `blobs/<etag>` + `snapshots/<commit>/<filename>` layout `HubClient`
//  expects. `Translator.loadModel` (unchanged) then finds every matching file
//  already cached via `HubClient+Files.swift`'s per-file fast path and does
//  zero network I/O for the weights.
//
//  App target only — the extension never downloads (every `Translator`
//  request loads the model with `allowDownload: false`).
//

import CryptoKit
import Foundation
import HuggingFace

enum ModelDownloader {
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Files mlx-swift-lm's `resolve(configuration:from:...)` actually asks
    /// for (see `MLXLMCommon/ModelFactory.swift`: `modelDownloadPatterns`).
    /// Kept in sync manually since it isn't exposed publicly.
    private static let filePatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// C3: sums the tree-listing sizes (no per-file HEAD requests, unlike
    /// `download`) for a model's weight files without downloading anything —
    /// used to show a projected size / memory-tier warning for models the
    /// user hasn't downloaded yet.
    static func estimatedSize(modelID: String) async throws -> Int64 {
        guard let repo = Repo.ID(rawValue: modelID) else {
            throw DownloadError(message: "無效的模型 ID：\(modelID)")
        }
        let cache = HubCache(cacheDirectory: MultiSubPaths.modelsRoot)
        let client = HubClient(cache: cache)
        let allEntries = try await client.listFiles(in: repo, kind: .model, revision: "main", recursive: true)
        let entries = allEntries.filter { entry in
            entry.type == .file && filePatterns.contains { fnmatch($0, entry.path, 0) == 0 }
        }
        return entries.reduce(Int64(0)) { $0 + (($1.size).map(Int64.init) ?? 0) }
    }

    /// Downloads (resumably) every file mlx-swift-lm needs for `modelID` and
    /// stores them in `MultiSubPaths.modelsRoot` using the standard
    /// Hugging Face cache layout. `progress` is reported in [0, 1] by bytes.
    static func download(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let repo = Repo.ID(rawValue: modelID) else {
            throw DownloadError(message: "無效的模型 ID：\(modelID)")
        }
        let cache = HubCache(cacheDirectory: MultiSubPaths.modelsRoot)
        let client = HubClient(cache: cache)

        let allEntries = try await client.listFiles(in: repo, kind: .model, revision: "main", recursive: true)
        let entries = allEntries.filter { entry in
            entry.type == .file && filePatterns.contains { fnmatch($0, entry.path, 0) == 0 }
        }
        guard !entries.isEmpty else {
            throw DownloadError(message: "在 \(modelID) 找不到需要的檔案")
        }

        // HEAD each file to resolve its etag/commit before touching the
        // network for actual bytes — this is metadata only, not the download.
        // Size comes from the tree listing (`entry.size`), not from `getFile`'s
        // `Content-Length` — that HEAD request sends `Range: bytes=0-0`, and
        // when the server honors it with a 206, `Content-Length` reflects the
        // 1-byte range, not the real file size, which under-counted the total
        // and made the progress bar shoot past 100% once the real bytes
        // (multiple GB) streamed in past that tiny expected total.
        var files: [(entry: Git.TreeEntry, etag: String, size: Int64, isLFS: Bool)] = []
        var commitHash: String?
        for entry in entries {
            let info = try await client.getFile(at: entry.path, in: repo, revision: "main")
            guard info.exists, let etag = info.etag else {
                throw DownloadError(message: "無法取得檔案資訊：\(entry.path)")
            }
            if commitHash == nil { commitHash = info.revision }
            let size = entry.size.map(Int64.init) ?? info.size ?? 0
            files.append((entry, etag, size, info.isLFS))
        }
        guard let commitHash else {
            throw DownloadError(message: "無法解析 \(modelID) 的版本")
        }

        // One folder per model, kept from one attempt (and one app run) to
        // the next: a download that failed, or an app that quit halfway,
        // picks up where it stopped, since `downloadResumable` resumes
        // whatever `.partial` file is already there. It goes once every
        // file is in the cache. Per model, not shared: one model finishing
        // must not delete another's files still in flight, and two models
        // with an identical small file (the same tokenizer config) must not
        // write the same etag-named partial. ModelDownloadManager never runs
        // two downloads of the same model at once.
        removeAbandonedTempDirs()
        let tempDir = partialDirectory(for: modelID)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: totalBytes, onFraction: progress)

        for file in files {
            // Already cached from an earlier attempt (this run or a prior one).
            if cache.cachedFilePath(repo: repo, kind: .model, revision: commitHash, filename: file.entry.path) != nil {
                tracker.fileCompleted(bytes: file.size)
                continue
            }

            let partialURL = tempDir.appendingPathComponent(cache.normalizeEtag(file.etag) + ".partial")
            try await downloadResumable(
                repo: repo, filePath: file.entry.path, revision: commitHash,
                to: partialURL, expectedSize: file.size, verifySHA256: file.isLFS ? file.etag : nil
            ) { written in
                tracker.fileProgress(currentWritten: written)
            }

            try await cache.storeFile(
                at: partialURL, repo: repo, kind: .model, revision: commitHash,
                filename: file.entry.path, etag: file.etag, ref: "main"
            )
            try? FileManager.default.removeItem(at: partialURL)

            tracker.fileCompleted(bytes: file.size)
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static var tempRoot: URL {
        MultiSubPaths.modelsRoot.appendingPathComponent(".download-tmp", isDirectory: true)
    }

    /// Where `modelID`'s unfinished files wait for the next attempt.
    private static func partialDirectory(for modelID: String) -> URL {
        // "org/name" -> "org--name", like the Hugging Face cache's own folders.
        let name = modelID.replacingOccurrences(of: "/", with: "--")
            .map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? String($0) : "_" }
            .joined()
        return tempRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Whether an earlier attempt left part of `modelID` behind, so 下載
    /// can say it will continue rather than start over.
    static func hasPartialDownload(modelID: String) -> Bool {
        FileManager.default.fileExists(atPath: partialDirectory(for: modelID).path)
    }

    /// Builds before resumable folders used a fresh UUID-named folder per
    /// attempt and left it behind when the app quit mid-download. Nothing
    /// can resume from those any more; they only take up disk space.
    private static func removeAbandonedTempDirs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tempRoot.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            try? fm.removeItem(at: tempRoot.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Accumulates completed-file bytes behind a lock, since `fileProgress`
    /// is called from `StreamingDownloadDelegate`'s callback queue while
    /// `fileCompleted` is called from the downloading `Task` — two different
    /// threads touching the same running total.
    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var doneBytes: Int64 = 0
        private let totalBytes: Int64
        private let onFraction: @Sendable (Double) -> Void

        init(totalBytes: Int64, onFraction: @escaping @Sendable (Double) -> Void) {
            self.totalBytes = max(totalBytes, 1)
            self.onFraction = onFraction
        }

        func fileCompleted(bytes: Int64) {
            lock.lock()
            doneBytes += bytes
            let fraction = Double(doneBytes) / Double(totalBytes)
            lock.unlock()
            onFraction(min(1, max(0, fraction)))
        }

        func fileProgress(currentWritten: Int64) {
            lock.lock()
            let fraction = Double(doneBytes + currentWritten) / Double(totalBytes)
            lock.unlock()
            // Defensive clamp: a size estimate that's briefly off (e.g. a
            // repo entry missing a size) shouldn't visibly overshoot 100%.
            onFraction(min(1, max(0, fraction)))
        }
    }

    /// Downloads a single file to `destination`, resuming via `Range` headers
    /// against whatever `destination` already contains, retrying transient
    /// failures. `verifySHA256`, when given (LFS files only — the etag *is*
    /// the sha256 for those, unlike small git-native files), is checked
    /// against the fully-downloaded bytes before returning.
    private static func downloadResumable(
        repo: Repo.ID, filePath: String, revision: String,
        to destination: URL, expectedSize: Int64, verifySHA256: String?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let url = HubClient.defaultHost
            .appendingPathComponent(repo.namespace)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
            .appendingPathComponent(filePath)

        let maxAttempts = 20
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let existing = fileSize(at: destination)
            if expectedSize > 0, existing >= expectedSize {
                break
            }
            var request = URLRequest(url: url)
            if existing > 0 {
                request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            }
            do {
                try await runDownload(request: request, to: destination, resumeOffset: existing, onBytes: onBytes)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt == maxAttempts { break }
                try? await Task.sleep(nanoseconds: UInt64(min(30, attempt * 2)) * 1_000_000_000)
            }
        }
        if let lastError { throw lastError }

        // A file that is too short is kept: the next attempt resumes it. One
        // that is too long, or whose bytes don't check out, can't be
        // repaired by resuming, so it goes and that file starts over.
        let finalSize = fileSize(at: destination)
        if expectedSize > 0, finalSize != expectedSize {
            if finalSize > expectedSize { try? FileManager.default.removeItem(at: destination) }
            throw DownloadError(message: "\(filePath) 下載大小不符（預期 \(expectedSize)，實際 \(finalSize)）")
        }
        if let verifySHA256 {
            let normalized = verifySHA256.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .replacingOccurrences(of: "W/", with: "")
            guard normalized.count == 64, let actual = try? sha256Hex(of: destination), actual == normalized else {
                try? FileManager.default.removeItem(at: destination)
                throw DownloadError(message: "\(filePath) 的 SHA256 驗證失敗，檔案可能損毀")
            }
        }
    }

    /// One attempt: streams the response body directly into `destination` via
    /// a data-task delegate — never through a system-managed temp file, which
    /// is exactly the mechanism that loses partial downloads on disconnect.
    private static func runDownload(
        request: URLRequest, to destination: URL, resumeOffset: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let delegate = StreamingDownloadDelegate(destination: destination, resumeOffset: resumeOffset, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.completion = { result in continuation.resume(with: result) }
            session.dataTask(with: request).resume()
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streams a data task's response body straight to a file handle we control,
/// resuming an existing `.partial` file when the server honors our `Range`
/// request (HTTP 206). If it ignores `Range` and returns 200 instead, we
/// truncate and restart that file fresh rather than risk appending full
/// content onto a partial one.
private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeOffset: Int64
    private let onBytes: (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var statusCode: Int?
    var completion: ((Result<Void, Error>) -> Void)?

    init(destination: URL, resumeOffset: Int64, onBytes: @escaping (Int64) -> Void) {
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.onBytes = onBytes
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            statusCode = (response as? HTTPURLResponse)?.statusCode
            completionHandler(.cancel)
            return
        }
        statusCode = http.statusCode
        let isResuming = resumeOffset > 0 && http.statusCode == 206
        if !isResuming {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            written = 0
        } else {
            written = resumeOffset
        }
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            completionHandler(.cancel)
            return
        }
        if isResuming { handle.seekToEndOfFile() }
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        written += Int64(data.count)
        onBytes(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if let error {
            completion?(.failure(error))
        } else if let statusCode, (200..<300).contains(statusCode) {
            completion?(.success(()))
        } else {
            completion?(.failure(ModelDownloader.DownloadError(message: "HTTP \(statusCode ?? -1)")))
        }
        completion = nil
    }
}
