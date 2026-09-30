// Zen garden: a bamboo spout trickles into a rocking bamboo tube (shishi-odoshi). When the tube
// fills it tips, pours into a stone basin, swings back and knocks a stone with a hollow "tock".
// The basin fills over the timer.

import AppKit
import QuartzCore

enum ZL {
    static let spoutEnd = CGPoint(x: 56, y: 104)
    static let postX: CGFloat = 150
    static let pivot = CGPoint(x: 100, y: 150)
    static let openLen: CGFloat = 42, closedLen: CGFloat = 34, tubeR: CGFloat = 5
    static let restDeg: CGFloat = 22, tipDeg: CGFloat = -30
    static let stone = CGPoint(x: 132, y: 178)
    static let basin = CGPoint(x: 58, y: 214)
    static let opening = CGPoint(x: 58, y: 200)
    static let trayTop: CGFloat = 232, trayBottom: CGFloat = 302
    static let groundTop: CGFloat = 237, groundBottom: CGFloat = 289

    static func openEnd(_ deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: pivot.x - openLen * cos(a), y: pivot.y - openLen * sin(a))
    }
    static func closedEnd(_ deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: pivot.x + closedLen * cos(a), y: pivot.y + closedLen * sin(a))
    }
}

struct DayStyle { let name: String; let top: RGB; let bottom: RGB; let light: CGFloat; let moon: Bool; let swatch: RGB }
let dayStyles: [DayStyle] = [
    .init(name: "Morning", top: RGB(0.78, 0.86, 0.94), bottom: RGB(0.98, 0.93, 0.82), light: 1.0, moon: false, swatch: RGB(0.98, 0.90, 0.70)),
    .init(name: "Noon", top: RGB(0.56, 0.76, 0.95), bottom: RGB(0.90, 0.95, 0.98), light: 1.05, moon: false, swatch: RGB(0.56, 0.76, 0.95)),
    .init(name: "Dusk", top: RGB(0.34, 0.27, 0.48), bottom: RGB(0.98, 0.62, 0.45), light: 0.82, moon: false, swatch: RGB(0.95, 0.55, 0.42)),
    .init(name: "Night", top: RGB(0.04, 0.06, 0.16), bottom: RGB(0.17, 0.23, 0.40), light: 0.5, moon: true, swatch: RGB(0.14, 0.18, 0.36)),
    .init(name: "Rain", top: RGB(0.52, 0.57, 0.64), bottom: RGB(0.74, 0.77, 0.80), light: 0.85, moon: false, swatch: RGB(0.60, 0.65, 0.72)),
]

struct ZRing { var t: CGFloat; var strength: CGFloat }

final class ZenSim: TimerBody {
    var totalMass: CGFloat = 100
    var topMass: CGFloat = 100
    var bottomMass: CGFloat = 0
    var forming: CGFloat = 0
    var tipMass: CGFloat = 5
    var tipT: CGFloat = -1              // -1 idle, else seconds into the tipping cycle
    var pourMass: CGFloat = 0
    var pourLeft: CGFloat = 0
    var level: CGFloat = 0              // shown basin fill 0...1
    var rings: [ZRing] = []
    var ringAcc: CGFloat = 0
    var flowing = false
    var time: CGFloat = 0
    var events: [SoundEvent] = []
    var busy = true
    var rng = RNG(s: 0x2E4C_9A31_F0D7_5B6E)
    var pointer: CGPoint?
    private var stirCooldown: CGFloat = 0

    func stir(at p: CGPoint, velocity v: CGPoint) {
        pointer = p
        let speed = hypot(v.x, v.y)
        let c = ZL.opening, rx: CGFloat = 12 + 9 * level, ry = rx * 0.32
        let inside = pow((p.x - c.x) / (rx + 4), 2) + pow((p.y - (206.5 - 7 * level)) / (ry + 4), 2) < 1
        guard speed > 40, stirCooldown <= 0, inside, level > 0.002 else { return }
        rings.append(ZRing(t: 0, strength: 0.6))
        stirCooldown = 0.12
    }

    static let swingDown: CGFloat = 0.45, pourTime: CGFloat = 0.55, swingUp: CGFloat = 0.45, settle: CGFloat = 0.4
    static var cycle: CGFloat { swingDown + pourTime + swingUp + settle }

    var fillFraction: CGFloat { min(1, forming / max(tipMass, 1e-6)) }
    var pouring: Bool { tipT >= ZenSim.swingDown && tipT < ZenSim.swingDown + ZenSim.pourTime }
    var inFlight: Bool { tipT >= 0 || forming > 1e-6 }

    /// Tube angle in degrees (positive = open end raised). The tube dips slightly as it fills.
    var angle: CGFloat {
        if tipT < 0 { return ZL.restDeg - 6 * fillFraction * fillFraction }
        let t = tipT
        if t < ZenSim.swingDown {
            let u = t / ZenSim.swingDown
            return ZL.restDeg - 6 + (ZL.tipDeg - ZL.restDeg + 6) * u * u
        }
        if t < ZenSim.swingDown + ZenSim.pourTime { return ZL.tipDeg }
        let t2 = t - ZenSim.swingDown - ZenSim.pourTime
        if t2 < ZenSim.swingUp {
            let u = t2 / ZenSim.swingUp
            return ZL.tipDeg + (ZL.restDeg - ZL.tipDeg) * u * u
        }
        let t3 = t2 - ZenSim.swingUp
        return ZL.restDeg + 5 * sin(2 * .pi * t3 / 0.22) * exp(-t3 / 0.1)
    }

    func configure(forSeconds s: Double) {
        let interval = min(18, max(8, s / 40))
        let newTotal = max(6, (s / interval).rounded()) * 10
        if totalMass > 0 {
            topMass = topMass / totalMass * newTotal
            bottomMass = bottomMass / totalMass * newTotal
        }
        totalMass = newTotal
        tipMass = 10
    }

    func reset() {
        topMass = totalMass
        bottomMass = 0
        forming = 0
        tipT = -1
        pourLeft = 0
        rings.removeAll()
        level = 0
        busy = true
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        time += dt
        flowing = drain > 0
        if flowing {
            let take = min(drain, topMass)
            topMass -= take
            forming += take
        }
        if tipT < 0 {
            if forming >= tipMass || (!flowing && topMass <= 1e-9 && forming > 0.02) {
                tipT = 0
            } else if !flowing && topMass <= 1e-9 && forming > 0 {
                bottomMass += forming; forming = 0
            }
        }
        if tipT >= 0 {
            let was = tipT
            tipT += dt
            let pourStart = ZenSim.swingDown, pourEnd = ZenSim.swingDown + ZenSim.pourTime
            if was < pourStart && tipT >= pourStart {
                pourMass = forming
                pourLeft = forming
                forming = 0
                events.append(SoundEvent(kind: .pour, a: Float(min(1, pourMass / tipMass))))
            }
            if tipT >= pourStart && pourLeft > 0 {
                let give = min(pourLeft, pourMass * dt / ZenSim.pourTime)
                pourLeft -= give
                bottomMass += give
                if tipT >= pourEnd { bottomMass += pourLeft; pourLeft = 0 }
                ringAcc += dt
                if ringAcc > 0.22 { ringAcc = 0; rings.append(ZRing(t: 0, strength: 0.7 + rng.unit() * 0.3)) }
            }
            let knock = pourEnd + ZenSim.swingUp
            if was < knock && tipT >= knock { events.append(SoundEvent(kind: .tock)) }
            if tipT >= ZenSim.cycle { tipT = -1 }
        }
        for k in rings.indices.reversed() {
            rings[k].t += dt
            if rings[k].t > 1.2 { rings.remove(at: k) }
        }
        stirCooldown = max(0, stirCooldown - dt)
        let target = bottomMass / max(totalMass, 1)
        level += (target - level) * min(1, dt * 3)
        busy = flowing || tipT >= 0 || !rings.isEmpty || abs(target - level) > 0.001
    }

    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        bottomMass += take
        busy = true
    }

    func landAll() {
        bottomMass += forming + pourLeft
        forming = 0
        pourLeft = 0
        tipT = -1
        rings.removeAll()
        level = bottomMass / max(totalMass, 1)
    }

    func flip() {
        landAll()
        Swift.swap(&topMass, &bottomMass)
        level = bottomMass / max(totalMass, 1)
        busy = true
    }
}

// MARK: - Rendering

final class ZenRenderer {
    let sim: ZenSim
    var day = dayStyles[0]
    let basinFaceBox = CGRect(x: ZL.opening.x - 26, y: ZL.opening.y - 12, width: 52, height: 24)

    init(sim: ZenSim) { self.sim = sim }

    var light: CGFloat { day.light }
    func lit(_ c: RGB) -> RGB { c.scaled(light).mixed(day.top, day.moon ? 0.25 : 0.05) }
    static let bamboo = RGB(0.76, 0.66, 0.36)
    static let stoneGrey = RGB(0.52, 0.53, 0.52)
    static let gravel = RGB(0.82, 0.80, 0.74)
    static let moss = RGB(0.24, 0.40, 0.20)
    var waterColor: CGColor { day.top.mixed(RGB(1, 1, 1), 0.45).cg(0.85) }
    var streamColor: CGColor { RGB(0.85, 0.93, 1.0).cg(0.8) }

    // Water surface in the basin for the current level
    var surface: (center: CGPoint, rx: CGFloat, ry: CGFloat) {
        let f = sim.level
        let rx = 12 + 9 * f
        return (CGPoint(x: ZL.opening.x, y: 206.5 - 7 * f), rx, rx * 0.32)
    }

    /// The rocking tube as paths: body, a highlight stripe, a shadow stripe, node rings and the open mouth.
    struct TubePaths { var body: CGPath; var hi: CGPath; var shade: CGPath; var nodes: CGPath; var mouth: CGPath }
    func tube() -> TubePaths {
        let a = sim.angle * .pi / 180
        let dir = CGPoint(x: cos(a), y: sin(a))                    // from the open end toward the closed end
        let nrm = CGPoint(x: -dir.y, y: dir.x)                     // "down" across the tube
        let o = ZL.openEnd(sim.angle), c = ZL.closedEnd(sim.angle)
        let r = ZL.tubeR
        func pt(_ base: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: base.x + dir.x * along + nrm.x * across, y: base.y + dir.y * along + nrm.y * across)
        }
        let body = CGMutablePath()
        body.move(to: pt(o, 0, -r)); body.addLine(to: pt(c, 0, -r))
        body.addQuadCurve(to: pt(c, 0, r), control: pt(c, r * 1.2, 0))
        body.addLine(to: pt(o, 0, r)); body.addLine(to: pt(o, 0, -r))
        body.closeSubpath()
        let hi = CGMutablePath()
        hi.move(to: pt(o, 2, -r * 0.55)); hi.addLine(to: pt(c, -1, -r * 0.55))
        let shade = CGMutablePath()
        shade.move(to: pt(o, 1, r * 0.6)); shade.addLine(to: pt(c, -1, r * 0.6))
        let nodes = CGMutablePath()
        for d in [26.0, 56.0] as [CGFloat] { nodes.move(to: pt(o, d, -r)); nodes.addLine(to: pt(o, d, r)) }
        let mouth = CGMutablePath()
        mouth.addEllipse(in: CGRect(x: -r * 0.45, y: -r, width: r * 0.9, height: r * 2))
        var mt = CGAffineTransform(a: dir.x, b: dir.y, c: nrm.x, d: nrm.y, tx: o.x + dir.x * 0.5, ty: o.y + dir.y * 0.5)
        let mouthT = mouth.copy(using: &mt) ?? mouth
        return TubePaths(body: body, hi: hi, shade: shade, nodes: nodes, mouth: mouthT)
    }

    /// Thin stream from the spout into the tube's mouth.
    func streamPath() -> CGPath? {
        guard sim.flowing || sim.tipT >= 0 else { return nil }
        let o = ZL.openEnd(sim.angle)
        let x0 = ZL.spoutEnd.x, y0 = ZL.spoutEnd.y
        let yEnd = max(y0 + 6, o.y - 1)
        var pts: [CGPoint] = []
        var y = y0
        while y <= yEnd { pts.append(CGPoint(x: x0 + 0.6 * sin(y * 0.4 + sim.time * 9), y: y)); y += 3 }
        pts.append(CGPoint(x: x0 + 3, y: yEnd))
        let line = CGMutablePath()
        line.addLines(between: pts)
        return line.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// The pour from the tipped tube into the basin, and its splash.
    func pourPaths() -> (stream: CGPath, splash: CGPath)? {
        guard sim.pouring || (sim.tipT >= 0 && sim.pourLeft > 0) else {
            // Not pouring: just the sparkle where the stream enters the tube.
            guard sim.flowing || sim.tipT >= 0 else { return nil }
            let splash = CGMutablePath()
            var r = RNG(s: UInt64(sim.time * 60) &* 2654435761 | 1)
            let o = ZL.openEnd(sim.angle)
            for _ in 0..<3 { splash.addEllipse(in: CGRect(x: o.x + r.signed() * 4 - 0.5, y: o.y - 2 - r.unit() * 4, width: 1, height: 1)) }
            return (CGMutablePath(), splash)
        }
        let o = ZL.openEnd(sim.angle)
        let s = surface
        let end = CGPoint(x: s.center.x + 3, y: s.center.y)
        var pts: [CGPoint] = []
        for k in 0...8 {
            let t = CGFloat(k) / 8
            let x = o.x + (end.x - o.x) * t * t + 0.5 * sin(t * 14 + sim.time * 12)
            let y = o.y + (end.y - o.y) * t
            pts.append(CGPoint(x: x, y: y))
        }
        let line = CGMutablePath()
        line.addLines(between: pts)
        let width: CGFloat = sim.pouring ? 3.2 : 1.6
        let stream = line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let splash = CGMutablePath()
        var r = RNG(s: UInt64(sim.time * 60) &* 2654435761 | 1)
        if sim.flowing || sim.tipT >= 0 {
            let o = ZL.openEnd(sim.angle)
            for _ in 0..<3 { splash.addEllipse(in: CGRect(x: o.x + r.signed() * 4 - 0.5, y: o.y - 2 - r.unit() * 4, width: 1, height: 1)) }
        }
        for _ in 0..<5 {
            let dx = r.signed() * 7, dy = -r.unit() * 4
            splash.addEllipse(in: CGRect(x: end.x + dx - 0.7, y: end.y + dy - 0.7, width: 1.4, height: 1.4))
        }
        return (stream, splash)
    }

    func drawRings(_ ctx: CGContext) {
        let s = surface
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: s.center.x - s.rx, y: s.center.y - s.ry, width: s.rx * 2, height: s.ry * 2))
        ctx.clip()
        ctx.setLineWidth(0.8)
        for r in sim.rings {
            let rad = 3 + 22 * r.t
            let a = r.strength * max(0, 1 - r.t / 1.2) * 0.75
            ctx.setStrokeColor(CGColor(gray: 1, alpha: a))
            ctx.strokeEllipse(in: CGRect(x: s.center.x + 3 - rad, y: s.center.y - rad * 0.32, width: rad * 2, height: rad * 0.64))
        }
        ctx.restoreGState()
    }

    private func stone(_ ctx: CGContext, at c: CGPoint, rx: CGFloat, ry: CGFloat, seed: CGFloat, base: RGB) {
        let p = CGMutablePath()
        var pts: [CGPoint] = []
        for k in 0..<14 {
            let a = CGFloat(k) / 14 * 2 * .pi
            let w = 1 + 0.08 * sin(a * 3 + seed) + 0.05 * cos(a * 5 + seed * 2)
            pts.append(CGPoint(x: c.x + cos(a) * rx * w, y: c.y + sin(a) * ry * w))
        }
        Renderer.smooth(p, pts + [pts[0], pts[1]], move: true)
        p.closeSubpath()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(makeGradient([lit(base.scaled(1.25)).cg(), lit(base).cg(), lit(base.scaled(0.6)).cg()], [0, 0.45, 1]),
                               start: CGPoint(x: c.x - rx * 0.4, y: c.y - ry), end: CGPoint(x: c.x + rx * 0.3, y: c.y + ry), options: [])
        var sg = RNG(s: UInt64(seed * 97 + 5))
        for _ in 0..<Int(rx * ry / 6) {
            let a = sg.unit() * 2 * .pi, d = sqrt(sg.unit())
            let px = c.x + cos(a) * d * rx, py = c.y + sin(a) * d * ry
            ctx.setFillColor(sg.unit() < 0.55 ? CGColor(gray: 1, alpha: 0.06 + 0.1 * sg.unit()) : CGColor(gray: 0, alpha: 0.05 + 0.09 * sg.unit()))
            ctx.fillEllipse(in: CGRect(x: px, y: py, width: 0.8 + sg.unit(), height: 0.6 + sg.unit() * 0.6))
        }
        ctx.restoreGState()
    }

    /// A moving glint on the basin's water.
    func shimmerPath() -> CGPath {
        let s = surface
        let p = CGMutablePath()
        let a0 = CGFloat.pi * (1.05 + 0.12 * sin(sim.time * 0.7))
        var t = CGAffineTransform(translationX: s.center.x, y: s.center.y).scaledBy(x: s.rx * 0.8, y: s.ry * 0.8)
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 1, startAngle: a0, endAngle: a0 + 0.55, clockwise: false)
        p.addPath(arc.copy(using: &t) ?? arc)
        return p
    }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        _ = ui.frame
        groundShadow(ctx, y: ZL.trayBottom + 2, strength: ui.shadow, radius: 100)
        // The wooden tray: its rim and front lip
        let outer = CGPath(roundedRect: CGRect(x: 10, y: ZL.trayTop, width: L.ow - 20, height: ZL.trayBottom - ZL.trayTop), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(outer); ctx.setFillColor(lit(RGB(0.42, 0.27, 0.15)).cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(outer); ctx.clip()
        ctx.drawLinearGradient(makeGradient([lit(RGB(0.58, 0.40, 0.24)).cg(), lit(RGB(0.46, 0.30, 0.17)).cg(), lit(RGB(0.30, 0.19, 0.10)).cg()], [0, 0.85, 1]),
                               start: CGPoint(x: 0, y: ZL.trayTop), end: CGPoint(x: 0, y: ZL.trayBottom), options: [])
        ctx.restoreGState()
        frameTexture(ctx, in: outer, rect: outer.boundingBox, seed: 21)
        // Gravel inside the tray, raked around the basin
        let inner = CGRect(x: 15, y: ZL.groundTop, width: L.ow - 30, height: ZL.groundBottom - ZL.groundTop)
        ctx.saveGState()
        ctx.clip(to: inner)
        ctx.setFillColor(lit(ZenRenderer.gravel).cg())
        ctx.fill(inner)
        ctx.setStrokeColor(lit(ZenRenderer.gravel.scaled(0.86)).cg()); ctx.setLineWidth(1)
        for rad in stride(from: 34, through: 130, by: 8) {
            ctx.addEllipse(in: CGRect(x: ZL.basin.x - CGFloat(rad), y: ZL.basin.y + 20 - CGFloat(rad) * 0.35, width: CGFloat(rad) * 2, height: CGFloat(rad) * 0.7))
        }
        ctx.strokePath()
        var g = RNG(s: 0x6A5)
        for _ in 0..<700 {
            let x = inner.minX + g.unit() * inner.width, y = inner.minY + g.unit() * inner.height
            ctx.setFillColor(g.unit() < 0.5 ? CGColor(gray: 0, alpha: 0.05 + 0.08 * g.unit()) : CGColor(gray: 1, alpha: 0.08 + 0.12 * g.unit()))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: 0.9, height: 0.7))
        }
        // Shadow of the rim on the gravel
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)], [0, 1]),
                               start: CGPoint(x: 0, y: inner.minY), end: CGPoint(x: 0, y: inner.minY + 8), options: [])
        ctx.restoreGState()
        // Moss
        for (mx, my, mrx, mry) in [(30, 258, 13, 5), (ZL.basin.x + 30, ZL.basin.y + 28, 16, 6), (140, 262, 15, 5), (56, 280, 11, 4)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            ctx.setFillColor(lit(ZenRenderer.moss).cg(0.9))
            ctx.fillEllipse(in: CGRect(x: mx - mrx, y: my - mry, width: mrx * 2, height: mry * 2))
            var mg = RNG(s: UInt64(mx * 7 + my))
            for _ in 0..<40 {
                let a = mg.unit() * 2 * .pi, d = sqrt(mg.unit())
                let px = mx + cos(a) * d * mrx * 0.95, py = my + sin(a) * d * mry * 0.95
                ctx.setFillColor(lit(mg.unit() < 0.5 ? ZenRenderer.moss.scaled(1.4) : ZenRenderer.moss.scaled(0.6)).cg(0.8))
                ctx.fillEllipse(in: CGRect(x: px - 0.6, y: py - 0.45, width: 1.2, height: 0.9))
            }
        }
        // Everything on the gravel casts a soft seam of shadow where it rests
        contactShadow(ctx, at: CGPoint(x: ZL.basin.x, y: ZL.basin.y + 25), rx: 36, ry: 8, alpha: 0.38)
        contactShadow(ctx, at: CGPoint(x: ZL.stone.x, y: ZL.stone.y + 55), rx: 14, ry: 5, alpha: 0.35)
        contactShadow(ctx, at: CGPoint(x: ZL.postX, y: ZL.groundTop + 6), rx: 9, ry: 3.5, alpha: 0.35)
        contactShadow(ctx, at: CGPoint(x: ZL.pivot.x, y: ZL.groundTop + 7), rx: 8, ry: 3, alpha: 0.3)
        for (px, py, rx, ry) in [(24, 276, 6, 4), (36, 284, 5, 3), (112, 286, 7, 4), (124, 279, 5, 3), (154, 284, 6, 4), (96, 278, 4, 2.5)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            contactShadow(ctx, at: CGPoint(x: px + 1, y: py + ry * 0.7), rx: rx * 1.3, ry: ry * 0.7, alpha: 0.3)
        }
        // Pebbles and stones
        for (i, (px, py, rx, ry)) in [(24, 276, 6, 4), (36, 284, 5, 3), (112, 286, 7, 4), (124, 279, 5, 3), (154, 284, 6, 4), (96, 278, 4, 2.5)].enumerated() as EnumeratedSequence<[(CGFloat, CGFloat, CGFloat, CGFloat)]> {
            stone(ctx, at: CGPoint(x: px, y: py), rx: rx, ry: ry, seed: CGFloat(i) * 1.7 + 3, base: ZenRenderer.stoneGrey.scaled(0.85 + 0.1 * CGFloat(i % 3)))
        }
        // The standing stone that the tube knocks against
        stone(ctx, at: CGPoint(x: ZL.stone.x, y: ZL.stone.y + 22), rx: 11, ry: 33, seed: 5, base: ZenRenderer.stoneGrey.scaled(0.9))
        // Stone basin with a dark hollow
        stone(ctx, at: ZL.basin, rx: 34, ry: 25, seed: 9, base: ZenRenderer.stoneGrey)
        ctx.setFillColor(lit(RGB(0.18, 0.19, 0.19)).cg())
        ctx.fillEllipse(in: CGRect(x: ZL.opening.x - 23, y: ZL.opening.y - 7.5, width: 46, height: 15))
        ctx.setFillColor(lit(RGB(0.10, 0.11, 0.12)).cg())
        ctx.fillEllipse(in: CGRect(x: ZL.opening.x - 20, y: ZL.opening.y - 5, width: 40, height: 12))
        ctx.addEllipse(in: CGRect(x: ZL.opening.x - 25, y: ZL.opening.y - 8.5, width: 50, height: 17))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22)); ctx.setLineWidth(3); ctx.strokePath()
        // Bamboo post carrying the spout
        let post = CGRect(x: ZL.postX - 5, y: 84, width: 10, height: ZL.groundTop + 6 - 84)
        ctx.saveGState()
        ctx.clip(to: post)
        ctx.drawLinearGradient(makeGradient([lit(ZenRenderer.bamboo.scaled(0.6)).cg(), lit(ZenRenderer.bamboo.scaled(1.2)).cg(), lit(ZenRenderer.bamboo).cg(), lit(ZenRenderer.bamboo.scaled(0.55)).cg()], [0, 0.3, 0.6, 1]),
                               start: CGPoint(x: post.minX, y: 0), end: CGPoint(x: post.maxX, y: 0), options: [])
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(0.6)
        for k in 0..<5 { let xx = post.minX + 1 + CGFloat(k) * 2; ctx.move(to: CGPoint(x: xx, y: post.minY)); ctx.addLine(to: CGPoint(x: xx, y: post.maxY)) }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(0.45)).cg()); ctx.setLineWidth(1.4)
        for y in stride(from: 120, through: 230, by: 38) { ctx.move(to: CGPoint(x: post.minX, y: CGFloat(y))); ctx.addLine(to: CGPoint(x: post.maxX, y: CGFloat(y))) }
        ctx.strokePath()
        ctx.setFillColor(lit(ZenRenderer.bamboo.scaled(0.8)).cg())
        ctx.fillEllipse(in: CGRect(x: post.minX, y: 81, width: 10, height: 6))
        // The spout pipe, lashed to the post
        let pipe = CGMutablePath()
        pipe.move(to: CGPoint(x: ZL.postX - 2, y: 92)); pipe.addLine(to: CGPoint(x: ZL.spoutEnd.x + 2, y: ZL.spoutEnd.y - 5))
        pipe.addLine(to: CGPoint(x: ZL.spoutEnd.x - 4, y: ZL.spoutEnd.y + 4)); pipe.addLine(to: CGPoint(x: ZL.postX - 2, y: 102))
        pipe.closeSubpath()
        ctx.saveGState()
        ctx.addPath(pipe); ctx.clip()
        ctx.drawLinearGradient(makeGradient([lit(ZenRenderer.bamboo.scaled(1.2)).cg(), lit(ZenRenderer.bamboo).cg(), lit(ZenRenderer.bamboo.scaled(0.6)).cg()], [0, 0.4, 1]),
                               start: CGPoint(x: 0, y: 90), end: CGPoint(x: 0, y: 106), options: [])
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.07)); ctx.setLineWidth(0.6)
        for k in 0..<5 { let yy = 93.5 + CGFloat(k) * 1.8; ctx.move(to: CGPoint(x: ZL.postX, y: yy - (ZL.postX - ZL.spoutEnd.x) * 0.15)); ctx.addLine(to: CGPoint(x: ZL.spoutEnd.x, y: yy + ZL.spoutEnd.x * 0.15)) }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(0.5)).cg()); ctx.setLineWidth(1)
        for x in [80.0, 112.0] as [CGFloat] {
            let yy = 92 + (ZL.postX - x) / (ZL.postX - ZL.spoutEnd.x) * (ZL.spoutEnd.y - 5 - 92)
            ctx.move(to: CGPoint(x: x, y: yy)); ctx.addLine(to: CGPoint(x: x, y: yy + 9))
        }
        ctx.strokePath()
        ctx.setStrokeColor(lit(RGB(0.25, 0.18, 0.10)).cg()); ctx.setLineWidth(1.3)
        for k in 0..<4 { let yy: CGFloat = 90 + CGFloat(k) * 3.6; ctx.move(to: CGPoint(x: ZL.postX - 7, y: yy)); ctx.addLine(to: CGPoint(x: ZL.postX + 7, y: yy + 1.2)) }
        ctx.strokePath()
        ctx.setFillColor(lit(RGB(0.25, 0.22, 0.12)).cg())
        ctx.fillEllipse(in: CGRect(x: ZL.spoutEnd.x - 3, y: ZL.spoutEnd.y - 5, width: 4, height: 9))
        // Support post behind the tube
        ctx.setFillColor(lit(ZenRenderer.bamboo.scaled(0.75)).cg())
        ctx.fill(CGRect(x: ZL.pivot.x - 6, y: ZL.pivot.y - 2, width: 3, height: ZL.groundTop - ZL.pivot.y + 8))
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        // Support post in front of the tube, and the ladle resting on the basin
        ctx.setFillColor(lit(ZenRenderer.bamboo.scaled(0.95)).cg())
        ctx.fill(CGRect(x: ZL.pivot.x + 3, y: ZL.pivot.y - 2, width: 3, height: ZL.groundTop - ZL.pivot.y + 8))
        ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(0.9)).cg()); ctx.setLineWidth(2); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: ZL.basin.x - 40, y: ZL.basin.y - 6)); ctx.addLine(to: CGPoint(x: ZL.basin.x + 8, y: ZL.basin.y - 12)); ctx.strokePath()
        ctx.setFillColor(lit(ZenRenderer.bamboo.scaled(0.8)).cg())
        ctx.fillEllipse(in: CGRect(x: ZL.basin.x + 4, y: ZL.basin.y - 16, width: 12, height: 7))
        // Front lip of the tray
        let lip = CGRect(x: 10, y: ZL.groundBottom, width: L.ow - 20, height: ZL.trayBottom - ZL.groundBottom)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 10, y: ZL.trayTop, width: L.ow - 20, height: ZL.trayBottom - ZL.trayTop), cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.clip()
        ctx.clip(to: lip)
        ctx.drawLinearGradient(makeGradient([lit(RGB(0.55, 0.38, 0.22)).cg(), lit(RGB(0.36, 0.23, 0.12)).cg()], [0, 1]),
                               start: CGPoint(x: 0, y: lip.minY), end: CGPoint(x: 0, y: lip.maxY), options: [])
        ctx.restoreGState()
        drawBadge(ctx, ui: ui, accent: RGB(0.62, 0.8, 0.38))
    }

    func drawDynamic(_ ctx: CGContext) {
        if let s = streamPath() { ctx.addPath(s); ctx.setFillColor(streamColor); ctx.fillPath() }
        let t = tube()
        ctx.addPath(t.body); ctx.setFillColor(lit(ZenRenderer.bamboo).cg()); ctx.fillPath()
        ctx.setLineCap(.round)
        ctx.addPath(t.hi); ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(1.25)).cg(0.9)); ctx.setLineWidth(2.2); ctx.strokePath()
        ctx.addPath(t.shade); ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(0.6)).cg(0.8)); ctx.setLineWidth(2.4); ctx.strokePath()
        ctx.addPath(t.nodes); ctx.setStrokeColor(lit(ZenRenderer.bamboo.scaled(0.5)).cg()); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.addPath(t.mouth); ctx.setFillColor(lit(RGB(0.22, 0.18, 0.10)).cg()); ctx.fillPath()
        let s = surface
        if sim.level > 0.002 || sim.pourLeft > 0 {
            ctx.addEllipse(in: CGRect(x: s.center.x - s.rx, y: s.center.y - s.ry, width: s.rx * 2, height: s.ry * 2))
            ctx.setFillColor(waterColor); ctx.fillPath()
            ctx.addPath(shimmerPath()); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55)); ctx.setLineWidth(0.9); ctx.strokePath()
            drawRings(ctx)
        }
        if let (stream, splash) = pourPaths() {
            ctx.addPath(stream); ctx.setFillColor(streamColor); ctx.fillPath()
            ctx.addPath(splash); ctx.setFillColor(CGColor(gray: 1, alpha: 0.8)); ctx.fillPath()
        }
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawDynamic(ctx)
        drawFront(ctx, ui: ui)
    }
}

final class ZenModule: StyleModule {
    let sim = ZenSim()
    lazy var r = ZenRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer()
    private let shimmer = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.55), width: 0.9)
    private let stream = shapeLayer(), tubeBody = shapeLayer(), tubeHi = shapeLayer(width: 2.2), tubeShade = shapeLayer(width: 2.4)
    private let tubeNodes = shapeLayer(width: 1.2), mouth = shapeLayer(), water = shapeLayer(), pour = shapeLayer(), splash = shapeLayer(fill: CGColor(gray: 1, alpha: 0.8))
    private lazy var rings = MiniCanvas(box: r.basinFaceBox)
    private var backKey = "", frontKey = "", dayKey = ""
    private var built = false
    private var previewTocked = false

    var body: TimerBody { sim }
    let colourTitle = "Time of Day"
    var colours: [(String, RGB)] { dayStyles.map { ($0.name, $0.swatch) } }
    var colourIndex = 0 { didSet { r.day = dayStyles[colourIndex] } }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        for l in [back, stream, tubeBody, tubeHi, tubeShade, tubeNodes, mouth, water, shimmer, rings.layer, pour, splash, front] {
            if l !== rings.layer { l.frame = container.bounds }
            container.addSublayer(l)
        }
    }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, stream, tubeBody, tubeHi, tubeShade, tubeNodes, mouth, water, pour, splash] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())|\(r.day.name)"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())|\(r.day.name)"
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        if dayKey != r.day.name {
            dayKey = r.day.name
            stream.fillColor = r.streamColor
            pour.fillColor = r.streamColor
            tubeBody.fillColor = r.lit(ZenRenderer.bamboo).cg()
            tubeHi.strokeColor = r.lit(ZenRenderer.bamboo.scaled(1.25)).cg(0.9)
            tubeShade.strokeColor = r.lit(ZenRenderer.bamboo.scaled(0.6)).cg(0.8)
            tubeNodes.strokeColor = r.lit(ZenRenderer.bamboo.scaled(0.5)).cg()
            mouth.fillColor = r.lit(RGB(0.22, 0.18, 0.10)).cg()
            water.fillColor = r.waterColor
        }
        stream.path = flipY(r.streamPath())
        let t = r.tube()
        tubeBody.path = flipY(t.body)
        tubeHi.path = flipY(t.hi)
        tubeShade.path = flipY(t.shade)
        tubeNodes.path = flipY(t.nodes)
        mouth.path = flipY(t.mouth)
        let s = r.surface
        if sim.level > 0.002 || sim.pourLeft > 0 {
            water.path = flipY(CGPath(ellipseIn: CGRect(x: s.center.x - s.rx, y: s.center.y - s.ry, width: s.rx * 2, height: s.ry * 2), transform: nil))
            shimmer.path = flipY(r.shimmerPath())
        } else {
            water.path = nil
            shimmer.path = nil
        }
        if sim.rings.isEmpty { rings.clear() } else { rings.draw(ps) { r.drawRings($0) } }
        if let (st, sp) = r.pourPaths() { pour.path = flipY(st); splash.path = flipY(sp) } else { pour.path = nil; splash.path = nil }
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) {
        if let p { sim.stir(at: p, velocity: velocity) } else { sim.pointer = nil }
    }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        for e in sim.events { st.post(e) }
        sim.events.removeAll(keepingCapacity: true)
        if let p = previewPhase, !running {
            // Preview: the trickle with the tube filling, then one knock near the end.
            st.ex.inFlow = 1
            st.ex.inFill = p
            if p >= 0.8 && !previewTocked { previewTocked = true; st.post(SoundEvent(kind: .tock)) }
        } else {
            previewTocked = false
            st.ex.inFlow = Float(sim.flowing || sim.tipT >= 0 ? 1 : 0)
            st.ex.inFill = Float(sim.fillFraction)
        }
    }
}
