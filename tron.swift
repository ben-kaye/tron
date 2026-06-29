import Foundation
import IOKit

// Tron: cap battery charge on Apple Silicon by toggling the SMC charging keys.
// Mechanism: write 0x02 to CH0B/CH0C to inhibit charging, 0x00 to allow.
// ponytail: SMC param struct is built as a raw 80-byte buffer at fixed offsets
//           instead of mirroring the C struct in Swift — same wire format, no padding fights.

final class SMC {
    private var conn: io_connect_t = 0

    // SMCParamStruct offsets (total 80 bytes)
    private let OFF_KEY = 0          // UInt32 fourcc
    private let OFF_DATASIZE = 28    // keyInfo.dataSize
    private let OFF_DATATYPE = 32    // keyInfo.dataType
    private let OFF_RESULT = 40      // 0 == success
    private let OFF_DATA8 = 42       // selector: 5 read, 6 write, 9 keyinfo
    private let OFF_BYTES = 48       // payload

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
        guard r == kIOReturnSuccess else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8 { v = (v << 8) | UInt32(b) }
        return v
    }
    // struct fields are native UInt32 — store/read little-endian (arm64) so the key isn't byte-reversed.
    private func setU32(_ buf: inout [UInt8], _ off: Int, _ val: UInt32) {
        buf[off]   = UInt8(val & 0xff)
        buf[off+1] = UInt8((val >> 8) & 0xff)
        buf[off+2] = UInt8((val >> 16) & 0xff)
        buf[off+3] = UInt8((val >> 24) & 0xff)
    }
    private func getU32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off])|(UInt32(buf[off+1]) << 8)|(UInt32(buf[off+2]) << 16)|(UInt32(buf[off+3]) << 24)
    }

    var debug = false
    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr.baseAddress, 80, outPtr.baseAddress, &outSize)
            }
        }
        if debug {
            let inHex = input.map { String(format:"%02x", $0) }.joined()
            let outHex = output.map { String(format:"%02x", $0) }.joined()
            FileHandle.standardError.write("  kr=\(String(format:"0x%x", r)) result=\(output[OFF_RESULT])\n   in =\(inHex)\n   out=\(outHex)\n".data(using:.utf8)!)
        }
        return r == kIOReturnSuccess ? output : nil
    }

    // returns (dataSize, dataType)
    private func keyInfo(_ key: UInt32) -> (UInt32, UInt32)? {
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        buf[OFF_DATA8] = 9
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return (getU32(out, OFF_DATASIZE), getU32(out, OFF_DATATYPE))
    }

    func writeByte(_ keyStr: String, _ value: UInt8) -> Bool {
        let key = fourCC(keyStr)
        guard let (size, type) = keyInfo(key), size >= 1 else { return false }
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        setU32(&buf, OFF_DATASIZE, size)
        setU32(&buf, OFF_DATATYPE, type)
        buf[OFF_DATA8] = 6
        // SMC numeric payloads are big-endian: low byte goes last within the key's size.
        buf[OFF_BYTES + Int(size) - 1] = value
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return false }
        return true
    }

    func readByte(_ keyStr: String) -> UInt8? {
        let key = fourCC(keyStr)
        guard let (size, _) = keyInfo(key), size >= 1 else { return nil }
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        setU32(&buf, OFF_DATASIZE, size)
        buf[OFF_DATA8] = 5
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return out[OFF_BYTES]
    }

    // full payload read/write — used by findkey to snapshot and restore exactly.
    func readRaw(_ keyStr: String) -> [UInt8]? {
        let key = fourCC(keyStr)
        guard let (size, _) = keyInfo(key), size >= 1 else { return nil }
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        setU32(&buf, OFF_DATASIZE, size)
        buf[OFF_DATA8] = 5
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return Array(out[OFF_BYTES ..< OFF_BYTES + Int(size)])
    }
    func writeRaw(_ keyStr: String, _ bytes: [UInt8]) -> Bool {
        let key = fourCC(keyStr)
        guard let (size, type) = keyInfo(key), Int(size) == bytes.count else { return false }
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        setU32(&buf, OFF_DATASIZE, size)
        setU32(&buf, OFF_DATATYPE, type)
        buf[OFF_DATA8] = 6
        for (i, b) in bytes.enumerated() { buf[OFF_BYTES + i] = b }
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return false }
        return true
    }

    // diagnostic: does this key exist, what size, and its first byte
    func probe(_ keyStr: String) -> (exists: Bool, size: UInt32, first: UInt8?) {
        let key = fourCC(keyStr)
        guard let (size, _) = keyInfo(key) else { return (false, 0, nil) }
        return (true, size, readByte(keyStr))
    }

    // Per-chip SMC keys (verified against charlie0129/batt source):
    //   M1–M3: charge gate CH0B/CH0C (0x02 stop / 0x00 allow); adapter CH0I (0x01 cut / 0x00 on)
    //   M4+  : charge gate CHTE (4-byte 01000000 stop / 0 allow); adapter CHIE (0x01 cut / 0x00 on)
    // Charge gate = stop charging but keep adapter powering the Mac (hold/float, no drain).
    // Adapter cut = run the Mac off battery (force discharge).
    struct Keys { let gate: [String]; let stop: [UInt8]; let allow: [UInt8]; let adapter: String }
    private func keys() -> Keys {
        if probe("CHTE").exists {       // M4 / macOS Sequoia+
            return Keys(gate: ["CHTE"], stop: [0x01,0,0,0], allow: [0,0,0,0], adapter: "CHIE")
        }
        return Keys(gate: ["CH0B","CH0C"], stop: [0x02], allow: [0x00], adapter: "CH0I")
    }
    lazy var k: Keys = keys()   // chip doesn't change at runtime — probe once

    // Stop/allow charging WITHOUT draining (adapter stays on).
    func setCharging(_ on: Bool) {
        for g in k.gate { _ = writeRaw(g, on ? k.allow : k.stop) }
    }
    // Adapter on = normal; off = Mac runs off battery (force discharge).
    func setAdapter(_ on: Bool) {
        _ = writeByte(k.adapter, on ? 0 : 1)
    }
    // Safe resting state: charging allowed + adapter on. Used on exit so nothing is ever stuck.
    func restore() { setAdapter(true); setCharging(true) }
}

// run a command, capture stdout. Empty string on failure.
func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// raw pmset battery line, plus whether it currently reports actively charging.
func chargeLine() -> String { shell("/usr/bin/pmset", ["-g", "batt"]) }
func batteryPercent() -> Int? {
    let l = chargeLine()
    guard let r = l.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
    return Int(l[r].dropLast())
}
func isCharging() -> Bool {
    let l = chargeLine().lowercased()
    return l.contains("; charging") && !l.contains("not charging")
}

// Notifications come from a root launchd daemon, so they must be posted as the
// logged-in GUI user via `launchctl asuser <uid>` — root can't post banners directly.
func notify(_ msg: String) {
    let uid = shell("/usr/bin/stat", ["-f", "%u", "/dev/console"]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uid.isEmpty, uid != "0" else { return }   // no GUI user (login screen)
    _ = shell("/bin/launchctl", ["asuser", uid, "/usr/bin/osascript", "-e",
              "display notification \"\(msg)\" with title \"Tron\""])
}

// /etc/tron-limit is a single "TARGET": ±2% hysteresis band [TARGET-2, TARGET+2].
// Charge to TARGET+2, hold, recharge once below TARGET-2. Edit file, no restart.
// Returns (high, low): stop charging at >= high, resume charging at <= low.
func bandFrom(_ nums: [Int]) -> (high: Int, low: Int) {
    let target = nums.first ?? 80
    let high = max(21, min(100, target + 2))
    let low = max(20, min(high - 1, target - 2))
    return (high, low)
}
func readBand() -> (high: Int, low: Int) {
    let s = (try? String(contentsOfFile: "/etc/tron-limit", encoding: .utf8)) ?? ""
    return bandFrom(s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").compactMap { Int($0) })
}

guard let smc = SMC() else {
    FileHandle.standardError.write("cannot open SMC — run as root\n".data(using: .utf8)!)
    exit(1)
}

// mode: "hold" (cap, float at limit) or "drain" (actively discharge to reach limit faster).
func readMode() -> String {
    if let s = try? String(contentsOfFile: "/etc/tron-mode", encoding: .utf8) {
        let m = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if m == "drain" { return "drain" }
    }
    return "hold"
}

// One-shot go-to-target. /etc/tron-once holds a single percent; the daemon charges up or
// drains down to it, then deletes the file and reverts to the band. Powers `full`/`drain-to`.
func readOnce() -> Int? {
    guard let s = try? String(contentsOfFile: "/etc/tron-once", encoding: .utf8),
          let t = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return max(21, min(100, t))
}

// What the daemon should do this tick. Pure decision (no hardware/IO) so it's unit-testable;
// apply() below turns an Action into the actual SMC writes.
enum Action: Equatable {
    case charge        // adapter on, charging on
    case hold          // adapter on, charging off — float at the limit
    case drainOff      // adapter off — run off battery
    case reached       // one-shot target hit: rest + clear the once-file
}
func decideOnce(pct: Int, target: Int) -> Action {
    if pct < target { return .charge }
    if pct > target { return .drainOff }
    return .reached
}
func decideBand(pct: Int, band: (high: Int, low: Int), drain: Bool) -> Action {
    if pct > band.high && drain { return .drainOff }   // above band: discharge to fall fast
    if pct >= band.high { return .hold }               // top of band: stop, adapter floats it
    if pct <= band.low { return .charge }              // bottom of band: recharge
    return .hold                                       // inside band: hold
}
// Battery cell temperature in whole °C, from the battery's own sensor via IORegistry
// ("Temperature" is centi-°C). Authoritative — this is what Coconut/Apple report, ~3°C
// cooler than the SMC board sensors. nil if unreadable → heat guard disables itself.
func batteryTempC() -> Int? {
    let out = shell("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"])
    guard let r = out.range(of: #""Temperature" = (\d+)"#, options: .regularExpression),
          let centi = Int(out[r].drop(while: { !$0.isNumber })) else { return nil }
    return centi / 100
}

// Heat guard: never charge while the battery is hot. Only blocks charging — holding and
// draining are fine (draining even helps it cool). /etc/tron-temp sets the °C ceiling (default 35).
func tempGuard(_ a: Action, hot: Bool) -> Action {
    (hot && a == .charge) ? .hold : a
}
func readTempLimit() -> Int {
    let s = (try? String(contentsOfFile: "/etc/tron-temp", encoding: .utf8)) ?? ""
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 35
}

let arg = CommandLine.arguments.dropFirst().first

if arg == "status" {
    let pct = batteryPercent().map(String.init) ?? "?"
    let band = readBand()
    let kind = readMode() == "drain" ? "drain" : "hold"
    let k = smc.k
    let temp = batteryTempC().map { "\($0)°C" } ?? "?"
    print("battery=\(pct)% band=\(band.low)-\(band.high) mode=\(kind) temp=\(temp)/\(readTempLimit())°C charging=\(isCharging()) gate=\(k.gate.joined(separator: ",")) adapter=\(k.adapter)")
    exit(0)
}

if arg == "probe" {
    for k in ["#KEY", "CH0B", "CH0C", "CH0I", "CH0J", "CHTE", "CHIE", "CHBI", "ACLM", "B0AC"] {
        let p = smc.probe(k)
        print("\(k): exists=\(p.exists) size=\(p.size) byte0=\(p.first.map { String($0) } ?? "-")")
    }
    exit(0)
}

if arg == "test" {
    // Confirm the charge gate works: toggle on→off→off→on, 10s each. Needs AC, battery <100%.
    // Run with the daemon stopped (it re-asserts every 20s and would fight this).
    func s() -> String { isCharging() ? "charging" : "not-charging" }
    print("gate=\(smc.k.gate.joined(separator: ","))")
    smc.setCharging(true);  Thread.sleep(forTimeInterval: 10); let a = s()
    smc.setCharging(false); Thread.sleep(forTimeInterval: 10); let b = s()
    smc.setCharging(false); Thread.sleep(forTimeInterval: 10); let b2 = s()
    smc.setCharging(true);  Thread.sleep(forTimeInterval: 10); let c = s()
    print("allow=\(a)  stop=\(b)  stop-still=\(b2)  allow=\(c)")
    let ok = a == "charging" && b == "not-charging" && b2 == "not-charging" && c == "charging"
    print(ok ? "✅ gate WORKS" : "❌ inconclusive (battery too full to see 'charging'? drain to ~70% and retry)")
    exit(ok ? 0 : 1)
}

if arg == "selftest" {   // band math — no hardware needed
    assert(bandFrom([80]) == (82, 78), "target 80 -> charge to 82, resume below 78")
    assert(bandFrom([]) == (82, 78), "empty -> default 80±2")
    assert(bandFrom([100]) == (100, 98), "high clamps to 100")
    assert(bandFrom([50]).low < bandFrom([50]).high, "low always below high")
    assert(decideBand(pct: 90, band: (82, 78), drain: false) == .hold, "above cap, no drain -> hold")
    assert(decideBand(pct: 90, band: (82, 78), drain: true) == .drainOff, "above cap + drain -> discharge")
    assert(decideBand(pct: 70, band: (82, 78), drain: false) == .charge, "below floor -> charge")
    assert(decideBand(pct: 80, band: (82, 78), drain: false) == .hold, "inside band -> hold")
    assert(decideOnce(pct: 50, target: 80) == .charge, "one-shot below target -> charge")
    assert(decideOnce(pct: 90, target: 80) == .drainOff, "one-shot above target -> drain")
    assert(decideOnce(pct: 80, target: 80) == .reached, "one-shot at target -> reached")
    assert(tempGuard(.charge, hot: true) == .hold, "hot blocks charging")
    assert(tempGuard(.charge, hot: false) == .charge, "cool allows charging")
    assert(tempGuard(.drainOff, hot: true) == .drainOff, "hot still drains (helps cool)")
    print("selftest OK"); exit(0)
}

if arg == "on"    { smc.restore(); print("charging enabled, adapter on"); exit(0) }
if arg == "drain" { smc.setAdapter(false); print("force-discharging (adapter off)"); exit(0) }

// one-shot go-to-target: write /etc/tron-once, daemon drives there then reverts to band.
func setOnce(_ pct: Int) {
    let t = max(21, min(100, pct))
    try? "\(t)".write(toFile: "/etc/tron-once", atomically: true, encoding: .utf8)
    print("going to \(t)%, then reverting to band")
}
if arg == "full"     { setOnce(100); exit(0) }
if arg == "drain-to" {
    guard let t = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) else {
        FileHandle.standardError.write("usage: tron drain-to <pct>\n".data(using: .utf8)!); exit(1)
    }
    setOnce(t); exit(0)
}

// daemon. On any exit, restore the safe state so the battery is never left charging or draining.
let onExit: @convention(c) (Int32) -> Void = { _ in SMC()?.restore(); exit(0) }
signal(SIGTERM, onExit)
signal(SIGINT, onExit)

func apply(_ a: Action) {
    switch a {
    case .charge:   smc.setAdapter(true); smc.setCharging(true)
    case .hold:     smc.setAdapter(true); smc.setCharging(false)
    case .drainOff: smc.setAdapter(false)
    case .reached:
        try? FileManager.default.removeItem(atPath: "/etc/tron-once")
        smc.setAdapter(true); smc.setCharging(false)
    }
}

var lastState = ""   // debounce: only notify when the state label changes
var wasHot = false
while true {
    let band = readBand(), drain = readMode() == "drain"
    let temp = batteryTempC()
    let hot = (temp ?? 0) >= readTempLimit()
    if hot && !wasHot { notify("too hot (\(temp ?? 0)°C) — charging paused") }
    wasHot = hot
    if let pct = batteryPercent() {
        if let target = readOnce() {            // one-shot go-to-target overrides the band
            let a = tempGuard(decideOnce(pct: pct, target: target), hot: hot)
            apply(a)
            if a == .reached { notify("reached \(pct)%") }
            Thread.sleep(forTimeInterval: 20); continue
        }
        let a = tempGuard(decideBand(pct: pct, band: band, drain: drain), hot: hot)
        apply(a)
        let atCap = a == .hold && pct >= band.high          // top-of-band hold (not inside-band)
        if atCap && lastState != "hold" { notify("holding at \(pct)% (cap \(band.high)%)") }
        if atCap { lastState = "hold" } else if a == .charge { lastState = "charge" }
    }
    Thread.sleep(forTimeInterval: 20)
}
