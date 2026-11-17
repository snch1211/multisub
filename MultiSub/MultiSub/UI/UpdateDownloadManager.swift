//
//  UpdateDownloadManager.swift
//  MultiSub
//
//  Direct (DMG) builds only; compiled out under `APP_STORE`. Downloads the
//  new version's DMG asset straight into "下載項目" (mirroring
//  `ModelDownloadManager`'s always-alive-at-app-root ownership, so
//  navigating away from the general-settings tab mid-download doesn't
//  interrupt it), then opens it and hands off to the Finder-driven "drag into
//  Applications" flow described in the UI's completion message — a build
//  outside the App Store can't safely replace its own running bundle.
//

#if !APP_STORE
import AppKit
import Foundation

@Observable
@MainActor
final class UpdateDownloadManager {
    struct DownloadState {
        var progress: Double = 0
        var failed = false
        var errorDescription: String?
        var completedFileURL: URL?
    }

    private(set) var state: DownloadState?
    private var task: Task<Void, Never>?

    var isDownloading: Bool { task != nil }

    /// No-op if a download is already in flight — mirrors
    /// `ModelDownloadManager.start`'s guard against double-tapping "開始更新".
    func start(from url: URL, suggestedFileName: String) {
        guard task == nil else { return }
        state = DownloadState()

        task = Task { [weak self] in
            do {
                let destination = try await Self.download(from: url, suggestedFileName: suggestedFileName) { fraction in
                    Task { @MainActor in self?.state?.progress = fraction }
                }
                self?.state?.completedFileURL = destination
                self?.task = nil
                NSWorkspace.shared.open(destination)
            } catch {
                self?.state?.failed = true
                self?.state?.errorDescription = error.localizedDescription
                self?.task = nil
            }
        }
    }

    func dismiss() {
        state = nil
    }

    private static func download(
        from url: URL, suggestedFileName: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ModelDownloader.DownloadError(message: "找不到「下載項目」資料夾")
        }
        let destination = downloadsDir.appendingPathComponent(suggestedFileName)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let delegate = DMGDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.completion = { result in continuation.resume(with: result) }
            session.dataTask(with: url).resume()
        }
        return destination
    }
}

/// Single-shot (no resume — a DMG is small enough that a dropped connection
/// just means "tap 開始更新 again"), unlike `ModelDownloader`'s
/// `StreamingDownloadDelegate` which exists specifically to resume
/// multi-gigabyte weight files.
private final class DMGDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (Double) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var expected: Int64 = 0
    private var statusCode: Int?
    private var writeError: DownloadWriteError?
    var completion: ((Result<Void, Error>) -> Void)?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
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
        expected = response.expectedContentLength
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            completionHandler(.cancel)
            return
        }
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The throwing write, as in `StreamingDownloadDelegate`: the older
        // `write(_:)` quits the app when the disk is full.
        guard writeError == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            writeError = DownloadWriteError(underlying: error)
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        if expected > 0 { progress(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if let writeError {
            completion?(.failure(writeError))
        } else if let error {
            completion?(.failure(error))
        } else if let statusCode, (200..<300).contains(statusCode) {
            completion?(.success(()))
        } else {
            completion?(.failure(ModelDownloader.DownloadError(message: "HTTP \(statusCode ?? -1)")))
        }
        completion = nil
    }
}
#endif
