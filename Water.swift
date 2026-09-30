// Water clock: a glass reservoir drips into a glass basin. Each drop swells at the spout, necks and
// lets go, falls under gravity, and lands with a splash crown, a rising jet and spreading ripples.

import AppKit
import QuartzCore

enum WL {
    static let R: CGFloat = 42                          // the glass cylinder's interior radius
    static let resTop: CGFloat = 40                     // interior top, under the upper disc
    static let funnelTop: CGFloat = 92, resBottom: CGFloat = 124
    static let spoutTip: CGFloat = 128, spoutHalf: CGFloat = 2.4
    static let basinTop: CGFloat = 142, basinFloor: CGFloat = 282
    static let persp: CGFloat = 0.16                    // ry / rx of a water surface seen from slightly above
    static let resMaxLevel: CGFloat = resBottom - resTop, basinMaxLevel: CGFloat = basinFloor - basinTop

    /// Interior half-width of the reservoir: the cylinder, then the glass funnel down to the spout.
    static func resHalf(_ y: CGFloat) -> CGFloat {
        if y <= funnelTop { return R }
        let u = min(1, (y - funnelTop) / (resBottom - funnelTop))
        return max(spoutHalf, R - (R - spoutHalf) * pow(u, 0.85))
    }
    /// Interior half-width of the lower part: the cylinder with a rounded floor.
    static func basinHalf(_ y: CGFloat) -> CGFloat {
        if y > basinFloor - 8 { let w = min(1, (y - (basinFloor - 8)) / 8); return R - 8 * (1 - sqrt(max(0, 1 - w * w))) }
        return R
    }
}

struct WaterTint { let name: String; let color: RGB; let alpha: CGFloat }
let waterTints: [WaterTint] = [
    .init(name: "Clear", color: RGB(0.72, 0.84, 0.92), alpha: 0.42),
    .init(name: "Sea Blue", color: RGB(0.30, 0.62, 0.92), alpha: 0.60),
    .init(name: "Rain Grey", color: RGB(0.62, 0.68, 0.75), alpha: 0.55),
    .init(name: "Jade", color: RGB(0.35, 0.80, 0.66), alpha: 0.55),
    .init(name: "Rose", color: RGB(0.93, 0.55, 0.68), alpha: 0.50),
    .init(name: "Amber Tea", color: RGB(0.86, 0.58, 0.24), alpha: 0.55),
]

struct WDrop { var x, y, vx, vy, r, m: CGFloat; var t: CGFloat = 0; var kind: Int }   // 0 main, 1 satellite, 2 splash, 3 jet droplet
struct WRing { var x: CGFloat; var t: CGFloat; var strength: CGFloat; var delay: CGFloat }
struct WJet { var x: CGFloat; var t: CGFloat; var h: CGFloat; var decided: Bool }

final class WaterSim: TimerBody {
    static let rD: CGFloat = 2.7
    static let g: CGFloat = 6500
    var totalMass: CGFloat = 100          // counted in drops
    var topMass: CGFloat = 100
    var bottomMass: CGFloat = 0
    var forming: CGFloat = 0              // the pendant drop growing at the spout, in drops
    var detachT: CGFloat = -1
    var satelliteIn: CGFloat = -1
    var drops: [WDrop] = []
    var rings: [WRing] = []
    var jets: [WJet] = []
    let N = 65
    let waveX0 = L.cx - 64, waveDX: CGFloat = 2
    var wave: [CGFloat], waveV: [CGFloat]
    var waveAcc: CGFloat = 0
    var waveEnergy: CGFloat = 0
    var resLevel: CGFloat = 0, basinLevel: CGFloat = 0
    var resBob: CGFloat = 0, resBobV: CGFloat = 0
    var events: [SoundEvent] = []
    var time: CGFloat = 0
    var busy = true
    var rng = RNG(s: 0x7A3B_5C1D_9E2F_4A6B)
    private var resTable: [CGFloat] = [0]
    private var basinTable: [CGFloat] = [0]

    init() {
        wave = Array(repeating: 0, count: N)
        waveV = wave
        // Volumes with round vessels grow with the square of the half-width.
        var v: CGFloat = 0
        for i in 1...Int(WL.resMaxLevel * 2) {
            let y = WL.resBottom - CGFloat(i) * 0.5 + 0.25
            let h = WL.resHalf(y)
            v += h * h * 0.5
            resTable.append(v)
        }
        v = 0
        for i in 1...Int(WL.basinMaxLevel * 2) {
            let y = WL.basinFloor - CGFloat(i) * 0.5 + 0.25
            let h = WL.basinHalf(y)
            v += h * h * 0.5
            basinTable.append(v)
        }
        reset()
    }

    private func level(_ vol: CGFloat, _ table: [CGFloat]) -> CGFloat {
        guard vol > 0 else { return 0 }
        if vol >= table.last! { return CGFloat(table.count - 1) * 0.5 }
        var lo = 0, hi = table.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if table[mid] < vol { lo = mid } else { hi = mid } }
        let t = (vol - table[lo]) / max(table[hi] - table[lo], 1e-6)
        return (CGFloat(lo) + t) * 0.5
    }
    var resTarget: CGFloat { level(topMass / max(totalMass, 1) * resTable.last!, resTable) }
    var basinTarget: CGFloat { level(bottomMass / max(totalMass, 1) * basinTable.last!, basinTable) }

    var resSurfaceY: CGFloat { WL.resBottom - resLevel }
    var basinLineY: CGFloat { WL.basinFloor - basinLevel }
    var hasBasinWater: Bool { basinLevel > 0.8 }
    var hasResWater: Bool { resLevel > 0.3 }

    func waveAt(_ x: CGFloat) -> CGFloat {
        let f = min(max((x - waveX0) / waveDX, 0), CGFloat(N - 1) - 0.001)
        let i = Int(f), t = f - CGFloat(i)
        return wave[i] * (1 - t) + wave[i + 1] * t
    }
    func surfaceY(at x: CGFloat) -> CGFloat { hasBasinWater ? basinLineY + waveAt(x) : WL.basinFloor - 0.5 }

    var inFlight: Bool { forming > 1e-6 || detachT >= 0 || !drops.isEmpty || !jets.isEmpty }

    func configure(forSeconds s: Double) {
        // A drop every second or so whatever the timer length, so the clock is never still.
        let interval = min(1.6, max(1.1, 1.0 + s / 1800))
        let newTotal = max(8, (s / interval).rounded())
        if totalMass > 0 {
            topMass = topMass / totalMass * newTotal
            bottomMass = bottomMass / totalMass * newTotal
        }
        totalMass = newTotal
    }

    func reset() {
        topMass = totalMass
        bottomMass = 0
        forming = 0
        detachT = -1
        satelliteIn = -1
        drops.removeAll(); rings.removeAll(); jets.removeAll(); events.removeAll()
        for i in 0..<N { wave[i] = 0; waveV[i] = 0 }
        resLevel = resTarget
        basinLevel = 0
        resBob = 0; resBobV = 0
        busy = true
    }

    private func release() {
        let m = min(forming, 1)
        let r = WaterSim.rD * pow(m, 1 / 3)
        drops.append(WDrop(x: L.cx + rng.signed() * 0.3, y: WL.spoutTip + r + 2.5, vx: rng.signed() * 2, vy: 40, r: r, m: m, kind: 0))
        forming -= m
        detachT = -1
        resBobV -= 14
        if rng.unit() < 0.35 { satelliteIn = 0.035 }
    }

    private func waveImpulse(at x: CGFloat, amp: CGFloat, width: CGFloat) {
        for i in 0..<N {
            let d = (waveX0 + CGFloat(i) * waveDX - x) / width
            wave[i] -= amp * exp(-d * d)
        }
    }

    private func impact(_ d: WDrop, surface: CGFloat) {
        let depth = basinLevel / WL.basinMaxLevel
        let size = d.r / WaterSim.rD
        bottomMass += d.m
        switch d.kind {
        case 2:
            if hasBasinWater {
                waveImpulse(at: d.x, amp: 0.7, width: 2)
                rings.append(WRing(x: d.x, t: 0, strength: 0.22, delay: 0))
            }
        default:
            events.append(SoundEvent(kind: .drop, a: Float(depth), b: Float(size)))
            if hasBasinWater {
                waveImpulse(at: d.x, amp: 3.2 * size, width: 3.5)
                let n = d.kind == 0 ? 3 : 2
                for k in 0..<n {
                    rings.append(WRing(x: d.x, t: 0, strength: (d.kind == 0 ? 1 : 0.5) * (1 - CGFloat(k) * 0.25), delay: CGFloat(k) * 0.13))
                }
                if d.kind != 3 { jets.append(WJet(x: d.x, t: 0, h: d.kind == 0 ? 9 : 3.5, decided: d.kind == 1)) }
            }
            let ns = d.kind == 0 ? 3 + Int(rng.next() % 3) : (d.kind == 1 ? 1 : 0)
            for _ in 0..<ns {
                let ang = (0.25 + rng.unit() * 0.5) * CGFloat.pi
                let sp = 300 + rng.unit() * 260
                drops.append(WDrop(x: d.x + rng.signed() * 1.5, y: surface - 1, vx: cos(ang) * sp, vy: -sin(ang) * sp,
                                   r: 0.45 + rng.unit() * 0.45, m: 0, kind: 2))
            }
        }
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        time += dt
        let flowing = drain > 0
        if flowing {
            let take = min(drain, topMass)
            topMass -= take
            forming += take
        }
        if detachT < 0 {
            if forming >= 1 {
                detachT = 0
            } else if topMass <= 1e-9 && !flowing && forming > 0 {
                if forming > 0.03 { detachT = 0 } else { bottomMass += forming; forming = 0 }
            }
        }
        if detachT >= 0 {
            detachT += dt
            if detachT >= 0.14 { release() }
        }
        if satelliteIn >= 0 {
            satelliteIn -= dt
            if satelliteIn < 0 { drops.append(WDrop(x: L.cx, y: WL.spoutTip + 1.5, vx: 0, vy: 25, r: 0.85, m: 0, kind: 1)) }
        }

        var i = 0
        while i < drops.count {
            var d = drops[i]
            d.t += dt
            d.vy += WaterSim.g * dt
            d.y += d.vy * dt
            d.x += d.vx * dt
            let surf = surfaceY(at: d.x)
            if d.vy > 0 && d.y + d.r * 0.6 >= surf {
                impact(d, surface: surf)
                drops.remove(at: i)
            } else {
                drops[i] = d
                i += 1
            }
        }
        i = 0
        while i < jets.count {
            var j = jets[i]
            j.t += dt
            if !j.decided && j.t >= 0.11 {
                j.decided = true
                if rng.unit() < 0.6 {
                    drops.append(WDrop(x: j.x, y: basinLineY + waveAt(j.x) - j.h, vx: rng.signed() * 6, vy: -j.h * 46, r: 1.25, m: 0, kind: 3))
                }
            }
            if j.t >= 0.24 { jets.remove(at: i) } else { jets[i] = j; i += 1 }
        }
        for k in rings.indices.reversed() {
            rings[k].t += dt
            if rings[k].t - rings[k].delay > 1.3 { rings.remove(at: k) }
        }

        // Surface waves (1-D wave equation, sub-stepped for stability)
        waveAcc += dt
        var steps = 0
        let h: CGFloat = 1.0 / 120, c2: CGFloat = 90 * 90, s2 = waveDX * waveDX
        while waveAcc >= h && steps < 8 {
            for k in 1..<(N - 1) {
                waveV[k] += (c2 * (wave[k - 1] - 2 * wave[k] + wave[k + 1]) / s2 - 3.0 * waveV[k]) * h
            }
            for k in 0..<N { wave[k] += waveV[k] * h }
            wave[0] = wave[1]; wave[N - 1] = wave[N - 2]
            waveAcc -= h
            steps += 1
        }
        if steps == 8 { waveAcc = 0 }
        var e: CGFloat = 0
        for k in 0..<N { e += abs(wave[k]) }
        waveEnergy = e

        let rt = resTarget, bt = basinTarget
        resLevel += (rt - resLevel) * min(1, dt * 5)
        basinLevel += (bt - basinLevel) * min(1, dt * 6)
        resBobV += (-90 * resBob - 7 * resBobV) * dt
        resBob += resBobV * dt

        busy = flowing || !drops.isEmpty || !jets.isEmpty || !rings.isEmpty || waveEnergy > 0.05 || detachT >= 0
            || abs(rt - resLevel) > 0.02 || abs(bt - basinLevel) > 0.02 || abs(resBob) > 0.02
    }

    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        bottomMass += take
        busy = true
    }

    func landAll() {
        for d in drops { bottomMass += d.m }
        bottomMass += forming
        forming = 0
        detachT = -1
        satelliteIn = -1
        drops.removeAll(); jets.removeAll(); rings.removeAll()
        for i in 0..<N { wave[i] = 0; waveV[i] = 0 }
        resLevel = resTarget
        basinLevel = basinTarget
        busy = true
    }

    func flip() {
        landAll()
        swap(&topMass, &bottomMass)
        resLevel = resTarget
        basinLevel = basinTarget
        busy = true
    }
}

// MARK: - Rendering

final class WaterRenderer {
    let sim: WaterSim
    var tint = waterTints[0]
    let resInterior: CGPath, resOutline: CGPath
    let basinInterior: CGPath, basinOutline: CGPath
    let sheen: [CGPath]
    let funnel: CGPath
    let resBox = CGRect(x: L.cx - WL.R, y: WL.resTop, width: WL.R * 2, height: WL.spoutTip - WL.resTop)
    let basinBox = CGRect(x: L.cx - WL.R, y: WL.basinTop, width: WL.R * 2, height: WL.basinFloor - WL.basinTop)
    let faceBox = CGRect(x: L.cx - WL.R - 2, y: WL.basinTop - 12, width: WL.R * 2 + 4, height: WL.basinFloor - WL.basinTop + 14)
    static let rimRY = WL.R * WL.persp

    init(sim: WaterSim) {
        self.sim = sim
        // The cylinder's silhouette (top rim seen from slightly above, rounded floor)
        func cylinder(inset: CGFloat) -> CGPath {
            let r = WL.R + inset, top = WL.resTop - 3, bottom = WL.basinFloor + inset
            let p = CGMutablePath()
            p.move(to: CGPoint(x: L.cx - r, y: top))
            p.addLine(to: CGPoint(x: L.cx - r, y: bottom - 8))
            p.addQuadCurve(to: CGPoint(x: L.cx - r + 10, y: bottom + WaterRenderer.rimRY * 0.8), control: CGPoint(x: L.cx - r, y: bottom + WaterRenderer.rimRY * 0.6))
            p.addQuadCurve(to: CGPoint(x: L.cx + r - 10, y: bottom + WaterRenderer.rimRY * 0.8), control: CGPoint(x: L.cx, y: bottom + WaterRenderer.rimRY * 1.5))
            p.addQuadCurve(to: CGPoint(x: L.cx + r, y: bottom - 8), control: CGPoint(x: L.cx + r, y: bottom + WaterRenderer.rimRY * 0.6))
            p.addLine(to: CGPoint(x: L.cx + r, y: top))
            p.addCurve(to: CGPoint(x: L.cx - r, y: top), control1: CGPoint(x: L.cx + r, y: top - WaterRenderer.rimRY * 1.33), control2: CGPoint(x: L.cx - r, y: top - WaterRenderer.rimRY * 1.33))
            p.closeSubpath()
            return p
        }
        resInterior = cylinder(inset: 0)
        resOutline = cylinder(inset: 1.6)
        basinInterior = resInterior
        basinOutline = resOutline
        let f = CGMutablePath()
        f.move(to: CGPoint(x: L.cx - WL.R, y: WL.funnelTop))
        var y = WL.funnelTop
        var left: [CGPoint] = []
        while y <= WL.resBottom { left.append(CGPoint(x: L.cx - WL.resHalf(y), y: y)); y += 2 }
        left.append(CGPoint(x: L.cx - WL.spoutHalf, y: WL.resBottom))
        f.addLines(between: left)
        f.addLine(to: CGPoint(x: L.cx - WL.spoutHalf, y: WL.spoutTip))
        f.addLine(to: CGPoint(x: L.cx + WL.spoutHalf, y: WL.spoutTip))
        f.addLine(to: CGPoint(x: L.cx + WL.spoutHalf, y: WL.resBottom))
        f.addLines(between: left.reversed().map { CGPoint(x: 2 * L.cx - $0.x, y: $0.y) })
        funnel = f
        let pl = CGMutablePath(), pr = CGMutablePath()
        pl.move(to: CGPoint(x: L.cx - WL.R * 0.8, y: WL.resTop + 8)); pl.addLine(to: CGPoint(x: L.cx - WL.R * 0.8, y: WL.basinFloor - 12))
        pr.move(to: CGPoint(x: L.cx + WL.R * 0.88, y: WL.resTop + 8)); pr.addLine(to: CGPoint(x: L.cx + WL.R * 0.88, y: WL.basinFloor - 12))
        sheen = [pl, pr]
    }

    var bodyColors: [CGColor] {
        let c = tint.color, a = tint.alpha
        return [c.mixed(RGB(1, 1, 1), 0.3).cg(a), c.cg(min(1, a + 0.1)), c.scaled(0.7).cg(min(1, a + 0.3))]
    }
    static let bodyLocs: [CGFloat] = [0, 0.5, 1]
    var faceColor: CGColor { tint.color.mixed(RGB(1, 1, 1), 0.5).cg(0.55) }
    var dropColor: CGColor { tint.color.mixed(RGB(1, 1, 1), 0.12).cg(0.92) }
    static let lineColor = CGColor(gray: 1, alpha: 0.6)
    // A soft vertical band of light through the water, like a lens catching the room.
    static let lensColors: [CGColor] = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.13), CGColor(gray: 1, alpha: 0.02), CGColor(gray: 0, alpha: 0.06), CGColor(gray: 0, alpha: 0.1)]
    static let lensLocs: [CGFloat] = [0.05, 0.3, 0.5, 0.8, 1]
    static let hiColor = CGColor(gray: 1, alpha: 0.75)

    // Region below the reservoir surface, including the spout tube (which stays full).
    func resWaterPath() -> CGPath? {
        let tubeFull = sim.topMass > 1e-6 || sim.forming > 0 || sim.detachT >= 0
        guard sim.hasResWater || tubeFull else { return nil }
        let p = CGMutablePath()
        let ys = max(WL.resTop + 0.5, sim.resSurfaceY)
        if sim.hasResWater {
            var left: [CGPoint] = []
            var y = ys
            while y < WL.resBottom { left.append(CGPoint(x: L.cx - WL.resHalf(y), y: y)); y += 2 }
            left.append(CGPoint(x: L.cx - WL.spoutHalf, y: WL.resBottom))
            let hw = WL.resHalf(ys)
            p.move(to: CGPoint(x: L.cx - hw, y: ys))
            p.addQuadCurve(to: CGPoint(x: L.cx + hw, y: ys), control: CGPoint(x: L.cx, y: ys + sim.resBob * 0.6))
            let right = left.reversed().map { CGPoint(x: 2 * L.cx - $0.x, y: $0.y) }
            for pt in right { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: L.cx + WL.spoutHalf, y: WL.spoutTip))
            p.addLine(to: CGPoint(x: L.cx - WL.spoutHalf, y: WL.spoutTip))
            for pt in left { p.addLine(to: pt) }
            p.closeSubpath()
        } else {
            p.addRect(CGRect(x: L.cx - WL.spoutHalf, y: WL.resBottom - 1, width: WL.spoutHalf * 2, height: WL.spoutTip - WL.resBottom + 1))
        }
        return p
    }

    func basinWaterPath() -> CGPath? {
        guard sim.hasBasinWater else { return nil }
        let yl = sim.basinLineY
        let hw = WL.basinHalf(yl)
        let p = CGMutablePath()
        var pts: [CGPoint] = []
        var x = L.cx - hw
        while x <= L.cx + hw { pts.append(CGPoint(x: x, y: yl + sim.waveAt(x))); x += 2 }
        pts.append(CGPoint(x: L.cx + hw, y: yl + sim.waveAt(L.cx + hw)))
        p.addLines(between: pts)
        var y = yl + 2
        var right: [CGPoint] = []
        while y < WL.basinFloor { right.append(CGPoint(x: L.cx + WL.basinHalf(y), y: y)); y += 2 }
        right.append(CGPoint(x: L.cx + WL.basinHalf(WL.basinFloor), y: WL.basinFloor))
        for pt in right { p.addLine(to: pt) }
        for pt in right.reversed() { p.addLine(to: CGPoint(x: 2 * L.cx - pt.x, y: pt.y)) }
        p.closeSubpath()
        return p
    }

    /// The two vertical reflections, refracted sideways where they pass through water.
    func sheenPaths() -> (bright: CGPath, faint: CGPath) {
        let bright = CGMutablePath(), faint = CGMutablePath()
        func line(_ p: CGMutablePath, x: CGFloat, shift: CGFloat) {
            var cuts: [(CGFloat, CGFloat, Bool)] = []       // (from, to, inWater)
            let top = WL.resTop + 8, bottom = WL.basinFloor - 12
            let rs = sim.hasResWater ? max(WL.resTop + 0.5, sim.resSurfaceY) : WL.funnelTop
            cuts.append((top, min(rs, WL.funnelTop), false))
            cuts.append((min(rs, WL.funnelTop), WL.funnelTop, true))
            let bl = sim.hasBasinWater ? sim.basinLineY : bottom
            cuts.append((WL.spoutTip + 2, bl, false))
            cuts.append((bl, bottom, true))
            for (a, b, wet) in cuts where b - a > 1 {
                p.move(to: CGPoint(x: x + (wet ? shift : 0), y: a))
                p.addLine(to: CGPoint(x: x + (wet ? shift : 0), y: b))
            }
        }
        line(bright, x: L.cx - WL.R * 0.8, shift: 3.5)
        line(faint, x: L.cx + WL.R * 0.88, shift: -2.5)
        return (bright, faint)
    }

    /// Sharp glints along the back edge of each water surface.
    func glintPath() -> CGPath {
        let p = CGMutablePath()
        func arc(_ cy: CGFloat, _ rx: CGFloat) {
            var t = CGAffineTransform(translationX: L.cx, y: cy).scaledBy(x: rx, y: rx * WL.persp)
            let a = CGMutablePath()
            a.addArc(center: .zero, radius: 1, startAngle: .pi * 1.15, endAngle: .pi * 1.6, clockwise: false)
            p.addPath(a.copy(using: &t) ?? a)
        }
        if sim.hasBasinWater { arc(sim.basinLineY, WL.basinHalf(sim.basinLineY) * 0.92) }
        if sim.hasResWater { let ys = max(WL.resTop + 0.5, sim.resSurfaceY); arc(ys, WL.resHalf(ys) * 0.92) }
        return p
    }

    func surfaceLines() -> CGPath {
        let p = CGMutablePath()
        if sim.hasBasinWater {
            let yl = sim.basinLineY, hw = WL.basinHalf(yl)
            var pts: [CGPoint] = []
            var x = L.cx - hw
            while x <= L.cx + hw { pts.append(CGPoint(x: x, y: yl + sim.waveAt(x))); x += 2 }
            p.addLines(between: pts)
        }
        if sim.hasResWater {
            let ys = max(WL.resTop + 0.5, sim.resSurfaceY), hw = WL.resHalf(ys)
            p.move(to: CGPoint(x: L.cx - hw, y: ys))
            p.addQuadCurve(to: CGPoint(x: L.cx + hw, y: ys), control: CGPoint(x: L.cx, y: ys + sim.resBob * 0.6))
        }
        return p
    }

    func facePath() -> CGPath {
        let p = CGMutablePath()
        if sim.hasBasinWater {
            let yl = sim.basinLineY, rx = WL.basinHalf(yl)
            p.addEllipse(in: CGRect(x: L.cx - rx, y: yl - rx * WL.persp, width: rx * 2, height: rx * WL.persp * 2))
        }
        if sim.hasResWater {
            let ys = max(WL.resTop + 0.5, sim.resSurfaceY), rx = WL.resHalf(ys)
            p.addEllipse(in: CGRect(x: L.cx - rx, y: ys - rx * WL.persp, width: rx * 2, height: rx * WL.persp * 2))
        }
        return p
    }

    /// Ripples on the basin's surface, drawn into a small bitmap so each ring can fade on its own.
    func drawRings(_ ctx: CGContext) {
        guard sim.hasBasinWater, !sim.rings.isEmpty else { return }
        let yl = sim.basinLineY, rx = WL.basinHalf(yl)
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: L.cx - rx, y: yl - rx * WL.persp, width: rx * 2, height: rx * WL.persp * 2))
        ctx.clip()
        ctx.setLineWidth(0.8)
        for r in sim.rings {
            let t = r.t - r.delay
            guard t > 0 else { continue }
            let rad = 55 * t + 1
            let a = r.strength * max(0, 1 - t / 1.3) * 0.7
            ctx.setStrokeColor(CGColor(gray: 1, alpha: a))
            ctx.strokeEllipse(in: CGRect(x: r.x - rad, y: yl - rad * WL.persp, width: rad * 2, height: rad * WL.persp * 2))
        }
        ctx.restoreGState()
    }

    func causticsPath() -> CGPath {
        let p = CGMutablePath()
        let t = sim.time
        for k in 0..<3 {
            var pts: [CGPoint] = []
            var x = L.cx - 36
            while x <= L.cx + 36 {
                let y = WL.basinFloor - 6 - CGFloat(k) * 5 + 2.2 * sin(x * 0.16 + t * (0.6 + CGFloat(k) * 0.2) + CGFloat(k) * 2) + 1.2 * sin(x * 0.31 - t * 0.9)
                pts.append(CGPoint(x: x, y: y))
                x += 4
            }
            p.addLines(between: pts)
        }
        return p
    }

    func dropPaths() -> (body: CGPath, hi: CGPath) {
        let body = CGMutablePath(), hi = CGMutablePath()
        let tip = WL.spoutTip
        let tubeFull = sim.topMass > 1e-6 || sim.forming > 0 || sim.detachT >= 0
        if tubeFull { body.addEllipse(in: CGRect(x: L.cx - 0.9, y: tip - 0.7, width: 1.8, height: 1.6)) }
        if sim.forming > 0.02 || sim.detachT >= 0 {
            let pN = sim.detachT >= 0 ? min(1, sim.detachT / 0.14) : 0
            let r = WaterSim.rD * pow(min(sim.forming, 1), 1 / 3)
            let cy = tip + r + 2.5 * pN
            let rx = r * (1 - 0.12 * pN), ry = r * (1 + 0.25 * pN)
            let neck = 1.6 * (1 - pN) + 0.25
            body.addRect(CGRect(x: L.cx - neck / 2, y: tip - 0.5, width: neck, height: cy - tip + 0.5))
            body.addEllipse(in: CGRect(x: L.cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            hi.addEllipse(in: CGRect(x: L.cx - rx * 0.55, y: cy - ry * 0.55, width: rx * 0.5, height: ry * 0.5))
        }
        for d in sim.drops {
            var a: CGFloat = 1
            if d.kind == 0 || d.kind == 1 { a = 1 + 0.25 * exp(-d.t / 0.12) * cos(2 * .pi * 14 * d.t) + min(0.3, d.vy / 3000) }
            let rx = d.r / sqrt(a), ry = d.r * sqrt(a)
            body.addEllipse(in: CGRect(x: d.x - rx, y: d.y - ry, width: rx * 2, height: ry * 2))
            if d.kind != 2 { hi.addEllipse(in: CGRect(x: d.x - rx * 0.55, y: d.y - ry * 0.6, width: rx * 0.5, height: ry * 0.45)) }
        }
        for j in sim.jets where sim.hasBasinWater {
            let h = j.h * sin(.pi * min(1, j.t / 0.24))
            let y = sim.basinLineY + sim.waveAt(j.x)
            body.addPath(CGPath(roundedRect: CGRect(x: j.x - 1.3, y: y - h, width: 2.6, height: h + 2), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
        }
        return (body, hi)
    }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        _ = ui.frame
        groundShadow(ctx, y: L.height - L.margin + 1, strength: ui.shadow)
        ctx.addPath(resInterior); ctx.setFillColor(CGColor(gray: 1, alpha: 0.07)); ctx.fillPath()
        // The glass funnel, seen through the front wall
        ctx.addPath(funnel); ctx.setFillColor(CGColor(gray: 1, alpha: 0.06)); ctx.fillPath()
        ctx.addPath(funnel); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); ctx.setLineWidth(0.9); ctx.strokePath()
        let top = CGRect(x: L.cx - WL.R, y: WL.funnelTop - WaterRenderer.rimRY, width: WL.R * 2, height: WaterRenderer.rimRY * 2)
        ctx.addEllipse(in: top); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); ctx.setLineWidth(0.8); ctx.strokePath()
    }

    func drawWater(_ ctx: CGContext) {
        func body(_ path: CGPath?, box: CGRect) {
            guard let path else { return }
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(makeGradient(bodyColors, WaterRenderer.bodyLocs), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
            ctx.restoreGState()
        }
        body(resWaterPath(), box: resBox)
        if let bp = basinWaterPath() {
            body(bp, box: basinBox)
            ctx.saveGState()
            ctx.addPath(bp); ctx.clip()
            ctx.drawLinearGradient(makeGradient(WaterRenderer.lensColors, WaterRenderer.lensLocs), start: CGPoint(x: basinBox.minX, y: 0), end: CGPoint(x: basinBox.maxX, y: 0), options: [])
            ctx.addPath(causticsPath()); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.15)); ctx.setLineWidth(1.2); ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.addPath(facePath()); ctx.setFillColor(faceColor); ctx.fillPath()
        ctx.addPath(surfaceLines()); ctx.setStrokeColor(WaterRenderer.lineColor); ctx.setLineWidth(0.8); ctx.strokePath()
        let sh = sheenPaths()
        ctx.setLineCap(.round)
        ctx.addPath(sh.bright); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.26)); ctx.setLineWidth(3.2); ctx.strokePath()
        ctx.addPath(sh.faint); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1.4); ctx.strokePath()
        ctx.addPath(glintPath()); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(1.2); ctx.strokePath()
        drawRings(ctx)
        let (b, h) = dropPaths()
        ctx.addPath(b); ctx.setFillColor(dropColor); ctx.fillPath()
        ctx.addPath(h); ctx.setFillColor(WaterRenderer.hiColor); ctx.fillPath()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        ctx.setLineCap(.round)
        ctx.saveGState()
        ctx.addPath(resInterior); ctx.clip()
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0.14), CGColor(gray: 1, alpha: 0.02), CGColor(gray: 1, alpha: 0),
                                             CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0.12)], [0, 0.25, 0.5, 0.8, 1]),
                               start: CGPoint(x: L.cx - WL.R, y: 0), end: CGPoint(x: L.cx + WL.R, y: 0), options: [])
        ctx.restoreGState()
        _ = sheen
        ctx.setLineJoin(.round)
        glassStreak(ctx, in: resInterior, center: CGPoint(x: L.cx - 8, y: WL.resTop + 40), length: 130, width: 7, alpha: 0.10)
        glassStreak(ctx, in: resInterior, center: CGPoint(x: L.cx - 10, y: WL.basinTop + 60), length: 150, width: 9, alpha: 0.08)
        ctx.addPath(resOutline); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.30)); ctx.setLineWidth(2.4); ctx.strokePath()
        ctx.addPath(resOutline); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.62)); ctx.setLineWidth(1.0); ctx.strokePath()
        fresnelRim(ctx, resOutline, width: 7, alpha: 0.15)
        ctx.saveGState()
        ctx.addPath(resInterior); ctx.clip()
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.22)], [0, 1]),
                               start: CGPoint(x: 0, y: WL.basinFloor - 8), end: CGPoint(x: 0, y: WL.basinFloor + 4), options: [])
        ctx.restoreGState()
        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: tint.color.cg(ui.glow))
            ctx.addPath(resOutline); ctx.setStrokeColor(tint.color.cg(0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }
        woodDisc(ctx, cy: 18, rx: WL.R + 12, ry: 6, thick: 14, fs: fs, seed: 5)
        woodDisc(ctx, cy: WL.basinFloor + 6, rx: WL.R + 13, ry: 6.5, thick: 15, fs: fs, seed: 12)
        drawBadge(ctx, ui: ui, accent: tint.color.mixed(RGB(1, 1, 1), 0.15))
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawWater(ctx)
        drawFront(ctx, ui: ui)
    }
}

final class WaterModule: StyleModule {
    let sim = WaterSim()
    lazy var r = WaterRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer(), ringsLayer = CALayer()
    private lazy var resBody = MaskedGradient(r.bodyColors, WaterRenderer.bodyLocs, box: r.resBox)
    private lazy var basinBody = MaskedGradient(r.bodyColors, WaterRenderer.bodyLocs, box: r.basinBox)
    private let caustics = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.15), width: 1.2)
    private lazy var lens = gradientLayer(WaterRenderer.lensColors, WaterRenderer.lensLocs, box: r.basinBox, vertical: false)
    private let face = shapeLayer(), lines = shapeLayer(stroke: WaterRenderer.lineColor, width: 0.8)
    private let sheenBright = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.26), width: 3.2), sheenFaint = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.12), width: 1.4)
    private let glints = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.6), width: 1.2)
    private let drops = shapeLayer(), dropHi = shapeLayer(fill: WaterRenderer.hiColor)
    private var ringCtx: CGContext?
    private var backKey = "", frontKey = "", tintKey = ""
    private var previewClock: CGFloat = 0
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Water Tint"
    var colours: [(String, RGB)] { waterTints.map { ($0.name, $0.color) } }
    var colourIndex = 0 { didSet { r.tint = waterTints[colourIndex] } }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        basinBody.layer.addSublayer(lens)
        basinBody.layer.addSublayer(caustics)
        ringsLayer.frame = upRect(r.faceBox)
        ringsLayer.contentsGravity = .resize
        for l in [back, resBody.layer, basinBody.layer, face, lines, sheenBright, sheenFaint, glints, ringsLayer, drops, dropHi, front] {
            l.frame = container.bounds
            container.addSublayer(l)
        }
        ringsLayer.frame = upRect(r.faceBox)
    }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, face, lines, drops, dropHi, caustics, resBody.mask, basinBody.mask] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())|\(r.tint.name)"
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        if tintKey != r.tint.name {
            tintKey = r.tint.name
            resBody.set(colors: r.bodyColors)
            basinBody.set(colors: r.bodyColors)
            face.fillColor = r.faceColor
            drops.fillColor = r.dropColor
        }
        resBody.set(path: r.resWaterPath())
        basinBody.set(path: r.basinWaterPath())
        caustics.path = flipY(r.causticsPath())
        face.path = flipY(r.facePath())
        lines.path = flipY(r.surfaceLines())
        let sh = r.sheenPaths()
        sheenBright.path = flipY(sh.bright)
        sheenFaint.path = flipY(sh.faint)
        glints.path = flipY(r.glintPath())
        let (b, h) = r.dropPaths()
        drops.path = flipY(b)
        dropHi.path = flipY(h)

        // Ripples: a small bitmap covering just the basin's surface area.
        if sim.rings.isEmpty {
            ringsLayer.contents = nil
        } else {
            let w = Int(ceil(r.faceBox.width * ps)), hgt = Int(ceil(r.faceBox.height * ps))
            if ringCtx?.width != w || ringCtx?.height != hgt {
                ringCtx = CGContext(data: nil, width: w, height: hgt, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            if let c = ringCtx {
                c.clear(CGRect(x: 0, y: 0, width: w, height: hgt))
                c.saveGState()
                c.translateBy(x: 0, y: CGFloat(hgt))
                c.scaleBy(x: ps, y: -ps)
                c.translateBy(x: -r.faceBox.minX, y: -r.faceBox.minY)
                r.drawRings(c)
                c.restoreGState()
                ringsLayer.contents = c.makeImage()
            }
        }
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        for e in sim.events { st.post(e) }
        sim.events.removeAll(keepingCapacity: true)
        st.ex.inFill = Float(sim.basinLevel / WL.basinMaxLevel)
        if let p = previewPhase, !running {
            previewClock += dt
            if previewClock > 0.9 {
                previewClock = 0
                st.post(SoundEvent(kind: .drop, a: 0.1 + 0.8 * p, b: 1))     // preview glides from an empty basin to a full one
            }
        }
    }
}
