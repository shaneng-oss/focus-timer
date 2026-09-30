// Snow globe: freshly shaken, the globe is full of swirling snow that settles over the timer,
// burying a small pine wood. Flakes drift on a slow wind and pile up; the pile creeps like snow.

import AppKit
import QuartzCore

enum SL {
    static let cx = L.cx, cy: CGFloat = 148, R: CGFloat = 74
    static let collarY: CGFloat = 214, collarRX: CGFloat = 46, collarRY: CGFloat = 8
    static let pedestalBottom: CGFloat = 296
    static let groundY: CGFloat = 196
    static let dx: CGFloat = 2

    static func top(_ x: CGFloat) -> CGFloat {           // upper glass boundary at x
        let d = x - cx
        return cy - sqrt(max(0, R * R - d * d))
    }
    static func ground(_ x: CGFloat) -> CGFloat { groundY + 3 * sin((x - cx) * 0.045) - 2 * cos((x - cx) * 0.11) }
    static func inside(_ x: CGFloat, _ y: CGFloat) -> Bool { (x - cx) * (x - cx) + (y - cy) * (y - cy) < (R - 1.5) * (R - 1.5) }
}

struct SkyStyle { let name: String; let top: RGB; let mid: RGB; let bottom: RGB; let day: Bool }
let skyStyles: [SkyStyle] = [
    .init(name: "Twilight", top: RGB(0.10, 0.11, 0.32), mid: RGB(0.30, 0.22, 0.48), bottom: RGB(0.62, 0.42, 0.55), day: false),
    .init(name: "Midnight", top: RGB(0.02, 0.04, 0.14), mid: RGB(0.07, 0.11, 0.28), bottom: RGB(0.14, 0.22, 0.42), day: false),
    .init(name: "Dawn", top: RGB(0.42, 0.34, 0.60), mid: RGB(0.85, 0.55, 0.60), bottom: RGB(0.99, 0.80, 0.62), day: true),
    .init(name: "Aurora", top: RGB(0.02, 0.07, 0.18), mid: RGB(0.05, 0.40, 0.42), bottom: RGB(0.10, 0.28, 0.40), day: false),
    .init(name: "Frost", top: RGB(0.58, 0.70, 0.86), mid: RGB(0.76, 0.84, 0.94), bottom: RGB(0.92, 0.95, 0.99), day: true),
]

struct Flake { var x, y, vx, vy, r, m, phase: CGFloat }
struct Mote { var x, y, phase, r: CGFloat }

final class SnowSim: TimerBody {
    let N: Int
    let x0: CGFloat
    var totalMass: CGFloat = 1
    var topMass: CGFloat = 1
    var bottomMass: CGFloat = 0
    var pile: [CGFloat]                 // height above the ground, per column
    var capH: [CGFloat]
    var flakes: [Flake] = []
    var motes: [Mote] = []
    var flakeMass: CGFloat = 1
    var spawnAcc: CGFloat = 0
    var wind: CGFloat = 0, windT: CGFloat = 0
    var stir: CGFloat = 0                // extra turbulence right after a shake
    var drift: CGFloat = 1               // haze motion fades out while the timer is stopped
    var time: CGFloat = 0
    var busy = true
    var settling: CGFloat = 0
    var rng = RNG(s: 0x5A5A_1234_9876_ABCD)
    var pointer: CGPoint?
    var pointerV = CGPoint.zero

    init() {
        N = Int(SL.R * 2 / SL.dx) + 1
        x0 = SL.cx - SL.R
        pile = Array(repeating: 0, count: N)
        capH = pile
        var cap: CGFloat = 0
        for i in 0..<N {
            let x = x0 + CGFloat(i) * SL.dx
            capH[i] = max(0, SL.ground(x) - SL.top(x) - 1.5)
            cap += capH[i] * SL.dx
        }
        totalMass = cap * 0.24
        topMass = totalMass
        for _ in 0..<170 { motes.append(randomMote()) }
        reset()
    }

    private func randomMote() -> Mote {
        for _ in 0..<20 {
            let a = rng.unit() * 2 * .pi, d = sqrt(rng.unit()) * (SL.R - 4)
            let x = SL.cx + cos(a) * d, y = SL.cy + sin(a) * d
            if y < surfaceY(at: x) - 2 { return Mote(x: x, y: y, phase: rng.unit() * 6.3, r: 0.5 + rng.unit() * 0.6) }
        }
        return Mote(x: SL.cx, y: SL.cy - 30, phase: 0, r: 0.6)
    }

    func surfaceY(at x: CGFloat) -> CGFloat {
        let f = min(max((x - x0) / SL.dx, 0), CGFloat(N - 1) - 0.001)
        let i = Int(f), t = f - CGFloat(i)
        let h = pile[i] * (1 - t) + pile[i + 1] * t
        return SL.ground(x) - h
    }

    var airborne: CGFloat { max(0, min(1, topMass / totalMass)) }
    var inFlight: Bool { !flakes.isEmpty }
    func configure(forSeconds s: Double) { flakeMass = totalMass / CGFloat(max(s, 1) * 7) }

    func reset() {
        topMass = totalMass
        bottomMass = 0
        for i in 0..<N { pile[i] = 0 }
        flakes.removeAll()
        spawnAcc = 0
        stir = 0.6
        drift = 1
        busy = true
    }

    private func deposit(_ m: CGFloat, at x: CGFloat) {
        let ci = Int(((x - x0) / SL.dx).rounded())
        var left = m
        for o in -5...5 {
            let k = ci + o
            guard k >= 0 && k < N else { continue }
            let w = exp(-CGFloat(o * o) / 8.5) / 5.13
            let h = min(m * w / SL.dx, capH[k] - pile[k])
            if h > 0 { pile[k] += h; left -= h * SL.dx }
        }
        if left > 1e-6 {
            for k in (0..<N).sorted(by: { abs($0 - N / 2) < abs($1 - N / 2) }) {
                let h = min(left / SL.dx, capH[k] - pile[k])
                if h > 0 { pile[k] += h; left -= h * SL.dx }
                if left <= 1e-6 { break }
            }
        }
    }

    private func relax(passes: Int) -> CGFloat {
        var moved: CGFloat = 0
        for p in 0..<passes {
            let fwd = (p & 1) == 0
            for k in 0..<(N - 1) {
                let i = fwd ? k : N - 2 - k, j = i + 1
                if capH[i] <= 0 || capH[j] <= 0 { continue }
                let si = SL.ground(x0 + CGFloat(i) * SL.dx) - pile[i], sj = SL.ground(x0 + CGFloat(j) * SL.dx) - pile[j]
                let d = sj - si
                if abs(d) / SL.dx <= 0.6 { continue }
                let h = d > 0 ? i : j, l = d > 0 ? j : i
                let q = min((abs(d) - 0.45 * SL.dx) * 0.25, pile[h], capH[l] - pile[l])
                if q > 1e-5 { pile[h] -= q; pile[l] += q; moved += q }
            }
        }
        return moved
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        time += dt
        let flowing = drain > 0
        if flowing {
            let take = min(drain, topMass)
            topMass -= take
            spawnAcc += take
            while spawnAcc >= flakeMass && flakes.count < 140 {
                spawnAcc -= flakeMass
                // Snow settles out of the whole cloud, not just from the top.
                var placed = false
                for _ in 0..<12 {
                    let a = rng.unit() * 2 * .pi, d = sqrt(rng.unit()) * (SL.R - 5)
                    let x = SL.cx + cos(a) * d, y = SL.cy + sin(a) * d
                    if y < surfaceY(at: x) - 6 {
                        let r = 0.9 + rng.unit() * 0.9
                        flakes.append(Flake(x: x, y: y, vx: 0, vy: 0, r: r, m: flakeMass, phase: rng.unit() * 6.3))
                        placed = true
                        break
                    }
                }
                if !placed { bottomMass += flakeMass; deposit(flakeMass, at: SL.cx) }
            }
            if topMass < 1e-6 && spawnAcc > 0 { bottomMass += spawnAcc; deposit(spawnAcc, at: SL.cx); spawnAcc = 0 }
        }
        windT += (rng.signed() * 12 - windT) * min(1, dt * 0.15)
        wind += (windT - wind) * min(1, dt * 0.5)
        stir *= exp(-dt * 0.9)
        drift += ((flowing || stir > 0.05 ? 1 : 0) - drift) * min(1, dt * 0.6)

        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let term = 12 + f.r * 6
            f.vy += (term - f.vy) * min(1, dt * 2)
            f.vx = wind * 0.5 + 6 * sin(time * 1.3 + f.phase) + stir * 40 * sin(time * 5 + f.phase * 3)
            f.x += f.vx * dt
            f.y += f.vy * dt
            let d = f.x - SL.cx
            let lim = sqrt(max(0, (SL.R - 3) * (SL.R - 3) - (f.y - SL.cy) * (f.y - SL.cy)))
            if abs(d) > lim { f.x = SL.cx + (d > 0 ? lim : -lim); }
            if f.y >= surfaceY(at: f.x) - f.r * 0.4 {
                bottomMass += f.m
                deposit(f.m, at: f.x)
                flakes.remove(at: i)
            } else {
                flakes[i] = f
                i += 1
            }
        }
        settling = relax(passes: max(1, Int(dt * 240)))

        // The cursor pushes the snow aside; a fast swipe stirs the whole globe a little.
        if let p = pointer, SL.inside(p.x, p.y) {
            let speed = hypot(pointerV.x, pointerV.y)
            if speed > 600 { stir = max(stir, 0.35) }
            for k in motes.indices {
                let dx = motes[k].x - p.x, dy = motes[k].y - p.y, d = max(1, hypot(dx, dy))
                if d < 30 { let f = (30 - d) / 30 * 60 * dt; motes[k].x += dx / d * f; motes[k].y += dy / d * f }
            }
            for k in flakes.indices {
                let dx = flakes[k].x - p.x, dy = flakes[k].y - p.y, d = max(1, hypot(dx, dy))
                if d < 30 { let f = (30 - d) / 30 * 60 * dt; flakes[k].x += dx / d * f; flakes[k].y += dy / d * f }
            }
            drift = 1
            pointerV = CGPoint(x: pointerV.x * 0.85, y: pointerV.y * 0.85)
        }
        // Suspended snow: slow sinking drift, stirred up by a shake, freezing when the timer stops.
        if drift > 0.01 {
            let amp = drift * (1 + stir * 6)
            for k in motes.indices {
                var m = motes[k]
                m.x += (wind * 0.25 + 3.5 * sin(time * 0.7 + m.phase) + stir * 30 * cos(time * 4 + m.phase * 2)) * amp * dt
                m.y += (1.6 + 2.5 * sin(time * 0.5 + m.phase * 2) + stir * 30 * sin(time * 3.7 + m.phase)) * amp * dt
                if !SL.inside(m.x, m.y) || m.y > surfaceY(at: m.x) - 1.5 { m = randomMote() }
                motes[k] = m
            }
        }
        busy = flowing || !flakes.isEmpty || (drift > 0.01 && airborne > 0.01) || settling > 1e-3 || stir > 0.05 || pointer != nil
    }

    /// Lay `m` of snow onto the ground as an even fall would.
    private func settle(_ m: CGFloat) {
        guard m > 0 else { return }
        bottomMass += m
        for _ in 0..<40 { deposit(m / 40, at: SL.cx + rng.signed() * SL.R * 0.6); _ = relax(passes: 12) }
        _ = relax(passes: 200)
    }

    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        settle(take)
        busy = true
    }

    func landAll() {
        for f in flakes { bottomMass += f.m; deposit(f.m, at: f.x) }
        flakes.removeAll()
        bottomMass += spawnAcc; if spawnAcc > 0 { deposit(spawnAcc, at: SL.cx) }
        spawnAcc = 0
        _ = relax(passes: 200)
    }

    /// A shake: what had settled is thrown back into the air, and what was in the air settles.
    func flip() {
        landAll()
        let pileMass = bottomMass, air = topMass
        for i in 0..<N { pile[i] = 0 }
        bottomMass = 0
        topMass = pileMass
        settle(air)
        stir = 1
        drift = 1
        for k in motes.indices { motes[k] = randomMote() }
        busy = true
    }
}

// MARK: - Rendering

final class SnowRenderer {
    let sim: SnowSim
    var sky = skyStyles[0]
    let globe: CGPath
    let pileBox = CGRect(x: SL.cx - SL.R, y: SL.cy - SL.R, width: SL.R * 2, height: SL.R * 2)

    init(sim: SnowSim) {
        self.sim = sim
        globe = CGPath(ellipseIn: CGRect(x: SL.cx - SL.R, y: SL.cy - SL.R, width: SL.R * 2, height: SL.R * 2), transform: nil)
    }

    static let pileColors: [CGColor] = [RGB(0.99, 0.99, 1.0).cg(), RGB(0.90, 0.93, 0.98).cg(), RGB(0.70, 0.77, 0.90).cg()]
    static let pileLocs: [CGFloat] = [0, 0.35, 1]
    static let pileShadeColors: [CGColor] = [RGB(1, 1, 1).cg(0.12), RGB(1, 1, 1).cg(0), RGB(0.35, 0.45, 0.7).cg(0.16)]
    static let pileShadeLocs: [CGFloat] = [0, 0.4, 1]
    static let flakeColor = CGColor(gray: 1, alpha: 0.92)
    static let moteColor = CGColor(gray: 1, alpha: 0.7)

    func pilePath() -> CGPath {
        let p = CGMutablePath()
        var pts: [CGPoint] = []
        for i in 0..<sim.N {
            let x = sim.x0 + CGFloat(i) * SL.dx
            pts.append(CGPoint(x: x, y: SL.ground(x) - sim.pile[i]))
        }
        // One round of corner-cutting keeps the drifts soft.
        var sm: [CGPoint] = [pts[0]]
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            sm.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
            sm.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
        }
        sm.append(pts[pts.count - 1])
        p.addLines(between: sm)
        p.addLine(to: CGPoint(x: SL.cx + SL.R, y: SL.cy + SL.R + 2))
        p.addLine(to: CGPoint(x: SL.cx - SL.R, y: SL.cy + SL.R + 2))
        p.closeSubpath()
        return p
    }

    func surfaceLine() -> CGPath {
        let p = CGMutablePath()
        var pts: [CGPoint] = []
        for i in 0..<sim.N where sim.capH[i] > 0 {
            let x = sim.x0 + CGFloat(i) * SL.dx
            pts.append(CGPoint(x: x, y: SL.ground(x) - sim.pile[i] + 0.4))
        }
        if pts.count > 1 { p.addLines(between: pts) }
        // Glints on the fresh snow
        var g = RNG(s: 0x51AB)
        for _ in 0..<9 {
            let x = SL.cx + g.signed() * (SL.R - 14)
            let y = sim.surfaceY(at: x) + 2 + g.unit() * 6
            if SL.inside(x, y) { p.addEllipse(in: CGRect(x: x - 0.35, y: y - 0.35, width: 0.7, height: 0.7)) }
        }
        return p
    }

    func flakesPath() -> CGPath {
        let p = CGMutablePath()
        for f in sim.flakes { p.addEllipse(in: CGRect(x: f.x - f.r, y: f.y - f.r, width: f.r * 2, height: f.r * 2)) }
        return p
    }
    func motesPath() -> CGPath {
        let p = CGMutablePath()
        let n = Int(CGFloat(sim.motes.count) * pow(sim.airborne, 0.75))
        for m in sim.motes.prefix(n) { p.addEllipse(in: CGRect(x: m.x - m.r, y: m.y - m.r, width: m.r * 2, height: m.r * 2)) }
        return p
    }
    var moteOpacity: Float { Float(0.75 * pow(sim.airborne, 0.6)) }

    private func tree(_ ctx: CGContext, x: CGFloat, h: CGFloat) {
        let base = SL.ground(x)
        let green = sky.day ? RGB(0.12, 0.36, 0.22) : RGB(0.07, 0.24, 0.16)
        ctx.setFillColor(RGB(0.28, 0.18, 0.10).cg())
        ctx.fill(CGRect(x: x - 1.2, y: base - 5, width: 2.4, height: 6))
        for tier in 0..<3 {
            let ty = base - h * (0.25 + 0.35 * CGFloat(tier))          // top of this tier
            let by = base - h * (0.0 + 0.32 * CGFloat(tier))           // bottom of this tier
            let w = h * (0.62 - 0.14 * CGFloat(tier))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: ty))
            p.addLine(to: CGPoint(x: x + w / 2, y: by))
            p.addLine(to: CGPoint(x: x - w / 2, y: by))
            p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(green.cg()); ctx.fillPath()
            // Snow resting on the left edge of each tier
            let s = CGMutablePath()
            s.move(to: CGPoint(x: x, y: ty))
            s.addLine(to: CGPoint(x: x - w / 2, y: by))
            s.addLine(to: CGPoint(x: x - w / 2 + 2.5, y: by))
            s.addLine(to: CGPoint(x: x + 0.5, y: ty + 2.2))
            s.closeSubpath()
            ctx.addPath(s); ctx.setFillColor(CGColor(gray: 1, alpha: 0.85)); ctx.fillPath()
        }
    }

    /// A small log cabin with a lit window.
    private func cabin(_ ctx: CGContext, x: CGFloat) {
        let base = SL.ground(x) + 1
        let w: CGFloat = 32, h: CGFloat = 17
        let body = CGRect(x: x - w / 2, y: base - h, width: w, height: h)
        ctx.saveGState()
        ctx.clip(to: body)
        ctx.drawLinearGradient(makeGradient([RGB(0.45, 0.30, 0.18).cg(), RGB(0.30, 0.19, 0.11).cg()], [0, 1]),
                               start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0), options: [])
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25)); ctx.setLineWidth(0.6)
        for k in 1..<5 { let yy = body.minY + CGFloat(k) * h / 5; ctx.move(to: CGPoint(x: body.minX, y: yy)); ctx.addLine(to: CGPoint(x: body.maxX, y: yy)) }
        ctx.strokePath()
        ctx.restoreGState()
        // Door and window (lit from inside)
        ctx.setFillColor(RGB(0.22, 0.13, 0.07).cg())
        ctx.fill(CGRect(x: x - 4, y: base - 10, width: 6, height: 10))
        let win = CGRect(x: x + 5, y: base - 12.5, width: 7, height: 5.5)
        softLight(ctx, at: CGPoint(x: win.midX, y: win.midY), radius: 14, color: RGB(1, 0.8, 0.4), alpha: 0.55)
        ctx.setFillColor(RGB(1, 0.85, 0.5).cg()); ctx.fill(win)
        ctx.setStrokeColor(RGB(0.25, 0.15, 0.08).cg()); ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: win.midX, y: win.minY)); ctx.addLine(to: CGPoint(x: win.midX, y: win.maxY))
        ctx.move(to: CGPoint(x: win.minX, y: win.midY)); ctx.addLine(to: CGPoint(x: win.maxX, y: win.midY)); ctx.strokePath()
        // Roof with snow, and a chimney
        let roof = CGMutablePath()
        roof.move(to: CGPoint(x: x - w / 2 - 3, y: base - h + 1))
        roof.addLine(to: CGPoint(x: x, y: base - h - 12))
        roof.addLine(to: CGPoint(x: x + w / 2 + 3, y: base - h + 1))
        roof.closeSubpath()
        ctx.addPath(roof); ctx.setFillColor(RGB(0.32, 0.22, 0.14).cg()); ctx.fillPath()
        ctx.setFillColor(RGB(0.35, 0.25, 0.16).cg()); ctx.fill(CGRect(x: x + 8, y: base - h - 11, width: 4, height: 8))
        let snow = CGMutablePath()
        snow.move(to: CGPoint(x: x - w / 2 - 3, y: base - h + 1))
        snow.addLine(to: CGPoint(x: x, y: base - h - 12))
        snow.addLine(to: CGPoint(x: x + w / 2 + 3, y: base - h + 1))
        snow.addLine(to: CGPoint(x: x + w / 2 + 1, y: base - h + 2.5))
        snow.addLine(to: CGPoint(x: x, y: base - h - 8.5))
        snow.addLine(to: CGPoint(x: x - w / 2 - 1, y: base - h + 2.5))
        snow.closeSubpath()
        ctx.addPath(snow); ctx.setFillColor(CGColor(gray: 1, alpha: 0.92)); ctx.fillPath()
    }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        groundShadow(ctx, y: SL.pedestalBottom + 1, strength: ui.shadow, radius: 88)
        // A turned wooden base
        let ped = CGMutablePath()
        ped.move(to: CGPoint(x: SL.cx - 44, y: SL.collarY))
        ped.addLine(to: CGPoint(x: SL.cx + 44, y: SL.collarY))
        ped.addCurve(to: CGPoint(x: SL.cx + 58, y: SL.collarY + 30), control1: CGPoint(x: SL.cx + 46, y: SL.collarY + 12), control2: CGPoint(x: SL.cx + 58, y: SL.collarY + 18))
        ped.addCurve(to: CGPoint(x: SL.cx + 54, y: SL.collarY + 46), control1: CGPoint(x: SL.cx + 58, y: SL.collarY + 38), control2: CGPoint(x: SL.cx + 54, y: SL.collarY + 40))
        ped.addCurve(to: CGPoint(x: SL.cx + 64, y: SL.pedestalBottom - 8), control1: CGPoint(x: SL.cx + 54, y: SL.collarY + 56), control2: CGPoint(x: SL.cx + 64, y: SL.collarY + 62))
        ped.addQuadCurve(to: CGPoint(x: SL.cx + 58, y: SL.pedestalBottom), control: CGPoint(x: SL.cx + 64, y: SL.pedestalBottom))
        ped.addLine(to: CGPoint(x: SL.cx - 58, y: SL.pedestalBottom))
        ped.addQuadCurve(to: CGPoint(x: SL.cx - 64, y: SL.pedestalBottom - 8), control: CGPoint(x: SL.cx - 64, y: SL.pedestalBottom))
        ped.addCurve(to: CGPoint(x: SL.cx - 54, y: SL.collarY + 46), control1: CGPoint(x: SL.cx - 64, y: SL.collarY + 62), control2: CGPoint(x: SL.cx - 54, y: SL.collarY + 56))
        ped.addCurve(to: CGPoint(x: SL.cx - 58, y: SL.collarY + 30), control1: CGPoint(x: SL.cx - 54, y: SL.collarY + 40), control2: CGPoint(x: SL.cx - 58, y: SL.collarY + 38))
        ped.addCurve(to: CGPoint(x: SL.cx - 44, y: SL.collarY), control1: CGPoint(x: SL.cx - 58, y: SL.collarY + 18), control2: CGPoint(x: SL.cx - 46, y: SL.collarY + 12))
        ped.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(ped); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(ped); ctx.clip()
        ctx.drawLinearGradient(makeGradient([fs.dark.scaled(0.7).cg(), fs.light.scaled(1.05).cg(), fs.light.scaled(0.9).cg(), fs.dark.scaled(0.8).cg(), fs.dark.scaled(0.6).cg()], [0, 0.28, 0.45, 0.8, 1]),
                               start: CGPoint(x: SL.cx - 62, y: 0), end: CGPoint(x: SL.cx + 62, y: 0), options: [])
        // Turning grooves
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.28)); ctx.setLineWidth(1)
        for yy in [SL.collarY + 30, SL.collarY + 46, SL.pedestalBottom - 8] as [CGFloat] { ctx.move(to: CGPoint(x: SL.cx - 70, y: yy)); ctx.addLine(to: CGPoint(x: SL.cx + 70, y: yy)) }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1)
        for yy in [SL.collarY + 31.5, SL.collarY + 47.5] as [CGFloat] { ctx.move(to: CGPoint(x: SL.cx - 70, y: yy)); ctx.addLine(to: CGPoint(x: SL.cx + 70, y: yy)) }
        ctx.strokePath()
        ctx.restoreGState()
        frameTexture(ctx, in: ped, rect: ped.boundingBox, seed: 11)
        ctx.saveGState()
        ctx.addPath(ped); ctx.clip()
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)], [0, 1]),
                               start: CGPoint(x: 0, y: SL.collarY + 4), end: CGPoint(x: 0, y: SL.collarY + 20), options: [])
        ctx.restoreGState()

        // Inside the globe: sky, hills, ground, trees, a darkening toward the rim
        ctx.saveGState()
        ctx.addPath(globe); ctx.clip()
        defer { grain(ctx, in: globe, rect: CGRect(x: SL.cx - SL.R, y: SL.cy - SL.R, width: SL.R * 2, height: SL.groundY - SL.cy + SL.R), alpha: 0.035, seed: 41) }
        ctx.drawLinearGradient(makeGradient([sky.top.cg(), sky.mid.cg(), sky.bottom.cg()], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: SL.cy - SL.R), end: CGPoint(x: 0, y: SL.groundY + 4), options: [])
        if !sky.day {
            let moon = CGPoint(x: SL.cx - 34, y: SL.cy - 40)
            ctx.drawRadialGradient(makeGradient([RGB(1, 0.98, 0.9).cg(0.55), RGB(1, 0.98, 0.9).cg(0.12), RGB(1, 1, 1).cg(0)], [0, 0.25, 1]),
                                   startCenter: moon, startRadius: 0, endCenter: moon, endRadius: 34, options: [])
            ctx.setFillColor(RGB(1, 0.98, 0.9).cg(0.9))
            ctx.fillEllipse(in: CGRect(x: moon.x - 5, y: moon.y - 5, width: 10, height: 10))
            var st = RNG(s: 0xBEEF)
            for _ in 0..<26 {
                let a = st.unit() * 2 * .pi, d = sqrt(st.unit()) * (SL.R - 8)
                let x = SL.cx + cos(a) * d, y = SL.cy + sin(a) * d
                if y < SL.groundY - 30 && hypot(x - moon.x, y - moon.y) > 14 {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 0.35 + 0.5 * st.unit()))
                    ctx.fillEllipse(in: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                }
            }
        }
        for (hx, hw, hh, a) in [(SL.cx - 30, 70, 22, 0.55), (SL.cx + 36, 80, 28, 0.7)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let hill = CGMutablePath()
            hill.move(to: CGPoint(x: hx - hw, y: SL.groundY + 6))
            hill.addQuadCurve(to: CGPoint(x: hx + hw, y: SL.groundY + 6), control: CGPoint(x: hx, y: SL.groundY - hh * 2))
            hill.closeSubpath()
            ctx.addPath(hill); ctx.setFillColor(sky.bottom.mixed(RGB(1, 1, 1), 0.55).cg(a)); ctx.fillPath()
        }
        // Base ground (before any new snow lands on it)
        let ground = CGMutablePath()
        var pts: [CGPoint] = []
        var x = SL.cx - SL.R
        while x <= SL.cx + SL.R { pts.append(CGPoint(x: x, y: SL.ground(x))); x += 2 }
        ground.addLines(between: pts)
        ground.addLine(to: CGPoint(x: SL.cx + SL.R, y: SL.cy + SL.R + 2))
        ground.addLine(to: CGPoint(x: SL.cx - SL.R, y: SL.cy + SL.R + 2))
        ground.closeSubpath()
        ctx.saveGState()
        ctx.addPath(ground); ctx.clip()
        ctx.drawLinearGradient(makeGradient(SnowRenderer.pileColors, SnowRenderer.pileLocs), start: CGPoint(x: 0, y: SL.groundY - 4), end: CGPoint(x: 0, y: SL.cy + SL.R), options: [])
        ctx.restoreGState()
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.16)], [0, 1]),
                               start: CGPoint(x: 0, y: SL.groundY - 30), end: CGPoint(x: 0, y: SL.groundY - 2), options: [])
        tree(ctx, x: SL.cx - 40, h: 46)
        tree(ctx, x: SL.cx - 16, h: 58)
        tree(ctx, x: SL.cx + 46, h: 44)
        cabin(ctx, x: SL.cx + 17)
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)], [0, 0.72, 1]),
                               startCenter: CGPoint(x: SL.cx, y: SL.cy), startRadius: 0, endCenter: CGPoint(x: SL.cx, y: SL.cy), endRadius: SL.R, options: [])
        ctx.restoreGState()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        // Glass: reflections and rim
        ctx.saveGState()
        ctx.addPath(globe); ctx.clip()
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.02), CGColor(gray: 1, alpha: 0.14)], [0, 0.8, 1]),
                               startCenter: CGPoint(x: SL.cx, y: SL.cy), startRadius: 0, endCenter: CGPoint(x: SL.cx, y: SL.cy), endRadius: SL.R, options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(globe); ctx.clip()
        softLight(ctx, at: CGPoint(x: SL.cx - 30, y: SL.cy - 34), radius: 54, color: RGB(1, 1, 1), alpha: 0.2)
        softLight(ctx, at: CGPoint(x: SL.cx + 36, y: SL.cy + 42), radius: 40, color: RGB(0, 0, 0), alpha: 0.13)
        ctx.restoreGState()
        ctx.setLineCap(.round)
        let hi = CGMutablePath()
        hi.addArc(center: CGPoint(x: SL.cx, y: SL.cy), radius: SL.R - 7, startAngle: .pi * 1.12, endAngle: .pi * 1.42, clockwise: false)
        ctx.addPath(hi); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.42)); ctx.setLineWidth(4); ctx.strokePath()
        let hi2 = CGMutablePath()
        hi2.addArc(center: CGPoint(x: SL.cx, y: SL.cy), radius: SL.R - 6, startAngle: .pi * 0.15, endAngle: .pi * 0.3, clockwise: false)
        ctx.addPath(hi2); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.2)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.addPath(globe); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.28)); ctx.setLineWidth(2.4); ctx.strokePath()
        ctx.addPath(globe); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(1.1); ctx.strokePath()
        fresnelRim(ctx, globe, width: 8, alpha: 0.14)
        specular(ctx, at: CGPoint(x: SL.cx - 33, y: SL.cy - 40), rx: 9, ry: 6, alpha: 0.6)
        // Collar holding the globe
        let collar = CGRect(x: SL.cx - SL.collarRX, y: SL.collarY - SL.collarRY, width: SL.collarRX * 2, height: SL.collarRY * 2)
        ctx.saveGState()
        ctx.addEllipse(in: collar); ctx.clip()
        ctx.drawLinearGradient(makeGradient([fs.ring.scaled(0.7).cg(), fs.ring.scaled(1.2).cg(), fs.ring.scaled(0.9).cg(), fs.ring.scaled(0.6).cg()], [0, 0.3, 0.6, 1]),
                               start: CGPoint(x: collar.minX, y: 0), end: CGPoint(x: collar.maxX, y: 0), options: [])
        ctx.restoreGState()
        ctx.addEllipse(in: collar); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.2)); ctx.setLineWidth(0.8); ctx.strokePath()
        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: CGColor(gray: 1, alpha: ui.glow))
            ctx.addPath(globe); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }
        drawBadge(ctx, ui: ui, accent: RGB(0.78, 0.84, 0.92))
    }

    func drawDynamic(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(globe); ctx.clip()
        ctx.saveGState()
        ctx.addPath(pilePath()); ctx.clip()
        ctx.drawLinearGradient(makeGradient(SnowRenderer.pileColors, SnowRenderer.pileLocs), start: CGPoint(x: 0, y: SL.cy - SL.R), end: CGPoint(x: 0, y: SL.cy + SL.R), options: [])
        ctx.drawLinearGradient(makeGradient(SnowRenderer.pileShadeColors, SnowRenderer.pileShadeLocs), start: CGPoint(x: SL.cx - SL.R, y: 0), end: CGPoint(x: SL.cx + SL.R, y: 0), options: [])
        ctx.restoreGState()
        ctx.addPath(surfaceLine()); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(1.1); ctx.strokePath()
        ctx.saveGState(); ctx.setAlpha(CGFloat(moteOpacity))
        ctx.addPath(motesPath()); ctx.setFillColor(SnowRenderer.moteColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(flakesPath()); ctx.setFillColor(SnowRenderer.flakeColor); ctx.fillPath()
        ctx.restoreGState()
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawDynamic(ctx)
        drawFront(ctx, ui: ui)
    }
}

final class SnowModule: StyleModule {
    let sim = SnowSim()
    lazy var r = SnowRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer(), inside = CALayer(), insideMask = CAShapeLayer()
    private lazy var pile = MaskedGradient(SnowRenderer.pileColors, SnowRenderer.pileLocs, box: r.pileBox)
    private let surface = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.9), width: 1.1)
    private let motes = shapeLayer(fill: SnowRenderer.moteColor), flakes = shapeLayer(fill: SnowRenderer.flakeColor)
    private var backKey = "", frontKey = ""
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Sky"
    var colours: [(String, RGB)] { skyStyles.map { ($0.name, $0.mid) } }
    var colourIndex = 0 { didSet { r.sky = skyStyles[colourIndex] } }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        insideMask.frame = container.bounds
        insideMask.path = flipY(r.globe)
        inside.frame = container.bounds
        inside.mask = insideMask
        pile.layer.addSublayer(gradientLayer(SnowRenderer.pileShadeColors, SnowRenderer.pileShadeLocs, box: r.pileBox, vertical: false))
        for l in [pile.layer, surface, motes, flakes] { l.frame = container.bounds; inside.addSublayer(l) }
        for l in [back, inside, front] { l.frame = container.bounds; container.addSublayer(l) }
    }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, surface, motes, flakes, pile.mask, insideMask] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())|\(r.sky.name)"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())"
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        pile.set(path: r.pilePath())
        surface.path = flipY(r.surfaceLine())
        motes.path = flipY(r.motesPath())
        motes.opacity = r.moteOpacity
        flakes.path = flipY(r.flakesPath())
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) {
        sim.pointer = p
        if p != nil { sim.pointerV = velocity }
    }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        if let p = previewPhase, !running {
            st.ex.inAir = 1 - 0.7 * p
        } else {
            st.ex.inAir = Float(sim.airborne)
        }
    }
}
