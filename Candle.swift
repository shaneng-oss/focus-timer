// Candle: a pillar candle burns down as the timer runs. The flame flickers and sways, lights the
// wax below it, and goes out (with a wisp of smoke) whenever the timer stops. Wax drips run down
// the side now and then and set where they stop.

import AppKit
import QuartzCore

enum CL {
    // A cream candle poured in a clear glass tumbler; the wax level sinks inside the glass.
    static let jarTop: CGFloat = 112, jarBottom: CGFloat = 274
    static let jarRY: CGFloat = 7.2                 // perspective of the rim
    static let waxFull: CGFloat = 136, waxStub: CGFloat = 258
    static let wickH: CGFloat = 7
    static let topRY: CGFloat = 6.4                 // perspective of the wax's top face
    static let radius: CGFloat = 38                 // wax radius near the top (the glass tapers slightly)
    static let bottom: CGFloat = jarBottom - 3
    static func jarHalf(_ y: CGFloat) -> CGFloat { 36 + 4 * (jarBottom - y) / (jarBottom - jarTop) }
    static func waxHalf(_ y: CGFloat) -> CGFloat { jarHalf(y) - 1.8 }
}

struct CandleColour { let name: String; let wax: RGB }
let candleColours: [CandleColour] = [
    .init(name: "Ivory", wax: RGB(0.96, 0.93, 0.85)),
    .init(name: "Beeswax", wax: RGB(0.93, 0.78, 0.45)),
    .init(name: "Crimson", wax: RGB(0.72, 0.15, 0.18)),
    .init(name: "Forest", wax: RGB(0.16, 0.40, 0.28)),
    .init(name: "Navy", wax: RGB(0.17, 0.23, 0.44)),
    .init(name: "Lavender", wax: RGB(0.72, 0.62, 0.86)),
    .init(name: "Charcoal", wax: RGB(0.25, 0.25, 0.27)),
]

struct WaxRun { var x: CGFloat; var y0: CGFloat; var y: CGFloat; var v: CGFloat; var tau: CGFloat; var wobble: CGFloat; var moving: Bool }
struct Smoke { var x: CGFloat; var y0: CGFloat; var t: CGFloat; var seed: CGFloat }

final class CandleSim: TimerBody {
    let totalMass: CGFloat = CL.waxStub - CL.waxFull
    var topMass: CGFloat = CL.waxStub - CL.waxFull
    var bottomMass: CGFloat = 0
    var lit = false
    var litHint = false
    var flame: CGFloat = 0          // 0 out ... 1 burning
    var flare: CGFloat = 0          // brief overshoot right after lighting
    var gust: CGFloat = 0, gustTarget: CGFloat = 0, gustTimer: CGFloat = 3
    var time: CGFloat = 0
    var runs: [WaxRun] = []
    var smoke: [Smoke] = []
    var dripTimer: CGFloat = 8
    var pointer: CGPoint?
    var lean: CGFloat = 0, mouseGust: CGFloat = 0
    var events: [SoundEvent] = []
    var busy = true
    var rng = RNG(s: 0x6C0F_FEE5_1234_ABCD)

    var topY: CGFloat { CL.waxStub - topMass }
    var inFlight: Bool { false }
    func configure(forSeconds s: Double) {}

    func reset() {
        topMass = totalMass
        bottomMass = 0
        runs.removeAll(); smoke.removeAll(); events.removeAll()
        flame = 0; flare = 0; lit = false
        dripTimer = 6 + rng.unit() * 10
        busy = true
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        time += dt
        let wantLit = (drain > 0 || litHint) && topMass > 1e-6
        litHint = false
        if wantLit != lit {
            lit = wantLit
            if lit { events.append(SoundEvent(kind: .light)); flare = 1 }
            else if flame > 0.2 {
                events.append(SoundEvent(kind: .extinguish))
                smoke.append(Smoke(x: L.cx, y0: topY - CL.wickH, t: 0, seed: rng.unit() * 10))
            }
        }
        if drain > 0 {
            let take = min(drain, topMass)
            topMass -= take
            bottomMass += take
        }
        flame += ((lit ? 1 : 0) - flame) * min(1, dt * (lit ? 4 : 9))
        if !lit && flame < 0.01 { flame = 0 }
        flare *= exp(-dt * 3)

        // Gusts: every few seconds the flame leans and shrinks for a moment.
        gustTimer -= dt
        if gustTimer <= 0 {
            gustTarget = gustTarget > 0 ? 0 : 0.4 + rng.unit() * 0.6
            gustTimer = gustTarget > 0 ? 0.4 + rng.unit() * 1.2 : 2 + rng.unit() * 6
        }
        gust += (gustTarget - gust) * min(1, dt * 5)
        // The cursor is a draught: the flame leans toward it and flutters when it moves fast.
        var leanTarget: CGFloat = 0
        if let p = pointer {
            let dy = (topY - CL.wickH - 14) - p.y
            let near = max(0, 1 - abs(dy) / 120)
            leanTarget = min(1, max(-1, (p.x - L.cx) / 45)) * near
        }
        lean += (leanTarget - lean) * min(1, dt * 6)
        mouseGust *= exp(-dt * 3)

        // Wax runs
        if lit && false {
            dripTimer -= dt
            if dripTimer <= 0 {
                dripTimer = 12 + rng.unit() * 24
                let x = L.cx + rng.signed() * CL.radius * 0.8
                runs.append(WaxRun(x: x, y0: topY + 1.5, y: topY + 1.5, v: 12 + rng.unit() * 8, tau: 1.5 + rng.unit() * 2.5, wobble: rng.unit() * 6, moving: true))
                if runs.count > 14 { runs.removeFirst() }
            }
        }
        var anyMoving = false
        for i in runs.indices where runs[i].moving {
            runs[i].v *= exp(-dt / runs[i].tau)
            runs[i].y += runs[i].v * dt
            if runs[i].y > CL.bottom - 2 { runs[i].y = CL.bottom - 2; runs[i].moving = false }
            if runs[i].v < 0.5 { runs[i].moving = false }
            anyMoving = true
        }
        runs.removeAll { $0.y0 >= topY + 0.5 && $0.y <= topY + 0.5 }   // burnt away entirely
        for i in smoke.indices.reversed() {
            smoke[i].t += dt
            if smoke[i].t > 5 { smoke.remove(at: i) }
        }
        busy = lit || flame > 0 || !smoke.isEmpty || anyMoving || flare > 0.01 || abs(lean) > 0.01 || mouseGust > 0.01
    }

    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        bottomMass += take
        litHint = true
        busy = true
    }

    func landAll() {}

    /// A fresh candle whose height is what has burnt so far.
    func flip() {
        Swift.swap(&topMass, &bottomMass)
        runs.removeAll()
        busy = true
    }
}

// MARK: - Rendering

final class CandleRenderer {
    let sim: CandleSim
    var colour = candleColours[0]
    let bodyBox = CGRect(x: L.cx - CL.radius - 4, y: CL.waxFull - 8, width: CL.radius * 2 + 8, height: CL.bottom - CL.waxFull + 8)
    let jar: CGPath = {
        let p = CGMutablePath()
        let rt = CL.jarHalf(CL.jarTop), rb = CL.jarHalf(CL.jarBottom)
        p.move(to: CGPoint(x: L.cx - rt, y: CL.jarTop))
        p.addLine(to: CGPoint(x: L.cx - rb, y: CL.jarBottom - 6))
        p.addQuadCurve(to: CGPoint(x: L.cx - rb + 8, y: CL.jarBottom + CL.jarRY * 0.7), control: CGPoint(x: L.cx - rb, y: CL.jarBottom + CL.jarRY * 0.5))
        p.addQuadCurve(to: CGPoint(x: L.cx + rb - 8, y: CL.jarBottom + CL.jarRY * 0.7), control: CGPoint(x: L.cx, y: CL.jarBottom + CL.jarRY * 1.4))
        p.addQuadCurve(to: CGPoint(x: L.cx + rb, y: CL.jarBottom - 6), control: CGPoint(x: L.cx + rb, y: CL.jarBottom + CL.jarRY * 0.5))
        p.addLine(to: CGPoint(x: L.cx + rt, y: CL.jarTop))
        p.addCurve(to: CGPoint(x: L.cx - rt, y: CL.jarTop), control1: CGPoint(x: L.cx + rt, y: CL.jarTop - CL.jarRY * 1.33), control2: CGPoint(x: L.cx - rt, y: CL.jarTop - CL.jarRY * 1.33))
        p.closeSubpath()
        return p
    }()
    var glowInColors: [CGColor] { [glowColor.cg(0.0), glowColor.cg(0.12), glowColor.cg(0.3)] }
    static let aoColors: [CGColor] = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.22)]
    static let aoLocs: [CGFloat] = [0, 1]
    static let reflectColor = RGB(1, 0.72, 0.3).cg(0.32)

    /// The flame mirrored faintly in the inner walls of the glass.
    func reflectPath(_ f: Flame) -> CGPath {
        let p = CGMutablePath()
        let h = f.h * 0.6, w: CGFloat = 3.2
        let y = f.y - f.h * 0.35
        p.addEllipse(in: CGRect(x: L.cx - CL.jarHalf(y) * 0.86 - w / 2, y: y - h / 2, width: w, height: h))
        p.addEllipse(in: CGRect(x: L.cx + CL.jarHalf(y) * 0.82 - w / 2, y: y - h / 2, width: w, height: h))
        return p
    }
    static let glowInLocs: [CGFloat] = [0, 0.5, 1]
    let glowColor = RGB(1.0, 0.72, 0.32)
    let flameColors: [CGColor] = [RGB(0.95, 0.30, 0.04).cg(0.0), RGB(0.98, 0.45, 0.08).cg(0.85), RGB(1.0, 0.72, 0.18).cg(0.95),
                                  RGB(1.0, 0.86, 0.35).cg(0.98), RGB(1.0, 0.80, 0.30).cg(0.9)]
    static let flameLocs: [CGFloat] = [0, 0.12, 0.5, 0.85, 1]
    static let innerColor = RGB(1.0, 0.97, 0.78).cg(0.95)
    static let blueColor = RGB(0.40, 0.55, 1.0).cg(0.75)

    init(sim: CandleSim) { self.sim = sim }

    var bodyColors: [CGColor] {
        let c = colour.wax
        return [c.scaled(0.68).cg(), c.scaled(0.98).cg(), c.mixed(RGB(1, 1, 1), 0.18).cg(), c.scaled(0.95).cg(), c.scaled(0.58).cg()]
    }
    static let bodyLocs: [CGFloat] = [0, 0.25, 0.42, 0.72, 1]
    var litColors: [CGColor] { [RGB(1, 0.78, 0.4).cg(0.68), RGB(1, 0.75, 0.4).cg(0.22), RGB(1, 0.7, 0.4).cg(0)] }
    static let litLocs: [CGFloat] = [0, 0.3, 1]
    var rimColor: CGColor { colour.wax.mixed(RGB(1, 1, 1), 0.22).cg() }
    var poolColor: CGColor { colour.wax.scaled(0.92).mixed(RGB(1, 0.85, 0.5), 0.15).cg() }
    var dripColor: CGColor { colour.wax.mixed(RGB(1, 1, 1), 0.12).cg() }

    // Flame geometry for this frame
    struct Flame { var x: CGFloat; var y: CGFloat; var h: CGFloat; var w: CGFloat; var dx: CGFloat; var bright: CGFloat; var level: CGFloat }
    func flame() -> Flame {
        let t = sim.time
        let level = sim.flame
        let g = min(1, sim.gust + sim.mouseGust)
        let scale = (0.2 + 0.8 * level) * (1 + 0.35 * sim.flare)
        let h = 30 * (0.85 + 0.3 * wobble(t * 1.1, 1)) * (1 - 0.35 * g) * scale
        let w = 9.5 * (0.9 + 0.2 * wobble(t * 1.4, 7)) * (1 + 0.25 * g) * (0.6 + 0.4 * level)
        let dx = (wobble(t * 0.9, 3) - 0.5) * 6 * (1 + 2.2 * g) + sim.gust * 5 + sim.lean * 11
        let bright = (0.82 + 0.18 * wobble(t * 2.3, 11)) * level
        return Flame(x: L.cx, y: sim.topY - CL.wickH, h: h, w: w, dx: dx, bright: bright, level: level)
    }

    func flamePath(_ f: Flame, inner: Bool) -> CGPath {
        let p = CGMutablePath()
        let w = inner ? f.w * 0.5 : f.w, h = inner ? f.h * 0.62 : f.h
        let y0 = inner ? f.y - 1.5 : f.y + 1
        let dx = inner ? f.dx * 0.7 : f.dx
        p.move(to: CGPoint(x: f.x - w / 2, y: y0))
        p.addCurve(to: CGPoint(x: f.x + dx, y: y0 - h), control1: CGPoint(x: f.x - w / 2, y: y0 - h * 0.45), control2: CGPoint(x: f.x + dx - w * 0.18, y: y0 - h * 0.78))
        p.addCurve(to: CGPoint(x: f.x + w / 2, y: y0), control1: CGPoint(x: f.x + dx + w * 0.18, y: y0 - h * 0.78), control2: CGPoint(x: f.x + w / 2, y: y0 - h * 0.45))
        p.addQuadCurve(to: CGPoint(x: f.x - w / 2, y: y0), control: CGPoint(x: f.x, y: y0 + w * 0.4))
        p.closeSubpath()
        return p
    }

    func bodyPath() -> CGPath {
        let p = CGMutablePath()
        let top = sim.topY, r = CL.waxHalf(top), rb = CL.waxHalf(CL.bottom)
        p.move(to: CGPoint(x: L.cx - r, y: top))
        p.addLine(to: CGPoint(x: L.cx - rb, y: CL.bottom))
        p.addCurve(to: CGPoint(x: L.cx + rb, y: CL.bottom), control1: CGPoint(x: L.cx - rb, y: CL.bottom + CL.topRY * 1.33), control2: CGPoint(x: L.cx + rb, y: CL.bottom + CL.topRY * 1.33))
        p.addLine(to: CGPoint(x: L.cx + r, y: top))
        p.addCurve(to: CGPoint(x: L.cx - r, y: top), control1: CGPoint(x: L.cx + r, y: top + CL.topRY * 1.33), control2: CGPoint(x: L.cx - r, y: top + CL.topRY * 1.33))
        p.closeSubpath()
        return p
    }

    /// The air inside the jar above the wax (lit warm by the flame).
    func airPath() -> CGPath {
        let p = CGMutablePath()
        let top = sim.topY, rt = CL.waxHalf(CL.jarTop) + 1, r = CL.waxHalf(top) + 1
        p.move(to: CGPoint(x: L.cx - rt, y: CL.jarTop))
        p.addLine(to: CGPoint(x: L.cx - r, y: top))
        p.addCurve(to: CGPoint(x: L.cx + r, y: top), control1: CGPoint(x: L.cx - r, y: top + CL.topRY * 1.33), control2: CGPoint(x: L.cx + r, y: top + CL.topRY * 1.33))
        p.addLine(to: CGPoint(x: L.cx + rt, y: CL.jarTop))
        p.closeSubpath()
        return p
    }

    func topFacePath() -> CGPath {
        let r = CL.waxHalf(sim.topY)
        return CGPath(ellipseIn: CGRect(x: L.cx - r, y: sim.topY - CL.topRY, width: r * 2, height: CL.topRY * 2), transform: nil)
    }
    func poolPath() -> CGPath {
        let rx = CL.waxHalf(sim.topY) * 0.76, ry = CL.topRY * 0.72
        return CGPath(ellipseIn: CGRect(x: L.cx - rx, y: sim.topY + 1.1 - ry, width: rx * 2, height: ry * 2), transform: nil)
    }
    func poolHighlight() -> CGPath {
        let p = CGMutablePath()
        let rx = CL.waxHalf(sim.topY) * 0.6, ry = CL.topRY * 0.5
        let t = CGAffineTransform(translationX: L.cx, y: sim.topY + 1.1).scaledBy(x: rx, y: ry)
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 1, startAngle: .pi * 1.15, endAngle: .pi * 1.75, clockwise: false)
        p.addPath(arc, transform: t)
        return p
    }

    func dripPaths() -> (solid: CGPath, moving: CGPath) {
        let solid = CGMutablePath(), moving = CGMutablePath()
        for r in sim.runs {
            let top = max(r.y0, sim.topY + 0.5)
            guard r.y > top + 0.5 else { continue }
            let p = r.moving ? moving : solid
            var pts: [CGPoint] = []
            var y = top
            while y < r.y { pts.append(CGPoint(x: r.x + 0.5 * sin(y * 0.25 + r.wobble), y: y)); y += 3 }
            pts.append(CGPoint(x: r.x, y: r.y))
            if pts.count >= 2 {
                let trail = CGMutablePath()
                trail.addLines(between: pts)
                p.addPath(trail.copy(strokingWithWidth: 2.8, lineCap: .round, lineJoin: .round, miterLimit: 1))
            }
            p.addEllipse(in: CGRect(x: r.x - 2.3, y: r.y - 2.2, width: 4.6, height: 5.4))
        }
        return (solid, moving)
    }

    func wickPath() -> CGPath {
        let p = CGMutablePath()
        let f = flame()
        p.move(to: CGPoint(x: L.cx, y: sim.topY + 1.5))
        p.addQuadCurve(to: CGPoint(x: L.cx + f.dx * 0.25, y: f.y), control: CGPoint(x: L.cx - 0.5, y: sim.topY - CL.wickH * 0.5))
        return p
    }

    func smokePath() -> CGPath {
        let p = CGMutablePath()
        for s in sim.smoke {
            let len = min(95, 42 * s.t)
            var pts: [CGPoint] = []
            var d: CGFloat = 0
            while d <= len {
                let y = s.y0 - d
                let x = s.x + 5 * sin(d * 0.07 + s.t * 1.6 + s.seed) + 3 * sin(d * 0.19 - s.t * 0.9) + d * 0.06 * sin(s.seed)
                pts.append(CGPoint(x: x, y: y))
                d += 4
            }
            if pts.count > 1 { p.addLines(between: pts) }
        }
        return p
    }
    var smokeAlpha: CGFloat { sim.smoke.map { max(0, 0.32 * (1 - $0.t / 5)) }.max() ?? 0 }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        groundShadow(ctx, y: CL.jarBottom + 9, strength: ui.shadow, radius: 70)
        ctx.addPath(jar); ctx.setFillColor(CGColor(gray: 1, alpha: 0.07)); ctx.fillPath()
        // Back half of the rim, seen through the glass
        let rt = CL.jarHalf(CL.jarTop)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: L.width, height: CL.jarTop))
        ctx.addEllipse(in: CGRect(x: L.cx - rt, y: CL.jarTop - CL.jarRY, width: rt * 2, height: CL.jarRY * 2))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3)); ctx.setLineWidth(1); ctx.strokePath()
        ctx.restoreGState()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        // The glass: side shading, reflections, rim and thick base
        ctx.saveGState()
        ctx.addPath(jar); ctx.clip()
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0),
                                             CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0.13)], [0, 0.25, 0.5, 0.8, 1]),
                               start: CGPoint(x: L.cx - 40, y: 0), end: CGPoint(x: L.cx + 40, y: 0), options: [])
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.18)], [0, 1]),
                               start: CGPoint(x: 0, y: CL.jarBottom - 12), end: CGPoint(x: 0, y: CL.jarBottom + 4), options: [])
        ctx.restoreGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28)); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: L.cx - CL.jarHalf(CL.jarTop) * 0.8, y: CL.jarTop + 10)); ctx.addLine(to: CGPoint(x: L.cx - CL.jarHalf(CL.jarBottom) * 0.8, y: CL.jarBottom - 14)); ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: L.cx + CL.jarHalf(CL.jarTop) * 0.86, y: CL.jarTop + 10)); ctx.addLine(to: CGPoint(x: L.cx + CL.jarHalf(CL.jarBottom) * 0.86, y: CL.jarBottom - 14)); ctx.strokePath()
        glassStreak(ctx, in: jar, center: CGPoint(x: L.cx - 6, y: CL.jarTop + 60), length: 120, width: 7, alpha: 0.10)
        ctx.setLineJoin(.round)
        ctx.addPath(jar); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.28)); ctx.setLineWidth(2.2); ctx.strokePath()
        ctx.addPath(jar); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(1.0); ctx.strokePath()
        fresnelRim(ctx, jar, width: 6, alpha: 0.16)
        let rt = CL.jarHalf(CL.jarTop)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: CL.jarTop, width: L.width, height: 20))
        ctx.addEllipse(in: CGRect(x: L.cx - rt, y: CL.jarTop - CL.jarRY, width: rt * 2, height: CL.jarRY * 2))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.restoreGState()
        drawBadge(ctx, ui: ui, accent: RGB(0.9, 0.76, 0.45))
    }

    func glowImage(radius: CGFloat, alpha: CGFloat, ps: CGFloat) -> CGImage? {
        let px = Int(ceil(radius * 2 * ps))
        guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ctr = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        c.drawRadialGradient(makeGradient([glowColor.cg(alpha), glowColor.cg(alpha * 0.35), glowColor.cg(0)], [0, 0.35, 1]),
                             startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: CGFloat(px) / 2, options: [])
        return c.makeImage()
    }

    func drawDynamic(_ ctx: CGContext) {
        let f = flame()
        if f.level > 0.01 {
            ctx.saveGState()
            ctx.addPath(airPath()); ctx.clip()
            ctx.setAlpha(f.bright)
            ctx.drawLinearGradient(makeGradient(glowInColors, CandleRenderer.glowInLocs), start: CGPoint(x: 0, y: CL.jarTop), end: CGPoint(x: 0, y: sim.topY), options: [])
            ctx.restoreGState()
            for (rad, a) in [(90.0, 0.30), (24.0, 0.5)] as [(CGFloat, CGFloat)] {
                let ctr = CGPoint(x: f.x + f.dx * 0.4, y: f.y - f.h * 0.45)
                ctx.drawRadialGradient(makeGradient([glowColor.cg(a * f.bright), glowColor.cg(a * f.bright * 0.35), glowColor.cg(0)], [0, 0.35, 1]),
                                       startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: rad, options: [])
            }
        }
        let body = bodyPath()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        ctx.drawLinearGradient(makeGradient(bodyColors, CandleRenderer.bodyLocs), start: CGPoint(x: bodyBox.minX, y: 0), end: CGPoint(x: bodyBox.maxX, y: 0), options: [])
        ctx.drawLinearGradient(makeGradient(CandleRenderer.aoColors, CandleRenderer.aoLocs), start: CGPoint(x: 0, y: CL.bottom - 26), end: CGPoint(x: 0, y: CL.bottom + 4), options: [])
        if f.level > 0.01 {
            ctx.saveGState(); ctx.setAlpha(f.bright)
            ctx.drawLinearGradient(makeGradient(litColors, CandleRenderer.litLocs), start: CGPoint(x: 0, y: sim.topY), end: CGPoint(x: 0, y: sim.topY + 70), options: [])
            ctx.restoreGState()
        }
        let (solid, moving) = dripPaths()
        ctx.addPath(solid); ctx.setFillColor(dripColor); ctx.fillPath()
        ctx.addPath(moving); ctx.setFillColor(dripColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(topFacePath()); ctx.setFillColor(rimColor); ctx.fillPath()
        ctx.addPath(poolPath()); ctx.setFillColor(poolColor); ctx.fillPath()
        ctx.addPath(poolHighlight()); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45)); ctx.setLineWidth(0.8); ctx.strokePath()
        ctx.addPath(wickPath()); ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(1.4); ctx.setLineCap(.round); ctx.strokePath()
        if f.level > 0.01 {
            ctx.setFillColor(RGB(1, 0.35, 0.1).cg(f.level))
            ctx.fillEllipse(in: CGRect(x: f.x + f.dx * 0.25 - 0.8, y: f.y - 0.8, width: 1.6, height: 1.6))
            ctx.addEllipse(in: CGRect(x: f.x - f.w * 0.45, y: f.y - 2.5, width: f.w * 0.9, height: 5)); ctx.setFillColor(CandleRenderer.blueColor); ctx.fillPath()
            let outer = flamePath(f, inner: false)
            ctx.saveGState()
            ctx.addPath(outer); ctx.clip()
            ctx.drawLinearGradient(makeGradient(flameColors, CandleRenderer.flameLocs), start: CGPoint(x: 0, y: f.y - f.h), end: CGPoint(x: 0, y: f.y + 2), options: [])
            ctx.restoreGState()
            ctx.addPath(flamePath(f, inner: true)); ctx.setFillColor(CandleRenderer.innerColor); ctx.fillPath()
            ctx.saveGState(); ctx.setAlpha(f.bright)
            ctx.addPath(reflectPath(f)); ctx.setFillColor(CandleRenderer.reflectColor); ctx.fillPath()
            ctx.restoreGState()
        }
        if !sim.smoke.isEmpty {
            ctx.addPath(smokePath()); ctx.setStrokeColor(CGColor(gray: 0.75, alpha: smokeAlpha)); ctx.setLineWidth(3); ctx.strokePath()
        }
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawDynamic(ctx)
        drawFront(ctx, ui: ui)
    }
}

final class CandleModule: StyleModule {
    let sim = CandleSim()
    lazy var r = CandleRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer(), glowBig = CALayer(), glowSmall = CALayer(), dishGlow = CALayer()
    private lazy var glowIn = MaskedGradient(r.glowInColors, CandleRenderer.glowInLocs, box: CGRect(x: L.cx - 42, y: CL.jarTop, width: 84, height: CL.waxStub - CL.jarTop))
    private lazy var waxBody = MaskedGradient(r.bodyColors, CandleRenderer.bodyLocs, box: r.bodyBox, vertical: false)
    private lazy var lit = MaskedGradient(r.litColors, CandleRenderer.litLocs, box: CGRect(x: r.bodyBox.minX, y: 0, width: r.bodyBox.width, height: 70))
    private let drips = shapeLayer(), dripsMask = CAShapeLayer()
    private let topFace = shapeLayer(), pool = shapeLayer(), poolHi = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.45), width: 0.8)
    private let wick = shapeLayer(stroke: CGColor(gray: 0.1, alpha: 1), width: 1.4), ember = shapeLayer(fill: RGB(1, 0.35, 0.1).cg())
    private let blue = shapeLayer(fill: CandleRenderer.blueColor)
    private lazy var flame = MaskedGradient(r.flameColors, CandleRenderer.flameLocs, box: CGRect(x: L.cx - 30, y: 0, width: 60, height: 40))
    private let inner = shapeLayer(fill: CandleRenderer.innerColor), smoke = shapeLayer(stroke: CGColor(gray: 0.75, alpha: 0.3), width: 3)
    private let reflect = shapeLayer(fill: CandleRenderer.reflectColor)
    private lazy var waxAO = MaskedGradient(CandleRenderer.aoColors, CandleRenderer.aoLocs, box: CGRect(x: L.cx - 44, y: CL.bottom - 26, width: 88, height: 30))
    private var backKey = "", frontKey = "", colourKey = "", glowKey = ""
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Candle Colour"
    var colours: [(String, RGB)] { candleColours.map { ($0.name, $0.wax) } }
    var colourIndex = 0 { didSet { r.colour = candleColours[colourIndex] } }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        dripsMask.frame = container.bounds
        dripsMask.fillColor = CGColor(gray: 0, alpha: 1)
        drips.mask = dripsMask
        for l in [back, glowIn.layer, glowBig, waxBody.layer, waxAO.layer, lit.layer, drips, topFace, pool, poolHi, wick, ember, blue, flame.layer, inner, reflect, glowSmall, smoke, front] {
            l.frame = container.bounds
            container.addSublayer(l)
        }
        glowBig.contentsGravity = .resize
        glowSmall.contentsGravity = .resize
        dishGlow.contentsGravity = .resize
        glowSmall.compositingFilter = "screenBlendMode"
    }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, drips, dripsMask, topFace, pool, poolHi, wick, ember, blue, inner, smoke, waxBody.mask, lit.mask, flame.mask] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ui.frame.name)|\(ps)|\(ui.time)|\(ui.paused)|\(ui.dimTime)|\(ui.task)|\((ui.glow * 50).rounded())"
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        if colourKey != r.colour.name {
            colourKey = r.colour.name
            waxBody.set(colors: r.bodyColors)
            topFace.fillColor = r.rimColor
            pool.fillColor = r.poolColor
            drips.fillColor = r.dripColor
        }
        let gk = "\(ps)"
        if gk != glowKey {
            glowKey = gk
            glowBig.contents = r.glowImage(radius: 90, alpha: 0.30, ps: ps)
            glowSmall.contents = r.glowImage(radius: 24, alpha: 0.5, ps: ps)
            glowIn.mask.contentsScale = ps
        }
        let f = r.flame()
        let bp = r.bodyPath()
        waxBody.set(path: bp)
        waxAO.set(path: bp)
        lit.set(path: bp)
        lit.gradient.frame = upRect(CGRect(x: r.bodyBox.minX, y: sim.topY, width: r.bodyBox.width, height: 70))
        lit.layer.opacity = Float(f.bright)
        dripsMask.path = flipY(bp)
        let (solid, moving) = r.dripPaths()
        let dp = CGMutablePath(); dp.addPath(solid); dp.addPath(moving)
        drips.path = flipY(dp)
        topFace.path = flipY(r.topFacePath())
        pool.path = flipY(r.poolPath())
        poolHi.path = flipY(r.poolHighlight())
        wick.path = flipY(r.wickPath())
        let on = f.level > 0.01
        ember.isHidden = !on; blue.isHidden = !on; flame.layer.isHidden = !on; inner.isHidden = !on; reflect.isHidden = !on
        glowBig.isHidden = !on; glowSmall.isHidden = !on; glowIn.layer.isHidden = !on
        glowIn.layer.opacity = Float(f.bright)
        glowIn.set(path: r.airPath())
        glowIn.gradient.frame = upRect(CGRect(x: L.cx - 42, y: CL.jarTop, width: 84, height: max(4, sim.topY - CL.jarTop)))
        if on {
            ember.opacity = Float(f.level)
            ember.path = flipY(CGPath(ellipseIn: CGRect(x: f.x + f.dx * 0.25 - 0.8, y: f.y - 0.8, width: 1.6, height: 1.6), transform: nil))
            blue.path = flipY(CGPath(ellipseIn: CGRect(x: f.x - f.w * 0.45, y: f.y - 2.5, width: f.w * 0.9, height: 5), transform: nil))
            flame.gradient.frame = upRect(CGRect(x: L.cx - 30, y: f.y - f.h, width: 60, height: f.h + 2))
            flame.set(path: r.flamePath(f, inner: false))
            inner.path = flipY(r.flamePath(f, inner: true))
            reflect.path = flipY(r.reflectPath(f))
            reflect.opacity = Float(f.bright)
            let ctr = CGPoint(x: f.x + f.dx * 0.4, y: L.height - (f.y - f.h * 0.45))
            glowBig.bounds = CGRect(x: 0, y: 0, width: 180, height: 180)
            glowBig.position = ctr
            glowBig.opacity = Float(f.bright)
            glowSmall.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
            glowSmall.position = ctr
            glowSmall.opacity = Float(f.bright)
        }
        if sim.smoke.isEmpty {
            smoke.path = nil
        } else {
            smoke.path = flipY(r.smokePath())
            smoke.strokeColor = CGColor(gray: 0.75, alpha: r.smokeAlpha)
        }
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) {
        sim.pointer = p
        if p != nil { sim.mouseGust = min(1, max(sim.mouseGust, hypot(velocity.x, velocity.y) / 900)) }
    }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        for e in sim.events { st.post(e) }
        sim.events.removeAll(keepingCapacity: true)
        if previewPhase != nil && !running {
            st.ex.inFlow = 1
            st.ex.inGust = Float(0.3 + 0.7 * wobble(sim.time * 0.8, 5))
        } else {
            st.ex.inFlow = Float(sim.flame)
            st.ex.inGust = Float(sim.gust)
        }
    }
}
