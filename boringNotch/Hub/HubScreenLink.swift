//
//  HubScreenLink.swift
//  boringNotch
//
//  The encoder link of hubcast (hub docs/SCREEN.md, D-153): how this app hands H.264 to the
//  embedded hub helper, which does the WebRTC. Foundation only, so the framing and the
//  AVCC -> Annex-B conversion are tested on their own (Hub/tests/screen-link-tests.sh).
//
//  One loopback TCP connection per capture: a hello line `{"session","token"}\n`, then frames
//  with a 16-byte big-endian header ("HS", type, flags, payload length, presentation time in
//  microseconds); the helper sends JSON control lines back on the same socket.
//

import Foundation

enum HubScreenLink {
    enum FrameType: UInt8 {
        case video = 1
        case info = 2
        case error = 3
        case end = 4
    }

    static let headerSize = 16
    static let maxPayload = 16 << 20
    /// A control line longer than this is garbage; the reader drops it.
    static let maxControlLine = 64 * 1024

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    // MARK: - Frames

    static func header(type: FrameType, keyframe: Bool, length: Int, ptsMicros: UInt64) -> Data {
        var h = Data(capacity: headerSize)
        h.append(contentsOf: [UInt8(ascii: "H"), UInt8(ascii: "S"), type.rawValue, keyframe ? 1 : 0])
        withUnsafeBytes(of: UInt32(clamping: length).bigEndian) { h.append(contentsOf: $0) }
        withUnsafeBytes(of: ptsMicros.bigEndian) { h.append(contentsOf: $0) }
        return h
    }

    /// Header plus payload, or nil when the payload is over the link's limit.
    static func frame(_ type: FrameType, keyframe: Bool = false, ptsMicros: UInt64 = 0, payload: Data = Data()) -> Data? {
        guard payload.count <= maxPayload else { return nil }
        var out = header(type: type, keyframe: keyframe, length: payload.count, ptsMicros: ptsMicros)
        out.append(payload)
        return out
    }

    static func helloLine(session: String, token: String) -> Data {
        jsonLine(["session": session, "token": token])
    }

    static func infoPayload(profile: String, width: Int, height: Int, fps: Int) -> Data {
        json(["codec": "h264", "profile": profile, "width": width, "height": height, "fps": fps])
    }

    static func errorPayload(_ message: String) -> Data {
        json(["error": message])
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func jsonLine(_ object: [String: Any]) -> Data {
        var d = json(object)
        d.append(0x0A)
        return d
    }

    // MARK: - AVCC -> Annex-B

    /// VideoToolbox hands out AVCC: each NAL unit behind a big-endian length of `lengthSize`
    /// bytes. The link wants Annex-B (start codes), with SPS and PPS in front of every IDR, so
    /// a keyframe gets the format description's parameter sets prepended (unless the sample
    /// already carries them). Nil when the lengths don't add up.
    static func annexB(avcc: Data, lengthSize: Int, parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(lengthSize) else { return nil }
        var units: [Range<Int>] = []
        var hasParameterSets = false
        var i = avcc.startIndex
        while i < avcc.endIndex {
            guard avcc.endIndex - i >= lengthSize else { return nil }
            var n = 0
            for k in 0..<lengthSize { n = n << 8 | Int(avcc[i + k]) }
            i += lengthSize
            guard n > 0, avcc.endIndex - i >= n else { return nil }
            let type = avcc[i] & 0x1F
            if type == 7 || type == 8 { hasParameterSets = true }
            units.append(i..<(i + n))
            i += n
        }
        guard !units.isEmpty else { return nil }

        var out = Data(capacity: avcc.count + units.count * 4 + parameterSets.reduce(0) { $0 + $1.count + 4 })
        if !hasParameterSets {
            for ps in parameterSets where !ps.isEmpty {
                out.append(contentsOf: startCode)
                out.append(ps)
            }
        }
        for unit in units {
            out.append(contentsOf: startCode)
            out.append(avcc[unit])
        }
        return out
    }

    // MARK: - Control lines

    enum Control: Equatable {
        case keyframe
        case bitrate(kbps: Int)
        case size(width: Int, height: Int)
        case stop
    }

    /// One control line, or nil for an unknown op or a malformed line (both are ignored).
    static func parseControl(_ line: Data) -> Control? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let op = object["op"] as? String
        else { return nil }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        switch op {
        case "keyframe": return .keyframe
        case "stop": return .stop
        case "bitrate":
            guard let kbps = int("kbps"), kbps > 0 else { return nil }
            return .bitrate(kbps: kbps)
        case "size":
            guard let w = int("width"), let h = int("height"), w > 0, h > 0 else { return nil }
            return .size(width: w, height: h)
        default: return nil
        }
    }

    /// Splits the helper's byte stream into control lines.
    struct LineReader {
        private var buffer = Data()
        private var discarding = false

        mutating func append(_ data: Data) -> [Control] {
            buffer.append(data)
            var out: [Control] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                if discarding {
                    discarding = false
                    continue
                }
                if let c = HubScreenLink.parseControl(Data(line)) { out.append(c) }
            }
            if buffer.count > HubScreenLink.maxControlLine {
                buffer.removeAll()
                discarding = true
            }
            return out
        }
    }

    // MARK: - Sizes and sources

    /// The source fitted into the box, aspect kept, never upscaled, even sides (the same rule
    /// as the helper's fitBox). A zero box means the source's own size.
    static func fit(width: Int, height: Int, boxWidth: Int, boxHeight: Int) -> (width: Int, height: Int) {
        func even(_ v: Int) -> Int { max(2, v & ~1) }
        guard width > 0, height > 0 else { return (even(boxWidth), even(boxHeight)) }
        if boxWidth <= 0 || boxHeight <= 0 || (width <= boxWidth && height <= boxHeight) {
            return (even(width), even(height))
        }
        let s = min(Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
        return (even(Int(Double(width) * s)), even(Int(Double(height) * s)))
    }

    enum SourceID: Equatable {
        case display(UInt32)
        case window(UInt32)

        init?(_ raw: String) {
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let n = UInt32(parts[1]) else { return nil }
            switch parts[0] {
            case "display": self = .display(n)
            case "window": self = .window(n)
            default: return nil
            }
        }

        var string: String {
            switch self {
            case .display(let id): return "display:\(id)"
            case .window(let id): return "window:\(id)"
            }
        }
    }

    /// Start bitrate when the helper sent none: ~0.1 bit per pixel per frame, 2..100 Mbit/s.
    static func defaultKbps(width: Int, height: Int, fps: Int) -> Int {
        let k = Int(Double(width) * Double(height) * Double(fps) * 0.1 / 1000)
        return min(max(k, 2000), 100_000)
    }
}
