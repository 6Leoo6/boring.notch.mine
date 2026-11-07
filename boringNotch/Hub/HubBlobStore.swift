//
//  HubBlobStore.swift
//  boringNotch
//
//  The files behind the agent bridge's streaming `/blob` route (hub D-176): uploads land
//  here as `<sha256>.part` and become `<sha256>` once every byte is in and the hash matches;
//  `shelf.put {blob}` moves a complete one onto the shelf, `shelf.get {blob: true}` hashes a
//  shelf file and remembers where it is so `GET /blob/{sha256}` can stream it. Nothing is
//  ever held in memory whole, so a 5 GB file costs what a 5 KB one does.
//

import CryptoKit
import Foundation

final class HubBlobStore: @unchecked Sendable {
    static let shared = HubBlobStore()

    /// Unused blobs, partials and references go 24 h after their last write or read.
    static let expiry: TimeInterval = 24 * 3600
    /// Kept free on the volume after an upload, so a big file never fills the disk.
    static let freeSpaceMargin: Int64 = 1 << 30
    static let ioChunk = 1 << 20

    enum Failure: Error {
        case invalid(String)
        case tooLarge(String)
        case notFound(String)
        case busy(String)
        case io(String)

        var message: String {
            switch self {
            case .invalid(let m), .tooLarge(let m), .notFound(let m), .busy(let m), .io(let m): return m
            }
        }

        /// The hub contract's error code for the envelope.
        var code: String {
            switch self {
            case .invalid: return "invalid_params"
            case .tooLarge: return "too_large"
            case .notFound: return "not_found"
            case .busy, .io: return "unavailable"
            }
        }
    }

    struct Progress {
        let sha256: String
        let size: Int64
        let receivedBytes: Int64
        let complete: Bool

        var json: [String: Any] {
            ["sha256": sha256, "size": size, "received_bytes": receivedBytes, "complete": complete]
        }
    }

    /// A file somewhere else (a shelf item's own file) that `GET /blob` may serve by its hash.
    private struct Reference {
        let url: URL
        let size: Int64
        let modified: Date?
        var lastUsed: Date
    }

    let directory: URL
    private let lock = NSLock()
    /// Running hash of each partial's contiguous prefix, so completing an upload does not
    /// read the whole file again. Lost on restart; the file is then hashed once at the end.
    private var hashers: [String: (hasher: SHA256, upTo: Int64)] = [:]
    /// Uploads running now, by sha256, with the bytes each may still write: busy blobs, and
    /// space promised to them so two big uploads at once can't both pass the free-space check.
    private var reserved: [String: Int64] = [:]
    private var references: [String: Reference] = [:]
    private var hashCache: [String: String] = [:]
    private var sweeper: DispatchSourceTimer?

    private init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hub-blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 3600)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweeper = timer
    }

    static func normalized(_ raw: String) -> String? {
        let sha = raw.lowercased()
        guard sha.count == 64, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return sha
    }

    private func completeURL(_ sha: String) -> URL { directory.appendingPathComponent(sha) }
    private func partURL(_ sha: String) -> URL { directory.appendingPathComponent(sha + ".part") }

    static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes this app could still take, keeping the margin free and the space promised to
    /// running uploads.
    func availableBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return availableBytesLocked()
    }

    private func availableBytesLocked() -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let promised = reserved.values.reduce(0, +)
        return max(0, free - Self.freeSpaceMargin - promised)
    }

    // MARK: - Upload (PUT /blob/{sha256})

    enum Begin {
        /// Nothing to write: answer with this (progress query, or already complete).
        case answer(Progress)
        case upload(Upload)
    }

    func begin(sha: String, size: Int64, offset requested: Int64, length: Int64) throws -> Begin {
        var offset = requested
        guard size >= 0 else { throw Failure.invalid("Hub-Blob-Size must be 0 or more") }
        guard offset >= 0 else { throw Failure.invalid("Hub-Blob-Offset must be 0 or more") }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if let done = Self.fileSize(completeURL(sha)) {
            touch(completeURL(sha))
            return .answer(Progress(sha256: sha, size: done, receivedBytes: done, complete: true))
        }
        let part = partURL(sha)
        var received = Self.fileSize(part) ?? 0
        if received > size {
            try? fm.removeItem(at: part)
            hashers[sha] = nil
            received = 0
        }
        let progress = Progress(sha256: sha, size: size, receivedBytes: received, complete: false)
        guard offset <= received else {
            throw Failure.invalid("Hub-Blob-Offset \(offset) is past received_bytes \(received)")
        }
        if length == 0 {
            // A partial with every byte that never completed (the app quit while hashing or
            // moving it): complete it now instead of answering progress forever.
            guard received == size, reserved[sha] == nil else { return .answer(progress) }
            offset = received
        }
        guard reserved[sha] == nil else { throw Failure.busy("Another upload of this blob is running; try again shortly") }
        guard length >= 0, length <= size - offset else {
            throw Failure.invalid("Hub-Blob-Offset \(offset) + Content-Length \(length) is past Hub-Blob-Size \(size)")
        }
        let available = availableBytesLocked()
        guard size - offset <= available else {
            throw Failure.tooLarge("\(size - offset) more bytes do not fit: \(available) bytes are free on this Mac")
        }
        if !fm.fileExists(atPath: part.path) {
            guard fm.createFile(atPath: part.path, contents: nil) else { throw Failure.io("Could not create the blob file") }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
            if offset < received { try handle.truncate(atOffset: UInt64(offset)) }
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            throw Failure.io("Could not open the blob file: \(error.localizedDescription)")
        }
        var hasher: SHA256?
        if let running = hashers[sha], running.upTo == offset {
            hasher = running.hasher
        } else if offset == 0 {
            hasher = SHA256()
        }
        hashers[sha] = nil
        reserved[sha] = size - offset
        return .upload(Upload(store: self, sha: sha, size: size, offset: offset, handle: handle, hasher: hasher))
    }

    /// One PUT's body going to disk. Used from one queue at a time.
    final class Upload: @unchecked Sendable {
        let sha: String
        let size: Int64
        private(set) var position: Int64
        private let store: HubBlobStore
        private var handle: FileHandle?
        private var hasher: SHA256?
        private var ended = false

        fileprivate init(store: HubBlobStore, sha: String, size: Int64, offset: Int64, handle: FileHandle, hasher: SHA256?) {
            self.store = store
            self.sha = sha
            self.size = size
            self.position = offset
            self.handle = handle
            self.hasher = hasher
        }

        func write(_ data: Data) throws {
            guard let handle else { throw Failure.io("Upload already closed") }
            do {
                try handle.write(contentsOf: data)
            } catch {
                let code = (error as NSError).code
                if code == Int(ENOSPC) || code == NSFileWriteOutOfSpaceError {
                    throw Failure.tooLarge("The disk is full")
                }
                throw Failure.io("Could not write the blob: \(error.localizedDescription)")
            }
            hasher?.update(data: data)
            position += Int64(data.count)
        }

        /// The body ended early (the client went away): keep what arrived for a resume.
        func abort() {
            guard !ended else { return }
            ended = true
            try? handle?.close()
            handle = nil
            store.release(sha, hasher: hasher, upTo: position)
        }

        /// All of this body is in. Hashes the file when the running hash was lost (slow for a
        /// big file, so call it off the connection queue).
        func finish() throws -> Progress {
            guard !ended else { throw Failure.io("Upload already ended") }
            ended = true
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            guard position == size else {
                store.release(sha, hasher: hasher, upTo: position)
                return Progress(sha256: sha, size: size, receivedBytes: position, complete: false)
            }
            return try store.complete(sha, size: size, hasher: hasher)
        }
    }

    private func release(_ sha: String, hasher: SHA256?, upTo: Int64) {
        lock.lock()
        reserved[sha] = nil
        if let hasher { hashers[sha] = (hasher, upTo) }
        lock.unlock()
    }

    private func complete(_ sha: String, size: Int64, hasher: SHA256?) throws -> Progress {
        let part = partURL(sha)
        let digest: String
        if let hasher {
            digest = Self.hex(hasher.finalize())
        } else {
            digest = (try? Self.hash(part)) ?? ""
        }
        lock.lock()
        defer { lock.unlock() }
        reserved[sha] = nil
        hashers[sha] = nil
        guard digest == sha else {
            try? FileManager.default.removeItem(at: part)
            throw Failure.invalid("The bytes do not match sha256 \(sha) (got \(digest.isEmpty ? "unreadable" : digest)); the partial was dropped")
        }
        let done = completeURL(sha)
        try? FileManager.default.removeItem(at: done)
        do {
            try FileManager.default.moveItem(at: part, to: done)
        } catch {
            throw Failure.io("Could not keep the blob: \(error.localizedDescription)")
        }
        return Progress(sha256: sha, size: size, receivedBytes: size, complete: true)
    }

    // MARK: - Download (GET /blob/{sha256})

    /// The file behind a hash: an uploaded blob first, then a shelf file `shelf.get` hashed.
    func resolve(_ sha: String) -> (url: URL, size: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        let done = completeURL(sha)
        if let size = Self.fileSize(done) {
            touch(done)
            return (done, size)
        }
        guard var reference = references[sha] else { return nil }
        let accessing = reference.url.startAccessingSecurityScopedResource()
        defer { if accessing { reference.url.stopAccessingSecurityScopedResource() } }
        // Edited since it was hashed: those bytes no longer have this sha256.
        guard Self.fileSize(reference.url) == reference.size, Self.modified(reference.url) == reference.modified else {
            references[sha] = nil
            return nil
        }
        reference.lastUsed = Date()
        references[sha] = reference
        return (reference.url, reference.size)
    }

    // MARK: - Shelf

    /// `shelf.put {blob}`: the complete blob moves into a temporary shelf file named `name`.
    func takeOver(_ sha: String, name: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let done = completeURL(sha)
        guard let size = Self.fileSize(done) else {
            throw Failure.notFound("No complete blob \(sha): upload it to /blob first")
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: done, to: target)
        } catch {
            throw Failure.io("Could not move the blob onto the shelf: \(error.localizedDescription)")
        }
        references[sha] = Reference(url: target, size: size, modified: Self.modified(target), lastUsed: Date())
        return target
    }

    /// Undoes `takeOver` when the shelf could not keep the file, so the blob isn't orphaned.
    func giveBack(_ sha: String, from url: URL) {
        lock.lock()
        defer { lock.unlock() }
        references[sha] = nil
        try? FileManager.default.moveItem(at: url, to: completeURL(sha))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// `shelf.get {blob: true}` for a file: its hash, remembered so `GET /blob` can serve it.
    /// `url` must be readable (inside the caller's security scope) while this runs.
    func reference(_ url: URL) throws -> (sha: String, size: Int64) {
        guard let size = Self.fileSize(url) else { throw Failure.notFound("The file behind this shelf item can't be read") }
        let modified = Self.modified(url)
        let mtime = modified?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(mtime)"
        lock.lock()
        let cached = hashCache[key]
        lock.unlock()
        let sha: String
        if let cached {
            sha = cached
        } else {
            do { sha = try Self.hash(url) } catch { throw Failure.io("Could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        lock.lock()
        hashCache[key] = sha
        references[sha] = Reference(url: url, size: size, modified: modified, lastUsed: Date())
        lock.unlock()
        return (sha, size)
    }

    /// A folder's zip (made by the caller in the temporary folder) becomes a complete blob.
    func adopt(_ file: URL) throws -> (sha: String, size: Int64) {
        guard let size = Self.fileSize(file) else { throw Failure.io("The archive vanished") }
        let sha: String
        do { sha = try Self.hash(file) } catch { throw Failure.io("Could not read the archive: \(error.localizedDescription)") }
        lock.lock()
        defer { lock.unlock() }
        let done = completeURL(sha)
        try? FileManager.default.removeItem(at: done)
        do { try FileManager.default.moveItem(at: file, to: done) } catch {
            throw Failure.io("Could not keep the archive: \(error.localizedDescription)")
        }
        return (sha, size)
    }

    // MARK: - Housekeeping

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.expiry)
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let name = file.lastPathComponent
            let sha = name.hasSuffix(".part") ? String(name.dropLast(5)) : name
            guard reserved[sha] == nil else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
                hashers[sha] = nil
            }
        }
        references = references.filter { $0.value.lastUsed >= cutoff }
        if hashCache.count > 4096 { hashCache.removeAll() }
    }

    // MARK: - Hashing

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through SHA-256, 4 MiB at a time.
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let more: Bool = try autoreleasepool {
                guard let data = try handle.read(upToCount: 4 << 20), !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
            if !more { break }
        }
        return hex(hasher.finalize())
    }
}
