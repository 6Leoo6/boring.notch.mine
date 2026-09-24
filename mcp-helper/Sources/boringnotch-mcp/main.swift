//
//  boringnotch-mcp
//
//  stdio MCP server for boring.notch's shelf and clipboard history.
//
//  The app is sandboxed and cannot touch the paths an agent names, so this helper, running
//  unsandboxed as the agent's child, does all file I/O and relays bytes to the app's loopback
//  bridge (`AgentBridgeServer`). It finds the bridge through a discovery file the app writes
//  on every start; there is nothing to configure.
//

import Foundation

// MARK: - JSON-RPC plumbing

typealias JSON = [String: Any]

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let maxPayloadBytes = 64 * 1024 * 1024
/// Above this an image is saved to disk and its path returned, rather than inlined: a large
/// screenshot as an image block costs far more context than it is worth.
let maxInlineImageBytes = 4 * 1024 * 1024

var clientName = "agent"

func send(_ message: JSON) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("[boringnotch-mcp] \(text)\n".utf8))
}

func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8)
    else { return "\(value)" }
    return text
}

// MARK: - Bridge client

struct Bridge {
    let port: Int
    let token: String

    static var discoveryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/boringnotch/agent-bridge.json")
    }

    static func locate() throws -> Bridge {
        let offMessage = "boring.notch isn't reachable. Make sure the app is running and that Settings → Agents → \"Allow local agents\" is on."
        guard let data = try? Data(contentsOf: discoveryFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let port = object["port"] as? Int,
              let token = object["token"] as? String
        else { throw ToolError(offMessage) }
        // A crash leaves the file behind; a dead pid means the token in it is dead too
        if let pid = object["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH {
            throw ToolError(offMessage)
        }
        return Bridge(port: port, token: token)
    }

    func call(_ op: String, _ args: JSON = [:]) async throws -> Any {
        guard let url = URL(string: "http://127.0.0.1:\(port)/rpc") else { throw ToolError("Bad bridge URL") }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["op": op, "args": args])

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolError("Could not reach boring.notch on port \(port): \(error.localizedDescription). Is the app still running?")
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw ToolError("boring.notch sent an unreadable reply")
        }
        guard reply["ok"] as? Bool == true else {
            throw ToolError(reply["error"] as? String ?? "boring.notch reported an unknown error")
        }
        return reply["result"] ?? NSNull()
    }
}

// MARK: - Paths

func expandPath(_ raw: String) -> URL {
    let expanded = (raw as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded).standardizedFileURL
}

func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// `destination` may be a directory (existing, or spelled with a trailing slash) to drop
/// `fileName` into, or a full file path. nil means a scratch folder the agent can read from.
func resolveDestination(_ destination: String?, fileName: String) throws -> URL {
    let fm = FileManager.default
    let target: URL
    if let destination, !destination.isEmpty {
        let url = expandPath(destination)
        target = (destination.hasSuffix("/") || isDirectory(url)) ? url.appendingPathComponent(fileName) : url
    } else {
        target = fm.temporaryDirectory
            .appendingPathComponent("boringnotch-shelf", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
    }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    return target
}

func write(_ data: Data, to url: URL, overwrite: Bool) throws {
    if FileManager.default.fileExists(atPath: url.path) && !overwrite {
        throw ToolError("\(url.path) already exists. Pass overwrite: true to replace it.")
    }
    try data.write(to: url, options: .atomic)
}

func readForUpload(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw ToolError("\(url.path) is not a regular file") }
    if let size = values.fileSize, size > maxPayloadBytes {
        throw ToolError("\(url.lastPathComponent) is \(size) bytes; the limit is \(maxPayloadBytes)")
    }
    return try Data(contentsOf: url)
}

/// Folders go to the shelf as a zip, matching how the shelf itself shares one.
func zipFolder(_ url: URL) throws -> URL {
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(url.lastPathComponent + ".zip")
    try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", url.path, archive.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolError("Could not zip \(url.path)") }
    return archive
}

// MARK: - Tools

struct Tool {
    let name: String
    let description: String
    let schema: JSON
    let readOnly: Bool
    let run: (JSON) async throws -> [JSON]
}

func textContent(_ value: Any) -> [JSON] {
    [["type": "text", "text": value as? String ?? prettyJSON(value)]]
}

func requiredString(_ args: JSON, _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty else { throw ToolError("\(key) is required") }
    return value
}

func object(_ properties: JSON, required: [String] = []) -> JSON {
    var schema: JSON = ["type": "object", "properties": properties, "additionalProperties": false]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

let tools: [Tool] = [
    Tool(
        name: "shelf_list",
        description: "List everything on the boring.notch shelf (the drop zone in the notch): files, text snippets and links, with each item's id, kind, name, and for files the file name, size and, for files the user dropped, their original path.",
        schema: object([:]),
        readOnly: true
    ) { _ in
        textContent(try await Bridge.locate().call("shelf.list"))
    },

    Tool(
        name: "shelf_pull",
        description: "Get one shelf item. Files (folders arrive as .zip) are written to `destination` — a directory or a full file path — or, if omitted, to a scratch folder whose path is returned. Text and link items are returned inline, and also written to `destination` if one is given. Does not remove the item from the shelf.",
        schema: object([
            "id": ["type": "string", "description": "Shelf item id from shelf_list"],
            "destination": ["type": "string", "description": "Directory or file path to write to. ~ and relative paths are accepted."],
            "overwrite": ["type": "boolean", "description": "Replace an existing file at the destination. Default false."],
        ], required: ["id"]),
        readOnly: false
    ) { args in
        let id = try requiredString(args, "id")
        guard let result = try await Bridge.locate().call("shelf.get", ["id": id]) as? JSON else {
            throw ToolError("Unexpected reply for shelf item")
        }
        let overwrite = args["overwrite"] as? Bool ?? false
        let destination = args["destination"] as? String
        switch result["kind"] as? String {
        case "file":
            guard let encoded = result["data_base64"] as? String, let data = Data(base64Encoded: encoded) else {
                throw ToolError("File payload was missing")
            }
            let name = result["file_name"] as? String ?? "file"
            let target = try resolveDestination(destination, fileName: name)
            try write(data, to: target, overwrite: overwrite)
            return textContent(["kind": "file", "saved_to": target.path, "byte_size": data.count])
        case let kind?:
            let body = (result["text"] as? String) ?? (result["url"] as? String) ?? ""
            var out: JSON = ["kind": kind, kind == "link" ? "url" : "text": body]
            if let destination, !destination.isEmpty {
                let target = try resolveDestination(destination, fileName: kind == "link" ? "link.txt" : "text.txt")
                try write(Data(body.utf8), to: target, overwrite: overwrite)
                out["saved_to"] = target.path
            }
            return textContent(out)
        default:
            throw ToolError("Unexpected shelf item kind")
        }
    },

    Tool(
        name: "shelf_put",
        description: "Add something to the boring.notch shelf, the tray in the notch where the user picks up files. Use it to deliver a finished file when the user has not asked for a specific location. Give exactly one of: `path` (a file, or a folder which is zipped; copied onto the shelf, max 64 MB), `text`, or `url`. Returns the new item's id. Adding something already on the shelf returns the existing id.",
        schema: object([
            "path": ["type": "string", "description": "File or folder to copy onto the shelf. ~ and relative paths are accepted."],
            "text": ["type": "string", "description": "A text snippet to put on the shelf"],
            "url": ["type": "string", "description": "A web link to put on the shelf"],
        ]),
        readOnly: false
    ) { args in
        let given = ["path", "text", "url"].filter { (args[$0] as? String)?.isEmpty == false }
        guard given.count == 1 else { throw ToolError("Give exactly one of path, text, url") }
        var payload: JSON = [:]
        if let raw = args["path"] as? String {
            var url = expandPath(raw)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No file at \(url.path)") }
            var zipped: URL?
            if isDirectory(url) {
                zipped = try zipFolder(url)
                url = zipped ?? url
            }
            defer { if let zipped { try? FileManager.default.removeItem(at: zipped.deletingLastPathComponent()) } }
            payload["file_name"] = url.lastPathComponent
            payload["data_base64"] = try readForUpload(url).base64EncodedString()
        } else if let text = args["text"] as? String {
            payload["text"] = text
        } else if let link = args["url"] as? String {
            payload["url"] = link
        }
        return textContent(try await Bridge.locate().call("shelf.put", payload))
    },

    Tool(
        name: "clipboard_list",
        description: "List the user's boring.notch clipboard history, newest first by default. Filter by type (text, image, files), by time window (since/until, ISO 8601 or YYYY-MM-DD, local time when no offset is given), pinned status, or protection. Each entry has id, type, timestamp (local, with offset), source_app, is_pinned, is_protected and a short preview. Protected entries are listed without any content.",
        schema: object([
            "type": ["type": "string", "enum": ["text", "image", "files"]],
            "since": ["type": "string", "description": "Only entries copied at or after this time"],
            "until": ["type": "string", "description": "Only entries copied at or before this time"],
            "pinned_only": ["type": "boolean", "description": "Only pinned entries"],
            "protected": ["type": "string", "enum": ["include", "exclude", "only"], "description": "How to treat protected entries. Default include."],
            "order": ["type": "string", "enum": ["newest", "oldest"]],
            "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50"],
            "offset": ["type": "integer", "minimum": 0],
        ]),
        readOnly: true
    ) { args in
        var payload: JSON = [:]
        for key in ["type", "since", "until", "pinned_only", "protected", "order", "limit", "offset"] {
            if let value = args[key] { payload[key] = value }
        }
        return textContent(try await Bridge.locate().call("clipboard.list", payload))
    },

    Tool(
        name: "clipboard_get",
        description: "Get one clipboard history entry by id, including whether it is pinned. Text comes back in full, files as their paths, and images as an image (or saved to `save_image_to`, and always saved to a scratch path when larger than 4 MB). Protected entries return their metadata only — the user has hidden their content from agents.",
        schema: object([
            "id": ["type": "string", "description": "Entry id from clipboard_list"],
            "save_image_to": ["type": "string", "description": "For image entries: write the PNG here (directory or file path) instead of returning it inline"],
            "overwrite": ["type": "boolean", "description": "Replace an existing file at save_image_to. Default false."],
        ], required: ["id"]),
        readOnly: true
    ) { args in
        let id = try requiredString(args, "id")
        guard var result = try await Bridge.locate().call("clipboard.get", ["id": id]) as? JSON else {
            throw ToolError("Unexpected reply for clipboard entry")
        }
        guard let encoded = result.removeValue(forKey: "image_png_base64") as? String else {
            return textContent(result)
        }
        guard let png = Data(base64Encoded: encoded) else { throw ToolError("Image payload was unreadable") }
        let saveTo = args["save_image_to"] as? String
        if saveTo != nil || png.count > maxInlineImageBytes {
            let target = try resolveDestination(saveTo, fileName: "clipboard-\(id.prefix(8)).png")
            try write(png, to: target, overwrite: args["overwrite"] as? Bool ?? false)
            result["saved_to"] = target.path
            return textContent(result)
        }
        return textContent(result) + [["type": "image", "data": encoded, "mimeType": "image/png"]]
    },

    Tool(
        name: "clipboard_add",
        description: "Add an entry to the user's boring.notch clipboard history (it does not change what is currently on the system clipboard). Give exactly one of: `text`, `image_path` (PNG, JPEG, TIFF, HEIC…), or `file_paths`. Set `pin` to keep it permanently.",
        schema: object([
            "text": ["type": "string"],
            "image_path": ["type": "string", "description": "Image file to add as an image entry"],
            "file_paths": ["type": "array", "items": ["type": "string"], "description": "Files to add as one file entry"],
            "pin": ["type": "boolean", "description": "Pin the new entry. Default false."],
        ]),
        readOnly: false
    ) { args in
        var payload: JSON = ["pin": args["pin"] as? Bool ?? false, "client": clientName]
        var given = 0
        if let text = args["text"] as? String, !text.isEmpty {
            payload["text"] = text; given += 1
        }
        if let raw = args["image_path"] as? String, !raw.isEmpty {
            payload["image_base64"] = try readForUpload(expandPath(raw)).base64EncodedString(); given += 1
        }
        if let raws = args["file_paths"] as? [String], !raws.isEmpty {
            let urls = raws.map(expandPath)
            if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw ToolError("No file at \(missing.path)")
            }
            payload["file_paths"] = urls.map(\.path); given += 1
        }
        guard given == 1 else { throw ToolError("Give exactly one of text, image_path, file_paths") }
        return textContent(try await Bridge.locate().call("clipboard.add", payload))
    },
]

// MARK: - Dispatch

func handle(_ message: JSON) async {
    let id = message["id"]
    guard let method = message["method"] as? String else { return }
    let params = message["params"] as? JSON ?? [:]

    func reply(_ result: Any) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }
    func fail(_ code: Int, _ text: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
    }

    switch method {
    case "initialize":
        if let info = params["clientInfo"] as? JSON, let name = info["name"] as? String {
            let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            clientName = String(cleaned.prefix(40))
        }
        let requested = params["protocolVersion"] as? String ?? ""
        reply([
            "protocolVersion": supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "boringnotch", "version": "1.0.0"],
            "instructions": "The shelf is a tray in the user's MacBook notch holding files, text and links; they can drag anything on it straight into any app. It is the default place to hand over finished deliverables: when you produce a file for the user (a report, export, image, archive) and they have not said where it should go, save it anywhere sensible, then shelf_put it and tell them it is on the shelf, with its path. Not for files edited in place in a project, or when the user named a location. Also exposes clipboard history: entries marked is_protected are secrets the user hid; their content cannot be read, so don't try to work around it.",
        ])
    case "ping":
        reply([:] as JSON)
    case "tools/list":
        reply(["tools": tools.map { tool -> JSON in
            [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": tool.schema,
                "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": false, "openWorldHint": false],
            ]
        }])
    case "tools/call":
        guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
            return fail(-32602, "Unknown tool")
        }
        let args = params["arguments"] as? JSON ?? [:]
        do {
            reply(["content": try await tool.run(args), "isError": false])
        } catch let error as ToolError {
            reply(["content": textContent(error.message), "isError": true])
        } catch {
            reply(["content": textContent(error.localizedDescription), "isError": true])
        }
    default:
        if method.hasPrefix("notifications/") { return }
        fail(-32601, "Method not found: \(method)")
    }
}

// Requests are handled one at a time, in order. An agent rarely overlaps calls to one server,
// and strict ordering keeps a put followed by a list from racing.
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? JSON
    else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        await handle(message)
        done.signal()
    }
    done.wait()
}
