//
//  AgentBridgeRouter.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation
import SwiftUI

/// The operations behind `AgentBridgeServer`: `{"op": "...", "args": {...}}` in,
/// `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}` out.
///
/// JSON and base64 are handled off the main actor; only reads and writes of the live shelf
/// and clipboard state hop onto it, so a large transfer does not stall the notch's animations.
enum AgentBridgeRouter {
    /// Per-file cap in either direction. The helper enforces the same number before it
    /// uploads, so this is the backstop rather than the usual refusal.
    static let maxPayloadBytes = 64 * 1024 * 1024

    struct BridgeError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// `[String: Any]` is not Sendable; these only ever cross from the connection's queue to
    /// the main actor and back, with no concurrent access.
    fileprivate struct Args: @unchecked Sendable {
        let raw: [String: Any]
        func string(_ key: String) -> String? { raw[key] as? String }
        func bool(_ key: String) -> Bool? { raw[key] as? Bool }
        func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
        func strings(_ key: String) -> [String]? { raw[key] as? [String] }
    }

    fileprivate struct Payload: @unchecked Sendable {
        let value: Any
    }

    static func respond(to body: Data) async -> Data {
        do {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let op = object["op"] as? String
            else { throw BridgeError(#"Body must be {"op": "...", "args": {...}}"#) }
            let args = Args(raw: object["args"] as? [String: Any] ?? [:])
            let result = try await dispatch(op, args)
            return encode(["ok": true, "result": result.value])
        } catch let error as BridgeError {
            return encode(["ok": false, "error": error.message])
        } catch {
            return encode(["ok": false, "error": error.localizedDescription])
        }
    }

    private static func dispatch(_ op: String, _ args: Args) async throws -> Payload {
        switch op {
        case "status": return await status()
        case "shelf.list": return try await shelfList()
        case "shelf.get": return try await shelfGet(args)
        case "shelf.put": return try await shelfPut(args)
        case "shelf.remove": return try await shelfRemove(args)
        case "events.push": return try await eventsPush(args)
        #if DEBUG
        case "debug.hub_peek": return await debugHubPeek(args)
        case "debug.hub_peek_render": return await debugHubPeekRender()
        #endif
        case "clipboard.list": return try await clipboardList(args)
        case "clipboard.get": return try await clipboardGet(args)
        case "clipboard.add": return try await clipboardAdd(args)
        default: throw BridgeError("Unknown op \(op)")
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"Response was not encodable"}"#.utf8)
    }

    // MARK: - Status

    @MainActor
    private static func status() -> Payload {
        let clipboard = ClipboardManager.shared
        return Payload(value: [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "shelf_enabled": Defaults[.boringShelf],
            "shelf_count": ShelfStateViewModel.shared.items.count,
            "clipboard_enabled": Defaults[.clipboardHistoryEnabled],
            "clipboard_count": clipboard.items.count,
            "clipboard_pinned_count": clipboard.pinnedItems.count,
            "auto_protect_secrets": Defaults[.clipboardAutoProtectSecrets],
            "max_payload_bytes": maxPayloadBytes,
        ])
    }

    // MARK: - Shelf

    @MainActor
    private static func requireShelf() throws {
        guard Defaults[.boringShelf] else { throw BridgeError("The shelf is turned off in boring.notch settings") }
    }

    @MainActor
    private static func shelfItem(_ args: Args) throws -> ShelfItem {
        guard let raw = args.string("id"), let id = UUID(uuidString: raw) else { throw BridgeError("id is required") }
        guard let item = ShelfStateViewModel.shared.items.first(where: { $0.id == id }) else {
            throw BridgeError("No shelf item with id \(raw)")
        }
        return item
    }

    @MainActor
    private static func shelfList() throws -> Payload {
        try requireShelf()
        let state = ShelfStateViewModel.shared
        let items: [[String: Any]] = state.items.map { item in
            var out: [String: Any] = [
                "id": item.id.uuidString,
                "name": item.displayName,
                "is_temporary": item.isTemporary,
            ]
            switch item.kind {
            case .file:
                out["kind"] = "file"
                if let url = state.resolveFileURL(for: item) {
                    out["file_name"] = url.lastPathComponent
                    // A temporary item's path is inside the app's container, which the agent
                    // cannot use; a dropped file's path is the user's own file and can be.
                    if !item.isTemporary { out["path"] = url.path }
                    let values = url.accessSecurityScopedResource { url in
                        try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    }
                    if values?.isDirectory == true { out["is_directory"] = true }
                    if let size = values?.fileSize { out["byte_size"] = size }
                } else {
                    out["missing"] = true
                }
            case .text(let string):
                out["kind"] = "text"
                out["char_count"] = string.count
                out["preview"] = preview(of: string)
            case .link(let url):
                out["kind"] = "link"
                out["url"] = url.absoluteString
            }
            return out
        }
        return Payload(value: ["count": items.count, "items": items])
    }

    private static func shelfGet(_ args: Args) async throws -> Payload {
        enum Target { case text(String), link(URL), file(URL, name: String) }
        let target: Target = try await MainActor.run {
            try requireShelf()
            let item = try shelfItem(args)
            switch item.kind {
            case .text(let string): return .text(string)
            case .link(let url): return .link(url)
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else {
                    throw BridgeError("The file behind this shelf item no longer exists")
                }
                return .file(url, name: url.lastPathComponent)
            }
        }

        switch target {
        case .text(let string):
            return Payload(value: ["kind": "text", "text": string])
        case .link(let url):
            return Payload(value: ["kind": "link", "url": url.absoluteString])
        case .file(let url, let name):
            let (data, sentName) = try await readShelfFile(url, name: name)
            return Payload(value: [
                "kind": "file",
                "file_name": sentName,
                "byte_size": data.count,
                "data_base64": data.base64EncodedString(),
            ])
        }
    }

    /// A folder goes out as a zip, the same way the shelf shares one.
    private static func readShelfFile(_ url: URL, name: String) async throws -> (Data, String) {
        try await url.accessSecurityScopedResource { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var source = url
            var sentName = name
            if values?.isDirectory == true {
                guard let zip = await TemporaryFileStorageService.shared.createZip(from: [url]) else {
                    throw BridgeError("Could not zip the folder")
                }
                source = zip
                sentName = zip.lastPathComponent
            } else if let size = values?.fileSize, size > maxPayloadBytes {
                throw BridgeError("File is \(size) bytes; the limit is \(maxPayloadBytes)")
            }
            defer { if source != url { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: source) } }
            let data = try Data(contentsOf: source)
            guard data.count <= maxPayloadBytes else {
                throw BridgeError("Archive is \(data.count) bytes; the limit is \(maxPayloadBytes)")
            }
            return (data, sentName)
        }
    }

    private static func shelfPut(_ args: Args) async throws -> Payload {
        try await MainActor.run { try requireShelf() }

        let kind: ShelfItemKind
        var isTemporary = false
        if let text = args.string("text") {
            guard !text.isEmpty else { throw BridgeError("text is empty") }
            kind = .text(string: text)
        } else if let raw = args.string("url") {
            guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty, !url.isFileURL else {
                throw BridgeError("url must be an absolute non-file URL")
            }
            kind = .link(url: url)
        } else if let raw = args.string("path") {
            // A file already on this Mac, put on the shelf by reference (hub D-142): the
            // hub helper hands over what other devices send, saved in ~/Documents/Hub, so
            // removing the item leaves the file. Not temporary, deduplicated by path. Only
            // the helper and local agents reach this /rpc (loopback + token); the helper
            // never passes a path that came from another device.
            guard raw.hasPrefix("/") else { throw BridgeError("path must be absolute") }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw BridgeError("path must be an existing file this app can read")
            }
            guard let bookmark = try? Bookmark(url: url).data else {
                throw BridgeError("Could not keep a reference to \(url.lastPathComponent)")
            }
            kind = .file(bookmark: bookmark)
        } else if let encoded = args.string("data_base64") {
            guard let data = Data(base64Encoded: encoded) else { throw BridgeError("data_base64 is not valid base64") }
            guard data.count <= maxPayloadBytes else { throw BridgeError("File exceeds \(maxPayloadBytes) bytes") }
            let name = sanitizedFileName(args.string("file_name"))
            guard let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: name)),
                  let bookmark = try? Bookmark(url: url).data
            else { throw BridgeError("Could not store the file") }
            kind = .file(bookmark: bookmark)
            isTemporary = true
        } else {
            throw BridgeError("Provide one of text, url, path, or data_base64 + file_name")
        }

        return await MainActor.run {
            let state = ShelfStateViewModel.shared
            let item = ShelfItem(kind: kind, isTemporary: isTemporary)
            state.add([item])
            // `add` dedupes by identity, so the id that survived may be an older twin's
            let key = item.identityKey
            let stored = state.items.first { $0.identityKey == key } ?? item
            // Anything put here came over the bridge, i.e. not a local drag: the hub helper
            // delivering another device's share. `from` / `from_kind` name the sender when
            // the caller knows it (optional; the peek says "On your shelf" without them).
            HubActivity.shared.arrived(stored, from: args.string("from"), fromKind: args.string("from_kind"))
            return Payload(value: [
                "id": stored.id.uuidString,
                "name": stored.displayName,
                "already_present": stored.id != item.id,
            ])
        }
    }

    #if DEBUG
    /// Debug builds only: previews the hub peek without another device. `mode` "transfer"
    /// (default) runs fake progress over `seconds` for `size` bytes, then lands; "fail" stops
    /// at 60%; "arrival" shows a finished arrival for the newest shelf item.
    @MainActor
    private static func debugHubPeek(_ args: Args) -> Payload {
        let from = args.string("from")
        let kind = args.string("from_kind")
        switch args.string("mode") ?? "transfer" {
        case "arrival":
            guard let item = ShelfStateViewModel.shared.items.last else {
                return Payload(value: ["shown": false])
            }
            HubActivity.shared.arrived(item, from: from, fromKind: kind)
        default:
            let seconds = (args.raw["seconds"] as? NSNumber)?.doubleValue ?? 6
            HubActivity.shared.previewTransfer(
                name: args.string("name") ?? "IMG_2041.HEIC",
                size: Int64(args.int("size") ?? 48_000_000),
                seconds: max(0.5, seconds),
                from: from, fromKind: kind,
                fail: args.string("mode") == "fail"
            )
        }
        // Whether a closed notch hides its peeks right now (a full-screen app with "Hide the
        // notch" on), so an agent can tell an empty screenshot from a broken peek.
        let delegate = NSApp.delegate as? AppDelegate
        let hidden = [delegate?.vm].compactMap { $0 } + (delegate.map { Array($0.viewModels.values) } ?? [])
        return Payload(value: ["shown": true, "hidden_by_fullscreen": hidden.contains { $0.hideOnClosed }])
    }
    #endif

    // MARK: - Events

    /// What the agent bridge accepts from `events.push` (hub contract, D-139): 1..64 events,
    /// each `{topic, type, time?, origin?, data?}` with `data` at most 4 KiB of JSON.
    static let maxPushedEvents = 64
    static let maxPushedEventData = 4096

    /// `events.push`: the hub helper hands over its `transfer` events while it receives a file
    /// (the sandboxed notch can't long-poll the helper). The notch keeps no event stream of its
    /// own, so the events drive the hub peek and are not kept; other topics are accepted and
    /// ignored. A malformed batch is refused whole, nothing of it shown.
    private static func eventsPush(_ args: Args) async throws -> Payload {
        guard let raw = args.raw["events"] as? [Any] else {
            throw BridgeError("events is required: an array of {topic, type, data}")
        }
        guard (1...maxPushedEvents).contains(raw.count) else {
            throw BridgeError("events must hold 1 to \(maxPushedEvents) events, not \(raw.count)")
        }
        let decoder = JSONDecoder()
        var transfers: [(type: String, event: HubRPC.TransferEvent)] = []
        for (index, element) in raw.enumerated() {
            guard let object = element as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: object),
                  let pushed = try? decoder.decode(HubRPC.PushedEvent.self, from: encoded)
            else { throw BridgeError("events[\(index)] must be {topic, type, data?} with string topic and type, and data an object") }
            guard !pushed.topic.isEmpty, !pushed.type.isEmpty else {
                throw BridgeError("events[\(index)]: topic and type must not be empty")
            }
            let data = object["data"] as? [String: Any] ?? [:]
            let dataBytes = (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
            guard dataBytes.count <= maxPushedEventData else {
                throw BridgeError("events[\(index)].data is \(dataBytes.count) bytes; the limit is \(maxPushedEventData)")
            }
            guard pushed.topic == "transfer" else { continue }
            // A failure code this build doesn't know yet still counts as a failure.
            var fields = data
            if let code = fields["code"] as? String, HubRPC.TransferFailure(rawValue: code) == nil {
                fields.removeValue(forKey: "code")
            }
            guard let fieldBytes = try? JSONSerialization.data(withJSONObject: fields),
                  let event = try? decoder.decode(HubRPC.TransferEvent.self, from: fieldBytes)
            else {
                throw BridgeError("events[\(index)].data is not a transfer event: it needs transfer_id, name, size, from and received_bytes")
            }
            transfers.append((pushed.type, event))
        }
        let accepted = raw.count
        if !transfers.isEmpty {
            await MainActor.run {
                for transfer in transfers { HubActivity.shared.handle(transfer.event, type: transfer.type) }
            }
        }
        return Payload(value: ["published": accepted])
    }

    #if DEBUG
    /// Debug builds only: the hub peek as it is drawn right now, rendered off screen on the
    /// island's black (PNG, 2x). For checks while the screen is locked or asleep, when the
    /// window server keeps showing a stale frame and screenshots can't see the notch.
    @MainActor
    private static func debugHubPeekRender() -> Payload {
        let activity = HubActivity.shared
        guard let item = activity.item else { return Payload(value: ["item": NSNull()]) }
        let view = HubPeekView()
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var out: [String: Any] = [
            "id": item.id,
            "name": item.name,
            "phase": "\(item.phase)",
            "received_bytes": item.receivedBytes,
            "size": item.size,
            "stalled": item.stalled,
            "peek_up": BoringViewCoordinator.shared.sneakPeek.show && BoringViewCoordinator.shared.sneakPeek.type == .hub,
        ]
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            out["png_base64"] = png.base64EncodedString()
        }
        return Payload(value: out)
    }
    #endif

    /// Unknown ids answer `removed: false` rather than an error, so a sync helper can
    /// retry a removal without special cases (hub contract `shelf.remove`).
    @MainActor
    private static func shelfRemove(_ args: Args) throws -> Payload {
        try requireShelf()
        guard let raw = args.string("id") else { throw BridgeError("id is required") }
        guard let id = UUID(uuidString: raw) else { throw BridgeError("id must be a UUID") }
        let state = ShelfStateViewModel.shared
        guard let item = state.items.first(where: { $0.id == id }) else {
            return Payload(value: ["removed": false])
        }
        state.remove(item)
        return Payload(value: ["removed": true])
    }

    private static func sanitizedFileName(_ raw: String?) -> String {
        let base = (raw ?? "").components(separatedBy: "/").last ?? ""
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "file" }
        return trimmed
    }

    // MARK: - Clipboard

    @MainActor
    private static func requireClipboard() throws {
        guard Defaults[.clipboardHistoryEnabled] else {
            throw BridgeError("Clipboard history is turned off in boring.notch settings")
        }
    }

    @MainActor
    private static func clipboardList(_ args: Args) throws -> Payload {
        try requireClipboard()
        let manager = ClipboardManager.shared

        let type = args.string("type")
        if let type, !["text", "image", "files"].contains(type) {
            throw BridgeError("type must be text, image or files")
        }
        let since = try args.string("since").map { try parseDate($0, name: "since") }
        let until = try args.string("until").map { try parseDate($0, name: "until") }
        let pinnedOnly = args.bool("pinned_only") ?? false
        let protection = args.string("protected") ?? "include"
        guard ["include", "exclude", "only"].contains(protection) else {
            throw BridgeError("protected must be include, exclude or only")
        }
        let oldestFirst = (args.string("order") ?? "newest") == "oldest"
        let limit = min(max(args.int("limit") ?? 50, 1), 500)
        let offset = max(args.int("offset") ?? 0, 0)

        let matching = manager.items
            .filter { entry in
                if let type, typeName(entry.content) != type { return false }
                if let since, entry.timestamp < since { return false }
                if let until, entry.timestamp > until { return false }
                if pinnedOnly, !entry.isPinned { return false }
                switch protection {
                case "exclude": return !manager.isProtected(entry)
                case "only": return manager.isProtected(entry)
                default: return true
                }
            }
            .sorted { oldestFirst ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp }

        let page = matching.dropFirst(offset).prefix(limit)
        return Payload(value: [
            "total": matching.count,
            "offset": offset,
            "count": page.count,
            "entries": page.map { describe($0, manager: manager) },
        ])
    }

    @MainActor
    private static func describe(_ entry: ClipboardEntry, manager: ClipboardManager) -> [String: Any] {
        let reason = manager.protectionReason(for: entry)
        var out: [String: Any] = [
            "id": entry.id.uuidString,
            "type": typeName(entry.content),
            "timestamp": timestampFormatter.string(from: entry.timestamp),
            "is_pinned": entry.isPinned,
            "is_protected": reason != nil,
        ]
        if let app = entry.sourceApp { out["source_app"] = app }
        if let reason { out["protection_reason"] = reason }
        switch entry.content {
        case .text(let text):
            out["char_count"] = text.count
            if reason == nil { out["preview"] = preview(of: text) }
        case .image(let image):
            out["width"] = Int(image.size.width)
            out["height"] = Int(image.size.height)
        case .fileURLs(let urls):
            out["file_count"] = urls.count
            if reason == nil { out["file_names"] = urls.map(\.lastPathComponent) }
        }
        return out
    }

    private static func clipboardGet(_ args: Args) async throws -> Payload {
        enum Content { case text(String), image(UUID, NSImage), files([URL]), withheld }
        let (meta, content): ([String: Any], Content) = try await MainActor.run {
            try requireClipboard()
            let manager = ClipboardManager.shared
            guard let raw = args.string("id"), let id = UUID(uuidString: raw) else { throw BridgeError("id is required") }
            guard let entry = manager.items.first(where: { $0.id == id }) else {
                throw BridgeError("No clipboard entry with id \(raw)")
            }
            let meta = describe(entry, manager: manager)
            guard !manager.isProtected(entry) else { return (meta, .withheld) }
            switch entry.content {
            case .text(let text): return (meta, .text(text))
            case .image(let image): return (meta, .image(entry.id, image))
            case .fileURLs(let urls): return (meta, .files(urls))
            }
        }

        var out = meta
        out.removeValue(forKey: "preview")
        switch content {
        case .withheld:
            out["content_withheld"] = true
        case .text(let text):
            out["text"] = text
        case .files(let urls):
            out["paths"] = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        case .image(let id, let image):
            let png = try await pngData(for: id, image: image)
            out["byte_size"] = png.count
            out["image_png_base64"] = png.base64EncodedString()
        }
        return Payload(value: out)
    }

    /// The PNG already on disk when there is one; the write is asynchronous, so a capture
    /// from the last instant may not have one yet and is encoded from memory instead.
    private static func pngData(for id: UUID, image: NSImage) async throws -> Data {
        let url = ClipboardPaths.imagesDir.appendingPathComponent(ClipboardPaths.imageFilename(for: id))
        if let data = try? Data(contentsOf: url) { return data }
        let tiff = await MainActor.run { image.tiffRepresentation }
        guard let tiff, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            throw BridgeError("Could not encode the image")
        }
        return png
    }

    private static func clipboardAdd(_ args: Args) async throws -> Payload {
        let input: ClipboardManager.AgentInput
        if let text = args.string("text") {
            input = .text(text)
        } else if let encoded = args.string("image_base64") {
            guard let data = Data(base64Encoded: encoded) else { throw BridgeError("image_base64 is not valid base64") }
            guard data.count <= maxPayloadBytes else { throw BridgeError("Image exceeds \(maxPayloadBytes) bytes") }
            input = .image(data)
        } else if let paths = args.strings("file_paths"), !paths.isEmpty {
            guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw BridgeError("file_paths must be absolute") }
            input = .fileURLs(paths.map { URL(fileURLWithPath: $0) })
        } else {
            throw BridgeError("Provide one of text, image_base64, or file_paths")
        }
        let pin = args.bool("pin") ?? false
        let client = args.string("client").map { $0.isEmpty ? "agent" : $0 } ?? "agent"

        return try await MainActor.run {
            try requireClipboard()
            let manager = ClipboardManager.shared
            guard let entry = manager.addFromAgent(input, pin: pin, sourceApp: "mcp.\(client)") else {
                throw BridgeError("Nothing usable to add (empty text or unreadable image)")
            }
            return Payload(value: describe(entry, manager: manager))
        }
    }

    // MARK: - Helpers

    private static func typeName(_ content: ClipboardEntry.ClipboardContent) -> String {
        switch content {
        case .text: return "text"
        case .image: return "image"
        case .fileURLs: return "files"
        }
    }

    private static func preview(of text: String) -> String {
        let limit = 200
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Local time with its offset, so an agent reasoning about "this afternoon" does not
    /// have to know the user's zone.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    /// Full ISO 8601 with or without fractional seconds, a bare local date-time, or a bare
    /// date (local midnight).
    private static func parseDate(_ raw: String, name: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: raw) { return date }
        }
        throw BridgeError("\(name) is not a recognisable date: \(raw)")
    }
}
