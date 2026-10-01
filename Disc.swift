// Focus disc: a desk dial in the spirit of the Time Timer. A coloured disc shows the time left and
// shrinks as it passes, so one glance says where you are without reading a number. The movement is
// modelled on a quartz clock: a stepper pulse once a second, and a second hand that overshoots and
// settles on every step the way a real one does.

import AppKit
import QuartzCore

enum DL {
    static let cx = L.cx, cy: CGFloat = 146
    static let R: CGFloat = 64            // dial face radius
    static let bezel: CGFloat = 9         // bezel ring width
    static let outer: CGFloat = R + bezel
    static let standTop: CGFloat = cy + R - 10, standBottom: CGFloat = 254
    static let face = CGPath(ellipseIn: CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2), transform: nil)
    static let faceBox = CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)
}

struct DiscStyle { let name: String; let disc: RGB }
let discStyles: [DiscStyle] = [
    .init(name: "Signal Red", disc: RGB(0.86, 0.17, 0.15)),
    .init(name: "Tangerine", disc: RGB(0.96, 0.53, 0.15)),
    .init(name: "Ocean", disc: RGB(0.17, 0.47, 0.86)),
    .init(name: "Forest", disc: RGB(0.14, 0.56, 0.35)),
    .init(name: "Plum", disc: RGB(0.52, 0.23, 0.60)),
]

final class DiscSim: TimerBody {
    var totalMass: CGFloat = 1
    var topMass: CGFloat = 1
    var busy = true
    var inFlight: Bool { false }
    var seconds: Double = 1500
    /// A 60-minute dial, or a 2-hour one for long blocks.
    var scaleSeconds: Double { seconds <= 3600 ? 3600 : 7200 }
    // Quartz movement: the stepper holds `held`; the hand follows with a little overshoot and settle.
    var hand: CGFloat = 0, handVel: CGFloat = 0, held: CGFloat = 0
    var secAcc: CGFloat = 0
    var setting = false                  // the hand is being wound back to 12 after a reset
    var running = false
    var pointer: CGPoint?
    static let restGloss = CGPoint(x: DL.cx - 20, y: DL.cy - 24)
    var gloss = DiscSim.restGloss, glossT = DiscSim.restGloss

    /// The disc's angular extent: the time left on the dial's scale.
    var remainingAngle: CGFloat { 2 * .pi * CGFloat(min(1, Double(topMass / totalMass) * seconds / scaleSeconds)) }

    func configure(forSeconds s: Double) { seconds = s }
    func reset() {
        topMass = totalMass
        // Wind the hand back to 12 the short way round
        hand = hand.truncatingRemainder(dividingBy: 2 * .pi)
        if hand > .pi { hand -= 2 * .pi }
        held = 0
        setting = true
        secAcc = 0
    }
    func flip() { topMass = totalMass - topMass; secAcc = 0 }
    func catchUp(_ amount: CGFloat) {
        let take = min(amount, topMass)
        topMass -= take
        // The movement kept stepping while the window was hidden
        let secs = Double(take / totalMass) * seconds
        held += CGFloat(floor(secs)) * .pi / 30
        secAcc += CGFloat(secs - floor(secs))
        while secAcc >= 1 { secAcc -= 1; held += .pi / 30 }
        hand = held; handVel = 0
    }
    func landAll() {}

    func update(_ dt: CGFloat, drain: CGFloat) {
        running = drain > 0
        if running {
            topMass -= min(drain, topMass)
            secAcc += dt
            while secAcc >= 1 { secAcc -= 1; held += .pi / 30 }
        }
        // The hand is a second-order system: underdamped on each step (the quartz "tick and settle"),
        // critically damped and slower while being set.
        let n = 4
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            let err = held - hand
            if setting {
                let w: CGFloat = 7
                handVel += (w * w * err - 2 * w * handVel) * h
                if abs(err) < 0.002 && abs(handVel) < 0.01 { hand = held; handVel = 0; setting = false }
            } else {
                let w: CGFloat = 54, z: CGFloat = 0.26
                handVel += (w * w * err - 2 * z * w * handVel) * h
            }
            hand += handVel * h
        }
        // The highlight on the acrylic cover drifts with the pointer, as a lamp moving over it would.
        glossT = pointer.map { CGPoint(x: DL.cx + ($0.x - DL.cx) * 0.45, y: DL.cy + ($0.y - DL.cy) * 0.45) } ?? DiscSim.restGloss
        gloss.x += (glossT.x - gloss.x) * min(1, dt * 5)
        gloss.y += (glossT.y - gloss.y) * min(1, dt * 5)
        let moving = abs(handVel) > 0.003 || abs(held - hand) > 0.0008 || setting
        busy = running || moving || hypot(glossT.x - gloss.x, glossT.y - gloss.y) > 0.05
    }
}

// MARK: - Rendering

final class DiscRenderer {
    let sim: DiscSim
    var style = discStyles[0]
    static let handColor = RGB(0.16, 0.17, 0.2)
    init(sim: DiscSim) { self.sim = sim }

    var wedgeColors: [CGColor] { [style.disc.scaled(1.14).cg(), style.disc.cg(), style.disc.scaled(0.8).cg()] }
    static let wedgeLocs: [CGFloat] = [0, 0.5, 1]

    /// The coloured disc: from 12 o'clock anticlockwise (as the numbers run) over the time left.
    func wedgePath() -> CGPath {
        let a = sim.remainingAngle
        let p = CGMutablePath()
        guard a > 0.0005 else { return p }
        let r = DL.R - 2.5
        if a >= 2 * .pi - 0.001 {
            p.addEllipse(in: CGRect(x: DL.cx - r, y: DL.cy - r, width: r * 2, height: r * 2))
            return p
        }
        p.move(to: CGPoint(x: DL.cx, y: DL.cy))
        let n = max(2, Int(a / 0.02))
        for i in 0...n {
            let t = -.pi / 2 - a * CGFloat(i) / CGFloat(n)      // decreasing angle = anticlockwise on screen
            p.addLine(to: CGPoint(x: DL.cx + cos(t) * r, y: DL.cy + sin(t) * r))
        }
        p.closeSubpath()
        return p
    }

    /// The disc's leading edge: a fine dark line where the colour stops.
    func edgePath() -> CGPath {
        let a = sim.remainingAngle
        let p = CGMutablePath()
        guard a > 0.0005 && a < 2 * .pi - 0.001 else { return p }
        let t = -.pi / 2 - a
        p.move(to: CGPoint(x: DL.cx + cos(t) * 3, y: DL.cy + sin(t) * 3))
        p.addLine(to: CGPoint(x: DL.cx + cos(t) * (DL.R - 2.5), y: DL.cy + sin(t) * (DL.R - 2.5)))
        return p
    }

    func handPath() -> CGPath {
        let th = sim.hand
        let d = CGPoint(x: sin(th), y: -cos(th)), n = CGPoint(x: cos(th), y: sin(th))
        let tipL = DL.R - 7, tailL: CGFloat = 13
        let p = CGMutablePath()
        p.move(to: CGPoint(x: DL.cx + d.x * tipL, y: DL.cy + d.y * tipL))
        p.addLine(to: CGPoint(x: DL.cx + n.x * 0.9 - d.x * tailL, y: DL.cy + n.y * 0.9 - d.y * tailL))
        p.addLine(to: CGPoint(x: DL.cx - n.x * 0.9 - d.x * tailL, y: DL.cy - n.y * 0.9 - d.y * tailL))
        p.closeSubpath()
        // Counterweight
        let c = CGPoint(x: DL.cx - d.x * (tailL - 2), y: DL.cy - d.y * (tailL - 2))
        p.addEllipse(in: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4))
        return p
    }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        groundShadow(ctx, y: DL.standBottom + 1, strength: ui.shadow, radius: 64)
        // A low wooden stand the dial rests in
        let stand = CGMutablePath()
        stand.move(to: CGPoint(x: DL.cx - 30, y: DL.standTop))
        stand.addLine(to: CGPoint(x: DL.cx + 30, y: DL.standTop))
        stand.addLine(to: CGPoint(x: DL.cx + 44, y: DL.standBottom - 5))
        stand.addQuadCurve(to: CGPoint(x: DL.cx + 39, y: DL.standBottom), control: CGPoint(x: DL.cx + 44, y: DL.standBottom))
        stand.addLine(to: CGPoint(x: DL.cx - 39, y: DL.standBottom))
        stand.addQuadCurve(to: CGPoint(x: DL.cx - 44, y: DL.standBottom - 5), control: CGPoint(x: DL.cx - 44, y: DL.standBottom))
        stand.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(stand); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(stand); ctx.clip()
        ctx.drawLinearGradient(makeGradient([fs.dark.scaled(0.8).cg(), fs.light.cg(), fs.light.scaled(1.08).cg(), fs.dark.scaled(0.85).cg()], [0, 0.3, 0.55, 1]),
                               start: CGPoint(x: DL.cx - 44, y: 0), end: CGPoint(x: DL.cx + 44, y: 0), options: [])
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)], [0, 1]),
                               start: CGPoint(x: 0, y: DL.standTop), end: CGPoint(x: 0, y: DL.standTop + 22), options: [])
        ctx.restoreGState()
        frameTexture(ctx, in: stand, rect: stand.boundingBox, seed: 23)
        ctx.addPath(stand); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); ctx.setLineWidth(0.8); ctx.strokePath()

        // Bezel: a turned ring in the frame finish
        let outer = CGRect(x: DL.cx - DL.outer, y: DL.cy - DL.outer, width: DL.outer * 2, height: DL.outer * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addEllipse(in: outer); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: outer); ctx.clip()
        ctx.drawLinearGradient(makeGradient([fs.light.scaled(1.2).cg(), fs.light.cg(), fs.dark.cg(), fs.light.scaled(0.95).cg(), fs.dark.scaled(0.7).cg()], [0, 0.25, 0.55, 0.8, 1]),
                               start: CGPoint(x: DL.cx - DL.outer, y: DL.cy - DL.outer), end: CGPoint(x: DL.cx + DL.outer, y: DL.cy + DL.outer), options: [])
        ctx.restoreGState()
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: outer)
        ringPath.addEllipse(in: DL.faceBox)
        frameTexture(ctx, in: ringPath, rect: outer, seed: 31)
        ctx.addEllipse(in: outer.insetBy(dx: 0.6, dy: 0.6)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); ctx.setLineWidth(1); ctx.strokePath()
        ctx.addEllipse(in: outer.insetBy(dx: 3.5, dy: 3.5)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18)); ctx.setLineWidth(0.8); ctx.strokePath()

        // Face: warm off-white, a touch darker toward the edge, with a fine paper grain
        ctx.saveGState()
        ctx.addPath(DL.face); ctx.clip()
        ctx.drawRadialGradient(makeGradient([RGB(0.985, 0.975, 0.95).cg(), RGB(0.96, 0.945, 0.91).cg(), RGB(0.86, 0.84, 0.80).cg()], [0, 0.78, 1]),
                               startCenter: CGPoint(x: DL.cx, y: DL.cy), startRadius: 0, endCenter: CGPoint(x: DL.cx, y: DL.cy), endRadius: DL.R, options: [])
        grain(ctx, in: DL.face, rect: DL.faceBox, alpha: 0.05, seed: 17)
        ctx.restoreGState()

        // Minute ticks and numerals, running anticlockwise from 0 at the top
        let twoHour = sim.scaleSeconds > 3600
        let ink = RGB(0.18, 0.19, 0.22)
        let ticks = 60
        for i in 0..<ticks {
            let t = -.pi / 2 - 2 * .pi * CGFloat(i) / CGFloat(ticks)
            let major = i % 5 == 0
            let len: CGFloat = major ? 6 : 3
            let r0 = DL.R - 4, r1 = r0 - len
            ctx.move(to: CGPoint(x: DL.cx + cos(t) * r0, y: DL.cy + sin(t) * r0))
            ctx.addLine(to: CGPoint(x: DL.cx + cos(t) * r1, y: DL.cy + sin(t) * r1))
            ctx.setStrokeColor(ink.cg(major ? 0.9 : 0.55))
            ctx.setLineWidth(major ? 1.3 : 0.7)
            ctx.strokePath()
        }
        let font = NSFont.systemFont(ofSize: 7.2, weight: .semibold)
        for k in 0..<12 {
            let mins = k * (twoHour ? 10 : 5)
            let t = -.pi / 2 - 2 * .pi * CGFloat(k) / 12
            let c = CGPoint(x: DL.cx + cos(t) * (DL.R - 16.5), y: DL.cy + sin(t) * (DL.R - 16.5))
            let s = NSAttributedString(string: "\(mins)", attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink.cg(0.92))!])
            let sz = s.size()
            s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
        }
        // Maker's mark under the centre
        let mark = NSAttributedString(string: "FOCUS", attributes: [.font: NSFont.systemFont(ofSize: 4.6, weight: .bold), .foregroundColor: NSColor(cgColor: ink.cg(0.55))!, .kern: 1.2])
        let ms = mark.size()
        mark.draw(at: CGPoint(x: DL.cx - ms.width / 2 + 0.6, y: DL.cy + 26 - ms.height / 2))
    }

    func drawWedge(_ ctx: CGContext) {
        let wp = wedgePath()
        guard !wp.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(wp); ctx.clip()
        ctx.drawLinearGradient(makeGradient(wedgeColors, DiscRenderer.wedgeLocs), start: CGPoint(x: 0, y: DL.faceBox.minY), end: CGPoint(x: 0, y: DL.faceBox.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(edgePath()); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35)); ctx.setLineWidth(0.7); ctx.strokePath()
    }

    func drawHand(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0.8, height: 1.2), blur: 1.6, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(handPath()); ctx.setFillColor(DiscRenderer.handColor.cg()); ctx.fillPath()
        ctx.restoreGState()
        drawCap(ctx)
    }

    func drawCap(_ ctx: CGContext) {
        let c = CGPoint(x: DL.cx, y: DL.cy)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.8), blur: 1.5, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(DiscRenderer.handColor.cg()); ctx.fillEllipse(in: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4))
        ctx.restoreGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.35)); ctx.fillEllipse(in: CGRect(x: c.x - 1.4, y: c.y - 2.0, width: 2.2, height: 1.6))
    }

    func drawGloss(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(DL.face); ctx.clip()
        softLight(ctx, at: sim.gloss, radius: 46, color: RGB(1, 1, 1), alpha: 0.26)
        ctx.restoreGState()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        // The acrylic cover: an inner shadow from the bezel, a fresnel rim, and an arc of reflection
        ctx.saveGState()
        ctx.addPath(DL.face); ctx.clip()
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.22)], [0, 0.9, 1]),
                               startCenter: CGPoint(x: DL.cx, y: DL.cy), startRadius: 0, endCenter: CGPoint(x: DL.cx, y: DL.cy), endRadius: DL.R, options: [])
        ctx.restoreGState()
        fresnelRim(ctx, DL.face, width: 5, alpha: 0.12)
        ctx.setLineCap(.round)
        let hi = CGMutablePath()
        hi.addArc(center: CGPoint(x: DL.cx, y: DL.cy), radius: DL.R - 4, startAngle: .pi * 1.1, endAngle: .pi * 1.38, clockwise: false)
        ctx.addPath(hi); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.4)); ctx.setLineWidth(2.6); ctx.strokePath()
        ctx.addPath(DL.face); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.3)); ctx.setLineWidth(1.2); ctx.strokePath()
        if ui.glow > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: style.disc.cg(ui.glow))
            ctx.addPath(DL.face); ctx.setStrokeColor(style.disc.cg(0.7 * ui.glow)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }
        drawBadge(ctx, ui: ui, accent: style.disc.mixed(RGB(1, 1, 1), 0.1))
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        drawWedge(ctx)
        drawHand(ctx)
        drawGloss(ctx)
        drawFront(ctx, ui: ui)
    }
}

final class DiscModule: StyleModule {
    let sim = DiscSim()
    lazy var r = DiscRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer(), cap = CALayer()
    private lazy var wedge = MaskedGradient(r.wedgeColors, DiscRenderer.wedgeLocs, box: DL.faceBox)
    private let edge = shapeLayer(stroke: CGColor(gray: 0, alpha: 0.35), width: 0.7)
    private let hand = shapeLayer(fill: DiscRenderer.handColor.cg())
    private let glossGroup = CALayer(), glossMask = CAShapeLayer(), gloss = CALayer()
    private var backKey = "", frontKey = ""
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Disc Colour"
    var colours: [(String, RGB)] { discStyles.map { ($0.name, $0.disc) } }
    var colourIndex = 0 { didSet { r.style = discStyles[colourIndex]; wedge.set(colors: r.wedgeColors) } }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        hand.shadowColor = CGColor(gray: 0, alpha: 1)
        hand.shadowOpacity = 0.35
        hand.shadowRadius = 1.2
        hand.shadowOffset = CGSize(width: 0.8, height: -1.2)
        glossGroup.frame = container.bounds
        glossMask.frame = container.bounds
        glossMask.path = flipY(DL.face)
        glossGroup.mask = glossMask
        gloss.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        glossGroup.addSublayer(gloss)
        for l in [back, wedge.layer, edge, hand, cap, glossGroup, front] { l.frame = container.bounds; container.addSublayer(l) }
    }
    private var staticPS: CGFloat = 0

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        if !built { build() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ps = scale * backing
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), angle, 0, 0, 1)
        for l in [back, front, edge, hand, cap, gloss, wedge.mask, glossMask] { l.contentsScale = ps }
        if staticPS != ps {
            staticPS = ps
            cap.contents = layerImage(ps) { self.r.drawCap($0) }
            // The highlight spot, drawn once and moved around with the pointer
            gloss.contents = smallImage(CGSize(width: 100, height: 100), ps) { softLight($0, at: CGPoint(x: 50, y: 50), radius: 46, color: RGB(1, 1, 1), alpha: 0.26) }
        }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())|\(sim.scaleSeconds)"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ps)|\(r.style.name)|" + ui.frontKey
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        wedge.set(path: r.wedgePath())
        edge.path = flipY(r.edgePath())
        hand.path = flipY(r.handPath())
        gloss.position = CGPoint(x: sim.gloss.x, y: L.height - sim.gloss.y)
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) { sim.pointer = p.flatMap { $0.x < L.ow ? $0 : nil } }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        st.ex.inFlow = previewPhase != nil || running ? 1 : 0.6
    }
}
