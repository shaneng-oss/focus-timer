// Horizon: a brass porthole on a wooden board, looking out at the sea. The sun sinks toward the
// water over the block, the sky moving from afternoon blue through gold and dusk to the first
// stars, so the sun's height is the time left and nothing on it ever happens suddenly. During a
// break the same sky runs from night to a sunrise.
//
// The light is approximate but physically grounded: the zenith, mid-sky and horizon colours are
// tabulated against the sun's elevation (Rayleigh blue overhead, Mie-scattered reds low down and
// after sunset), the disc reddens and flattens through atmospheric extinction and refraction near
// the horizon, and the glitter path on the sea is the set of wave facets tilted just right to
// reflect the sun to the eye, which widens and brightens as the sun gets low.

import AppKit
import QuartzCore

enum HL {
    static let cx = L.cx, cy: CGFloat = 148, R: CGFloat = 66, ring: CGFloat = 11
    static let horizonY: CGFloat = cy + 14
    static let top: CGFloat = cy - R
    static let boardTop: CGFloat = cy - R - 16, boardBottom: CGFloat = cy + R + 20, boardHalf: CGFloat = 86
    static let glass = CGPath(ellipseIn: CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2), transform: nil)
    static let glassBox = CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)
    static let pxPerDegree: CGFloat = (horizonY - top - 14) / 55
    static func sunY(_ e: CGFloat) -> CGFloat { horizonY - e * pxPerDegree }
}

struct HorizonStyle { let name: String; let tint: RGB; let warmth: CGFloat; let haze: CGFloat }
let horizonStyles: [HorizonStyle] = [
    .init(name: "Clear Day", tint: RGB(0.30, 0.56, 0.90), warmth: 1.0, haze: 0.0),
    .init(name: "Golden Haze", tint: RGB(0.95, 0.72, 0.42), warmth: 1.35, haze: 0.45),
    .init(name: "Tropical", tint: RGB(0.25, 0.70, 0.80), warmth: 0.85, haze: 0.1),
    .init(name: "Nordic", tint: RGB(0.55, 0.66, 0.78), warmth: 0.7, haze: 0.3),
    .init(name: "Rose Dusk", tint: RGB(0.88, 0.52, 0.62), warmth: 1.5, haze: 0.25),
]

struct Cloud { var x, y, w, h, speed, seed: CGFloat }
struct Facet { var u, v, phase, speed: CGFloat }   // u: across the glitter band (-1...1), v: down from the horizon (0...1)

final class HorizonSim: TimerBody {
    var totalMass: CGFloat = 1
    var topMass: CGFloat = 1
    var busy = true
    var inFlight: Bool { false }
    var seconds: Double = 1500
    var onBreak = false
    var time: CGFloat = 0
    var clouds: [Cloud] = []
    var facets: [Facet] = []
    var rng = RNG(s: 0x6A09_E667_F3BC_C908)
    var pointer: CGPoint?
    var stir: CGFloat = 0, stirAt = CGPoint.zero
    var running = false

    var elapsed: CGFloat { max(0, min(1, 1 - topMass / totalMass)) }
    /// The sun's elevation in degrees: afternoon to full set over a focus block, night to morning over a break.
    var elevation: CGFloat { onBreak ? -8 + 20 * elapsed : 55 - 60 * elapsed }
    var sunX: CGFloat { onBreak ? HL.cx - 46 + 20 * elapsed : HL.cx - 36 + 62 * elapsed }

    init() {
        for i in 0..<4 {
            clouds.append(Cloud(x: HL.cx - 70 + CGFloat(i) * 42 + rng.signed() * 10, y: HL.top + 18 + CGFloat(i % 2) * 22 + rng.unit() * 8,
                                w: 26 + rng.unit() * 18, h: 7 + rng.unit() * 4, speed: 0.22 + rng.unit() * 0.25, seed: rng.unit() * 100))
        }
        for _ in 0..<260 {
            facets.append(Facet(u: rng.signed(), v: pow(rng.unit(), 0.8), phase: rng.unit() * 2 * .pi, speed: 1.2 + rng.unit() * 3.5))
        }
    }

    func configure(forSeconds s: Double) { seconds = s }
    func reset() { topMass = totalMass; stir = 0 }
    func flip() { topMass = totalMass - topMass }
    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        drift(CGFloat(Double(take / totalMass) * seconds))
    }
    func landAll() {}

    private func drift(_ dt: CGFloat) {
        for i in clouds.indices {
            clouds[i].x += clouds[i].speed * dt
            let span = HL.R + clouds[i].w + 6
            if clouds[i].x > HL.cx + span { clouds[i].x -= span * 2 + CGFloat(Int(clouds[i].x - HL.cx - span) / Int(span * 2)) * span * 2 }
        }
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        running = drain > 0
        if running { topMass -= min(drain, topMass) }
        time += dt
        // Clouds drift while the timer runs, and barely at all when it is stopped
        drift(running ? dt : dt * 0.15)
        stir *= exp(-dt * 1.6)
        if let p = pointer, p.y > HL.horizonY, HL.glassBox.contains(p) { stir = max(stir, 0.6); stirAt = p }
    }
}

// MARK: - Rendering

final class HorizonRenderer {
    let sim: HorizonSim
    var style = horizonStyles[0]
    init(sim: HorizonSim) { self.sim = sim }

    // Sky colours against the sun's elevation (degrees): zenith, mid sky, horizon
    static let keys: [(CGFloat, RGB, RGB, RGB)] = [
        (60, RGB(0.15, 0.40, 0.86), RGB(0.40, 0.65, 0.94), RGB(0.76, 0.86, 0.96)),
        (30, RGB(0.17, 0.40, 0.84), RGB(0.50, 0.69, 0.93), RGB(0.88, 0.88, 0.86)),
        (12, RGB(0.19, 0.36, 0.74), RGB(0.68, 0.70, 0.82), RGB(0.98, 0.82, 0.60)),
        (5, RGB(0.18, 0.30, 0.62), RGB(0.76, 0.60, 0.60), RGB(0.99, 0.68, 0.38)),
        (1, RGB(0.15, 0.22, 0.52), RGB(0.70, 0.42, 0.48), RGB(0.98, 0.50, 0.26)),
        (-2, RGB(0.10, 0.14, 0.40), RGB(0.48, 0.26, 0.46), RGB(0.86, 0.40, 0.30)),
        (-5, RGB(0.05, 0.07, 0.26), RGB(0.22, 0.16, 0.38), RGB(0.50, 0.28, 0.38)),
        (-9, RGB(0.02, 0.03, 0.13), RGB(0.06, 0.08, 0.22), RGB(0.16, 0.13, 0.27)),
    ]

    func skyColours(_ e: CGFloat) -> (RGB, RGB, RGB) {
        let k = HorizonRenderer.keys
        if e >= k[0].0 { return tinted(k[0].1, k[0].2, k[0].3) }
        if e <= k[k.count - 1].0 { let l = k[k.count - 1]; return tinted(l.1, l.2, l.3) }
        for i in 0..<(k.count - 1) where e <= k[i].0 && e >= k[i + 1].0 {
            let t = (k[i].0 - e) / (k[i].0 - k[i + 1].0)
            return tinted(k[i].1.mixed(k[i + 1].1, t), k[i].2.mixed(k[i + 1].2, t), k[i].3.mixed(k[i + 1].3, t))
        }
        return tinted(k[0].1, k[0].2, k[0].3)
    }

    private func tinted(_ z: RGB, _ m: RGB, _ h: RGB) -> (RGB, RGB, RGB) {
        // Each setting pushes the sky toward its own tint and its own warmth low down
        let z2 = z.mixed(style.tint, 0.22)
        let m2 = m.mixed(style.tint, 0.18 + style.haze * 0.2)
        let h2 = h.mixed(style.tint, 0.1).scaled(0.9 + 0.1 * style.warmth)
        return (z2, m2, h2)
    }

    func sunColour(_ e: CGFloat) -> RGB {
        let hi = RGB(1, 0.98, 0.90), mid = RGB(1, 0.86, 0.55), low = RGB(1, 0.58, 0.26), set = RGB(0.95, 0.38, 0.18)
        if e > 15 { return hi }
        if e > 5 { return hi.mixed(mid, (15 - e) / 10) }
        if e > 0 { return mid.mixed(low, (5 - e) / 5) }
        return low.mixed(set, min(1, -e / 3))
    }

    func drawBoard(_ ctx: CGContext, fs: FrameStyle) {
        groundShadow(ctx, y: HL.boardBottom + 2, strength: 1, radius: 92)
        let board = CGPath(roundedRect: CGRect(x: HL.cx - HL.boardHalf, y: HL.boardTop, width: HL.boardHalf * 2, height: HL.boardBottom - HL.boardTop),
                           cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(board); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(board); ctx.clip()
        ctx.drawLinearGradient(makeGradient([fs.light.scaled(1.08).cg(), fs.light.cg(), fs.light.scaled(0.9).cg(), fs.dark.scaled(1.1).cg()], [0, 0.3, 0.7, 1]),
                               start: CGPoint(x: HL.cx - HL.boardHalf, y: HL.boardTop), end: CGPoint(x: HL.cx + HL.boardHalf, y: HL.boardBottom), options: [])
        ctx.restoreGState()
        frameTexture(ctx, in: board, rect: board.boundingBox, seed: 19)
        ctx.addPath(board); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); ctx.setLineWidth(1); ctx.strokePath()
        // The porthole's shadow on the board
        ctx.saveGState()
        ctx.addPath(board); ctx.clip()
        let c = CGPoint(x: HL.cx + 2, y: HL.cy + 4)
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0.5), CGColor(gray: 0, alpha: 0.5), CGColor(gray: 0, alpha: 0)], [0, 0.88, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: HL.R + HL.ring + 8, options: [])
        ctx.restoreGState()
    }

    /// Sky, sun, stars and sea: everything that only changes with the sun's height.
    func drawSky(_ ctx: CGContext) {
        let e = sim.elevation
        let (zen, mid, hor) = skyColours(e)
        ctx.saveGState()
        ctx.addPath(HL.glass); ctx.clip()
        ctx.drawLinearGradient(makeGradient([zen.cg(), mid.cg(), hor.cg()], [0, 0.6, 1]),
                               start: CGPoint(x: 0, y: HL.top), end: CGPoint(x: 0, y: HL.horizonY), options: [])
        // Stars come out once the sun is well down
        let night = max(0, min(1, (-3.5 - e) / 4.5))
        if night > 0 {
            var st = RNG(s: 0xC0FFEE)
            for _ in 0..<34 {
                let x = HL.cx + st.signed() * (HL.R - 6), y = HL.top + 4 + st.unit() * (HL.horizonY - HL.top - 12)
                if hypot(x - HL.cx, y - HL.cy) < HL.R - 3 {
                    let tw = 0.4 + 0.6 * st.unit()
                    ctx.setFillColor(CGColor(gray: 1, alpha: tw * night * (y < HL.horizonY - 20 ? 1 : 0.4)))
                    let r = 0.45 + 0.4 * st.unit()
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        }
        // The sun: glow, then the disc, reddening and flattening as it reaches the horizon
        let sx = sim.sunX, sy = HL.sunY(e)
        let sc = sunColour(e)
        let low = max(0, min(1, (20 - e) / 20))
        let glowR = 22 + 30 * low + 14 * style.haze
        let visible = max(0, min(1, (e + 5) / 3))               // extinction once it is below the horizon
        softLight(ctx, at: CGPoint(x: sx, y: sy), radius: glowR, color: sc.mixed(RGB(1, 1, 1), 0.2), alpha: (0.3 + 0.35 * low) * style.warmth * visible)
        if e > -5 {
            let flatten = e < 4 ? 1 - 0.3 * (4 - max(e, -1)) / 5 : 1
            let r: CGFloat = 6 + 2.5 * low
            let disc = CGRect(x: sx - r, y: sy - r * flatten, width: r * 2, height: r * 2 * flatten)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: L.width, height: HL.horizonY))       // the sea hides the lower limb
            ctx.setShadow(offset: .zero, blur: 6 + 6 * low, color: sc.cg(0.9 * visible))
            ctx.setFillColor(sc.mixed(RGB(1, 1, 1), 0.55 * (1 - low)).cg(visible))
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()
        }
        // Haze band hugging the horizon
        ctx.drawLinearGradient(makeGradient([hor.cg(0), hor.mixed(RGB(1, 1, 1), 0.25).cg(0.35 + 0.4 * style.haze)], [0, 1]),
                               start: CGPoint(x: 0, y: HL.horizonY - 22), end: CGPoint(x: 0, y: HL.horizonY), options: [])

        // The sea: reflecting the sky far off, its own deep colour close in
        let far = hor.mixed(RGB(0.10, 0.30, 0.48), 0.5)
        let near = zen.mixed(RGB(0.03, 0.10, 0.20), 0.55)
        ctx.drawLinearGradient(makeGradient([far.cg(), far.mixed(near, 0.5).cg(), near.cg()], [0, 0.35, 1]),
                               start: CGPoint(x: 0, y: HL.horizonY), end: CGPoint(x: 0, y: HL.cy + HL.R), options: [])
        // The sun's broad reflection under the glitter
        let refl = max(0, min(1, (e + 3) / 6)) * (0.35 + 0.65 * low)
        if refl > 0.01 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: HL.horizonY, width: L.width, height: 200))
            ctx.translateBy(x: sx, y: HL.horizonY)
            ctx.scaleBy(x: 0.35 + 0.5 * low, y: 1.6)
            ctx.drawRadialGradient(makeGradient([sc.cg(0.45 * refl), sc.cg(0.12 * refl), sc.cg(0)], [0, 0.45, 1]),
                                   startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 40, options: [])
            ctx.restoreGState()
        }
        // Horizon line
        ctx.setStrokeColor(hor.mixed(RGB(1, 1, 1), 0.3).cg(0.5)); ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: HL.cx - HL.R, y: HL.horizonY)); ctx.addLine(to: CGPoint(x: HL.cx + HL.R, y: HL.horizonY)); ctx.strokePath()
        ctx.restoreGState()
    }

    /// One cloud, lit by the sun: bright on top, shadowed beneath, and pink underneath when the sun is low.
    func drawCloud(_ ctx: CGContext, _ c: Cloud, at origin: CGPoint) {
        let e = sim.elevation
        let (_, mid, hor) = skyColours(e)
        let low = max(0, min(1, (18 - e) / 18))
        let lit = RGB(1, 1, 1).mixed(sunColour(e), 0.25 * low)
        let shade = mid.mixed(hor, 0.5).mixed(RGB(0.5, 0.5, 0.6), 0.3).mixed(sunColour(max(e, -2)), 0.45 * low)
        let dusk = max(0, min(1, (-e + 1) / 5))
        let litD = lit.mixed(shade, dusk * 0.7), shadeD = shade.scaled(1 - 0.5 * dusk)
        var r = RNG(s: UInt64(c.seed * 1000) + 5)
        var puffs: [(CGFloat, CGFloat, CGFloat)] = []
        let n = 5 + Int(c.w / 9)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let x = origin.x + (t - 0.5) * c.w
            let rr = c.h * (0.55 + 0.6 * sin(t * .pi)) * (0.75 + 0.5 * r.unit())
            puffs.append((x + r.signed() * 3, origin.y - rr * 0.3 + r.signed() * 2.5, rr))
            // Smaller puffs riding on top give the cumulus its cauliflower top
            if i > 0 && i < n - 1 && r.unit() < 0.7 {
                let r2 = rr * (0.45 + 0.3 * r.unit())
                puffs.append((x + r.signed() * 4, origin.y - rr * 0.9 - r2 * 0.3, r2))
            }
        }
        for (x, y, rr) in puffs {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.drawRadialGradient(makeGradient([litD.cg(0.95), litD.mixed(shadeD, 0.5).cg(0.85), shadeD.cg(0.6), shadeD.cg(0)], [0, 0.45, 0.8, 1]),
                                   startCenter: CGPoint(x: 0, y: -rr * 0.3), startRadius: 0, endCenter: .zero, endRadius: rr * 1.15, options: [])
            ctx.restoreGState()
        }
        // Flat underside
        ctx.setFillColor(shadeD.cg(0.5))
        ctx.fill(CGRect(x: origin.x - c.w / 2 + 2, y: origin.y + c.h * 0.25, width: c.w - 4, height: 1.2))
    }

    /// Glitter: the wave facets reflecting the sun this instant. Low sun means a longer, wider path.
    func glitterPath() -> CGPath {
        let p = CGMutablePath()
        let e = sim.elevation
        let vis = max(0, min(1, (e + 3) / 6))
        guard vis > 0.01 else { return p }
        let low = max(0, min(1, (25 - e) / 25))
        let sx = sim.sunX
        let t = sim.time
        let depth = HL.cy + HL.R - HL.horizonY
        for f in sim.facets {
            let y = HL.horizonY + 1.5 + f.v * depth * (0.55 + 0.45 * low)
            let half = (2.5 + (y - HL.horizonY) * (0.26 + 0.34 * low))
            let x = sx + f.u * half
            guard hypot(x - HL.cx, y - HL.cy) < HL.R - 2 else { continue }
            // A facet flashes when its slope passes through the reflecting angle
            var thresh = 0.86 - 0.18 * low - 0.1 * (1 - f.v)
            if sim.stir > 0.02 {
                let d = hypot(x - sim.stirAt.x, y - sim.stirAt.y)
                if d < 30 { thresh -= sim.stir * 0.4 * (1 - d / 30) }
            }
            let s = sin(f.phase + t * f.speed) * (0.7 + 0.3 * sin(t * 0.7 + f.u * 3))
            if s > thresh {
                let w = 1.2 + 2.2 * f.v + 1.5 * low
                p.addRect(CGRect(x: x - w / 2, y: y - 0.45, width: w, height: 0.9))
            }
        }
        return p
    }

    /// Slow swells: soft highlights moving toward the viewer.
    func wavesPath() -> CGPath {
        let p = CGMutablePath()
        let t = sim.time
        for k in 0..<5 {
            let phase = (t * 0.11 + CGFloat(k) / 5).truncatingRemainder(dividingBy: 1)
            let y = HL.horizonY + 3 + phase * phase * (HL.R + HL.cy - HL.horizonY - 4)
            let half = sqrt(max(0, HL.R * HL.R - (y - HL.cy) * (y - HL.cy))) - 2
            guard half > 4 else { continue }
            var x = HL.cx - half
            p.move(to: CGPoint(x: x, y: y))
            while x < HL.cx + half {
                x += 4
                p.addLine(to: CGPoint(x: min(x, HL.cx + half), y: y + (0.3 + phase * 1.2) * sin(x * 0.18 + t * 0.9 + CGFloat(k))))
            }
        }
        return p
    }
    var waveAlpha: Float { 0.1 }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        // Glass: a fresnel rim, a reflection arc, and vignetting toward the edge
        ctx.saveGState()
        ctx.addPath(HL.glass); ctx.clip()
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.3)], [0, 0.82, 1]),
                               startCenter: CGPoint(x: HL.cx, y: HL.cy), startRadius: 0, endCenter: CGPoint(x: HL.cx, y: HL.cy), endRadius: HL.R, options: [])
        glassStreak(ctx, in: HL.glass, center: CGPoint(x: HL.cx - 14, y: HL.cy - 16), length: 150, width: 7, alpha: 0.08)
        ctx.restoreGState()
        fresnelRim(ctx, HL.glass, width: 6, alpha: 0.16)
        ctx.setLineCap(.round)
        let hi = CGMutablePath()
        hi.addArc(center: CGPoint(x: HL.cx, y: HL.cy), radius: HL.R - 5, startAngle: .pi * 1.1, endAngle: .pi * 1.4, clockwise: false)
        ctx.addPath(hi); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3)); ctx.setLineWidth(2.4); ctx.strokePath()

        // The porthole ring: cast metal in the frame's ring colour, with its screws
        let outer = CGRect(x: HL.cx - HL.R - HL.ring, y: HL.cy - HL.R - HL.ring, width: (HL.R + HL.ring) * 2, height: (HL.R + HL.ring) * 2)
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: outer)
        ringPath.addEllipse(in: HL.glassBox)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(ringPath); ctx.setFillColor(fs.ring.scaled(0.6).cg()); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(ringPath); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(makeGradient([fs.ring.scaled(1.25).cg(), fs.ring.cg(), fs.ring.scaled(0.62).cg(), fs.ring.scaled(1.05).cg(), fs.ring.scaled(0.55).cg()], [0, 0.3, 0.55, 0.78, 1]),
                               start: CGPoint(x: outer.minX, y: outer.minY), end: CGPoint(x: outer.maxX, y: outer.maxY), options: [])
        // A raised lip half-way across the ring
        ctx.addEllipse(in: outer.insetBy(dx: HL.ring * 0.5, dy: HL.ring * 0.5)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); ctx.setLineWidth(1); ctx.strokePath()
        ctx.addEllipse(in: outer.insetBy(dx: HL.ring * 0.5 + 1.2, dy: HL.ring * 0.5 + 1.2)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25)); ctx.setLineWidth(0.8); ctx.strokePath()
        ctx.restoreGState()
        frameTexture(ctx, in: ringPath, rect: outer, seed: 29)
        ctx.addEllipse(in: outer.insetBy(dx: 0.5, dy: 0.5)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25)); ctx.setLineWidth(0.9); ctx.strokePath()
        ctx.addPath(HL.glass); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); ctx.setLineWidth(1.4); ctx.strokePath()
        for k in 0..<8 {
            let a = CGFloat(k) / 8 * 2 * .pi + .pi / 8
            let c = CGPoint(x: HL.cx + cos(a) * (HL.R + HL.ring * 0.5), y: HL.cy + sin(a) * (HL.R + HL.ring * 0.5))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 1, color: CGColor(gray: 0, alpha: 0.4))
            ctx.setFillColor(fs.ring.scaled(0.85).cg()); ctx.fillEllipse(in: CGRect(x: c.x - 2.1, y: c.y - 2.1, width: 4.2, height: 4.2))
            ctx.restoreGState()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.3)); ctx.fillEllipse(in: CGRect(x: c.x - 1, y: c.y - 1.4, width: 1.6, height: 1.1))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); ctx.setLineWidth(0.6)
            let sa = c.x < HL.cx ? CGFloat(0.6) : CGFloat(-0.4)
            ctx.move(to: CGPoint(x: c.x - cos(sa) * 1.4, y: c.y - sin(sa) * 1.4)); ctx.addLine(to: CGPoint(x: c.x + cos(sa) * 1.4, y: c.y + sin(sa) * 1.4)); ctx.strokePath()
        }
        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: style.tint.cg(ui.glow))
            ctx.addPath(HL.glass); ctx.setStrokeColor(style.tint.mixed(RGB(1, 1, 1), 0.4).cg(0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }
        drawBadge(ctx, ui: ui, accent: style.tint.mixed(RGB(1, 1, 1), 0.08))
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBoard(ctx, fs: ui.frame)
        drawSky(ctx)
        ctx.saveGState()
        ctx.addPath(HL.glass); ctx.clip()
        for c in sim.clouds { drawCloud(ctx, c, at: CGPoint(x: c.x, y: c.y)) }
        ctx.addPath(wavesPath()); ctx.setStrokeColor(CGColor(gray: 1, alpha: CGFloat(waveAlpha))); ctx.setLineWidth(1); ctx.strokePath()
        ctx.addPath(glitterPath()); ctx.setFillColor(sunColour(sim.elevation).mixed(RGB(1, 1, 1), 0.5).cg(0.85)); ctx.fillPath()
        ctx.restoreGState()
        drawFront(ctx, ui: ui)
    }
}

final class HorizonModule: StyleModule {
    let sim = HorizonSim()
    lazy var r = HorizonRenderer(sim: sim)
    let container = CALayer()
    private let board = CALayer(), sky = CALayer(), front = CALayer()
    private let inside = CALayer(), insideMask = CAShapeLayer()
    private var cloudLayers: [CALayer] = []
    private var cloudKeys: [String] = []
    private let waves = shapeLayer(stroke: CGColor(gray: 1, alpha: 0.1), width: 1)
    private let glitter = shapeLayer(fill: CGColor(gray: 1, alpha: 0.85))
    private var boardKey = "", skyKey = "", frontKey = ""
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Sky"
    var colours: [(String, RGB)] { horizonStyles.map { ($0.name, $0.tint) } }
    var colourIndex = 0 { didSet { r.style = horizonStyles[colourIndex] } }

    func setPhase(onBreak: Bool) { sim.onBreak = onBreak }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        insideMask.frame = container.bounds
        insideMask.path = flipY(HL.glass)
        inside.frame = container.bounds
        inside.mask = insideMask
        for c in sim.clouds {
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: c.w + 24, height: c.h * 3 + 12)
            inside.addSublayer(l)
            cloudLayers.append(l)
            cloudKeys.append("")
        }
        for l in [waves, glitter] { l.frame = container.bounds; inside.addSublayer(l) }
        for l in [board, sky, inside, front] { l.frame = container.bounds; container.addSublayer(l) }
    }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [board, sky, front, waves, glitter, insideMask] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)"
        if bk != boardKey { boardKey = bk; board.contents = layerImage(ps) { r.drawBoard($0, fs: ui.frame) } }
        let eq = (sim.elevation * 4).rounded() / 4
        let sk = "\(ps)|\(eq)|\(r.style.name)|\((sim.sunX * 2).rounded())"
        if sk != skyKey { skyKey = sk; sky.contents = layerImage(ps) { r.drawSky($0) } }
        let ceq = (sim.elevation).rounded()
        for (i, c) in sim.clouds.enumerated() {
            let l = cloudLayers[i]
            let ck = "\(ps)|\(ceq)|\(r.style.name)"
            if ck != cloudKeys[i] {
                cloudKeys[i] = ck
                l.contentsScale = ps
                let size = l.bounds.size
                l.contents = smallImage(size, ps) { ctx in r.drawCloud(ctx, c, at: CGPoint(x: size.width / 2, y: size.height * 0.55)) }
            }
            l.position = CGPoint(x: c.x, y: L.height - (c.y - l.bounds.height * 0.05))
        }
        waves.path = flipY(r.wavesPath())
        glitter.path = flipY(r.glitterPath())
        glitter.fillColor = r.sunColour(sim.elevation).mixed(RGB(1, 1, 1), 0.5).cg(0.85)
        let fk = "\(ps)|\(r.style.name)|" + ui.frontKey
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) { sim.pointer = p }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        // The breeze freshens a little as the sun gets low
        let low = Float(max(0, min(1, (30 - sim.elevation) / 30)))
        st.ex.inFlow = previewPhase != nil ? 0.5 + 0.5 * previewPhase! : 0.4 + 0.6 * low
    }
}
