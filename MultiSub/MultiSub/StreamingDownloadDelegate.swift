//
//  StreamingDownloadDelegate.swift
//  MultiSub
//
//  The URLSession delegate `ModelDownloader` streams each model file
//  through, and the error it reports when that file can't be written. Kept
//  out of ModelDownloader.swift, which needs the Hugging Face package, so
//  tests/native can build it with Foundation alone.
//
//  Every write goes through FileHandle's throwing calls
//  (`write(contentsOf:)`, `seekToEnd()`). The older `write(_:)` and
//  `seekToEndOfFile()` raise an Objective-C exception when a write fails,
//  which Swift can't catch: a disk that filled up mid-download quit the
//  app, and every 繼續下載 quit it again while the disk stayed full.
//

import Foundation

/// A download stopped because its file couldn't be opened or written,
/// usually because the disk is full. Trying again at once fails the same
/// way, so `ModelDownloader` reports it without retrying; what was written
/// before it stays on disk, and 繼續下載 resumes from there once there is
/// room.
struct DownloadWriteError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        // Unlike Foundation's text, says what to do about it.
        isOutOfSpace ? "磁碟空間不足，清出空間後再試一次" : underlying.localizedDescription
    }

    var isOutOfSpace: Bool {
        let error = underlying as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return posix.code == Int(ENOSPC) || posix.code == Int(EDQUOT)
    }
}

/// Streams a data task's response body straight to a file handle we control,
/// resuming an existing `.partial` file when the server honors our `Range`
/// request (HTTP 206). If it ignores `Range` and returns 200 instead, we
/// truncate and restart that file fresh rather than risk appending full
/// content onto a partial one.
///
/// A file that can't be opened or written cancels the task, and the
/// completion reports that `DownloadWriteError` instead of the
/// cancellation. The bytes written before it are still the file's first
/// bytes, so the next attempt resumes from them.
final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeOffset: Int64
    private let onBytes: (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var statusCode: Int?
    private var writeError: DownloadWriteError?
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
        do {
            let handle = try FileHandle(forWritingTo: destination)
            self.handle = handle
            if isResuming { try handle.seekToEnd() }
        } catch {
            writeError = DownloadWriteError(underlying: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Chunks still arriving after a failed write are dropped.
        guard writeError == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            writeError = DownloadWriteError(underlying: error)
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        onBytes(written)
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
