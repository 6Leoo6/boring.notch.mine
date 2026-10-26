// Ingest test client: plays an Annex-B H.264 file over the hubcast encoder link the way the
// notch does (hello line, info frame, AVCC -> Annex-B through HubScreenLink, control lines
// back), so the link can be checked against a real towerbridge without a Mac. Built together
// with boringNotch/Hub/HubScreenLink.swift.
//
//   ingest-client PORT SESSION TOKEN FILE.h264 [FPS] [SECONDS]

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

let args = CommandLine.arguments
guard args.count >= 5, let port = UInt16(args[1]) else {
    print("usage: ingest-client PORT SESSION TOKEN FILE.h264 [FPS] [SECONDS]")
    exit(2)
}
let session = args[2], token = args[3]
let fps = args.count > 5 ? Int(args[5]) ?? 30 : 30
let seconds = args.count > 6 ? Double(args[6]) ?? 3 : 3
guard let file = FileManager.default.contents(atPath: args[4]) else { print("cannot read \(args[4])"); exit(2) }

// Annex-B -> NAL units.
func nalUnits(_ d: [UInt8]) -> [[UInt8]] {
    var starts: [(Int, Int)] = [] // (start code offset, payload offset)
    var i = 0
    while i + 3 <= d.count {
        if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
            let sc = (i > 0 && d[i - 1] == 0) ? i - 1 : i
            starts.append((sc, i + 3))
            i += 3
        } else { i += 1 }
    }
    return starts.enumerated().map { k, s in Array(d[s.1..<(k + 1 < starts.count ? starts[k + 1].0 : d.count)]) }
}

// NAL units -> access units in AVCC (no SPS/PPS: those come from the "format description").
struct AU { var avcc = Data(); var key = false }
var sps: [UInt8] = [], pps: [UInt8] = []
var aus: [AU] = []
var cur = AU(), pending = Data(), curHasVCL = false
for n in nalUnits([UInt8](file)) where !n.isEmpty {
    let type = n[0] & 0x1F
    var len = UInt32(n.count).bigEndian
    let unit = withUnsafeBytes(of: &len) { Data($0) } + Data(n)
    switch type {
    case 7: sps = n
    case 8: pps = n
    case 9: break
    case 1, 5:
        let firstSlice = n.count > 1 && n[1] & 0x80 != 0
        if firstSlice && curHasVCL { aus.append(cur); cur = AU(); curHasVCL = false }
        cur.avcc.append(pending); pending = Data()
        cur.avcc.append(unit)
        cur.key = cur.key || type == 5
        curHasVCL = true
    default: pending.append(unit)
    }
}
if curHasVCL { aus.append(cur) }
guard !aus.isEmpty, !sps.isEmpty, !pps.isEmpty else { print("no access units / parameter sets"); exit(2) }

// Connect.
let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard rc == 0 else { print("connect failed: \(errno)"); exit(1) }

func write(_ d: Data) -> Bool {
    d.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

let lock = NSLock()
var forceKey = false, stopped = false
var controls: [String] = []
Thread.detachNewThread {
    var reader = HubScreenLink.LineReader()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        for c in reader.append(Data(buf[0..<n])) {
            lock.lock()
            controls.append("\(c)")
            if c == .keyframe { forceKey = true }
            if c == .stop { stopped = true }
            lock.unlock()
        }
    }
    lock.lock(); stopped = true; lock.unlock()
}

_ = write(HubScreenLink.helloLine(session: session, token: token))
_ = write(HubScreenLink.frame(.info, payload: HubScreenLink.infoPayload(profile: "high", width: 0, height: 0, fps: fps))!)

let start = Date()
var i = 0, sent = 0, keys = 0
while Date().timeIntervalSince(start) < seconds {
    lock.lock(); let stop = stopped; var key = forceKey; forceKey = false; lock.unlock()
    if stop { break }
    // "Force a keyframe": skip ahead to the next IDR in the file.
    if key { while !aus[i % aus.count].key { i += 1 } }
    let au = aus[i % aus.count]
    key = au.key
    let annexB = HubScreenLink.annexB(avcc: au.avcc, lengthSize: 4, parameterSets: key ? [Data(sps), Data(pps)] : [])!
    let pts = UInt64(Date().timeIntervalSince(start) * 1_000_000)
    if !write(HubScreenLink.frame(.video, keyframe: key, ptsMicros: pts, payload: annexB)!) { break }
    sent += 1
    if key { keys += 1 }
    i += 1
    usleep(useconds_t(1_000_000 / fps))
}
lock.lock(); let wasStopped = stopped; lock.unlock()
if !wasStopped { _ = write(HubScreenLink.frame(.end)!) }
lock.lock()
print("ingest-client: sent \(sent) frames (\(keys) keyframes) from \(aus.count) access units; controls: \(controls.joined(separator: ", "))")
lock.unlock()
close(fd)
