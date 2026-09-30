// Focus Timer - a floating desktop timer drawn as an hourglass, lava lamp, water clock, candle, snow globe or zen garden,
// with live sound. Everything is drawn and synthesised in code.
// Build: ./build.sh   (produces "Focus Timer.app" and installs it to ~/Applications)

import AppKit
import AVFoundation
import QuartzCore
import ServiceManagement

// MARK: - Layout (unscaled points; the view scales everything)

enum L {
    static let width: CGFloat = 224          // window: the object on the left, the time badge on the right
    static let ow: CGFloat = 176             // the object's own area
    static let bx: CGFloat = 194, by: CGFloat = 150, badgeR: CGFloat = 26
    static let margin: CGFloat = 14
    static let capH: CGFloat = 22
    static let inset: CGFloat = 4
    static let chamberH: CGFloat = 125
    static let neckH: CGFloat = 10
    static let gridH = chamberH * 2 + neckH
    static let height = margin * 2 + capH * 2 + inset * 2 + gridH
    static let glassTop = margin + capH + inset
    static let neckTop = glassTop + chamberH
    static let neckBottom = neckTop + neckH
    static let glassBottom = neckBottom + chamberH
    static let cx = ow / 2
    static let cy = height / 2
    static let capInset: CGFloat = 8
    static let maxHalf: CGFloat = 61
    static let neckHalf: CGFloat = 2.6
}

// MARK: - Random

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func signed() -> CGFloat { unit() * 2 - 1 }
}

// MARK: - Glass shape (interior half-width as a function of height)

enum Glass {
    static let step: CGFloat = 0.25
    static let y0 = L.glassTop - L.inset
    static let y1 = L.glassBottom + L.inset
    static let table: [CGFloat] = build()

    static func profile(_ u: CGFloat) -> CGFloat {
        let a = min(1, u / 0.78)
        var s = pow(sin(a * .pi / 2), 1.25)
        if u > 0.78 { let t = (u - 0.78) / 0.22; s *= 1 - 0.2 * t * t }
        return s
    }

    static func index(_ y: CGFloat) -> Int { Int(((y - y0) / step).rounded()) }

    static func build() -> [CGFloat] {
        let n = index(y1) + 1
        var t = [CGFloat](repeating: 0, count: n)
        let iNeck = index(L.neckTop)
        var prev = L.neckHalf
        var i = iNeck
        while i >= 0 {
            let y = y0 + CGFloat(i) * step
            let u = min(1, max(0, (L.neckTop - y) / L.chamberH))
            var v = L.neckHalf + (L.maxHalf - L.neckHalf) * profile(u)
            // Funnel walls stay steeper than 45 degrees, well above sand's angle of repose.
            if i < iNeck { v = min(v, prev + step) }
            t[i] = v
            prev = v
            i -= 1
        }
        for i in (iNeck + 1)..<n {
            let y = y0 + CGFloat(i) * step
            t[i] = y < L.neckBottom ? L.neckHalf * 0.85 : t[index(2 * L.cy - y)]
        }
        return t
    }

    static func hw(_ y: CGFloat) -> CGFloat { table[min(max(index(y), 0), table.count - 1)] }
}

// MARK: - Sand simulation
// Each chamber is a height field of thin sand columns. Slopes steeper than the maximum angle of
// stability (~34 deg) avalanche down to the angle of repose (~30 deg). The top drains at a constant
// rate through the orifice (like a real hourglass, flow does not depend on how much sand is left),
// the stream falls under gravity, and every grain's mass lands on the pile below.

struct Particle { var x, y, px, py, vx, vy, m: CGFloat; var shade: Int }
struct Roller { var x, vx: CGFloat; var chamber: Int; var shade: Int; var age: CGFloat = 0; var stop: CGFloat = 0 }
struct Pour { var t: CGFloat; var hangT: [CGFloat]; var hangB: [CGFloat]; var dT: CGFloat; var dB: CGFloat; var hasT: Bool; var hasB: Bool }

final class SandSim {
    let dx: CGFloat = 0.5
    let N: Int
    let c0: Int
    var xs: [CGFloat] = []
    var valid: [Bool] = []
    var ceilT: [CGFloat] = [], floorT: [CGFloat] = [], ceilB: [CGFloat] = [], floorB: [CGFloat] = []
    var top: [CGFloat] = [], bot: [CGFloat] = []
    var avT: [Bool] = [], avB: [Bool] = []
    var orifice: [Int] = []
    var byDistance: [Int] = []
    var totalMass: CGFloat = 0
    var topMass: CGFloat = 0
    var particles: [Particle] = []
    var rollers: [Roller] = []
    var emitRate: CGFloat = 60
    var emitAcc: CGFloat = 0
    var emitMass: CGFloat = 0
    var rollAcc: CGFloat = 0
    var emitting = false
    var connected = false
    var busy = true
    var landedCount = 0            // grains that reached the pile during the last update
    var slideRate: CGFloat = 0     // how much sand is avalanching on the pile (for sound)
    var pour: Pour?
    var spots: [Int] = []
    var rng = RNG(s: 0x9E37_79B9_7F4A_7C15)
    let g: CGFloat = 14000          // pt/s^2 (about real gravity at this hourglass's scale)
    let tanMax: CGFloat = 0.67      // ~34 deg, where a slope lets go
    let tanRest: CGFloat = 0.58     // ~30 deg, where an avalanche stops
    let fill: CGFloat

    init(fill: CGFloat = 0.58) {
        self.fill = fill
        N = 2 * Int(L.maxHalf / 0.5) + 1
        c0 = N / 2
        for i in 0..<N {
            let x = L.cx + CGFloat(i - c0) * dx
            let a = abs(x - L.cx)
            var ce = CGFloat.nan, fl = CGFloat.nan
            var y = L.glassTop
            while y <= L.neckTop { if Glass.hw(y) >= a { ce = y; break }; y += Glass.step }
            y = L.neckTop
            while y >= L.glassTop { if Glass.hw(y) >= a { fl = y; break }; y -= Glass.step }
            let ok = !ce.isNaN && !fl.isNaN && fl - ce > 0.3
            xs.append(x)
            valid.append(ok)
            ceilT.append(ok ? ce : L.neckTop)
            floorT.append(ok ? fl : L.neckTop)
            ceilB.append(ok ? 2 * L.cy - fl : L.neckBottom)
            floorB.append(ok ? 2 * L.cy - ce : L.neckBottom)
            if a <= L.neckHalf { orifice.append(i) }
        }
        byDistance = (0..<N).filter { valid[$0] }.sorted { abs($0 - c0) < abs($1 - c0) }
        avT = Array(repeating: false, count: N)
        avB = avT
        top = floorT
        bot = floorB
        var cap: CGFloat = 0
        for i in 0..<N where valid[i] { cap += (floorT[i] - ceilT[i]) * dx }
        totalMass = cap * fill
        reset()
    }

    func reset() {
        particles.removeAll()
        rollers.removeAll()
        emitMass = 0
        emitAcc = 0
        emitting = false
        pour = nil
        top = flatFill(totalMass, ceil: ceilT, floor: floorT)
        bot = floorB
        avT = Array(repeating: false, count: N)
        avB = avT
        topMass = mass(top, floorT)
        busy = true
    }

    func mass(_ s: [CGFloat], _ fl: [CGFloat]) -> CGFloat {
        var m: CGFloat = 0
        for i in 0..<N where valid[i] { m += (fl[i] - s[i]) * dx }
        return m
    }

    var bottomMass: CGFloat { mass(bot, floorB) }

    /// Level surface holding `m`, found by bisection.
    func flatFill(_ m: CGFloat, ceil: [CGFloat], floor: [CGFloat]) -> [CGFloat] {
        func at(_ y: CGFloat) -> [CGFloat] { (0..<N).map { valid[$0] ? min(floor[$0], max(y, ceil[$0])) : floor[$0] } }
        var lo = ceil.min()!, hi = floor.max()!
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if mass(at(mid), floor) > m { lo = mid } else { hi = mid }
        }
        return at((lo + hi) / 2)
    }

    @inline(__always) func surfaceAt(_ s: [CGFloat], _ x: CGFloat) -> CGFloat {
        let f = min(max((x - xs[0]) / dx, 0), CGFloat(N - 1) - 0.001)
        let i = Int(f), t = f - CGFloat(i)
        return s[i] * (1 - t) + s[i + 1] * t
    }

    private func relax(_ s: inout [CGFloat], _ ce: [CGFloat], _ fl: [CGFloat], _ av: inout [Bool], passes: Int, collect: Bool) -> CGFloat {
        var moved: CGFloat = 0
        for p in 0..<passes {
            let fwd = (p & 1) == 0
            for k in 0..<(N - 1) {
                let i = fwd ? k : N - 2 - k, j = i + 1
                if !valid[i] || !valid[j] { continue }
                let d = s[j] - s[i]
                let slope = abs(d) / dx
                if av[i] {
                    if slope <= tanRest + 0.01 { av[i] = false; continue }
                } else if slope > tanMax {
                    av[i] = true
                } else {
                    continue
                }
                let h = d > 0 ? i : j, l = d > 0 ? j : i
                let q = min((abs(d) - tanRest * dx) * 0.25, fl[h] - s[h], s[l] - ce[l])
                if q > 1e-5 {
                    s[h] += q
                    s[l] -= q
                    moved += q
                    if collect && q > 0.03 && spots.count < 12 { spots.append(l) }
                }
            }
        }
        return moved
    }

    private func drainTop(_ amount: CGFloat) -> CGFloat {
        var need = amount
        for _ in 0..<3 where need > 1e-9 {
            let open = orifice.filter { floorT[$0] - top[$0] > 1e-6 }
            if open.isEmpty { break }
            let share = need / CGFloat(open.count)
            for i in open {
                let take = min(share, (floorT[i] - top[i]) * dx)
                top[i] += take / dx
                need -= take
            }
        }
        if need > 1e-9 {
            for i in byDistance {
                let take = min(need, (floorT[i] - top[i]) * dx)
                if take > 0 { top[i] += take / dx; need -= take }
                if need <= 1e-9 { break }
            }
        }
        return amount - max(0, need)
    }

    func deposit(_ m: CGFloat, at x: CGFloat) {
        let ci = Int(((x - xs[0]) / dx).rounded())
        var left = m
        var wsum: CGFloat = 0
        for o in -5...5 { wsum += exp(-CGFloat(o * o) / 9.7) }
        for o in -5...5 {
            let k = ci + o
            guard k >= 0 && k < N && valid[k] else { continue }
            let h = min(m * exp(-CGFloat(o * o) / 9.7) / wsum / dx, bot[k] - ceilB[k])
            if h > 0 { bot[k] -= h; left -= h * dx }
        }
        if left > 1e-7 {
            for k in byDistance {
                let h = min(left / dx, bot[k] - ceilB[k])
                if h > 0 { bot[k] -= h; left -= h * dx }
                if left <= 1e-7 { break }
            }
        }
    }

    private func spawnRoller(chamber: Int, at k: Int, vx: CGFloat) {
        guard rollers.count < 70 else { return }
        rollers.append(Roller(x: xs[k], vx: vx, chamber: chamber, shade: Int(rng.next() % 8)))
    }

    /// One frame. `drain` is how much sand mass should leave the top chamber this frame.
    func update(_ dt: CGFloat, drain: CGFloat) {
        var moved: CGFloat = 0
        if var p = pour {
            p.t += dt / 0.5
            pour = p.t >= 1 ? nil : p
        }

        // Orifice: constant mass flow, split into grains.
        let flowing = drain > 0 && pour == nil && (topMass > 1e-4 || emitMass > 1e-6)
        if flowing {
            emitMass += drainTop(drain)
            if !emitting { connected = false }
            emitAcc += emitRate * dt
        } else {
            emitAcc = 0
        }
        emitting = flowing
        var n = Int(emitAcc)
        if n == 0 && emitMass > 1e-7 && (!flowing || topMass < 1e-4) { n = 1 }
        if n > 0 && emitMass > 0 {
            emitAcc = max(0, emitAcc - CGFloat(n))
            let m = emitMass / CGFloat(n)
            emitMass = 0
            for _ in 0..<n {
                let tau = rng.unit() * dt
                var vy = 18 + rng.unit() * 14
                let x = L.cx + rng.signed() * L.neckHalf * 0.45
                let y = L.neckTop - 2 + vy * tau + 0.5 * g * tau * tau
                vy += g * tau
                particles.append(Particle(x: x, y: y, px: x, py: y - vy * dt, vx: rng.signed() * 3, vy: vy, m: m, shade: Int(rng.next() % 8)))
            }
        }

        // Falling grains.
        landedCount = 0
        var i = 0
        while i < particles.count {
            var p = particles[i]
            p.px = p.x
            p.py = p.y
            p.vy += g * dt
            p.y += p.vy * dt
            p.x += p.vx * dt
            if p.y < L.neckBottom + 3 { p.x = min(max(p.x, L.cx - L.neckHalf * 0.6), L.cx + L.neckHalf * 0.6) }
            if p.y >= surfaceAt(bot, p.x) {
                deposit(p.m, at: p.x)
                landedCount += 1
                connected = true
                if rng.unit() < 0.1 {
                    let k = min(max(Int(((p.x - xs[0]) / dx).rounded()), 0), N - 1)
                    spawnRoller(chamber: 1, at: k, vx: (rng.unit() < 0.5 ? -1 : 1) * (18 + rng.unit() * 40))
                }
                particles.swapAt(i, particles.count - 1)
                particles.removeLast()
            } else {
                particles[i] = p
                i += 1
            }
        }

        // Granular relaxation (avalanches) in both chambers.
        let passes = max(2, Int(dt * 480))
        spots.removeAll(keepingCapacity: true)
        moved += relax(&top, ceilT, floorT, &avT, passes: passes, collect: false)
        let slid = relax(&bot, ceilB, floorB, &avB, passes: passes, collect: true)
        moved += slid
        slideRate = slid / max(dt, 1e-3)
        for k in spots where rng.unit() < 0.3 {
            spawnRoller(chamber: 1, at: k, vx: (xs[k] < L.cx ? -1 : 1) * (5 + rng.unit() * 15))
        }

        // Grains sliding down the crater walls toward the orifice.
        if emitting {
            rollAcc += emitRate * 0.3 * dt
            while rollAcc >= 1 {
                rollAcc -= 1
                for _ in 0..<8 {
                    let k = byDistance[Int(rng.next() % UInt64(byDistance.count))]
                    guard k > 0 && k < N - 1, floorT[k] - top[k] > 0.5, abs(xs[k] - L.cx) > L.neckHalf + 1 else { continue }
                    let m = (top[k + 1] - top[k - 1]) / (2 * dx)
                    if abs(m) > 0.45 && abs(m) < 1.1 { spawnRoller(chamber: 0, at: k, vx: 0); break }
                }
            }
        }
        updateRollers(dt)

        topMass = mass(top, floorT)
        busy = !particles.isEmpty || !rollers.isEmpty || moved > 1e-4 || pour != nil || emitting
    }

    private func updateRollers(_ dt: CGFloat) {
        var i = 0
        while i < rollers.count {
            var r = rollers[i]
            r.age += dt
            var dead = false
            if r.stop > 0 {
                r.stop += dt
                dead = r.stop > 0.35
            } else {
                let s = r.chamber == 0 ? top : bot
                let fl = r.chamber == 0 ? floorT : floorB
                let raw = Int(((r.x - xs[0]) / dx).rounded())
                let k = min(max(raw, 1), N - 2)
                let m = (s[k + 1] - s[k - 1]) / (2 * dx)
                let along = 2600 * (abs(m) - 0.5) / (1 + m * m)
                if along > 0 { r.vx += (m >= 0 ? 1 : -1) * along * dt } else { r.vx *= exp(-dt * 7) }
                r.vx *= exp(-dt * 1.2)
                r.x += r.vx * dt
                if raw < 1 || raw > N - 2 || !valid[k] || !valid[k - 1] || !valid[k + 1] || fl[k] - s[k] < 0.2 { dead = true }
                if r.chamber == 0 && abs(r.x - L.cx) < L.neckHalf { dead = true }
                if (abs(r.vx) < 1.5 && along <= 0) || r.age > 3 { r.stop = 0.0001 }
            }
            if dead {
                rollers.swapAt(i, rollers.count - 1)
                rollers.removeLast()
            } else {
                rollers[i] = r
                i += 1
            }
        }
    }

    /// Catch-up after the Mac slept or the hourglass was hidden: move sand instantly.
    func catchUp(_ amount: CGFloat) {
        let got = drainTop(amount)
        for _ in 0..<30 {
            deposit(got / 30, at: L.cx)
            _ = relax(&bot, ceilB, floorB, &avB, passes: 16, collect: false)
        }
        _ = relax(&top, ceilT, floorT, &avT, passes: 300, collect: false)
        _ = relax(&bot, ceilB, floorB, &avB, passes: 300, collect: false)
        topMass = mass(top, floorT)
        busy = true
    }

    func landAll() {
        for p in particles { deposit(p.m, at: p.x) }
        if emitMass > 0 { deposit(emitMass, at: L.cx) }
        particles.removeAll()
        rollers.removeAll()
        emitMass = 0
        emitting = false
        _ = relax(&top, ceilT, floorT, &avT, passes: 200, collect: false)
        _ = relax(&bot, ceilB, floorB, &avB, passes: 200, collect: false)
        topMass = mass(top, floorT)
    }

    /// Turn the hourglass over. Each chamber's sand is left hanging where it was, then pours down.
    func flip() {
        landAll()
        var hangT = [CGFloat](repeating: 0, count: N), hangB = hangT
        for k in 0..<N {
            let j = N - 1 - k
            hangT[k] = valid[k] ? 2 * L.cy - bot[j] : ceilT[k]
            hangB[k] = valid[k] ? 2 * L.cy - top[j] : ceilB[k]
        }
        let mT = bottomMass, mB = topMass
        top = flatFill(mT, ceil: ceilT, floor: floorT)
        bot = flatFill(mB, ceil: ceilB, floor: floorB)
        avT = Array(repeating: false, count: N)
        avB = avT
        func centroid(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
            var m: CGFloat = 0, s: CGFloat = 0
            for i in 0..<N where valid[i] && b[i] > a[i] { let t = b[i] - a[i]; m += t; s += t * (a[i] + b[i]) / 2 }
            return m > 0 ? s / m : 0
        }
        let dT = max(0, centroid(top, floorT) - centroid(ceilT, hangT))
        let dB = max(0, centroid(bot, floorB) - centroid(ceilB, hangB))
        pour = Pour(t: 0, hangT: hangT, hangB: hangB, dT: dT, dB: dB, hasT: mT > 1, hasB: mB > 1)
        topMass = mass(top, floorT)
        busy = true
    }

    /// Upper and lower ends of the falling stream, if any.
    func streamExtent() -> (CGFloat, CGFloat)? {
        if particles.isEmpty { return nil }
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in particles { minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let impact = surfaceAt(bot, L.cx)
        let upper = emitting ? L.neckTop - 1 : minY
        let lower = connected ? impact : min(maxY, impact)
        return lower > upper ? (upper, lower) : nil
    }
}

extension SandSim {
    /// How bright the grain impacts sound: 1 = grains striking bare glass (crisp, high),
    /// 0 = grains landing on a deep bed of sand after a short fall (soft, smooth).
    var impactBrightness: CGFloat {
        let depth = floorB[c0] - bot[c0]
        let filled = min(1, max(0, 1 - topMass / max(totalMass, 1)))
        let fall = min(1, max(0, (surfaceAt(bot, L.cx) - L.neckBottom) / L.chamberH))
        let direct = exp(-depth / 5)                        // stream still hitting glass
        let ring = pow(1 - filled, 1.6) * sqrt(fall)        // sand against the glass damps its ring
        return min(1, 0.45 * direct + 0.55 * ring)
    }
}

// MARK: - Calm background noise (generated live, never loops)

struct NoiseChannel {
    var brown: Float = 0
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, pink: Float = 0
    var lp1: Float = 0, lp2: Float = 0
}

/// Two-pole resonator: one natural ringing tone of the glass.
struct Reso {
    var b1: Float = 0, b2: Float = 0, norm: Float = 0, y1: Float = 0, y2: Float = 0
    init() {}
    init(_ f: Float, _ ms: Float, _ sr: Float) {
        let r = expf(-1 / (ms * 0.001 * sr)), w = 2 * Float.pi * f / sr
        b1 = 2 * r * cosf(w)
        b2 = -r * r
        norm = sinf(w)
    }
    @inline(__always) mutating func tick(_ x: Float) -> Float {
        let y = x * norm + b1 * y1 + b2 * y2
        y2 = y1
        y1 = y
        return y
    }
}

/// State-variable filter (band-pass and low-pass outputs).
struct SVF {
    var a1: Float = 0, a2: Float = 0, a3: Float = 0, k: Float = 0, ic1: Float = 0, ic2: Float = 0
    init() {}
    init(_ f: Float, _ q: Float, _ sr: Float) {
        let g = tanf(Float.pi * min(f, sr * 0.45) / sr)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }
    mutating func set(_ f: Float, _ q: Float, _ sr: Float) {
        let g = tanf(Float.pi * min(f, sr * 0.45) / sr)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }
    @inline(__always) mutating func tick(_ v0: Float) -> (bp: Float, lp: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v1, v2)
    }
}

/// A real hourglass sound is thousands of tiny grain impacts a second: most land on sand (a short,
/// muffled tick), some ring the glass at its natural resonances. These presets shape that process.
/// Sand is thousands of tiny impacts a second: far too many to hear one by one, so what reaches the
/// ear is a smooth, textured hiss. Grains striking bare glass are short and bright; grains settling
/// on a bed of sand are longer, softer and lower. Each profile gives the two ends (sand, glass).
struct GrainProfile {
    var rate: (Float, Float)          // grain impacts per second at full flow
    var spread: (Float, Float)        // loudness spread between grains (higher = more uneven)
    var tickMs: (Float, Float)        // how long one grain's tick lasts
    var hissF: (Float, Float), hissQ: (Float, Float)
    var airF: (Float, Float)          // overall high-frequency roll-off
    var click: (Float, Float)         // share of a very short bright click (grain on glass)
    var clickF: Float
    var body: (Float, Float), bodyF: Float
    var flicker: Float                // natural unevenness of the flow
    var room: Float                   // faint reflections from the desk
    var level: [Float]                // loudness calibration at brightness 0, 0.25, 0.5, 0.75, 1 (see --noise-test)
    var fixed: Float? = nil           // steady presets keep one brightness

    static func forKind(_ k: Int) -> GrainProfile? {
        switch k {
        case 5: return GrainProfile(rate: (6500, 2600), spread: (1.8, 1.4), tickMs: (0.9, 0.25), hissF: (1400, 6500), hissQ: (0.5, 0.8),
                                    airF: (3600, 13000), click: (0.05, 0.6), clickF: 8000, body: (0.45, 0), bodyF: 300, flicker: 0.18, room: 0.22,
                                    level: [0.415, 0.341, 0.322, 0.354, 0.434])
        // Close-up: finer grains heard from nearby, so more fine detail and a crisper glass phase.
        case 6: return GrainProfile(rate: (7500, 3200), spread: (1.7, 1.4), tickMs: (0.6, 0.18), hissF: (2200, 7200), hissQ: (0.55, 0.8),
                                    airF: (6000, 15000), click: (0.03, 0.5), clickF: 9000, body: (0.2, 0), bodyF: 350, flicker: 0.22, room: 0.12,
                                    level: [0.386, 0.353, 0.348, 0.382, 0.454])
        // Grains on glass: steady, bright and delicate.
        case 7: return GrainProfile(rate: (2600, 2600), spread: (1.6, 1.6), tickMs: (0.3, 0.3), hissF: (6800, 6800), hissQ: (0.85, 0.85),
                                    airF: (15000, 15000), click: (0.6, 0.6), clickF: 9500, body: (0, 0), bodyF: 400, flicker: 0.3, room: 0.3,
                                    level: [0.382, 0.382, 0.382, 0.382, 0.382], fixed: 1)
        // Big: coarser grains and thicker glass, so a deeper, grainier pour.
        case 8: return GrainProfile(rate: (3000, 1800), spread: (2.0, 1.6), tickMs: (1.5, 0.45), hissF: (850, 3400), hissQ: (0.5, 0.75),
                                    airF: (2500, 8000), click: (0.04, 0.5), clickF: 5500, body: (0.6, 0.1), bodyF: 200, flicker: 0.25, room: 0.28,
                                    level: [0.657, 0.536, 0.5, 0.515, 0.584])
        default: return nil
        }
    }
}

final class NoiseState {
    static let names = ["Off", "Brown Noise · deep and warm", "Pink Noise · soft and even", "Ocean Waves · slow swells", "Soft Hiss · airy",
                        "Live Hourglass · follows the sand", "Close-up Trickle · fine, follows the sand", "Grains on Glass · bright, steady",
                        "Big Hourglass · deep, follows the sand",
                        "Lava Lamp · warm hum and bloops", "Water Clock · follows the drops", "Cave Drips · echoing",
                        "Candle Flame · soft flutter", "Winter Hush · soft wind", "Zen Garden · stream and tock",
                        "Gentle Rain · soft patter", "Fireplace · soft crackle"]
    static let norm: [Float] = [0, 0.63, 0.216, 0.39, 0.40, 1, 1, 1, 1, 0.40, 0.59, 0.47, 0.19, 0.40, 0.48, 0.75, 0.61]
    static let liveKinds: Set<Int> = [5, 6, 8]
    static let hourglassKinds = [5, 6, 7, 8]
    static let ambientKinds = [1, 2, 3, 4, 15, 16]

    // Sounds for the other styles live in Audio2.swift; simulations post one-off events here.
    let ex = ExtraSynth()
    private let evLock: UnsafeMutablePointer<os_unfair_lock> = {
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        return l
    }()
    private var evQueue: [SoundEvent] = []
    private var evScratch: [SoundEvent] = []

    func post(_ e: SoundEvent) {
        guard target > 0 else { return }          // nothing is playing: don't pile up stale triggers
        os_unfair_lock_lock(evLock)
        if evQueue.count < 64 { evQueue.append(e) }
        os_unfair_lock_unlock(evLock)
    }

    func clearEvents() {
        os_unfair_lock_lock(evLock)
        evQueue.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(evLock)
    }

    private func drainEvents() {
        os_unfair_lock_lock(evLock)
        Swift.swap(&evQueue, &evScratch)
        os_unfair_lock_unlock(evLock)
        for e in evScratch { ex.handle(e) }
        evScratch.removeAll(keepingCapacity: true)
    }
    var kind = 0
    var pending = 0
    var target: Float = 0
    var gain: Float = 0
    var swap: Float = 1
    var volume: Float = 0.5
    var rng = RNG(s: 0x5DEE_CE66_D123_4567)
    var cl = NoiseChannel(), cr = NoiseChannel()
    var phase: Float = 0, period: Float = 9
    var flick: Float = 0.8, flickT: Float = 0.8
    let sr: Float = 44100

    @inline(__always) func white() -> Float { Float(Int64(bitPattern: rng.next())) / Float(Int64.max) }

    @inline(__always) func pinkStep(_ c: inout NoiseChannel, _ w: Float) {
        c.b0 = 0.99765 * c.b0 + w * 0.0990460
        c.b1 = 0.96300 * c.b1 + w * 0.2965164
        c.b2 = 0.57000 * c.b2 + w * 1.0526913
        c.pink = (c.b0 + c.b1 + c.b2 + w * 0.1848) * 0.25
    }

    @inline(__always) func sample(_ c: inout NoiseChannel, _ w: Float, _ env: Float) -> Float {
        switch kind {
        case 1:
            c.brown = (c.brown + 0.02 * w) / 1.02
            c.lp1 += (c.brown * 3.5 - c.lp1) * 0.2
            return c.lp1
        case 2:
            pinkStep(&c, w)
            c.lp1 += (c.pink - c.lp1) * 0.28
            return c.lp1
        case 3:
            c.brown = (c.brown + 0.02 * w) / 1.02
            pinkStep(&c, w)
            c.lp1 += (c.pink - c.lp1) * 0.1
            c.lp2 += (c.brown * 3.5 - c.lp2) * 0.1
            return c.lp2 * 0.45 + c.lp1 * env
        case 4:
            pinkStep(&c, w)
            c.lp1 += (c.pink - c.lp1) * 0.33
            c.lp2 += (c.lp1 - c.lp2) * 0.06
            return (c.lp1 - c.lp2) * flick
        default:
            return 0
        }
    }

    // Hourglass grain synthesis
    var gp = GrainProfile.forKind(5)!
    var hiss = SVF(), air = SVF(), slideF = SVF(), bodyF = SVF(), clickBP = SVF()
    var tickEnv: Float = 0, tickDecay: Float = 0.96
    var clickEnv: Float = 0
    let clickDecay: Float = 0.68
    var flow: Float = 1, flowT: Float = 1
    var tap = [Float](repeating: 0, count: 2048), tapPos = 0
    var counter = 0
    // Live inputs from the simulation (written on the main thread, smoothed here)
    var liveFlow: Float = 0, liveFall: Float = 1, liveSlide: Float = 0, liveBright: Float = 1
    var sFlow: Float = 0, sFall: Float = 1, sSlide: Float = 0, sBright: Float = 1
    var liveGain: Float = 1

    @inline(__always) func unitF() -> Float { Float(rng.next() >> 40) / 16_777_216 }

    func configure(_ k: Int) {
        if k >= 9 { ex.configure(k); return }
        guard let p = GrainProfile.forKind(k) else { return }
        gp = p
        hiss = SVF(p.hissF.0, p.hissQ.0, sr)
        air = SVF(p.airF.0, 0.7, sr)
        clickBP = SVF(p.clickF, 0.7, sr)
        slideF = SVF(1700, 0.8, sr)
        bodyF = SVF(p.bodyF, 0.9, sr)
        tickDecay = expf(-1 / (p.tickMs.0 * 0.001 * sr))
        tickEnv = 0
        clickEnv = 0
        for i in tap.indices { tap[i] = 0 }
    }

    /// One grain process whose sound glides from grains striking bare glass (short, crisp, high)
    /// to grains settling on a deep bed of sand (longer, softer, lower, dense and smooth).
    @inline(__always) func grainMono() -> Float {
        sFlow += (liveFlow - sFlow) * 0.0006
        sFall += (liveFall - sFall) * 0.0003
        sSlide += (liveSlide - sSlide) * 0.0015
        sBright += (liveBright - sBright) * 0.00002
        let b = gp.fixed ?? sBright
        @inline(__always) func mix(_ p: (Float, Float)) -> Float { p.0 + (p.1 - p.0) * b }
        if counter & 63 == 0 {
            hiss.set(mix(gp.hissF), mix(gp.hissQ), sr)
            air.set(mix(gp.airF), 0.7, sr)
            tickDecay = expf(-1 / (mix(gp.tickMs) * 0.001 * sr))
            let f = min(max(b, 0), 1) * 4, i = min(3, Int(f)), t = f - Float(i)
            liveGain = gp.level[i] + (gp.level[i + 1] - gp.level[i]) * t
        }
        let fl = gp.fixed != nil ? 1 : sFlow
        let lambda = mix(gp.rate) * fl * flow * (1 + sSlide * 0.6)
        if unitF() < lambda / sr {
            let a = powf(unitF(), mix(gp.spread)) * (0.5 + 0.5 * sFall) * liveGain
            tickEnv += a
            clickEnv += a * mix(gp.click)
        }
        tickEnv *= tickDecay
        clickEnv *= clickDecay
        let w = white()
        let exc = tickEnv * w
        var out = hiss.tick(exc).bp
        out += clickBP.tick(clickEnv * w).bp * 2.5
        let body = mix(gp.body)
        if body > 0.001 { out += bodyF.tick(exc).lp * body }
        if sSlide > 0.002 { out += slideF.tick(w).bp * sSlide * 0.12 }
        return air.tick(out).lp
    }

    @inline(__always) func hourglassSample() -> (Float, Float) {
        counter &+= 1
        if counter & 511 == 0 { flowT = 1 - gp.flicker + 2 * gp.flicker * unitF() }
        flow += (flowT - flow) * 0.0004
        var out = grainMono()
        if !out.isFinite { configure(kind); out = 0 }
        tap[tapPos] = out
        let left = out + (tap[(tapPos - 490) & 2047] + tap[(tapPos - 1310) & 2047] * 0.5) * gp.room
        let right = out + (tap[(tapPos - 750) & 2047] + tap[(tapPos - 1580) & 2047] * 0.5) * gp.room
        tapPos = (tapPos + 1) & 2047
        return (left, right)
    }

    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let vol = pow(max(0, volume), 1.5)
        drainEvents()
        for i in 0..<n {
            gain += (target - gain) * 0.00004
            if pending != kind {
                if gain < 0.001 {
                    kind = pending
                    configure(kind)
                    swap = 1
                } else {
                    swap -= 0.00012
                    if swap <= 0 { swap = 0; kind = pending; configure(kind) }
                }
            } else if swap < 1 {
                swap = min(1, swap + 0.00012)
            }
            phase += 1 / (period * sr)
            if phase >= 1 { phase -= 1; period = 7 + 5 * Float(rng.unit()) }
            let s = sin(Float.pi * phase)
            let env = 0.12 + 0.88 * s * s * s
            if i & 255 == 0 { flickT = 0.55 + 0.45 * Float(rng.unit()) }
            flick += (flickT - flick) * 0.0008
            var a: Float, b: Float
            if kind >= 9 {
                (a, b) = ex.sample()
            } else if kind >= 5 {
                (a, b) = hourglassSample()
            } else {
                a = sample(&cl, white(), env)
                b = sample(&cr, white(), env)
            }
            let g = gain * swap * vol * NoiseState.norm[kind]
            l[i] = a * g
            r[i] = b * g
        }
    }
}

final class NoisePlayer {
    let st = NoiseState()
    private var engine: AVAudioEngine?
    private var stopItem: DispatchWorkItem?

    func set(kind: Int, volume: Float, playing: Bool) {
        st.volume = volume
        if kind > 0 { st.pending = kind }
        if playing && kind > 0 {
            stopItem?.cancel()
            stopItem = nil
            if engine == nil { build() }
            if let e = engine, !e.isRunning { st.clearEvents(); try? e.start() }
            st.target = 1
        } else {
            st.target = 0
            guard engine?.isRunning == true, stopItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stopItem = nil
                if self.st.target == 0 { self.engine?.stop() }
            }
            stopItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
        }
    }

    private func build() {
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let st = self.st
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2, let l = bufs[0].mData, let r = bufs[1].mData else { return noErr }
            st.render(l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self, self.st.target > 0 else { return }
            try? self.engine?.start()
        }
        engine = e
    }
}

// MARK: - Styles

struct RGB {
    var r, g, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
    func scaled(_ f: CGFloat) -> RGB { RGB(min(1, r * f), min(1, g * f), min(1, b * f)) }
    func mixed(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
}

struct SandStyle { let name: String; let color: RGB }
let sandStyles: [SandStyle] = [
    .init(name: "Desert Gold", color: RGB(0.93, 0.76, 0.47)),
    .init(name: "Rose Quartz", color: RGB(0.94, 0.64, 0.68)),
    .init(name: "Ocean", color: RGB(0.38, 0.66, 0.93)),
    .init(name: "Mint", color: RGB(0.47, 0.86, 0.72)),
    .init(name: "Lavender", color: RGB(0.72, 0.62, 0.95)),
    .init(name: "Ember", color: RGB(0.96, 0.50, 0.32)),
    .init(name: "Snow", color: RGB(0.93, 0.94, 0.96)),
]

struct FrameStyle { let name: String; let light: RGB; let dark: RGB; let ring: RGB; let text: RGB }
let frameStyles: [FrameStyle] = [
    .init(name: "Walnut", light: RGB(0.50, 0.33, 0.20), dark: RGB(0.25, 0.15, 0.08), ring: RGB(0.88, 0.72, 0.44), text: RGB(0.99, 0.94, 0.86)),
    .init(name: "Graphite", light: RGB(0.36, 0.37, 0.40), dark: RGB(0.12, 0.13, 0.15), ring: RGB(0.80, 0.82, 0.86), text: RGB(0.96, 0.97, 0.99)),
    .init(name: "Oak", light: RGB(0.87, 0.72, 0.52), dark: RGB(0.64, 0.48, 0.30), ring: RGB(0.42, 0.29, 0.17), text: RGB(0.24, 0.15, 0.07)),
    .init(name: "Ivory", light: RGB(0.99, 0.98, 0.95), dark: RGB(0.82, 0.80, 0.76), ring: RGB(0.80, 0.64, 0.36), text: RGB(0.26, 0.24, 0.21)),
]

struct UIState {
    var time: String
    var paused: Bool
    var dimTime: Bool
    var task: String
    var frame: FrameStyle
    var glow: CGFloat
    var shadow: CGFloat
    var running = false
    var done = false
}

// MARK: - Renderer

final class Renderer {
    let sim: SandSim
    let glass: CGPath
    let sheenL: [CGPath]
    let sheenR: [CGPath]
    let texRect = CGRect(x: L.cx - L.maxHalf - 4, y: Glass.y0, width: L.maxHalf * 2 + 8, height: Glass.y1 - Glass.y0)
    var texture: CGImage?
    var grainColors: [CGColor] = []
    var rim = RGB(1, 1, 1)
    var sand = sandStyles[0].color
    var fx = RNG(s: 0x1234_5678_9ABC_DEF1)
    let space = CGColorSpaceCreateDeviceRGB()

    init(sim: SandSim) {
        self.sim = sim
        func half(_ y: CGFloat) -> CGFloat { Glass.hw(y) + 1.7 }
        var left: [CGPoint] = []
        var y = Glass.y0
        while y <= Glass.y1 + 0.01 { left.append(CGPoint(x: L.cx - half(y), y: y)); y += 2 }
        let right = left.reversed().map { CGPoint(x: 2 * L.cx - $0.x, y: $0.y) }
        let p = CGMutablePath()
        Renderer.smooth(p, left, move: true)
        p.addLine(to: right[0])
        Renderer.smooth(p, right, move: false)
        p.closeSubpath()
        glass = p

        var sl: [CGPath] = [], sr: [CGPath] = []
        for (a, b) in [(L.neckTop - 110, L.neckTop - 22), (L.neckBottom + 22, L.neckBottom + 110)] {
            let ys = stride(from: a, through: b, by: 2).map { $0 }
            let pl = CGMutablePath(), pr = CGMutablePath()
            Renderer.smooth(pl, ys.map { CGPoint(x: L.cx - half($0) * 0.80, y: $0) }, move: true)
            Renderer.smooth(pr, ys.map { CGPoint(x: L.cx + half($0) * 0.88, y: $0) }, move: true)
            sl.append(pl)
            sr.append(pr)
        }
        sheenL = sl
        sheenR = sr
        setSand(sand)
    }

    static func smooth(_ path: CGMutablePath, _ pts: [CGPoint], move: Bool) {
        guard pts.count > 1 else { return }
        if move { path.move(to: pts[0]) } else { path.addLine(to: pts[0]) }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    func setSand(_ c: RGB) {
        sand = c
        grainColors = (0..<8).map { i in
            let f = 0.78 + 0.34 * CGFloat(i) / 7
            return RGB(c.r * f, c.g * f, c.b * f * (0.95 + 0.1 * CGFloat(i) / 7)).cg()
        }
        rim = c.mixed(RGB(1, 1, 1), 0.35)
        texture = Renderer.makeTexture(c, size: texRect.size, scale: texScale)
    }

    /// A still image of packed grains; sand regions are windows onto it.
    static func makeTexture(_ c: RGB, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(c.scaled(0.84).cg())
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var rng = RNG(s: 0xABC_DEF1_2345_6789)
        let palette: [CGColor] = (0..<12).map { i in
            let f = 0.72 + 0.42 * CGFloat(i) / 11
            return RGB(c.r * f, c.g * f, c.b * f * (0.94 + 0.12 * CGFloat(i) / 11)).cg()
        }
        let dark = c.scaled(0.5).cg(), bright = c.mixed(RGB(1, 1, 1), 0.55).cg(), mineral = RGB(0.33, 0.29, 0.27).cg()
        let count = Int(size.width * size.height * 1.7)
        for _ in 0..<count {
            let x = rng.unit() * CGFloat(w), y = rng.unit() * CGFloat(h)
            let r = (0.4 + 0.38 * rng.unit()) * scale
            let roll = rng.unit()
            ctx.setFillColor(roll < 0.025 ? dark : roll < 0.04 ? bright : roll < 0.044 ? mineral : palette[Int(rng.next() % 12)])
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }

    private func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
    }

    // Region between an upper and a lower boundary, column by column.
    private func region(_ upper: [CGFloat], _ lower: [CGFloat], dy: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        var first = true
        for i in 0..<sim.N where sim.valid[i] {
            let pt = CGPoint(x: sim.xs[i], y: upper[i] + dy)
            if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
        }
        for i in stride(from: sim.N - 1, through: 0, by: -1) where sim.valid[i] { p.addLine(to: CGPoint(x: sim.xs[i], y: lower[i] + dy)) }
        p.closeSubpath()
        return p
    }

    struct SandFrame {
        var settled: CGPath
        var settledAlpha: CGFloat = 1
        var pour: CGPath?
        var pourAlpha: CGFloat = 0
        var rim: CGPath?
        var stream: CGPath?
        var light = CGMutablePath()
        var dark = CGMutablePath()
    }

    /// Geometry of everything that moves this frame. Shared by the live layers and the still renderer.
    func sandFrame() -> SandFrame {
        let settled = CGMutablePath()
        settled.addPath(region(sim.top, sim.floorT))
        settled.addPath(region(sim.bot, sim.floorB))
        var f = SandFrame(settled: settled)
        if let p = sim.pour {
            let e = p.t * p.t
            let hang = CGMutablePath()
            if p.hasT { hang.addPath(region(sim.ceilT, p.hangT, dy: p.dT * e)) }
            if p.hasB { hang.addPath(region(sim.ceilB, p.hangB, dy: p.dB * e)) }
            f.pour = hang
            f.pourAlpha = 1 - min(1, max(0, (p.t - 0.6) / 0.4))
            f.settledAlpha = min(1, max(0, (p.t - 0.5) / 0.5))
        } else {
            let r = CGMutablePath()
            for (sf, fl) in [(sim.top, sim.floorT), (sim.bot, sim.floorB)] {
                var open = false
                for i in 0..<sim.N where sim.valid[i] {
                    if fl[i] - sf[i] > 0.25 {
                        let pt = CGPoint(x: sim.xs[i], y: sf[i] + 0.2)
                        if open { r.addLine(to: pt) } else { r.move(to: pt); open = true }
                    } else {
                        open = false
                    }
                }
            }
            f.rim = r
        }

        // The stream: a thread that thins as it speeds up, with grains glinting along it.
        if let (y0, y1) = sim.streamExtent() {
            let thick = 0.85 + 0.6 * min(1, max(0, (sim.emitRate - 45) / 120))
            var lpts: [CGPoint] = [], rpts: [CGPoint] = []
            var y = y0
            while true {
                let v = sqrt(26 * 26 + 2 * sim.g * max(0, y - L.neckTop))
                let w = max(0.8, 2.2 * pow(26 / v, 0.25)) * thick / 2
                lpts.append(CGPoint(x: L.cx - w, y: y))
                rpts.append(CGPoint(x: L.cx + w, y: y))
                if y >= y1 { break }
                y = min(y1, y + 3)
            }
            let p = CGMutablePath()
            p.addLines(between: lpts)
            p.addLines(between: rpts.reversed())
            p.closeSubpath()
            f.stream = p
            for _ in 0..<Int((y1 - y0) / 5) {
                let gy = y0 + fx.unit() * (y1 - y0)
                let gx = L.cx + fx.signed() * 0.6 * thick
                (fx.unit() < 0.5 ? f.light : f.dark).addEllipse(in: CGRect(x: gx - 0.45, y: gy - 0.45, width: 0.9, height: 0.9))
            }
        }
        // Grains in flight near the neck (still slow enough to see one by one)
        for gp in sim.particles where gp.y < L.neckBottom + 14 {
            (gp.shade >= 4 ? f.light : f.dark).addEllipse(in: CGRect(x: gp.x - 0.7, y: gp.y - 0.7, width: 1.4, height: 1.4))
        }
        // Grains rolling on the sand surfaces
        for r in sim.rollers where r.stop < 0.2 {
            let y = sim.surfaceAt(r.chamber == 0 ? sim.top : sim.bot, r.x) - 0.55
            (r.shade >= 4 ? f.light : f.dark).addEllipse(in: CGRect(x: r.x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
        }
        return f
    }

    var streamColor: CGColor { sand.scaled(0.95).cg(0.92) }
    var lightGrain: CGColor { rim.cg(0.95) }
    var darkGrain: CGColor { grainColors[1] }
    var rimColor: CGColor { rim.cg(0.55) }
    static let shadeColors = [CGColor(gray: 0, alpha: 0.24), CGColor(gray: 0, alpha: 0.03), CGColor(gray: 0, alpha: 0),
                              CGColor(gray: 0, alpha: 0.07), CGColor(gray: 0, alpha: 0.30)]
    static let shadeLocs: [CGFloat] = [0, 0.25, 0.45, 0.75, 1]

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawSand(ctx)
        drawFront(ctx, ui: ui)
    }

    private(set) var texScale: CGFloat = 3

    func setTextureScale(_ ps: CGFloat) {
        guard abs(ps - texScale) > 0.01 else { return }
        texScale = ps
        texture = Renderer.makeTexture(sand, size: texRect.size, scale: ps)
    }

    /// Render a static layer (glass back or front) into a bitmap at the screen's pixel size.
    func image(_ ps: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int(ceil(L.width * ps)), h = Int(ceil(L.height * ps))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: ps, y: -ps)
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        body(c)
        NSGraphicsContext.current = saved
        return c.makeImage()
    }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        let capTopY = L.margin, capBotY = L.height - L.margin - L.capH

        if ui.shadow > 0 {
            ctx.saveGState()
            ctx.translateBy(x: L.cx, y: L.height - L.margin + 1)
            ctx.scaleBy(x: 1, y: 0.1)
            ctx.drawRadialGradient(gradient([CGColor(gray: 0, alpha: 0.34 * ui.shadow), CGColor(gray: 0, alpha: 0)], [0, 1]),
                                   startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 80, options: [])
            ctx.restoreGState()
        }

        _ = (fs, capTopY, capBotY)
        ctx.addPath(glass)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
        ctx.fillPath()
    }

    func drawSand(_ ctx: CGContext) {
        let f = sandFrame()
        func fill(_ path: CGPath, _ alpha: CGFloat) {
            guard let tex = texture, alpha > 0 else { return }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(tex, in: texRect)
            ctx.drawLinearGradient(gradient(Renderer.shadeColors, Renderer.shadeLocs),
                                   start: CGPoint(x: texRect.minX, y: 0), end: CGPoint(x: texRect.maxX, y: 0), options: [])
            ctx.restoreGState()
        }
        if let p = f.pour { fill(p, f.pourAlpha) }
        fill(f.settled, f.settledAlpha)
        if let r = f.rim {
            var down = CGAffineTransform(translationX: 0, y: 1.3)
            if let seam = r.copy(using: &down) { ctx.addPath(seam); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.2)); ctx.setLineWidth(1.4); ctx.strokePath() }
            ctx.addPath(r); ctx.setStrokeColor(rimColor); ctx.setLineWidth(0.7); ctx.strokePath()
        }
        if let st = f.stream { ctx.addPath(st); ctx.setFillColor(streamColor); ctx.fillPath() }
        ctx.addPath(f.light); ctx.setFillColor(lightGrain); ctx.fillPath()
        ctx.addPath(f.dark); ctx.setFillColor(darkGrain); ctx.fillPath()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        let capTopY = L.margin, capBotY = L.height - L.margin - L.capH
        // Glass front
        let maxHalf = L.maxHalf + 2
        ctx.saveGState()
        ctx.addPath(glass)
        ctx.clip()
        ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0),
                                          CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0.11)], [0, 0.22, 0.5, 0.8, 1]),
                               start: CGPoint(x: L.cx - maxHalf, y: 0), end: CGPoint(x: L.cx + maxHalf, y: 0), options: [])
        ctx.restoreGState()
        ctx.setLineCap(.round)
        for p in sheenL { ctx.addPath(p); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.26)); ctx.setLineWidth(3.2); ctx.strokePath() }
        for p in sheenR { ctx.addPath(p); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1.4); ctx.strokePath() }
        glassStreak(ctx, in: glass, center: CGPoint(x: L.cx - 10, y: L.neckTop - 78), length: 150, width: 9, alpha: 0.11)
        glassStreak(ctx, in: glass, center: CGPoint(x: L.cx - 6, y: L.neckBottom + 70), length: 150, width: 7, alpha: 0.07)
        ctx.setLineJoin(.round)
        ctx.addPath(glass); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.30)); ctx.setLineWidth(2.4); ctx.strokePath()
        ctx.addPath(glass); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.62)); ctx.setLineWidth(1.0); ctx.strokePath()
        fresnelRim(ctx, glass, width: 7, alpha: 0.16)
        specular(ctx, at: CGPoint(x: L.cx - 2.5, y: L.neckTop + L.neckH / 2), rx: 3.5, ry: 4, alpha: 0.55)

        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: sand.cg(ui.glow))
            ctx.addPath(glass); ctx.setStrokeColor(sand.cg(0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }

        _ = (capTopY, capBotY)
        let ringW = 2 * (Glass.hw(Glass.y0) + 1.7) + 10
        woodDisc(ctx, cy: 18, rx: 80, ry: 7, thick: 14, fs: fs, seed: 3)
        woodDisc(ctx, cy: 292, rx: 82, ry: 7.5, thick: 15, fs: fs, seed: 9)
        drawRing(ctx, y: 33, w: ringW, fs: fs)
        drawRing(ctx, y: 288, w: ringW, fs: fs)
        drawBadge(ctx, ui: ui, accent: sand.mixed(RGB(1, 1, 1), 0.1))
    }

    private func drawCap(_ ctx: CGContext, y: CGFloat, fs: FrameStyle) {
        let rect = CGRect(x: L.capInset, y: y, width: L.width - 2 * L.capInset, height: L.capH)
        let p = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(p); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(gradient([fs.light.scaled(1.12).cg(), fs.light.cg(), fs.dark.cg()], [0, 0.35, 1]),
                               start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
        frameTexture(ctx, in: p, rect: rect, seed: UInt64(y) + 3)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); ctx.setLineWidth(1); ctx.strokePath()
    }

    private func drawRing(_ ctx: CGContext, y: CGFloat, w: CGFloat, fs: FrameStyle) {
        let r = CGRect(x: L.cx - w / 2, y: y, width: w, height: 3.5)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient([fs.ring.scaled(1.18).cg(), fs.ring.scaled(0.72).cg()], [0, 1]),
                               start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        ctx.restoreGState()
    }
}

// MARK: - Timer bodies (sand hourglass or lava lamp)

/// Anything that holds "time" as material moving from a top store to a bottom store.
protocol TimerBody: AnyObject {
    var totalMass: CGFloat { get }
    var topMass: CGFloat { get }
    var busy: Bool { get }
    var inFlight: Bool { get }
    func reset()
    func update(_ dt: CGFloat, drain: CGFloat)
    func catchUp(_ amount: CGFloat)
    func landAll()
    func flip()
    func configure(forSeconds s: Double)
}

extension SandSim: TimerBody {
    var inFlight: Bool { !particles.isEmpty || emitMass > 1e-7 }
    func configure(forSeconds s: Double) { emitRate = AppController.emitRate(forSeconds: s) }
}

// MARK: - Lava lamp

/// Lamp layout, inside the same outer box as the hourglass so sizes and window positions carry over.
enum LL {
    static let capTop: CGFloat = 12, capBottom: CGFloat = 56
    static let top: CGFloat = 56            // bottle interior top
    static let bottom: CGFloat = 236        // bottle interior bottom, where the base collar starts
    static let baseBottom: CGFloat = 316
    static let capTopHalf: CGFloat = 9, capBottomHalf: CGFloat = 24
    static let baseTopHalf: CGFloat = 35, baseBottomHalf: CGFloat = 62
    static let step: CGFloat = 0.5

    /// Interior half-width of the bottle: narrow at the top, widest low down, like a classic lamp.
    static func half(_ y: CGFloat) -> CGFloat {
        let u = min(1, max(0, (y - top) / (bottom - top)))
        var w = 21 + 27 * pow(u, 0.8)
        if u > 0.82 { let t = (u - 0.82) / 0.18; w -= 7 * t * t }
        return w
    }
}

struct LavaStyle { let name: String; let wax: RGB; let liquid: RGB }
let lavaStyles: [LavaStyle] = [
    .init(name: "Classic", wax: RGB(1.0, 0.46, 0.10), liquid: RGB(0.78, 0.16, 0.44)),
    .init(name: "Classic Orange", wax: RGB(1.0, 0.42, 0.12), liquid: RGB(0.98, 0.78, 0.30)),
    .init(name: "Ocean Blue", wax: RGB(0.25, 0.64, 1.0), liquid: RGB(0.42, 0.20, 0.62)),
    .init(name: "Hot Pink", wax: RGB(1.0, 0.34, 0.63), liquid: RGB(0.28, 0.17, 0.52)),
    .init(name: "Lime", wax: RGB(0.64, 1.0, 0.30), liquid: RGB(0.08, 0.32, 0.52)),
    .init(name: "Sunset Red", wax: RGB(1.0, 0.28, 0.20), liquid: RGB(0.96, 0.56, 0.22)),
    .init(name: "Aqua", wax: RGB(0.32, 0.95, 0.86), liquid: RGB(0.12, 0.17, 0.44)),
    .init(name: "Violet", wax: RGB(0.78, 0.48, 1.0), liquid: RGB(0.10, 0.28, 0.48)),
]

struct WaxDrop {
    var x, y, vy, m: CGFloat
    var phase: CGFloat
    var merging: CGFloat = 0        // 0 while moving, then 0...1 as it melts into a pool
    var m0: CGFloat = 0
    var decor = false               // a warm blob rising from the bottom pool
    var riseTo: CGFloat = 0         // where a rising blob cools and turns back (-1: all the way to the top pool)
    var intoTop = false             // merging into the top pool rather than the bottom one
}

/// Wax moves from a pool hanging at the top to a pool at the bottom, one drip at a time. The top
/// drains at a constant rate into a drip that swells, stretches and lets go when heavy enough.
final class LavaSim: TimerBody {
    let totalMass: CGFloat
    var topMass: CGFloat = 0
    var bottomMass: CGFloat = 0
    // The wax keeps circulating at its own pace whatever the timer length: the pools' levels carry
    // the time, while drips and rising blobs are the lamp's constant motion.
    var pendT: CGFloat = 0, swellTime: CGFloat = 6
    var dripX = L.cx
    var dripSize: CGFloat = 70
    let meanDrip: CGFloat = 70
    var drops: [WaxDrop] = []
    var tails: [(x: CGFloat, y: CGFloat, r: CGFloat, life: CGFloat)] = []
    var time: CGFloat = 0
    var shownTop: CGFloat = 0, shownBot: CGFloat = 0
    var busy = true
    var riseTimer: CGFloat = 10
    var events: [SoundEvent] = []
    var rng = RNG(s: 0x2545_F491_4F6C_DD1D)
    private var areaTop: [CGFloat] = [0], areaBot: [CGFloat] = [0]

    init() {
        var y = LL.top
        while y < LL.bottom { areaTop.append(areaTop.last! + 2 * LL.half(y + LL.step / 2) * LL.step); y += LL.step }
        y = LL.bottom
        while y > LL.top { areaBot.append(areaBot.last! + 2 * LL.half(y - LL.step / 2) * LL.step); y -= LL.step }
        totalMass = areaTop.last! * 0.2
        reset()
    }

    private func height(_ m: CGFloat, _ table: [CGFloat]) -> CGFloat {
        guard m > 0 else { return 0 }
        var lo = 0, hi = table.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if table[mid] < m { lo = mid } else { hi = mid } }
        let t = (m - table[lo]) / max(table[hi] - table[lo], 1e-6)
        return (CGFloat(lo) + t) * LL.step
    }
    func topHeight(_ m: CGFloat) -> CGFloat { height(m, areaTop) }
    func botHeight(_ m: CGFloat) -> CGFloat { height(m, areaBot) }

    var hasTop: Bool { shownTop > 0.4 }
    var hasBottom: Bool { shownBot > 0.4 }
    func topSurface(_ x: CGFloat) -> CGFloat {
        LL.top + shownTop + 1.8 * sin(x * 0.08 + time * 0.5) + 1.1 * sin(x * 0.19 - time * 0.9)
    }
    func bottomSurface(_ x: CGFloat) -> CGFloat {
        LL.bottom - shownBot + 2.0 * sin(x * 0.07 - time * 0.4) + 1.2 * sin(x * 0.16 + time * 0.8)
    }

    var inFlight: Bool { drops.contains { !$0.decor } }

    func configure(forSeconds s: Double) {}

    func reset() {
        topMass = totalMass
        bottomMass = 0
        pendT = 0
        swellTime = 3 + rng.unit() * 2
        drops.removeAll()
        tails.removeAll()
        shownTop = topHeight(topMass)
        shownBot = 0
        dripX = L.cx
        riseTimer = 5
        busy = true
    }

    private func release(scale: CGFloat = 1) {
        let m = dripSize * scale
        let r = sqrt(m / .pi)
        drops.append(WaxDrop(x: dripX, y: topSurface(dripX) + r * 1.25, vy: 4, m: m, phase: rng.unit() * 6))
        tails.append((dripX, topSurface(dripX) + r * 0.4, r * 0.5, 0.9))
        let w = LL.half(LL.top + shownTop)
        dripX = L.cx + rng.signed() * w * 0.4
        dripSize = meanDrip * (0.7 + 0.6 * rng.unit())
        pendT = 0
        swellTime = 3.5 + rng.unit() * 3
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        time += dt
        let flowing = drain > 0
        if flowing {
            let take = min(drain, topMass)
            topMass -= take
            bottomMass += take
        }
        // A drip swells under the top pool and lets go every few seconds while the timer runs.
        if pendT >= 0 {
            if flowing && topMass > 1e-3 && hasTop {
                pendT += dt
                if pendT >= swellTime { release() }
            } else if topMass <= 1e-3 && pendT > 0.3 {
                release(scale: min(1, pendT / swellTime))
                pendT = -1
            }
        }

        var i = 0
        while i < drops.count {
            var d = drops[i]
            let r = sqrt(max(d.m, 0) / .pi)
            var gone = false
            if d.merging == 0 {
                // Warm wax is lighter and rises; cooled wax is heavier and sinks. Both move slowly.
                let rising = d.decor && d.riseTo != 0
                let target: CGFloat = rising ? -14 : 16 + 12 * sqrt(r / 5)
                d.vy += (target - d.vy) * min(1, dt * 1.2)
                d.y += d.vy * dt
                d.x += sin(time * 0.7 + d.phase) * 3 * dt
                d.x = min(max(d.x, L.cx - LL.half(d.y) + r), L.cx + LL.half(d.y) - r)
                if rising {
                    if d.riseTo > 0 && d.y <= d.riseTo { d.riseTo = 0 }                          // cooled: now it sinks
                    if d.riseTo < 0 {
                        if hasTop && d.y - r * 1.1 <= topSurface(d.x) {
                            d.merging = 0.0001; d.m0 = d.m; d.intoTop = true                    // joins the top pool
                            events.append(SoundEvent(kind: .bloop, a: 0.4))
                        } else if !hasTop && d.y <= LL.top + 30 {
                            d.riseTo = 0
                        }
                    }
                } else if d.vy > 0 && d.y + r * 1.1 >= bottomSurface(d.x) {
                    d.merging = 0.0001; d.m0 = d.m
                    events.append(SoundEvent(kind: .bloop, a: Float(min(1, r / 9))))
                }
            } else {
                d.merging += dt / 1.3
                d.m -= min(d.m, d.m0 * dt / 1.3)
                d.y += d.vy * dt * 0.3
                if d.merging >= 1 { gone = true }
            }
            if gone { drops.remove(at: i) } else { drops[i] = d; i += 1 }
        }
        for k in tails.indices.reversed() {
            tails[k].life -= dt
            tails[k].r *= 1 - min(1, dt * 1.6)
            tails[k].y += (topSurface(tails[k].x) - tails[k].y) * min(1, dt * 2)
            if tails[k].life <= 0 { tails.remove(at: k) }
        }

        // Warm blobs lift off the bottom pool: some rise all the way and join the top pool,
        // others cool part-way up and sink back.
        if flowing && hasBottom && shownBot > 6 && drops.filter({ $0.decor }).count < 2 {
            riseTimer -= dt
            if riseTimer <= 0 {
                let m = meanDrip * (0.8 + 0.5 * rng.unit())
                let r = sqrt(m / .pi)
                let x = L.cx + rng.signed() * LL.half(LL.bottom - shownBot) * 0.4
                let y0 = bottomSurface(x) + r * 0.3
                let allTheWay = hasTop && rng.unit() < 0.55
                drops.append(WaxDrop(x: x, y: y0, vy: 0, m: m, phase: rng.unit() * 6, decor: true,
                                     riseTo: allTheWay ? -1 : y0 - 30 - rng.unit() * 60))
                events.append(SoundEvent(kind: .plip))
                riseTimer = 4 + rng.unit() * 6
            }
        }

        let tTop = topHeight(topMass), tBot = botHeight(bottomMass)
        shownTop += (tTop - shownTop) * min(1, dt * 4)
        shownBot += (tBot - shownBot) * min(1, dt * 4)
        busy = flowing || !drops.isEmpty || !tails.isEmpty || abs(tTop - shownTop) > 0.01 || abs(tBot - shownBot) > 0.01
    }

    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        bottomMass += take
        busy = true
    }

    func landAll() {
        drops.removeAll()
        tails.removeAll()
        pendT = 0
        shownTop = topHeight(topMass)
        shownBot = botHeight(bottomMass)
    }

    func flip() {
        landAll()
        swap(&topMass, &bottomMass)
        shownTop = topHeight(topMass)
        shownBot = botHeight(bottomMass)
        busy = true
    }

    /// Metaballs making up the moving wax: (x, y, rx, ry).
    func blobs() -> [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        var b: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
        // Lumps that drift slowly along both pools, so the wax never looks like a flat slab.
        if hasTop && shownTop > 5 {
            for k in 0..<3 {
                let ph = CGFloat(k) * 2.1
                let x = L.cx + sin(time * 0.06 + ph) * LL.half(LL.top + shownTop) * 0.55
                let r = min(9, shownTop * 0.35) * (0.8 + 0.2 * sin(time * 0.3 + ph))
                b.append((x, topSurface(x) - r * 0.3, r * 1.3, r))
            }
        }
        if hasBottom && shownBot > 4 {
            for k in 0..<3 {
                let ph = CGFloat(k) * 2.4 + 1
                let x = L.cx + sin(time * 0.05 + ph) * LL.half(LL.bottom - shownBot) * 0.6
                let r = min(11, shownBot * 0.45 + 3) * (0.8 + 0.2 * sin(time * 0.25 + ph))
                b.append((x, bottomSurface(x) + r * 0.3, r * 1.35, r))
            }
        }
        if pendT > 0.2 && hasTop {
            let p = min(1, pendT / swellTime)
            let r = sqrt(dripSize * (0.15 + 0.85 * p) / .pi)
            let s = topSurface(dripX)
            b.append((dripX, s + r * (0.15 + 1.1 * p), r * (1 - 0.12 * p), r * (1 + 0.35 * p)))
            b.append((dripX, s + r * 0.35, r * 0.6, r * 0.6))
        }
        for d in drops where d.m > 0.2 {
            let r = sqrt(d.m / .pi)
            let wob = sin(time * 2.1 + d.phase)
            b.append((d.x, d.y, r * (0.93 - 0.05 * wob), r * (1.1 + 0.06 * wob)))
        }
        for t in tails where t.r > 0.3 { b.append((t.x, t.y, t.r, t.r * 1.3)) }
        return b
    }
}

/// Renders a static layer into a bitmap at the screen's pixel size (y-down drawing).
func layerImage(_ ps: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
    let w = Int(ceil(L.width * ps)), h = Int(ceil(L.height * ps))
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.translateBy(x: 0, y: CGFloat(h))
    c.scaleBy(x: ps, y: -ps)
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    body(c)
    NSGraphicsContext.current = saved
    return c.makeImage()
}

final class LavaRenderer {
    let sim: LavaSim
    let interior: CGPath
    let outline: CGPath
    let sheen: [CGPath]
    let box = CGRect(x: L.cx - 56, y: LL.top - 3, width: 112, height: LL.bottom - LL.top + 6)
    let step: CGFloat = 1.6
    let nx: Int, ny: Int
    private var field: [Float]
    private var adjA: [Int32], adjB: [Int32], seen: [Bool]
    private var touched: [Int] = []
    var style = lavaStyles[0]
    let space = CGColorSpaceCreateDeviceRGB()

    init(sim: LavaSim) {
        self.sim = sim
        nx = Int(box.width / step) + 1
        ny = Int(box.height / step) + 1
        field = Array(repeating: 0, count: nx * ny)
        adjA = Array(repeating: -1, count: nx * ny * 2)
        adjB = adjA
        seen = Array(repeating: false, count: nx * ny * 2)
        func side(_ inset: CGFloat) -> CGPath {
            var left: [CGPoint] = []
            var y = LL.top - 1
            while y <= LL.bottom + 1.01 { left.append(CGPoint(x: L.cx - LL.half(y) - inset, y: y)); y += 2 }
            let right = left.reversed().map { CGPoint(x: 2 * L.cx - $0.x, y: $0.y) }
            let p = CGMutablePath()
            Renderer.smooth(p, left, move: true)
            p.addLine(to: right[0])
            Renderer.smooth(p, right, move: false)
            p.closeSubpath()
            return p
        }
        interior = side(0)
        outline = side(1.6)
        let ys = stride(from: LL.top + 16, through: LL.bottom - 22, by: 2).map { $0 }
        let pl = CGMutablePath(), pr = CGMutablePath()
        Renderer.smooth(pl, ys.map { CGPoint(x: L.cx - (LL.half($0) + 1.6) * 0.78, y: $0) }, move: true)
        Renderer.smooth(pr, ys.map { CGPoint(x: L.cx + (LL.half($0) + 1.6) * 0.88, y: $0) }, move: true)
        sheen = [pl, pr]
    }

    private func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
    }

    /// The wax outline: an implicit surface (top pool + bottom pool + metaballs), traced with marching squares.
    func waxPath() -> CGPath {
        let st = step
        let hasT = sim.hasTop, hasB = sim.hasBottom
        for i in 0..<nx {
            let x = box.minX + CGFloat(i) * st
            let yT = sim.topSurface(x), yB = sim.bottomSurface(x)
            for j in 0..<ny {
                let y = box.minY + CGFloat(j) * st
                var v: CGFloat = 0
                if hasT {
                    let d = (yT - y) / 4
                    v += d > 1.3 ? 3.7 : (d < -5 ? 0 : exp(d))
                }
                if hasB {
                    let d = (y - yB) / 4
                    v += d > 1.3 ? 3.7 : (d < -5 ? 0 : exp(d))
                }
                field[j * nx + i] = Float(v)
            }
        }
        for (bx, by, rx, ry) in sim.blobs() {
            let sx = rx * 1.6, sy = ry * 1.6
            let i0 = max(0, Int((bx - sx - box.minX) / st)), i1 = min(nx - 1, Int((bx + sx - box.minX) / st) + 1)
            let j0 = max(0, Int((by - sy - box.minY) / st)), j1 = min(ny - 1, Int((by + sy - box.minY) / st) + 1)
            if i0 > i1 || j0 > j1 { continue }
            for j in j0...j1 {
                let dy = (box.minY + CGFloat(j) * st - by) / ry
                for i in i0...i1 {
                    let dx = (box.minX + CGFloat(i) * st - bx) / rx
                    let d2 = dx * dx + dy * dy
                    if d2 < 2.56 { let k = 1 - d2 / 2.56; field[j * nx + i] += Float(k * k / 0.3713) }
                }
            }
        }
        for i in 0..<nx { field[i] = 0; field[(ny - 1) * nx + i] = 0 }
        for j in 0..<ny { field[j * nx] = 0; field[j * nx + nx - 1] = 0 }
        return trace()
    }

    private func edgePoint(_ e: Int) -> CGPoint {
        let cell = e >> 1, i = cell % nx, j = cell / nx
        let a = field[cell]
        if e & 1 == 0 {
            let b = field[cell + 1]
            let t = CGFloat((1 - a) / (b - a))
            return CGPoint(x: box.minX + (CGFloat(i) + t) * step, y: box.minY + CGFloat(j) * step)
        } else {
            let b = field[cell + nx]
            let t = CGFloat((1 - a) / (b - a))
            return CGPoint(x: box.minX + CGFloat(i) * step, y: box.minY + (CGFloat(j) + t) * step)
        }
    }

    private func link(_ a: Int, _ b: Int) {
        if adjA[a] < 0 { adjA[a] = Int32(b); touched.append(a) } else { adjB[a] = Int32(b) }
        if adjA[b] < 0 { adjA[b] = Int32(a); touched.append(b) } else { adjB[b] = Int32(a) }
    }

    private func trace() -> CGPath {
        for e in touched { adjA[e] = -1; adjB[e] = -1; seen[e] = false }
        touched.removeAll(keepingCapacity: true)
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let c = j * nx + i
                let f0 = field[c], f1 = field[c + 1], f2 = field[c + nx + 1], f3 = field[c + nx]
                let idx = (f0 >= 1 ? 1 : 0) | (f1 >= 1 ? 2 : 0) | (f2 >= 1 ? 4 : 0) | (f3 >= 1 ? 8 : 0)
                if idx == 0 || idx == 15 { continue }
                let eT = c * 2, eB = (c + nx) * 2, eL = c * 2 + 1, eR = (c + 1) * 2 + 1
                let center = (f0 + f1 + f2 + f3) / 4 >= 1
                switch idx {
                case 1, 14: link(eL, eT)
                case 2, 13: link(eT, eR)
                case 3, 12: link(eL, eR)
                case 4, 11: link(eR, eB)
                case 6, 9: link(eT, eB)
                case 7, 8: link(eL, eB)
                case 5: if center { link(eT, eR); link(eB, eL) } else { link(eL, eT); link(eR, eB) }
                case 10: if center { link(eL, eT); link(eR, eB) } else { link(eT, eR); link(eB, eL) }
                default: break
                }
            }
        }
        let path = CGMutablePath()
        for start in touched where !seen[start] {
            var pts: [CGPoint] = []
            var prev = -1, cur = start
            while true {
                seen[cur] = true
                pts.append(edgePoint(cur))
                let a = Int(adjA[cur]), b = Int(adjB[cur])
                let nxt = a != prev ? a : b
                if nxt < 0 || nxt == start || seen[nxt] { break }
                prev = cur
                cur = nxt
            }
            guard pts.count > 3 else { continue }
            // One round of Chaikin smoothing for soft, liquid edges.
            var sm: [CGPoint] = []
            sm.reserveCapacity(pts.count * 2)
            for k in 0..<pts.count {
                let p = pts[k], q = pts[(k + 1) % pts.count]
                sm.append(CGPoint(x: 0.75 * p.x + 0.25 * q.x, y: 0.75 * p.y + 0.25 * q.y))
                sm.append(CGPoint(x: 0.25 * p.x + 0.75 * q.x, y: 0.25 * p.y + 0.75 * q.y))
            }
            path.addLines(between: sm)
            path.closeSubpath()
        }
        return path
    }

    var waxColors: [CGColor] { [style.wax.scaled(0.86).cg(), style.wax.cg(), style.wax.mixed(RGB(1, 0.96, 0.75), 0.18).cg()] }
    static let waxLocs: [CGFloat] = [0, 0.55, 1]
    static let roundShade = [CGColor(gray: 0, alpha: 0.28), CGColor(gray: 0, alpha: 0.02), CGColor(gray: 0, alpha: 0),
                             CGColor(gray: 0, alpha: 0.05), CGColor(gray: 0, alpha: 0.32)]
    static let roundLocs: [CGFloat] = [0, 0.28, 0.45, 0.75, 1]
    var rimColor: CGColor { style.wax.mixed(RGB(1, 1, 1), 0.5).cg(0.55) }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        let lq = style.liquid
        if ui.shadow > 0 {
            ctx.saveGState()
            ctx.translateBy(x: L.cx, y: LL.baseBottom + 1)
            ctx.scaleBy(x: 1, y: 0.1)
            ctx.drawRadialGradient(gradient([CGColor(gray: 0, alpha: 0.34 * ui.shadow), CGColor(gray: 0, alpha: 0)], [0, 1]),
                                   startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 86, options: [])
            ctx.restoreGState()
        }
        // Coloured liquid, lit from the lamp in the base.
        ctx.saveGState()
        ctx.addPath(interior)
        ctx.clip()
        ctx.drawLinearGradient(gradient([lq.scaled(0.32).cg(0.86), lq.scaled(0.62).cg(0.87), lq.scaled(0.92).cg(0.9)], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: LL.top), end: CGPoint(x: 0, y: LL.bottom), options: [])
        // The bulb in the base lights the liquid from below.
        ctx.drawLinearGradient(gradient([RGB(1, 0.9, 0.6).cg(0), RGB(1, 0.9, 0.6).cg(0.12), RGB(1, 0.92, 0.7).cg(0.4)], [0, 0.6, 1]),
                               start: CGPoint(x: 0, y: LL.top + 60), end: CGPoint(x: 0, y: LL.bottom), options: [])
        grain(ctx, in: interior, rect: box, alpha: 0.04, seed: 31)
        let glowC = CGPoint(x: L.cx, y: LL.bottom + 10)
        ctx.drawRadialGradient(gradient([RGB(1, 0.97, 0.85).cg(0.55), RGB(1, 0.95, 0.8).cg(0.2), RGB(1, 0.95, 0.8).cg(0)], [0, 0.4, 1]),
                               startCenter: glowC, startRadius: 0, endCenter: glowC, endRadius: 120, options: [])
        ctx.restoreGState()
    }

    /// Specular glints on the moving blobs.
    func highlightPath() -> CGPath {
        let p = CGMutablePath()
        for d in sim.drops where d.m > 4 {
            let r = sqrt(d.m / .pi)
            p.addEllipse(in: CGRect(x: d.x - r * 0.55, y: d.y - r * 0.7, width: r * 0.5, height: r * 0.32))
        }
        if sim.pendT > 0.2 && sim.hasTop {
            let pr = min(1, sim.pendT / sim.swellTime)
            let r = sqrt(sim.dripSize * (0.15 + 0.85 * pr) / .pi)
            let cy = sim.topSurface(sim.dripX) + r * (0.15 + 1.1 * pr)
            p.addEllipse(in: CGRect(x: sim.dripX - r * 0.5, y: cy - r * 0.55, width: r * 0.45, height: r * 0.28))
        }
        return p
    }
    static let highlightColor = CGColor(gray: 1, alpha: 0.42)
    static let blobShadeColor = CGColor(gray: 0, alpha: 0.2)

    /// Darker undersides of the blobs, so they read as rounded.
    func blobShadePath() -> CGPath {
        let p = CGMutablePath()
        for d in sim.drops where d.m > 4 {
            let r = sqrt(d.m / .pi)
            p.addEllipse(in: CGRect(x: d.x - r * 0.75 + r * 0.12, y: d.y + r * 0.1, width: r * 1.5, height: r * 1.0))
        }
        return p
    }

    func drawWax(_ ctx: CGContext) {
        let wax = waxPath()
        ctx.saveGState()
        ctx.addPath(interior)
        ctx.clip()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12, color: style.wax.cg(0.9))
        ctx.addPath(wax); ctx.setFillColor(style.wax.cg(0.4)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(wax)
        ctx.clip()
        ctx.drawLinearGradient(gradient(waxColors, LavaRenderer.waxLocs), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        ctx.addPath(blobShadePath()); ctx.setFillColor(LavaRenderer.blobShadeColor); ctx.fillPath()
        ctx.drawLinearGradient(gradient(LavaRenderer.roundShade, LavaRenderer.roundLocs),
                               start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
        ctx.restoreGState()
        ctx.addPath(wax); ctx.setStrokeColor(rimColor); ctx.setLineWidth(1.1); ctx.strokePath()
        ctx.addPath(highlightPath()); ctx.setFillColor(LavaRenderer.highlightColor); ctx.fillPath()
        ctx.restoreGState()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        ctx.setLineCap(.round)
        glassStreak(ctx, in: outline, center: CGPoint(x: L.cx - 8, y: LL.top + 60), length: 170, width: 8, alpha: 0.09)
        ctx.addPath(sheen[0]); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.24)); ctx.setLineWidth(3.2); ctx.strokePath()
        ctx.addPath(sheen[1]); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1.4); ctx.strokePath()
        ctx.setLineJoin(.round)
        ctx.addPath(outline); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.30)); ctx.setLineWidth(2.4); ctx.strokePath()
        ctx.addPath(outline); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55)); ctx.setLineWidth(1.0); ctx.strokePath()
        fresnelRim(ctx, outline, width: 6, alpha: 0.14)
        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: style.wax.cg(ui.glow))
            ctx.addPath(outline); ctx.setStrokeColor(style.wax.cg(0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }

        // Metal cap and base (the frame finish sets the metal colour).
        let metal = [fs.dark.cg(), fs.light.scaled(1.3).cg(), fs.light.cg(), fs.dark.scaled(0.8).cg(), fs.light.scaled(1.1).cg(), fs.dark.cg()]
        let mlocs: [CGFloat] = [0, 0.22, 0.4, 0.62, 0.82, 1]
        func fillMetal(_ p: CGPath, _ x0: CGFloat, _ x1: CGFloat) {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(p); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(p); ctx.clip()
            ctx.drawLinearGradient(gradient(metal, mlocs), start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
            ctx.restoreGState()
            frameTexture(ctx, in: p, rect: p.boundingBox, seed: UInt64(x1))
            ctx.addPath(p); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.15)); ctx.setLineWidth(0.8); ctx.strokePath()
        }
        let cap = CGMutablePath()
        cap.move(to: CGPoint(x: L.cx - LL.capBottomHalf, y: LL.capBottom))
        cap.addLine(to: CGPoint(x: L.cx - LL.capTopHalf, y: LL.capTop + 4))
        cap.addQuadCurve(to: CGPoint(x: L.cx + LL.capTopHalf, y: LL.capTop + 4), control: CGPoint(x: L.cx, y: LL.capTop - 5))
        cap.addLine(to: CGPoint(x: L.cx + LL.capBottomHalf, y: LL.capBottom))
        cap.closeSubpath()
        fillMetal(cap, L.cx - LL.capBottomHalf, L.cx + LL.capBottomHalf)
        let base = CGMutablePath()
        let collar = LL.bottom + 22
        base.move(to: CGPoint(x: L.cx - LL.baseTopHalf, y: LL.bottom))
        base.addLine(to: CGPoint(x: L.cx + LL.baseTopHalf, y: LL.bottom))
        base.addLine(to: CGPoint(x: L.cx + LL.baseTopHalf + 2, y: collar))
        base.addQuadCurve(to: CGPoint(x: L.cx + LL.baseBottomHalf, y: LL.baseBottom - 5), control: CGPoint(x: L.cx + LL.baseTopHalf + 6, y: LL.baseBottom - 18))
        base.addQuadCurve(to: CGPoint(x: L.cx + LL.baseBottomHalf - 5, y: LL.baseBottom), control: CGPoint(x: L.cx + LL.baseBottomHalf, y: LL.baseBottom))
        base.addLine(to: CGPoint(x: L.cx - LL.baseBottomHalf + 5, y: LL.baseBottom))
        base.addQuadCurve(to: CGPoint(x: L.cx - LL.baseBottomHalf, y: LL.baseBottom - 5), control: CGPoint(x: L.cx - LL.baseBottomHalf, y: LL.baseBottom))
        base.addQuadCurve(to: CGPoint(x: L.cx - LL.baseTopHalf - 2, y: collar), control: CGPoint(x: L.cx - LL.baseTopHalf - 6, y: LL.baseBottom - 18))
        base.closeSubpath()
        fillMetal(base, L.cx - LL.baseBottomHalf, L.cx + LL.baseBottomHalf)
        // The bottle's shadow on the base, and a soft reflection down the metal
        ctx.saveGState()
        ctx.addPath(base); ctx.clip()
        ctx.drawLinearGradient(gradient([CGColor(gray: 0, alpha: 0.4), CGColor(gray: 0, alpha: 0)], [0, 1]), start: CGPoint(x: 0, y: LL.bottom), end: CGPoint(x: 0, y: LL.bottom + 14), options: [])
        ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)], [0, 0.5, 1]),
                               start: CGPoint(x: L.cx - 30, y: 0), end: CGPoint(x: L.cx - 6, y: 0), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(cap); ctx.clip()
        ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.2), CGColor(gray: 1, alpha: 0)], [0, 0.5, 1]),
                               start: CGPoint(x: L.cx - 14, y: 0), end: CGPoint(x: L.cx - 2, y: 0), options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25)); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: L.cx - LL.baseTopHalf - 2, y: collar)); ctx.addLine(to: CGPoint(x: L.cx + LL.baseTopHalf + 2, y: collar)); ctx.strokePath()
        for (y, hw) in [(LL.capBottom - 1.5, LL.capBottomHalf + 1), (LL.bottom - 1.5, LL.baseTopHalf + 1)] {
            let r = CGRect(x: L.cx - hw, y: y, width: hw * 2, height: 3.5)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.clip()
            ctx.drawLinearGradient(gradient([fs.ring.scaled(1.18).cg(), fs.ring.scaled(0.72).cg()], [0, 1]),
                                   start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
        }

        drawBadge(ctx, ui: ui, accent: style.wax.mixed(RGB(1, 1, 1), 0.15))
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawWax(ctx)
        drawFront(ctx, ui: ui)
    }
}

/// Live layers for the lava lamp: liquid and metal are bitmaps; the wax shape is updated each frame.
final class LavaScene {
    let container = CALayer()
    private let back = CALayer(), front = CALayer()
    private let interior = CALayer(), interiorMask = CAShapeLayer()
    private let glow = CAShapeLayer(), body = CALayer(), bodyMask = CAShapeLayer(), rim = CAShapeLayer(), glint = CAShapeLayer(), blobShade = CAShapeLayer()
    private let waxGrad = CAGradientLayer(), roundGrad = CAGradientLayer()
    private var backKey = "", frontKey = "", styleKey = ""

    init(renderer r: LavaRenderer) {
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        for l in [back, interior, front] { l.frame = container.bounds; container.addSublayer(l) }
        interiorMask.frame = container.bounds
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: L.height)
        interiorMask.path = r.interior.copy(using: &t)
        interior.mask = interiorMask
        for l in [glow, body, rim, glint] { l.frame = container.bounds; interior.addSublayer(l) }
        blobShade.frame = container.bounds
        blobShade.fillColor = LavaRenderer.blobShadeColor
        body.insertSublayer(blobShade, at: 1)
        glint.fillColor = LavaRenderer.highlightColor
        glow.shadowOffset = .zero
        glow.shadowRadius = 9
        glow.shadowOpacity = 0.9
        // Layers nested below the flipped container are laid out y-up, so mirror the wax box.
        let box = CGRect(x: r.box.minX, y: L.height - r.box.maxY, width: r.box.width, height: r.box.height)
        waxGrad.frame = box
        roundGrad.frame = box
        roundGrad.colors = LavaRenderer.roundShade
        roundGrad.locations = LavaRenderer.roundLocs.map { NSNumber(value: Double($0)) }
        roundGrad.startPoint = CGPoint(x: 0, y: 0.5)
        roundGrad.endPoint = CGPoint(x: 1, y: 0.5)
        body.addSublayer(waxGrad)
        body.addSublayer(roundGrad)
        bodyMask.frame = container.bounds
        bodyMask.fillColor = CGColor(gray: 0, alpha: 1)
        body.mask = bodyMask
        rim.fillColor = nil
        rim.lineWidth = 1.1
        rim.lineJoin = .round
    }

    func update(_ r: LavaRenderer, ui: UIState, in bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, glow, rim, glint, blobShade, bodyMask, interiorMask] { l.contentsScale = ps }
        let sk = r.style.name
        let bk = "\(sk)|\(ps)|\((ui.shadow * 10).rounded())"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(sk)|\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())"
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        if sk != styleKey {
            styleKey = sk
            waxGrad.colors = r.waxColors
            waxGrad.locations = LavaRenderer.waxLocs.map { NSNumber(value: Double($0)) }
            // Unit-space gradient points are y-up here: bright (hot) at the bottom, cooler at the top.
            waxGrad.startPoint = CGPoint(x: 0.5, y: 1)
            waxGrad.endPoint = CGPoint(x: 0.5, y: 0)
            glow.fillColor = r.style.wax.cg(0.4)
            glow.shadowColor = r.style.wax.cg()
            rim.strokeColor = r.rimColor
        }
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: L.height)
        let wax = r.waxPath().copy(using: &t)
        glow.path = wax
        glow.shadowPath = wax
        bodyMask.path = wax
        rim.path = wax
        glint.path = flipY(r.highlightPath())
        blobShade.path = flipY(r.blobShadePath())
        CATransaction.commit()
    }
}

// MARK: - Settings

final class Settings {
    let d = UserDefaults.standard
    var minutes: Double { get { d.object(forKey: "minutes") as? Double ?? 25 } set { d.set(newValue, forKey: "minutes") } }
    var sand: Int { get { min(d.integer(forKey: "sand"), sandStyles.count - 1) } set { d.set(newValue, forKey: "sand") } }
    var frame: Int { get { min(d.integer(forKey: "frame"), frameStyles.count - 1) } set { d.set(newValue, forKey: "frame") } }
    var scaleValue: Double {
        get {
            if let v = d.object(forKey: "scaleValue") as? Double { return v }
            let i = min(max(d.object(forKey: "size") as? Int ?? 1, 0), 2)   // older builds stored a preset index
            return Double(sizeOptions[i].1)
        }
        set { d.set(newValue, forKey: "scaleValue") }
    }
    var task: String { get { d.string(forKey: "task") ?? "" } set { d.set(newValue, forKey: "task") } }
    var chime: Bool { get { d.object(forKey: "chime") as? Bool ?? true } set { d.set(newValue, forKey: "chime") } }
    var onTop: Bool { get { d.object(forKey: "onTop") as? Bool ?? true } set { d.set(newValue, forKey: "onTop") } }
    var style: Int { get { min(max(d.integer(forKey: "style"), 0), StyleKind.allCases.count - 1) } set { d.set(newValue, forKey: "style") } }
    var lava: Int { get { min(d.integer(forKey: "lava"), lavaStyles.count - 1) } set { d.set(newValue, forKey: "lava") } }
    func colour(for k: StyleKind) -> Int {
        switch k {
        case .sand: return sand
        case .lava: return lava
        default: return max(0, d.integer(forKey: "colour_" + k.key))
        }
    }
    func setColour(_ i: Int, for k: StyleKind) {
        switch k {
        case .sand: sand = i
        case .lava: lava = i
        default: d.set(i, forKey: "colour_" + k.key)
        }
    }
    /// Each style remembers its own sound; the default is the style's own live sound.
    func sound(for k: StyleKind) -> Int {
        let key = k == .sand ? "sound" : "sound_" + k.key
        if let v = d.object(forKey: key) as? Int { return min(max(v, 0), NoiseState.names.count - 1) }
        return k.sounds[0]
    }
    func setSound(_ v: Int, for k: StyleKind) { d.set(v, forKey: k == .sand ? "sound" : "sound_" + k.key) }
    var volume: Double { get { d.object(forKey: "volume") as? Double ?? 0.5 } set { d.set(newValue, forKey: "volume") } }
    var soundOnlyRunning: Bool { get { d.object(forKey: "soundOnlyRunning") as? Bool ?? true } set { d.set(newValue, forKey: "soundOnlyRunning") } }
    var origin: NSPoint? {
        get { guard let a = d.array(forKey: "origin") as? [Double], a.count == 2 else { return nil }; return NSPoint(x: a[0], y: a[1]) }
        set { if let p = newValue { d.set([Double(p.x), Double(p.y)], forKey: "origin") } }
    }
}

let sizeOptions: [(String, CGFloat)] = [("Small", 0.6), ("Medium", 0.8), ("Large", 1.0), ("Extra Large", 1.35), ("Huge", 1.75)]

// MARK: - Live scene
// Static parts (glass, frame, texture) are bitmaps composited by the GPU. Each frame only the
// sand outlines, the stream and a few grains are updated, so the hourglass costs very little CPU.

final class Scene {
    let container = CALayer()
    private let back = CALayer(), front = CALayer()
    private let settled = CALayer(), pour = CALayer()
    private let settledMask = CAShapeLayer(), pourMask = CAShapeLayer()
    private var texLayers: [CALayer] = []
    private let rim = CAShapeLayer(), seam = CAShapeLayer(), stream = CAShapeLayer(), light = CAShapeLayer(), dark = CAShapeLayer()
    private var backKey = "", frontKey = ""
    private var tex: CGImage?

    init(renderer r: Renderer) {
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        for (group, mask) in [(pour, pourMask), (settled, settledMask)] {
            group.frame = container.bounds
            let t = CALayer()
            t.frame = r.texRect
            let shade = CAGradientLayer()
            shade.frame = r.texRect
            shade.colors = Renderer.shadeColors
            shade.locations = Renderer.shadeLocs.map { NSNumber(value: Double($0)) }
            shade.startPoint = CGPoint(x: 0, y: 0.5)
            shade.endPoint = CGPoint(x: 1, y: 0.5)
            group.addSublayer(t)
            group.addSublayer(shade)
            mask.frame = container.bounds
            mask.fillColor = CGColor(gray: 0, alpha: 1)
            group.mask = mask
            texLayers.append(t)
        }
        rim.fillColor = nil
        rim.lineWidth = 0.7
        rim.lineJoin = .round
        seam.fillColor = nil
        seam.strokeColor = CGColor(gray: 0, alpha: 0.2)
        seam.lineWidth = 1.4
        for l in [back, pour, settled, seam, rim, stream, dark, light, front] {
            l.frame = container.bounds
            container.addSublayer(l)
        }
    }

    func update(_ r: Renderer, ui: UIState, in bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        r.setTextureScale(texScale)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, rim, stream, light, dark, settledMask, pourMask] { l.contentsScale = ps }

        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())"
        if bk != backKey {
            backKey = bk
            back.contents = r.image(ps) { r.drawBack($0, ui: ui) }
        }
        let fk = "\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())"
        if fk != frontKey {
            frontKey = fk
            front.contents = r.image(ps) { r.drawFront($0, ui: ui) }
        }
        if tex !== r.texture {
            tex = r.texture
            texLayers.forEach { $0.contents = tex }
        }

        let f = r.sandFrame()
        // Shape-layer paths are y-up even inside the flipped container; our geometry is y-down.
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: L.height)
        func up(_ p: CGPath?) -> CGPath? { p?.copy(using: &t) }
        settledMask.path = up(f.settled)
        settled.opacity = Float(f.settledAlpha)
        pour.isHidden = f.pour == nil
        pourMask.path = up(f.pour)
        pour.opacity = Float(f.pourAlpha)
        rim.path = up(f.rim)
        var down = CGAffineTransform(translationX: 0, y: 1.3)
        seam.path = up(f.rim?.copy(using: &down))
        rim.strokeColor = r.rimColor
        stream.path = up(f.stream)
        stream.fillColor = r.streamColor
        light.path = up(f.light)
        light.fillColor = r.lightGrain
        dark.path = up(f.dark)
        dark.fillColor = r.darkGrain
        CATransaction.commit()
    }
}

// MARK: - View

final class HourglassView: NSView {
    weak var app: AppController?
    private var downPoint: NSPoint = .zero
    private var downOrigin: NSPoint = .zero
    private var dragged = false
    private var scrollAcc: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard app?.flipAngle == 0 else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { app?.savePosition(); return }
        if event.clickCount == 2 { app?.flip() } else if event.clickCount == 1 { app?.toggle() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let app else { return }
        let m = NSMenu()
        app.populate(m)
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
            if d != 0 { app?.resize(by: d) }
            return
        }
        scrollAcc += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        while abs(scrollAcc) >= 1 {
            app?.nudgeMinutes(scrollAcc > 0 ? 1 : -1)
            scrollAcc -= scrollAcc > 0 ? 1 : -1
        }
    }
}

// MARK: - App

enum RunState { case idle, running, paused, finishing, done }

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var modules: [Int: StyleModule] = [:]
    let settings = Settings()
    var styleKind: StyleKind { StyleKind(rawValue: settings.style) ?? .sand }
    func module(_ k: StyleKind) -> StyleModule {
        if let m = modules[k.rawValue] { return m }
        let m: StyleModule
        switch k {
        case .sand: m = SandModule()
        case .lava: m = LavaModule()
        case .water: m = WaterModule()
        case .candle: m = CandleModule()
        case .snow: m = SnowModule()
        case .zen: m = ZenModule()
        }
        m.colourIndex = min(max(settings.colour(for: k), 0), m.colours.count - 1)
        m.body.configure(forSeconds: seconds)
        modules[k.rawValue] = m
        return m
    }
    var current: StyleModule { module(styleKind) }
    /// Whatever is keeping time right now: sand, wax, water, a candle, snow or a garden.
    var body: TimerBody { current.body }
    var soundKind: Int { settings.sound(for: styleKind) }
    var flipMode: FlipMode = .rotate
    var flipDone = false
    let noise = NoisePlayer()
    var state = RunState.idle {
        didSet { if oldValue != state { updateStatusTitle(); syncSound() } }
    }
    var panel: NSPanel!
    var view: HourglassView!
    var status: NSStatusItem!
    var link: CADisplayLink?
    var backup: Timer?
    var lastTick = CACurrentMediaTime()
    var flipT: Double?
    var flipAngle: CGFloat = 0
    var restFrame: NSRect = .zero
    var doneAt: Double?
    var previewUntil: Double = 0
    var slideAvg: CGFloat = 0
    var lastLabel = ""
    var forceDraw = true

    var scale: CGFloat { CGFloat(settings.scaleValue) }
    var texPS: CGFloat = 0
    var texWork: DispatchWorkItem?
    var seconds: Double { settings.minutes * 60 }
    var rate: CGFloat { body.totalMass / CGFloat(seconds) }
    var remaining: Double { Double(max(0, body.topMass / rate)) }

    static func emitRate(forSeconds s: Double) -> CGFloat { CGFloat(min(200, 40 + 24000 / max(s, 1))) }

    func applicationDidFinishLaunching(_ note: Notification) {
        let size = NSSize(width: ceil(L.width * scale), height: ceil(L.height * scale))
        var origin = settings.origin ?? defaultOrigin(size)
        if !NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: origin, size: size)) }) {
            origin = defaultOrigin(size)
        }
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = settings.onTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view = HourglassView(frame: NSRect(origin: .zero, size: size))
        view.app = self
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.addSublayer(current.container)
        view.autoresizingMask = [.width, .height]
        view.toolTip = "Click: start / pause\nDouble-click: flip (time used becomes time left)\nScroll: set minutes\n⌥ scroll: resize\nRight-click: options"
        panel.contentView = view
        panel.orderFrontRegardless()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = status.button {
            b.imagePosition = .imageLeading
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        let l = view.displayLink(target: self, selector: #selector(onFrame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        // Keeps time moving while the hourglass is hidden (the display link pauses then).
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if CACurrentMediaTime() - self.lastTick > 0.3 { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        backup = t
        if CommandLine.arguments.contains("--autostart") { startFresh(minutes: settings.minutes) }
        if let f = argValue("--flip-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + f) { [weak self] in self?.flip() }
        }
        // Debug: capture this window after a few seconds and quit (an app may always capture itself).
        if let path = argValue("--selfshot") {
            let delays = (argValue("--after") ?? "5").split(separator: ",").compactMap { Double($0) }
            for (i, delay) in delays.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(self.panel.windowNumber),
                                                                       [.bestResolution, .boundsIgnoreFraming]) else { exit(1) }
                    let out = delays.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "_\(Int(delay * 10)).png")
                    if self.debugTiming { FileHandle.standardError.write("shot \(delay) at \(CACurrentMediaTime() - self.launchTime) opacity \(self.current.container.opacity)\n".data(using: .utf8)!) }
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    if i == delays.count - 1 { exit(0) }
                }
            }
        }
        if let secs = argValue("--pause-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in self?.toggle() }
        }
    }

    func defaultOrigin(_ size: NSSize) -> NSPoint {
        let f = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: f.maxX - size.width - 40, y: f.maxY - size.height - 40)
    }

    @objc func onFrame(_ l: CADisplayLink) { tick() }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0, now - lastTick)
        lastTick = now
        var draw = forceDraw
        forceDraw = false
        if let t0 = flipT {
            let dur: Double = flipMode == .rotate ? 0.75 : (flipMode == .shake ? 0.9 : 0.6)
            let t = min(1, t0 + dt / dur)
            switch flipMode {
            case .rotate:
                flipAngle = .pi * CGFloat(t * t * (3 - 2 * t))
            case .fade:
                current.container.opacity = Float(abs(cos(.pi * t)))
                if t >= 0.5 && !flipDone {
                    flipDone = true; body.flip()
                    if debugTiming { FileHandle.standardError.write("swap \(CACurrentMediaTime() - launchTime) opacity \(current.container.opacity)\n".data(using: .utf8)!) }
                }
            case .shake:
                flipAngle = CGFloat(sin(t * 5 * .pi) * 0.11 * (1 - t))
                if t >= 0.45 && !flipDone { flipDone = true; body.flip() }
            }
            if t >= 1 { finishFlip() } else { flipT = t }
            draw = true
        } else {
            var drain: CGFloat = 0
            if state == .running {
                let want = rate * CGFloat(dt)
                if dt > 0.3 { body.catchUp(want); draw = true } else { drain = want }
            }
            let pdt = CGFloat(min(dt, 1.0 / 20))
            body.update(pdt, drain: drain)
            let now2 = CACurrentMediaTime()
            let pv: Float? = now2 < previewUntil ? Float(min(1, max(0, (now2 - (previewUntil - 4)) / 4))) : nil
            current.feedSound(noise.st, dt: pdt, running: state == .running || state == .finishing, previewPhase: pv)
            if state == .running && body.topMass < 1e-3 { state = .finishing }
            if state == .finishing && !body.inFlight {
                state = .done
                doneAt = now
                if settings.chime { NSSound(named: NSSound.Name("Glass"))?.play() }
            }
            if body.busy { draw = true }
        }
        if let d = doneAt, now - d < 9 { draw = true }
        let label = timeText()
        if label != lastLabel {
            lastLabel = label
            draw = true
            updateStatusTitle()
        }
        if draw && panel.isVisible { renderFrame() }
    }

    func renderFrame() {
        let want = scale * panel.backingScaleFactor
        if texPS == 0 { texPS = want }
        if abs(want - texPS) > 0.01 && texWork == nil {
            // Rebuilding the grain texture takes a moment, so wait until resizing settles.
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.texWork = nil
                self.texPS = self.scale * self.panel.backingScaleFactor
                self.forceDraw = true
            }
            texWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
        current.render(ui: uiState(), bounds: view.bounds, scale: scale, angle: -flipAngle, backing: panel.backingScaleFactor, texScale: texPS)
    }

    func fmt(_ secs: Double) -> String {
        let s = Int(ceil(secs - 0.05))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func timeText() -> String { state == .done ? "Done" : fmt(remaining) }

    func uiState() -> UIState {
        var glow: CGFloat = 0
        if state == .done, let d = doneAt {
            let t = CACurrentMediaTime() - d
            glow = t < 9 ? CGFloat((0.55 + 0.45 * sin(t * 4)) * max(0, 1 - t / 9)) : 0
        }
        return UIState(time: timeText(), paused: state == .paused, dimTime: state == .idle || state == .paused,
                       task: settings.task, frame: frameStyles[settings.frame], glow: glow,
                       shadow: CGFloat(max(0, cos(Double(flipAngle)))), running: state == .running || state == .finishing,
                       done: state == .done)
    }

    func updateStatusIcon() {
        guard let b = status?.button else { return }
        let img = NSImage(systemSymbolName: styleKind.symbol, accessibilityDescription: "Focus Timer")
            ?? NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Focus Timer")
        img?.isTemplate = true
        b.image = img
    }

    func updateStatusTitle() {
        guard let b = status?.button else { return }
        switch state {
        case .idle: b.title = ""
        case .running, .finishing: b.title = " " + timeText()
        case .paused: b.title = " ❚❚ " + timeText()
        case .done: b.title = " Done"
        }
    }

    func syncSound() {
        let running = state == .running || state == .finishing
        let playing = !settings.soundOnlyRunning || running || CACurrentMediaTime() < previewUntil
        noise.set(kind: soundKind, volume: Float(settings.volume), playing: playing)
    }

    /// Let the sound be heard for a few seconds while choosing it, even if the timer is stopped.
    func previewSound() {
        guard soundKind > 0 else { syncSound(); return }
        previewUntil = CACurrentMediaTime() + 4
        syncSound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in self?.syncSound() }
    }

    // MARK: Actions

    @objc func toggle() {
        switch state {
        case .idle, .paused: state = body.topMass > 1e-3 ? .running : .done
        case .running: state = .paused
        case .finishing: break
        case .done: flip()
        }
        forceDraw = true
    }

    @objc func flip() {
        guard flipT == nil else { return }
        body.landAll()
        flipMode = styleKind.flipMode
        flipDone = false
        restFrame = panel.frame
        if flipMode != .fade {
            let side = ceil(hypot(L.width, L.height) * scale) + 4
            panel.setFrame(NSRect(x: restFrame.midX - side / 2, y: restFrame.midY - side / 2, width: side, height: side), display: false)
        }
        if flipMode == .shake { noise.st.post(SoundEvent(kind: .swish)) }
        flipT = 0
        doneAt = nil
        if debugTiming { FileHandle.standardError.write("flip start \(CACurrentMediaTime() - launchTime)\n".data(using: .utf8)!) }
    }
    let launchTime = CACurrentMediaTime()
    let debugTiming = CommandLine.arguments.contains("--debug-timing")

    func finishFlip() {
        if !flipDone { body.flip() }
        flipT = nil
        flipAngle = 0
        current.container.opacity = 1
        panel.setFrame(restFrame, display: true)
        state = body.topMass > 1e-3 ? .running : .done
        forceDraw = true
    }

    @objc func reset() {
        if flipT != nil { return }
        body.reset()
        state = .idle
        doneAt = nil
        forceDraw = true
    }

    func startFresh(minutes: Double) {
        settings.minutes = minutes
        for m in modules.values { m.body.configure(forSeconds: seconds) }
        reset()
        state = .running
    }

    func nudgeMinutes(_ d: Int) {
        guard state == .idle || state == .done, flipT == nil else { return }
        if state == .done { reset() }
        settings.minutes = min(180, max(1, settings.minutes.rounded() + Double(d)))
        for m in modules.values { m.body.configure(forSeconds: seconds) }
        forceDraw = true
    }

    @objc func pickDuration(_ item: NSMenuItem) { startFresh(minutes: Double(item.tag)) }

    @objc func customDuration() {
        guard let text = prompt("Custom duration", info: "Minutes (e.g. 40), or h:mm (e.g. 1:30).",
                                value: String(format: "%g", settings.minutes)) else { return }
        var mins: Double?
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let h = parts[0], let m = parts[1] { mins = h * 60 + m } else if parts.count == 1 { mins = parts[0] }
        if let m = mins, m > 0 { startFresh(minutes: min(720, max(0.25, m))) }
    }

    @objc func setTask() {
        guard let t = prompt("Focus task", info: "Shown on the timer. Leave blank to clear.", value: settings.task) else { return }
        settings.task = t.trimmingCharacters(in: .whitespacesAndNewlines)
        forceDraw = true
    }

    func prompt(_ title: String, info: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    @objc func pickColour(_ item: NSMenuItem) {
        current.colourIndex = item.tag
        settings.setColour(item.tag, for: styleKind)
        forceDraw = true
    }

    /// Switch styles, carrying over how far through the timer we are.
    @objc func pickStyle(_ item: NSMenuItem) {
        guard let k = StyleKind(rawValue: item.tag), k != styleKind, flipT == nil else { return }
        let old = body
        old.landAll()
        let spent = old.totalMass > 0 ? 1 - old.topMass / old.totalMass : 0
        current.container.removeFromSuperlayer()
        settings.style = k.rawValue
        let m = current
        m.body.configure(forSeconds: seconds)
        m.body.reset()
        if spent > 0 { m.body.catchUp(spent * m.body.totalMass); m.body.landAll() }
        view.layer?.addSublayer(m.container)
        if state == .finishing { state = .done }
        updateStatusIcon()
        syncSound()
        forceDraw = true
    }

    @objc func pickFrame(_ item: NSMenuItem) { settings.frame = item.tag; forceDraw = true }

    @objc func pickSize(_ item: NSMenuItem) { applyScale(sizeOptions[item.tag].1) }

    /// Option + scroll over the hourglass resizes it freely.
    func resize(by steps: CGFloat) { applyScale(scale * pow(1.04, steps)) }

    func applyScale(_ wanted: CGFloat) {
        guard flipT == nil else { return }
        let old = panel.frame
        let screen = panel.screen ?? NSScreen.main
        let maxScale = min(2.5, ((screen?.visibleFrame.height ?? 1400) - 10) / L.height)
        settings.scaleValue = Double(min(max(wanted, 0.45), maxScale))
        let size = NSSize(width: ceil(L.width * scale), height: ceil(L.height * scale))
        var frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        if let vf = screen?.visibleFrame {
            frame.origin.y = max(vf.minY, min(frame.origin.y, vf.maxY - size.height))
            frame.origin.x = max(vf.minX, min(frame.origin.x, vf.maxX - size.width))
        }
        panel.setFrame(frame, display: true)
        savePosition()
        forceDraw = true
    }

    @objc func pickSound(_ item: NSMenuItem) {
        settings.setSound(item.tag, for: styleKind)
        previewSound()
    }

    @objc func toggleSoundOnlyRunning() {
        settings.soundOnlyRunning.toggle()
        syncSound()
    }

    @objc func volumeChanged(_ s: NSSlider) {
        settings.volume = s.doubleValue
        if s.window?.currentEvent?.type == .leftMouseUp || previewUntil < CACurrentMediaTime() { previewSound() } else { syncSound() }
    }

    @objc func toggleChime() { settings.chime.toggle() }

    @objc func toggleOnTop() {
        settings.onTop.toggle()
        panel.level = settings.onTop ? .floating : .normal
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Couldn't change Open at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless(); forceDraw = true }
    }

    func savePosition() { settings.origin = panel.frame.origin }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func item(_ title: String, _ sel: Selector, tag: Int = 0, on: Bool = false, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.tag = tag
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu()
        items.forEach { m.addItem($0) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    private func volumeItem() -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let lo = NSImageView(frame: NSRect(x: 18, y: 7, width: 16, height: 16))
        lo.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        lo.contentTintColor = .secondaryLabelColor
        let s = NSSlider(value: settings.volume, minValue: 0.05, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
        s.frame = NSRect(x: 40, y: 5, width: 150, height: 20)
        s.isContinuous = true
        let hi = NSImageView(frame: NSRect(x: 196, y: 7, width: 22, height: 16))
        hi.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        hi.contentTintColor = .secondaryLabelColor
        [lo, s, hi].forEach { v.addSubview($0) }
        let it = NSMenuItem()
        it.view = v
        return it
    }

    func populate(_ m: NSMenu) {
        let head = NSMenuItem(title: state == .idle ? "Ready · \(fmt(remaining))" : "\(timeText()) left", action: nil, keyEquivalent: "")
        if state == .done { head.title = "Time's up" }
        head.isEnabled = false
        m.addItem(head)
        let primary: String
        switch state {
        case .idle: primary = "Start"
        case .running, .finishing: primary = "Pause"
        case .paused: primary = "Resume"
        case .done: primary = "\(styleKind.flipTitle) & Start Again"
        }
        m.addItem(item(primary, #selector(toggle)))
        m.addItem(item(styleKind.flipTitle, #selector(flip)))
        m.addItem(item("Reset", #selector(reset)))
        m.addItem(.separator())

        var durs = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90].map { mins in
            item(mins == 25 ? "25 min · Pomodoro" : "\(mins) min", #selector(pickDuration(_:)), tag: mins,
                 on: abs(settings.minutes - Double(mins)) < 0.01)
        }
        durs.append(.separator())
        durs.append(item("Custom…", #selector(customDuration)))
        m.addItem(submenu("Start a Timer", durs))
        m.addItem(item(settings.task.isEmpty ? "Set Focus Task…" : "Focus Task: \(settings.task)…", #selector(setTask)))
        m.addItem(.separator())

        func header(_ t: String) -> NSMenuItem {
            let h = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            return h
        }
        let chosen = soundKind
        func soundItem(_ k: Int) -> NSMenuItem { item(NoiseState.names[k], #selector(pickSound(_:)), tag: k, on: k == chosen) }
        var sounds = [soundItem(0), .separator(), header(styleKind.title)]
        sounds += styleKind.sounds.map(soundItem)
        sounds += [.separator(), header("Ambient")]
        sounds += NoiseState.ambientKinds.map(soundItem)
        sounds.append(.separator())
        sounds.append(item("Only While Timer Runs", #selector(toggleSoundOnlyRunning), on: settings.soundOnlyRunning))
        sounds.append(.separator())
        sounds.append(volumeItem())
        let soundItem = submenu("Sound", sounds)
        soundItem.image = NSImage(systemSymbolName: chosen == 0 ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: nil)
        m.addItem(soundItem)

        m.addItem(submenu("Style", StyleKind.allCases.map { k in
            let it = item(k.title, #selector(pickStyle(_:)), tag: k.rawValue, on: k == styleKind)
            it.image = NSImage(systemSymbolName: k.symbol, accessibilityDescription: nil)
            return it
        }))
        let cur = current
        m.addItem(submenu(cur.colourTitle, cur.colours.enumerated().map { i, c in
            let it = item(c.0, #selector(pickColour(_:)), tag: i, on: i == cur.colourIndex)
            it.image = swatch(c.1)
            return it
        }))
        m.addItem(submenu("Frame", frameStyles.enumerated().map { i, f in
            let it = item(f.name, #selector(pickFrame(_:)), tag: i, on: i == settings.frame)
            it.image = swatch(f.light)
            return it
        }))
        var sizes = sizeOptions.enumerated().map { i, s in item(s.0, #selector(pickSize(_:)), tag: i, on: abs(scale - s.1) < 0.01) }
        sizes.append(.separator())
        let hint = NSMenuItem(title: "Any size: hold ⌥ and scroll on the timer", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sizes.append(hint)
        m.addItem(submenu("Size", sizes))
        m.addItem(item("Chime When Done", #selector(toggleChime), on: settings.chime))
        m.addItem(item("Keep on Top", #selector(toggleOnTop), on: settings.onTop))
        m.addItem(item("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        m.addItem(.separator())
        m.addItem(item(panel.isVisible ? "Hide Timer" : "Show Timer", #selector(toggleVisible)))
        m.addItem(NSMenuItem(title: "Quit Focus Timer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func swatch(_ c: RGB) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSColor(cgColor: c.cg())!.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}

// MARK: - Headless checks (render a still, measure the noise)

func renderPNG(path: String, progress: Double, icon: Bool, sandIndex: Int, frameIndex: Int, minutes: Double) {
    let sim = SandSim()
    let duration = minutes * 60
    sim.emitRate = AppController.emitRate(forSeconds: duration)
    let rate = sim.totalMass / CGFloat(duration)
    var t = 0.0
    let dt = 1.0 / 60
    while t < progress * duration || (progress >= 1 && sim.busy) {
        sim.update(CGFloat(dt), drain: t < duration ? rate * CGFloat(dt) : 0)
        t += dt
        if t > duration + 30 { break }
    }
    let r = Renderer(sim: sim)
    r.setSand(sandStyles[sandIndex].color)
    let px = icon ? 1024 : Int(L.width * 3), py = icon ? 1024 : Int(L.height * 3)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(py))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    if icon {
        let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(bg)
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
        ctx.restoreGState()
        let s = 740 / L.height
        ctx.translateBy(x: 512 - L.cx * s, y: 512 - L.cy * s)
        ctx.scaleBy(x: s, y: s)
        ctx.clip(to: CGRect(x: 0, y: 0, width: L.ow, height: L.height))
    } else {
        ctx.setFillColor(CGColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: py))
        ctx.scaleBy(x: 3, y: 3)
    }
    let s = Int(ceil(Double(sim.topMass / rate)))
    r.draw(ctx, ui: UIState(time: progress >= 1 ? "Done" : String(format: "%02d:%02d", s / 60, s % 60), paused: false,
                            dimTime: false, task: icon ? "" : "Deep work", frame: frameStyles[frameIndex], glow: 0, shadow: icon ? 0 : 1))
    NSGraphicsContext.current = nil
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func brightCurve() {
    for minutes in [5.0, 25.0] {
        let sim = SandSim()
        let duration = minutes * 60
        sim.emitRate = AppController.emitRate(forSeconds: duration)
        let rate = sim.totalMass / CGFloat(duration)
        let dt: CGFloat = 1.0 / 60
        var line = String(format: "%.0f min:", minutes)
        let marks: [Double] = [0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 0.99]
        var mi = 0
        for f in 0..<Int(duration * 60) {
            let t = Double(f) / 60 / duration
            if mi < marks.count && t >= marks[mi] { line += String(format: " %.1f%%=%.2f", marks[mi] * 100, sim.impactBrightness); mi += 1 }
            sim.update(dt, drain: rate * dt)
        }
        print(line)
    }
}

func slideStats() {
    for minutes in [5.0, 25.0] {
        let sim = SandSim()
        let duration = minutes * 60
        sim.emitRate = AppController.emitRate(forSeconds: duration)
        let rate = sim.totalMass / CGFloat(duration)
        var v: [CGFloat] = [], landed: [Int] = []
        let dt: CGFloat = 1.0 / 60
        for f in 0..<Int(duration * 60) {
            sim.update(dt, drain: rate * dt)
            if f % 7 == 0 { v.append(sim.slideRate); landed.append(sim.landedCount) }
        }
        v.sort()
        func q(_ p: Double) -> CGFloat { v[min(v.count - 1, Int(Double(v.count) * p))] }
        print(String(format: "%.0f min: slide p50 %.2f p90 %.2f p99 %.2f max %.2f | landed/frame avg %.2f emitRate %.0f", minutes,
                     q(0.5), q(0.9), q(0.99), v.last!, Double(landed.reduce(0, +)) / Double(landed.count), sim.emitRate))
    }
}

/// A short demo of the live sound compressing a whole timer: grains on glass gliding to grains on sand.
func liveDemo(_ path: String, kind: Int) {
    let secs = 24, sr = 44100, n = secs * sr
    let st = NoiseState()
    st.kind = kind; st.pending = kind; st.configure(kind); st.gain = 0; st.target = 1; st.volume = 0.9
    st.liveFlow = 1; st.sFlow = 1
    var data = Data()
    let chunk = 441
    let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    for c in 0..<(n / chunk) {
        let t = Double(c * chunk) / Double(n)
        let b = Float(max(0, 1 - pow(t, 0.55) * 1.05))        // bright start, then a gradual glide
        st.liveBright = b; st.liveFall = 0.3 + 0.7 * b
        if t > 0.94 { st.target = 0 }
        st.render(l, r, chunk)
        for i in 0..<chunk {
            for v in [l[i], r[i]] {
                var s = Int16(max(-1, min(1, v * 1.6)) * 32767)
                withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
            }
        }
    }
    var h = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
    h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + data.count)); h.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
    h.append("data".data(using: .ascii)!); u32(UInt32(data.count))
    try? (h + data).write(to: URL(fileURLWithPath: path))
}

func renderLavaPNG(path: String, progress: Double, minutes: Double, styleIndex: Int, frameIndex: Int) {
    let sim = LavaSim()
    let duration = minutes * 60
    sim.configure(forSeconds: duration)
    let rate = sim.totalMass / CGFloat(duration)
    var t = 0.0
    let dt = 1.0 / 60
    while t < progress * duration || (progress >= 1 && sim.busy) {
        sim.update(CGFloat(dt), drain: t < duration ? rate * CGFloat(dt) : 0)
        t += dt
        if t > duration + 30 { break }
    }
    let r = LavaRenderer(sim: sim)
    r.style = lavaStyles[styleIndex]
    let px = Int(L.width * 3), py = Int(L.height * 3)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(py))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.setFillColor(CGColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: py))
    ctx.scaleBy(x: 3, y: 3)
    let s = Int(ceil(Double(sim.topMass / rate)))
    r.draw(ctx, ui: UIState(time: progress >= 1 ? "Done" : String(format: "%02d:%02d", s / 60, s % 60), paused: false,
                            dimTime: false, task: "Deep work", frame: frameStyles[frameIndex], glow: 0, shadow: 1))
    NSGraphicsContext.current = nil
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func renderStylePNG(path: String, style: Int, progress: Double, minutes: Double, colour: Int, frameIndex: Int, lit: Bool) {
    let k = StyleKind(rawValue: style) ?? .sand
    let m: StyleModule
    switch k {
    case .sand: m = SandModule()
    case .lava: m = LavaModule()
    case .water: m = WaterModule()
    case .candle: m = CandleModule()
    case .snow: m = SnowModule()
    case .zen: m = ZenModule()
    }
    m.colourIndex = min(max(colour, 0), m.colours.count - 1)
    let duration = minutes * 60
    m.body.configure(forSeconds: duration)
    m.body.reset()
    let rate = m.body.totalMass / CGFloat(duration)
    var t = 0.0
    let dt = 1.0 / 60
    while t < progress * duration || (progress >= 1 && m.body.busy) {
        m.body.update(CGFloat(dt), drain: t < duration && lit ? rate * CGFloat(dt) : 0)
        t += dt
        if t > duration + 30 { break }
    }
    // Optionally keep going with the timer stopped (to catch smoke, ripples settling, and so on).
    var extra = Double(argValue("--extra") ?? "0") ?? 0
    while extra > 0 { m.body.update(CGFloat(dt), drain: 0); extra -= dt }
    let px = Int(L.width * 3), py = Int(L.height * 3)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(py))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.setFillColor(CGColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: py))
    ctx.scaleBy(x: 3, y: 3)
    let s = Int(ceil(Double(m.body.topMass / rate)))
    m.still(ctx, ui: UIState(time: progress >= 1 ? "Done" : String(format: "%02d:%02d", s / 60, s % 60), paused: false,
                             dimTime: !lit, task: "Deep work", frame: frameStyles[frameIndex], glow: 0, shadow: 1,
                             running: lit && progress < 1, done: progress >= 1))
    NSGraphicsContext.current = nil
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// A short demo of one of the style sounds, with the events a running timer would send.
func soundDemo(_ path: String, kind: Int, seconds: Int = 16) {
    let sr = 44100, n = seconds * sr
    let st = NoiseState()
    st.kind = kind; st.pending = kind; st.configure(kind); st.gain = 0; st.target = 1; st.volume = 0.9
    st.ex.inFlow = 1; st.ex.inGust = 0.3; st.ex.inAir = 1; st.ex.inFill = 0.5
    var data = Data()
    let chunk = 441
    let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    var lastTick = -1
    for c in 0..<(n / chunk) {
        let t = Float(c * chunk) / Float(sr)
        let tick = Int(t * 10)
        if tick != lastTick {
            lastTick = tick
            switch kind {
            case 9: if tick % 28 == 12 { st.post(SoundEvent(kind: .bloop, a: 0.8)) }; if tick == 70 || tick == 130 { st.post(SoundEvent(kind: .plip)) }
            case 10: if tick % 21 == 5 { st.post(SoundEvent(kind: .drop, a: t / Float(seconds), b: 1)) }
            case 12: if tick == 3 { st.post(SoundEvent(kind: .light)) }; if tick == (seconds - 3) * 10 { st.post(SoundEvent(kind: .extinguish)); st.ex.inFlow = 0 }
                st.ex.inGust = tick % 40 < 8 ? 0.8 : 0.1
            case 13: st.ex.inAir = 1 - t / Float(seconds); if tick == 5 { st.post(SoundEvent(kind: .swish)) }
            case 14: st.ex.inFill = (t.truncatingRemainder(dividingBy: 7)) / 7
                if tick % 70 == 0 && tick > 0 { st.post(SoundEvent(kind: .pour, a: 1)) }
                if tick % 70 == 15 && tick > 15 { st.post(SoundEvent(kind: .tock)) }
            default: break
            }
        }
        if t > Float(seconds) - 1.2 { st.target = 0 }
        st.render(l, r, chunk)
        for i in 0..<chunk {
            for v in [l[i], r[i]] {
                var s = Int16(max(-1, min(1, v * 1.6)) * 32767)
                withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
            }
        }
    }
    var h = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
    h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + data.count)); h.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
    h.append("data".data(using: .ascii)!); u32(UInt32(data.count))
    try? (h + data).write(to: URL(fileURLWithPath: path))
}

func noiseTest() {
    let n = 44100 * 20
    let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
    for k in 1..<NoiseState.names.count {
        let st = NoiseState()
        st.kind = k; st.pending = k; st.gain = 1; st.target = 1; st.volume = 1
        st.configure(k)
        st.liveFlow = 0.8; st.liveBright = 0.4; st.liveFall = 0.6; st.liveSlide = 0.1
        if k >= 9 {
            // Feed the style sounds the events they would get from a running timer.
            st.ex.inFlow = 1; st.ex.inGust = 0.3; st.ex.inAir = 1; st.ex.inFill = 0.5
            st.ex.sFlow = 1; st.ex.sAir = 1
            let chunk = 4410
            var t: Float = 0
            var i = 0
            while i < n {
                let m = min(chunk, n - i)
                let tick = Int((t * 10).rounded())
                switch k {
                case 9: if tick % 30 == 20 { st.post(SoundEvent(kind: .bloop, a: 0.8)) }; if tick == 95 { st.post(SoundEvent(kind: .plip)) }
                case 10: if tick % 23 == 5 { st.post(SoundEvent(kind: .drop, a: t / 20, b: 1)) }
                case 12: if tick == 5 { st.post(SoundEvent(kind: .light)) }
                case 13: st.ex.inAir = 1 - t / 20; if tick == 30 { st.post(SoundEvent(kind: .swish)) }
                case 14: st.ex.inFill = (t.truncatingRemainder(dividingBy: 8)) / 8
                    if tick % 80 == 0 && tick > 0 { st.post(SoundEvent(kind: .pour, a: 1)) }
                    if tick % 80 == 15 && tick > 15 { st.post(SoundEvent(kind: .tock)) }
                default: break
                }
                st.render(l + i, r + i, m)
                i += m
                t += Float(m) / 44100
            }
        } else {
            st.render(l, r, n)
        }
        var sum: Double = 0, peak: Float = 0
        for i in (n / 4)..<n { sum += Double(l[i] * l[i]); peak = max(peak, abs(l[i])) }
        if NoiseState.hourglassKinds.contains(k) {
            for bright: Float in [1, 0.75, 0.5, 0.25, 0] {
                st.liveBright = bright; st.sBright = bright; st.liveFall = 0.3 + 0.7 * bright; st.sFall = st.liveFall
                st.liveFlow = 1; st.sFlow = 1
                st.render(l, r, n)
                var s2: Double = 0, p2: Float = 0
                for i in (n / 4)..<n { s2 += Double(l[i] * l[i]); p2 = max(p2, abs(l[i])) }
                // Spectral centroid ("brightness / pitch" of the sound), from a 4096-point DFT on a few frames.
                var num = 0.0, den = 0.0
                for frame in 0..<6 {
                    let off = n / 2 + frame * 8192
                    for bin in stride(from: 4, to: 1024, by: 4) {
                        var re = 0.0, im = 0.0
                        for j in stride(from: 0, to: 4096, by: 1) {
                            let ph = 2 * Double.pi * Double(bin * j) / 4096
                            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / 4095)
                            re += Double(l[off + j]) * w * cos(ph); im -= Double(l[off + j]) * w * sin(ph)
                        }
                        let mag = re * re + im * im
                        num += mag * Double(bin) * 44100 / 4096; den += mag
                    }
                }
                print(String(format: "  live brightness %.1f  rms %.4f  peak %.3f  centre of sound %.0f Hz", bright, sqrt(s2 / Double(n * 3 / 4)), p2, num / den))
            }
        }
        print(String(format: "%@  rms %.3f (%.1f dBFS)  peak %.3f", NoiseState.names[k], sqrt(sum / Double(n * 3 / 4)),
                     20 * log10(sqrt(sum / Double(n * 3 / 4))), peak))
    }
}

// MARK: - Entry

let args = CommandLine.arguments
func argValue(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
if args.contains("--noise-test") { noiseTest(); exit(0) }
if let p = argValue("--video") {
    do { try VideoRenderer().render(to: p) } catch { print("video failed: \(error)"); exit(1) }
    exit(0)
}
if args.contains("--slide-stats") { slideStats(); exit(0) }
if args.contains("--bright-curve") { brightCurve(); exit(0) }
if let p = argValue("--live-demo") { liveDemo(p, kind: Int(argValue("--kind") ?? "5") ?? 5); exit(0) }
if let p = argValue("--sound-demo") { soundDemo(p, kind: Int(argValue("--kind") ?? "10") ?? 10); exit(0) }
if let path = argValue("--style-snapshot") {
    renderStylePNG(path: path, style: Int(argValue("--style") ?? "2") ?? 2, progress: Double(argValue("--progress") ?? "0.4") ?? 0.4,
                   minutes: Double(argValue("--minutes") ?? "5") ?? 5, colour: Int(argValue("--colour") ?? "0") ?? 0,
                   frameIndex: Int(argValue("--frame") ?? "1") ?? 1, lit: !args.contains("--unlit"))
    exit(0)
}
if let path = argValue("--lava-snapshot") {
    renderLavaPNG(path: path, progress: Double(argValue("--progress") ?? "0.4") ?? 0.4, minutes: Double(argValue("--minutes") ?? "5") ?? 5,
                  styleIndex: Int(argValue("--lava") ?? "0") ?? 0, frameIndex: Int(argValue("--frame") ?? "1") ?? 1)
    exit(0)
}
if let path = argValue("--snapshot") {
    renderPNG(path: path, progress: Double(argValue("--progress") ?? "0.4") ?? 0.4, icon: args.contains("--icon"),
              sandIndex: Int(argValue("--sand") ?? "0") ?? 0, frameIndex: Int(argValue("--frame") ?? "0") ?? 0,
              minutes: Double(argValue("--minutes") ?? "5") ?? 5)
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
