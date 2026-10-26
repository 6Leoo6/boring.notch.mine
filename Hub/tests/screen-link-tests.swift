// Tests for boringNotch/Hub/HubScreenLink.swift (hubcast encoder link). Foundation only:
// run with Hub/tests/screen-link-tests.sh (macOS: swiftc; Linux: the swift Docker image).

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func bytes(_ d: Data?) -> [UInt8] { d.map { [UInt8]($0) } ?? [] }
let sc: [UInt8] = [0, 0, 0, 1]
func annexB(_ units: [UInt8]...) -> [UInt8] { units.flatMap { sc + $0 } }

// Header: "HS", type, flags, big-endian length and microseconds.
do {
    let h = HubScreenLink.header(type: .video, keyframe: true, length: 0x0102_0304, ptsMicros: 0x0A0B_0C0D_0E0F_1011)
    check(bytes(h) == [0x48, 0x53, 1, 1, 1, 2, 3, 4, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11], "header bytes \(bytes(h))")
    let f = HubScreenLink.frame(.end)
    check(bytes(f) == [0x48, 0x53, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "end frame")
    let big = HubScreenLink.frame(.video, payload: Data(count: HubScreenLink.maxPayload + 1))
    check(big == nil, "payload over 16 MiB refused")
    let info = HubScreenLink.frame(.info, payload: HubScreenLink.infoPayload(profile: "high", width: 2560, height: 1664, fps: 60))
    let json = info.flatMap { try? JSONSerialization.jsonObject(with: $0.subdata(in: 16..<$0.count)) as? [String: Any] }
    check(json?["codec"] as? String == "h264" && json?["width"] as? Int == 2560 && json?["fps"] as? Int == 60, "info payload")
    check(info.map { Int($0[7]) + Int($0[6]) << 8 } == (info?.count ?? 0) - 16, "info length")
}

// Hello line.
do {
    let line = HubScreenLink.helloLine(session: "s1", token: "t\"x")
    check(line.last == 0x0A && line.filter { $0 == 0x0A }.count == 1, "hello is one line")
    let obj = try? JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String]
    check(obj == ["session": "s1", "token": "t\"x"], "hello fields \(String(describing: obj))")
}

// AVCC -> Annex-B.
do {
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
    let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00]
    let sei: [UInt8] = [0x06, 0x05, 0x01]
    var avcc = Data([0, 0, 0, UInt8(sei.count)] + sei)
    avcc.append(contentsOf: [0, 0, 0, UInt8(idr.count)] + idr)
    let key = HubScreenLink.annexB(avcc: avcc, lengthSize: 4, parameterSets: [Data(sps), Data(pps)])
    check(bytes(key) == annexB(sps, pps, sei, idr), "keyframe gets SPS/PPS first: \(bytes(key))")

    let delta = HubScreenLink.annexB(avcc: Data([0, 0, 0, 3, 0x41, 0x9A, 0x02]), lengthSize: 4)
    check(bytes(delta) == [0, 0, 0, 1, 0x41, 0x9A, 0x02], "delta frame")

    var withPS = Data([0, 0, 0, 4] + sps)
    withPS.append(contentsOf: [0, 0, 0, 4] + pps)
    withPS.append(contentsOf: [0, 0, 0, 4] + idr)
    let noDup = HubScreenLink.annexB(avcc: withPS, lengthSize: 4, parameterSets: [Data(sps), Data(pps)])
    check(bytes(noDup) == annexB(sps, pps, idr), "parameter sets not doubled")

    let two = HubScreenLink.annexB(avcc: Data([0, 3, 0x41, 1, 2, 0, 2, 0x41, 3]), lengthSize: 2)
    check(bytes(two) == [0, 0, 0, 1, 0x41, 1, 2, 0, 0, 0, 1, 0x41, 3], "2-byte lengths")

    check(HubScreenLink.annexB(avcc: Data([0, 0, 0, 9, 0x41, 1]), lengthSize: 4) == nil, "truncated unit refused")
    check(HubScreenLink.annexB(avcc: Data([0, 0, 0]), lengthSize: 4) == nil, "short length refused")
    check(HubScreenLink.annexB(avcc: Data(), lengthSize: 4) == nil, "empty refused")
    check(HubScreenLink.annexB(avcc: Data([0, 0, 0, 0]), lengthSize: 4) == nil, "zero-length unit refused")
    check(HubScreenLink.annexB(avcc: Data([0, 1, 0x41]), lengthSize: 5) == nil, "bad length size")

    // A slice of a bigger Data (non-zero startIndex) converts the same.
    let padded = Data([9, 9]) + Data([0, 0, 0, 2, 0x41, 7])
    check(bytes(HubScreenLink.annexB(avcc: padded[2...], lengthSize: 4)) == [0, 0, 0, 1, 0x41, 7], "sliced input")
}

// Control lines.
do {
    var r = HubScreenLink.LineReader()
    var got = r.append(Data(#"{"op":"keyframe"}"#.utf8))
    check(got.isEmpty, "no line yet")
    got = r.append(Data("\n{\"op\":\"bitrate\",\"kbps\":20000}\n{\"op\":\"size\",\"width\":2560,\"height\":1440}\n{\"op\":\"future\"}\nnot json\n{\"op\":\"st".utf8))
    check(got == [.keyframe, .bitrate(kbps: 20000), .size(width: 2560, height: 1440)], "lines \(got)")
    got = r.append(Data("op\"}\n".utf8))
    check(got == [.stop], "split line \(got)")
    check(HubScreenLink.parseControl(Data(#"{"op":"bitrate","kbps":0}"#.utf8)) == nil, "zero bitrate ignored")
    check(HubScreenLink.parseControl(Data(#"{"op":"size","width":10}"#.utf8)) == nil, "size needs both")
    // An endless line is dropped, and the reader recovers at the next newline.
    _ = r.append(Data(repeating: 0x61, count: HubScreenLink.maxControlLine + 10))
    got = r.append(Data("aaaa\n{\"op\":\"keyframe\"}\n".utf8))
    check(got == [.keyframe], "recovers after an overlong line \(got)")
}

// Sizes and ids.
do {
    func fit(_ w: Int, _ h: Int, _ bw: Int, _ bh: Int) -> [Int] { let r = HubScreenLink.fit(width: w, height: h, boxWidth: bw, boxHeight: bh); return [r.width, r.height] }
    check(fit(2560, 1664, 0, 0) == [2560, 1664], "native")
    check(fit(2560, 1664, 3840, 2160) == [2560, 1664], "never upscaled")
    check(fit(2560, 1664, 1920, 1080) == [1660, 1080], "fit height \(fit(2560, 1664, 1920, 1080))")
    check(fit(1001, 501, 0, 0) == [1000, 500], "even")
    check(fit(3024, 1964, 1512, 1964) == [1512, 982], "fit width")
    check(HubScreenLink.SourceID("display:1") == .display(1), "display id")
    check(HubScreenLink.SourceID("window:4242")?.string == "window:4242", "window id")
    check(HubScreenLink.SourceID("monitor:HDMI-A-2") == nil && HubScreenLink.SourceID("window:") == nil && HubScreenLink.SourceID("window:-1") == nil, "bad ids")
    check(HubScreenLink.defaultKbps(width: 2560, height: 1440, fps: 60) == 22118, "default kbps")
    check(HubScreenLink.defaultKbps(width: 320, height: 200, fps: 30) == 2000, "min kbps")
}

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("screen link tests: ok")
