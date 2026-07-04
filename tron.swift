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

    // Build the 80-byte request. selector: 5 read, 6 write, 9 keyinfo.
    // Reads set size only; writes set size + type; keyinfo sets neither (0 == skip).
    private func request(key: UInt32, selector: UInt8, size: UInt32 = 0, type: UInt32 = 0) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 80)
        setU32(&buf, OFF_KEY, key)
        if size != 0 { setU32(&buf, OFF_DATASIZE, size) }
        if type != 0 { setU32(&buf, OFF_DATATYPE, type) }
        buf[OFF_DATA8] = selector
        return buf
    }

    var debug = false
    // A wedged AppleSMC (e.g. a stale daemon holding the connection) can block this call indefinitely.
    // We don't try to bound it here — a half-cancelled SMC call on a shared connection is worse than a
    // hang. Clear a wedge with `tron restart`, which restarts the daemon and frees the connection.
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
        var buf = request(key: key, selector: 9)
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return (getU32(out, OFF_DATASIZE), getU32(out, OFF_DATATYPE))
    }

    func writeByte(_ keyStr: String, _ value: UInt8) -> Bool {
        let key = fourCC(keyStr)
        guard let (size, type) = keyInfo(key), size >= 1 else { return false }
        var buf = request(key: key, selector: 6, size: size, type: type)
        // SMC numeric payloads are big-endian: low byte goes last within the key's size.
        buf[OFF_BYTES + Int(size) - 1] = value
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return false }
        return true
    }

    func readByte(_ keyStr: String) -> UInt8? {
        let key = fourCC(keyStr)
        guard let (size, _) = keyInfo(key), size >= 1 else { return nil }
        var buf = request(key: key, selector: 5, size: size)
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return out[OFF_BYTES]
    }

    // full payload read/write — used by findkey to snapshot and restore exactly.
    func readRaw(_ keyStr: String) -> [UInt8]? {
        let key = fourCC(keyStr)
        guard let (size, _) = keyInfo(key), size >= 1 else { return nil }
        var buf = request(key: key, selector: 5, size: size)
        guard let out = call(&buf), out[OFF_RESULT] == 0 else { return nil }
        return Array(out[OFF_BYTES ..< OFF_BYTES + Int(size)])
    }
    func writeRaw(_ keyStr: String, _ bytes: [UInt8]) -> Bool {
        let key = fourCC(keyStr)
        guard let (size, type) = keyInfo(key), Int(size) == bytes.count else { return false }
        var buf = request(key: key, selector: 6, size: size, type: type)
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

    // Stop/allow charging WITHOUT draining (adapter stays on). false if any SMC write failed.
    @discardableResult
    func setCharging(_ on: Bool) -> Bool {
        var ok = true
        for g in k.gate { ok = writeRaw(g, on ? k.allow : k.stop) && ok }
        return ok
    }
    // Adapter on = normal; off = Mac runs off battery (force discharge). false on SMC write failure.
    @discardableResult
    func setAdapter(_ on: Bool) -> Bool {
        writeByte(k.adapter, on ? 0 : 1)
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
    // Read before wait: ioreg's output overflows the 64KB pipe buffer, and a full
    // buffer blocks the child while waitUntilExit() blocks us → deadlock.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// raw pmset battery line → percent + AC. One pmset spawn feeds both per tick (default = fetch own).
func chargeLine() -> String { shell("/usr/bin/pmset", ["-g", "batt"]) }
func batteryPercent(_ l: String = chargeLine()) -> Int? {
    guard let r = l.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
    return Int(l[r].dropLast())
}
func onAC(_ l: String = chargeLine()) -> Bool { l.contains("AC Power") }

// Actual charging state comes from IORegistry, NOT pmset: pmset's text lags and prints
// "AC attached; not charging" while the cell is really taking several amps (IsCharging=Yes).
// Trusting pmset made the daemon fire a bogus "disable native Charge Limit" warning mid-charge.
func isCharging(_ io: String = batteryIO()) -> Bool { io.range(of: #""IsCharging" = Yes"#) != nil }

// Notifications come from a root launchd daemon, so they must be posted as the
// logged-in GUI user via `launchctl asuser <uid>` — root can't post banners directly.
func notify(_ msg: String) {
    let uid = shell("/usr/bin/stat", ["-f", "%u", "/dev/console"]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uid.isEmpty, uid != "0" else { return }   // no GUI user (login screen)
    _ = shell("/bin/launchctl", ["asuser", uid, "/usr/bin/osascript", "-e",
              "display notification \"\(msg)\" with title \"Tron\""])
}

// Timestamped line to stderr → launchd captures it to /var/log/tron.log (see install.sh).
func log(_ msg: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(t) \(msg)\n".data(using: .utf8)!)
}

// /etc/tron-limit holds 1–3 numbers "TARGET [UP] [DOWN]":
//   "TARGET"          → ±2% window: stop at TARGET+2, recharge at TARGET-2
//   "TARGET UP"       → ±UP window (lower mirrors upper): [TARGET-UP, TARGET+UP]
//   "TARGET UP DOWN"  → asymmetric: stop at TARGET+UP, recharge at TARGET-DOWN (e.g. 80 1 2 → 79..81)
// Offsets are magnitudes (sign ignored). Fractional values round to whole percent.
// Returns (high, low): stop charging at >= high, resume charging at <= low. Edit file, no restart.
func bandFrom(_ nums: [Int]) -> (high: Int, low: Int) {
    let target = nums.first ?? 80
    let up   = nums.count >= 2 ? abs(nums[1]) : 2
    let down = nums.count >= 3 ? abs(nums[2]) : up          // lower omitted → mirror upper
    let high = max(21, min(100, target + up))
    let low  = max(20, min(high - 1, target - down))
    return (high, low)
}
func readBand() -> (high: Int, low: Int) {
    let s = (try? String(contentsOfFile: "/etc/tron-limit", encoding: .utf8)) ?? ""
    // split on any whitespace; accept ints or floats, rounding to whole percent
    let nums = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { Double($0).map { Int($0.rounded()) } }
    return bandFrom(nums)
}

// `restart` must run BEFORE opening the SMC: its whole job is to clear a wedged AppleSMC
// connection, so it can't afford to block on SMC() itself. Restarts the launchd daemon (root).
if CommandLine.arguments.dropFirst().first == "restart" {
    let out = shell("/bin/launchctl", ["kickstart", "-k", "system/com.tron"])
    print("restarted com.tron daemon\(out.isEmpty ? "" : ": \(out)")")
    exit(0)
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
func batteryIO() -> String { shell("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]) }
func batteryTempC(_ io: String = batteryIO()) -> Int? {
    guard let r = io.range(of: #""Temperature" = (\d+)"#, options: .regularExpression),
          let centi = Int(io[r].drop(while: { !$0.isNumber })) else { return nil }
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
    let pctN = batteryPercent()
    let pct = pctN.map(String.init) ?? "?"
    let band = readBand()
    let drain = readMode() == "drain"
    let k = smc.k
    let io = batteryIO()
    let temp = batteryTempC(io)
    let hot = (temp ?? 0) >= readTempLimit()
    let tempS = temp.map { "\($0)°C" } ?? "?"
    let line = chargeLine(), ac = onAC(line)
    // what the daemon would do right now — the same decision the loop makes.
    // off AC the hardware can't charge no matter what the policy wants, so say so.
    let now: String = pctN.map { p in
        if !ac { return "on battery (unplugged)" }
        switch tempGuard(readOnce().map { decideOnce(pct: p, target: $0) } ?? decideBand(pct: p, band: band, drain: drain), hot: hot) {
        case .charge:   return "charging up"
        case .hold:     return p >= band.high ? "holding at cap" : "idle (in band)"
        case .drainOff: return "draining (off adapter)"
        case .reached:  return "at one-shot target"
        }
    } ?? "?"
    print("battery=\(pct)% → \(now)")
    print("policy: charge ≤\(band.low)%, stop at \(band.low + 1)%, cap \(band.high)% (mode=\(drain ? "drain" : "hold"))")
    print("temp=\(tempS)/\(readTempLimit())°C\(hot ? " HOT" : "")  ac=\(ac) charging=\(isCharging(io))  gate=\(k.gate.joined(separator: ",")) adapter=\(k.adapter)")
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
    assert(bandFrom([80, 1]) == (81, 79), "up 1, lower mirrors -> [79, 81]")
    assert(bandFrom([80, 1, 2]) == (81, 78), "asymmetric up 1 down 2 -> [78, 81]")
    assert(bandFrom([80, 0, 0]) == (80, 79), "zero offsets -> low forced just below high")
    assert(bandFrom([90, 80, 80]) == (100, 20), "high clamps to 100, low clamps to 20")
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

// macOS Sonoma+ has its own Settings → Battery → Charge Limit that writes the same SMC
// keys; when it's on, our writes get overridden and the gate won't open. Detect it
// behaviorally: open the gate on AC below 100%, and if pmset still won't charge, Apple wins.
if arg == "check" {
    guard onAC() else { print("plug in AC first"); exit(2) }
    if (batteryPercent() ?? 0) >= 100 { print("battery full — drain below 100% and retry"); exit(2) }
    smc.restore(); Thread.sleep(forTimeInterval: 5)
    if isCharging() { print("✅ tron controls charging — macOS native limit is off"); exit(0) }
    print("❌ gate opened but not charging — turn OFF System Settings → Battery → Charge Limit"); exit(1)
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
// Restore on exit via a fresh connection (a C closure can't capture the live `smc`, and a fresh
// one avoids reentering the main loop's in-flight SMC call). Retry the open so a transient
// failure can't leave the battery stuck draining with the daemon gone.
let onExit: @convention(c) (Int32) -> Void = { _ in
    for _ in 0..<5 { if let s = SMC() { s.restore(); break } }
    exit(0)
}
signal(SIGTERM, onExit)
signal(SIGINT, onExit)

// Watchdog: a tick that wedges in an SMC ioctl or a pmset/ioreg shell() must not strand the
// adapter off, draining a plugged-in Mac forever (observed: loop dead 6h, battery -27%). Each
// tick arms alarm(WATCHDOG); a hang trips SIGALRM → _exit, and launchd KeepAlive relaunches with
// a fresh SMC connection that re-decides. We do NOT try to restore here — the SMC may be the thing
// that's wedged, so a fresh process is the only reliable recovery (same idea as `tron restart`).
// ponytail: process-level watchdog; per-call timeouts on SMC/shell if the ~40s blip matters.
let WATCHDOG: UInt32 = 30   // normal tick is sub-second; sleep (20s) runs disarmed
let onWedge: @convention(c) (Int32) -> Void = { _ in
    let m: StaticString = "watchdog: tick timed out — exiting for launchd restart\n"
    write(2, m.utf8Start, m.utf8CodeUnitCount)   // async-signal-safe: static bytes, raw write
    _exit(1)
}
signal(SIGALRM, onWedge)

func apply(_ a: Action) {
    // Run BOTH writes unconditionally then combine — never let a failed adapter write
    // short-circuit away the safety-critical charge-gate write (would overcharge on .hold).
    let ok: Bool
    switch a {
    case .charge:   let p = smc.setAdapter(true);  let g = smc.setCharging(true);  ok = p && g
    case .hold:     let p = smc.setAdapter(true);  let g = smc.setCharging(false); ok = p && g
    case .drainOff: ok = smc.setAdapter(false)
    case .reached:
        try? FileManager.default.removeItem(atPath: "/etc/tron-once")
        let p = smc.setAdapter(true); let g = smc.setCharging(false); ok = p && g
    }
    if !ok { log("SMC write FAILED applying \(a)") }
}

var notifiedCap = false   // true while holding at cap, so we notify only on entry (reset by a charge cycle)
var wasHot = false
var warnedNative = false   // warn once if macOS native charge limit is overriding us

// Log every action change, plus a heartbeat every ~5min so /var/log/tron.log proves the daemon is alive.
var lastAction: Action? = nil
var tick = 0
func record(_ a: Action, pct: Int, temp: Int?, charging: Bool, ac: Bool) {
    tick += 1
    if a != lastAction {
        log("\(pct)% \(ac ? "AC" : "batt") \(temp.map { "\($0)°C " } ?? "")charging=\(charging) -> \(a)")
        lastAction = a
    } else if tick % 15 == 0 {
        log("heartbeat \(pct)% \(a) charging=\(charging)")
    }
}
log("daemon start — band=\(readBand()) mode=\(readMode()) gate=\(smc.k.gate.joined(separator: ","))")
while true {
    alarm(WATCHDOG)   // arm before any hardware I/O; disarmed just before each sleep below
    let band = readBand(), drain = readMode() == "drain"
    let io = batteryIO()                            // one ioreg spawn per tick → temp + charging
    let temp = batteryTempC(io)
    let hot = (temp ?? 0) >= readTempLimit()
    if hot && !wasHot { notify("too hot (\(temp ?? 0)°C) — charging paused") }
    wasHot = hot
    let line = chargeLine()                         // one pmset spawn per tick → percent + AC
    if let pct = batteryPercent(line) {
        let charging = isCharging(io), ac = onAC(line)     // shared by both branches below
        if let target = readOnce() {            // one-shot go-to-target overrides the band
            let a = tempGuard(decideOnce(pct: pct, target: target), hot: hot)
            apply(a)
            record(a, pct: pct, temp: temp, charging: charging, ac: ac)
            if a == .reached { notify("reached \(pct)%") }
            alarm(0); Thread.sleep(forTimeInterval: 20); continue
        }
        let a = tempGuard(decideBand(pct: pct, band: band, drain: drain), hot: hot)
        apply(a)
        record(a, pct: pct, temp: temp, charging: charging, ac: ac)
        // we commanded charge on AC below the floor but it didn't take → Apple's native limit owns the gate
        if a == .charge && ac && !charging && !hot {
            if !warnedNative {
                notify("not charging — disable System Settings → Battery → Charge Limit")
                log("commanded charge on AC but pmset shows not-charging — macOS native Charge Limit overriding?")
                warnedNative = true
            }
        } else { warnedNative = false }
        let atCap = a == .hold && pct >= band.high          // top-of-band hold (not inside-band)
        if atCap && !notifiedCap { notify("holding at \(pct)% (cap \(band.high)%)") }
        if atCap { notifiedCap = true } else if a == .charge { notifiedCap = false }
    }
    alarm(0); Thread.sleep(forTimeInterval: 20)
}
