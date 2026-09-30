// Shared framework for the timer styles: a style keeps time in a "body" (material moving from a
// top store to a bottom store), draws itself into layers, and feeds its own sound.

import AppKit
import QuartzCore

enum FlipMode { case rotate, fade, shake }

enum StyleKind: Int, CaseIterable {
    case sand = 0, lava, water, candle, snow, zen

    var title: String { ["Sand Hourglass", "Lava Lamp", "Water Clock", "Candle", "Snow Globe", "Zen Garden"][rawValue] }
    var key: String { ["sand", "lava", "water", "candle", "snow", "zen"][rawValue] }
    var noun: String { ["hourglass", "lamp", "water clock", "candle", "globe", "garden"][rawValue] }
    /// What "flip" means for this style: turn the time already used into the new remaining time.
    var flipTitle: String { ["Flip Hourglass", "Flip Lamp", "Swap the Vessels", "Swap the Candle", "Shake the Globe", "Turn the Basin"][rawValue] }
    var flipMode: FlipMode {
        switch self {
        case .sand, .lava: return .rotate
        case .snow: return .shake
        default: return .fade
        }
    }
    var symbol: String { ["hourglass", "lamp.floor", "drop", "flame", "snowflake", "leaf"][rawValue] }
    /// Sound kinds that belong to this style (the first one is the default).
    var sounds: [Int] {
        switch self {
        case .sand: return [5, 6, 7, 8]
        case .lava: return [9]
        case .water: return [10, 11]
        case .candle: return [12]
        case .snow: return [13]
        case .zen: return [14]
        }
    }
}

/// A one-off sound trigger from a simulation (a drop landing, a bamboo knock, a flame lighting).
struct SoundEvent {
    enum Kind: Int32 { case drop = 1, bloop, plip, light, extinguish, swish, tock, pour }
    var kind: Kind
    var a: Float = 0
    var b: Float = 0
}

protocol StyleModule: AnyObject {
    var body: TimerBody { get }
    var container: CALayer { get }
    var colourTitle: String { get }
    var colours: [(String, RGB)] { get }
    var colourIndex: Int { get set }
    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat)
    func still(_ ctx: CGContext, ui: UIState)
    /// Called every frame the sound is on. `previewPhase` is 0...1 while a sound is being auditioned.
    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?)
    /// The mouse over the object (in the object's own coordinates), or nil when it leaves.
    func pointer(_ p: CGPoint?, velocity: CGPoint)
}

extension StyleModule {
    func pointer(_ p: CGPoint?, velocity: CGPoint) {}
}

// MARK: - Shared drawing helpers

@inline(__always) func flipY(_ p: CGPath?) -> CGPath? {
    var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: L.height)
    return p?.copy(using: &t)
}

/// A rect given in the app's y-down coordinates, expressed for a layer inside the flipped container.
@inline(__always) func upRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: L.height - r.maxY, width: r.width, height: r.height) }

func makeGradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locs)!
}

func shapeLayer(fill: CGColor? = nil, stroke: CGColor? = nil, width: CGFloat = 1) -> CAShapeLayer {
    let l = CAShapeLayer()
    l.frame = CGRect(x: 0, y: 0, width: L.width, height: L.height)
    l.fillColor = fill
    l.strokeColor = stroke
    l.lineWidth = width
    l.lineJoin = .round
    l.lineCap = .round
    return l
}

func gradientLayer(_ colors: [CGColor], _ locs: [CGFloat], box: CGRect, vertical: Bool = true) -> CAGradientLayer {
    let g = CAGradientLayer()
    g.frame = upRect(box)
    g.colors = colors
    g.locations = locs.map { NSNumber(value: Double($0)) }
    // Unit points are y-up inside the flipped container: "top" of our y-down box is y = 1.
    g.startPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0, y: 0.5)
    g.endPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 1, y: 0.5)
    return g
}

/// A gradient clipped to a path that changes every frame (mask path set by the caller via `mask`).
final class MaskedGradient {
    let layer = CALayer()
    let gradient: CAGradientLayer
    let mask = CAShapeLayer()
    init(_ colors: [CGColor], _ locs: [CGFloat], box: CGRect, vertical: Bool = true) {
        layer.frame = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        gradient = gradientLayer(colors, locs, box: box, vertical: vertical)
        layer.addSublayer(gradient)
        mask.frame = layer.frame
        mask.fillColor = CGColor(gray: 0, alpha: 1)
        layer.mask = mask
    }
    func set(colors: [CGColor]) { gradient.colors = colors }
    func set(path: CGPath?) { mask.path = flipY(path) }
}

/// A small bitmap layer covering one region, redrawn each frame (for things that need per-item alpha).
final class MiniCanvas {
    let layer = CALayer()
    let box: CGRect
    private var ctx: CGContext?
    init(box: CGRect) {
        self.box = box
        layer.frame = upRect(box)
        layer.contentsGravity = .resize
    }
    func clear() { layer.contents = nil }
    func draw(_ ps: CGFloat, _ body: (CGContext) -> Void) {
        let w = Int(ceil(box.width * ps)), h = Int(ceil(box.height * ps))
        if ctx?.width != w || ctx?.height != h {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let c = ctx else { return }
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        c.saveGState()
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: ps, y: -ps)
        c.translateBy(x: -box.minX, y: -box.minY)
        body(c)
        c.restoreGState()
        layer.contents = c.makeImage()
    }
}

/// Faint streaks that read as wood grain on the wooden finishes and brushing on the metal ones.
func frameTexture(_ ctx: CGContext, in path: CGPath, rect: CGRect, seed: UInt64 = 7) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    var r = RNG(s: seed)
    ctx.setLineWidth(0.6)
    let n = max(3, Int(rect.height / 2.2))
    for i in 0..<n {
        let y = rect.minY + (CGFloat(i) + r.unit()) * rect.height / CGFloat(n)
        let a = 0.03 + 0.07 * r.unit()
        ctx.setStrokeColor(r.unit() < 0.7 ? CGColor(gray: 0, alpha: a) : CGColor(gray: 1, alpha: a * 0.8))
        let p = CGMutablePath()
        let amp = 0.5 + r.unit() * 1.1, ph = r.unit() * 6
        var x = rect.minX
        p.move(to: CGPoint(x: x, y: y))
        while x < rect.maxX { x += 6; p.addLine(to: CGPoint(x: x, y: y + amp * sin(x * 0.07 + ph))) }
        ctx.addPath(p); ctx.strokePath()
    }
    ctx.restoreGState()
}

/// A soft diagonal reflection across glass, as a window or lamp would leave.
func glassStreak(_ ctx: CGContext, in clip: CGPath, center: CGPoint, length: CGFloat, width: CGFloat, alpha: CGFloat, angle: CGFloat = -0.5) {
    ctx.saveGState()
    ctx.addPath(clip); ctx.clip()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    ctx.clip(to: CGRect(x: -length / 2, y: -width, width: length, height: width * 2))
    ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: alpha), CGColor(gray: 1, alpha: alpha * 0.6), CGColor(gray: 1, alpha: 0)], [0, 0.4, 0.6, 1]),
                           start: CGPoint(x: 0, y: -width), end: CGPoint(x: 0, y: width), options: [])
    ctx.restoreGState()
}

/// A soft pool of light (radial falloff) in a given colour.
func softLight(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, color: RGB, alpha: CGFloat) {
    ctx.drawRadialGradient(makeGradient([color.cg(alpha), color.cg(alpha * 0.35), color.cg(0)], [0, 0.4, 1]),
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

/// The wooden / metal end caps used by the hourglass and water clock.
func frameCap(_ ctx: CGContext, y: CGFloat, fs: FrameStyle) {
    let rect = CGRect(x: L.capInset, y: y, width: L.width - 2 * L.capInset, height: L.capH)
    let p = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(p); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(makeGradient([fs.light.scaled(1.12).cg(), fs.light.cg(), fs.dark.cg()], [0, 0.35, 1]),
                           start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
    frameTexture(ctx, in: p, rect: rect, seed: UInt64(y) + 3)
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); ctx.setLineWidth(1); ctx.strokePath()
}

func frameRing(_ ctx: CGContext, y: CGFloat, w: CGFloat, fs: FrameStyle) {
    let r = CGRect(x: L.cx - w / 2, y: y, width: w, height: 3.5)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(makeGradient([fs.ring.scaled(1.18).cg(), fs.ring.scaled(0.72).cg()], [0, 1]),
                           start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    ctx.restoreGState()
}

func framePosts(_ ctx: CGContext, from y0: CGFloat, to y1: CGFloat, fs: FrameStyle) {
    for x in [L.capInset + 7, L.width - L.capInset - 7] {
        let r = CGRect(x: x - 1.8, y: y0, width: 3.6, height: y1 - y0)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(makeGradient([fs.dark.cg(), fs.light.scaled(1.15).cg(), fs.dark.cg()], [0, 0.45, 1]),
                               start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
        ctx.restoreGState()
    }
}

func groundShadow(_ ctx: CGContext, y: CGFloat, strength: CGFloat, radius: CGFloat = 80) {
    guard strength > 0 else { return }
    ctx.saveGState()
    ctx.translateBy(x: L.cx, y: y)
    ctx.scaleBy(x: 1, y: 0.1)
    ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0.22 * strength), CGColor(gray: 0, alpha: 0.08 * strength), CGColor(gray: 0, alpha: 0)], [0, 0.5, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius * 1.25, options: [])
    ctx.scaleBy(x: 1, y: 0.6)
    ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0.42 * strength), CGColor(gray: 0, alpha: 0)], [0, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius * 0.75, options: [])
    ctx.restoreGState()
}

/// The soft dark seam where something rests on a surface.
func contactShadow(_ ctx: CGContext, at c: CGPoint, rx: CGFloat, ry: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: 1, y: ry / rx)
    ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: alpha), CGColor(gray: 0, alpha: alpha * 0.4), CGColor(gray: 0, alpha: 0)], [0, 0.5, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
    ctx.restoreGState()
}

/// Glass thickness: a soft glow that hugs the inside of an outline (brighter at grazing angles).
func fresnelRim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.setShadow(offset: .zero, blur: width, color: CGColor(gray: 1, alpha: alpha))
    let big = CGMutablePath()
    big.addRect(CGRect(x: -600, y: -600, width: 1600, height: 1600))
    big.addPath(path)
    ctx.addPath(big); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Fine grain over large gradients so they read as material rather than flat vector fill.
func grain(_ ctx: CGContext, in path: CGPath, rect: CGRect, alpha: CGFloat = 0.045, seed: UInt64 = 99) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    var r = RNG(s: seed)
    let n = Int(rect.width * rect.height / 6)
    for _ in 0..<n {
        let x = rect.minX + r.unit() * rect.width, y = rect.minY + r.unit() * rect.height
        ctx.setFillColor(r.unit() < 0.5 ? CGColor(gray: 0, alpha: alpha * r.unit()) : CGColor(gray: 1, alpha: alpha * r.unit()))
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }
    ctx.restoreGState()
}

/// A small sharp specular highlight.
func specular(_ ctx: CGContext, at c: CGPoint, rx: CGFloat, ry: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: 1, y: ry / rx)
    ctx.drawRadialGradient(makeGradient([CGColor(gray: 1, alpha: alpha), CGColor(gray: 1, alpha: alpha * 0.5), CGColor(gray: 1, alpha: 0)], [0, 0.35, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
    ctx.restoreGState()
}

func drawTimeLabel(_ ctx: CGContext, ui: UIState, centerX: CGFloat = L.cx, centerY: CGFloat, size: CGFloat = 12.5, color: RGB? = nil) {
    let fs = ui.frame
    let col = color ?? fs.text
    let tcol = NSColor(cgColor: col.cg(ui.dimTime ? 0.62 : 0.95))!
    let str = NSAttributedString(string: ui.time, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: tcol, .kern: 0.4])
    let ts = str.size()
    var tx = centerX - ts.width / 2
    if ui.paused {
        tx += 6
        ctx.setFillColor(col.cg(0.8))
        let bh: CGFloat = size * 0.64
        ctx.fill(CGRect(x: tx - 11, y: centerY - bh / 2, width: 2.4, height: bh))
        ctx.fill(CGRect(x: tx - 6.8, y: centerY - bh / 2, width: 2.4, height: bh))
    }
    str.draw(at: CGPoint(x: tx, y: centerY - ts.height / 2))
}

func drawTaskLabel(_ ctx: CGContext, ui: UIState, centerX: CGFloat = L.cx, centerY: CGFloat, width: CGFloat, size: CGFloat = 10, color: RGB? = nil) {
    guard !ui.task.isEmpty else { return }
    let col = color ?? ui.frame.text
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byTruncatingTail
    let str = NSAttributedString(string: ui.task, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor(cgColor: col.cg(0.85))!, .paragraphStyle: para])
    let h = str.size().height
    str.draw(with: CGRect(x: centerX - width / 2, y: centerY - h / 2, width: width, height: h + 2),
             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

/// The floating time badge beside the object: a frosted disc with a coloured ring and a pin.
func drawBadge(_ ctx: CGContext, ui: UIState, accent: RGB) {
    let c = CGPoint(x: L.bx, y: L.by), r = L.badgeR
    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    let circle = CGPath(ellipseIn: rect, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(circle); ctx.setFillColor(RGB(0.93, 0.94, 0.96).cg(0.66)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(circle); ctx.clip()
    ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0.4), CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0.05)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
    if ui.glow > 0.01 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14, color: accent.cg(ui.glow))
        ctx.addPath(circle); ctx.setStrokeColor(accent.cg(0.9 * ui.glow)); ctx.setLineWidth(3); ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.addPath(circle); ctx.setStrokeColor(accent.cg(0.92)); ctx.setLineWidth(2.6); ctx.strokePath()
    ctx.addEllipse(in: rect.insetBy(dx: 2.6, dy: 2.6)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5)); ctx.setLineWidth(0.8); ctx.strokePath()
    let pin = CGPoint(x: c.x, y: c.y - r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: CGColor(gray: 0, alpha: 0.3))
    ctx.setFillColor(accent.scaled(0.92).cg()); ctx.fillEllipse(in: CGRect(x: pin.x - 3.4, y: pin.y - 3.4, width: 6.8, height: 6.8))
    ctx.restoreGState()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.65)); ctx.fillEllipse(in: CGRect(x: pin.x - 1.7, y: pin.y - 2.3, width: 2.4, height: 1.7))
    let ink = RGB(0.21, 0.23, 0.27)
    if ui.task.isEmpty {
        drawTimeLabel(ctx, ui: ui, centerX: c.x, centerY: c.y + 0.5, size: 12.5, color: ink)
    } else {
        drawTaskLabel(ctx, ui: ui, centerX: c.x, centerY: c.y - 8, width: r * 2 - 12, size: 6.8, color: ink)
        drawTimeLabel(ctx, ui: ui, centerX: c.x, centerY: c.y + 4.5, size: 12, color: ink)
    }
}

/// A turned wooden disc seen from slightly above (hourglass and water clock ends).
func woodDisc(_ ctx: CGContext, cy: CGFloat, rx: CGFloat, ry: CGFloat, thick: CGFloat, fs: FrameStyle, seed: UInt64) {
    let side = CGMutablePath()
    side.move(to: CGPoint(x: L.cx - rx, y: cy))
    side.addLine(to: CGPoint(x: L.cx - rx, y: cy + thick))
    side.addCurve(to: CGPoint(x: L.cx + rx, y: cy + thick), control1: CGPoint(x: L.cx - rx, y: cy + thick + ry * 1.33), control2: CGPoint(x: L.cx + rx, y: cy + thick + ry * 1.33))
    side.addLine(to: CGPoint(x: L.cx + rx, y: cy))
    side.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(side); ctx.setFillColor(fs.dark.cg()); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(side); ctx.clip()
    ctx.drawLinearGradient(makeGradient([fs.dark.scaled(0.8).cg(), fs.light.cg(), fs.light.scaled(1.12).cg(), fs.light.scaled(0.9).cg(), fs.dark.scaled(0.75).cg()], [0, 0.2, 0.42, 0.7, 1]),
                           start: CGPoint(x: L.cx - rx, y: 0), end: CGPoint(x: L.cx + rx, y: 0), options: [])
    ctx.restoreGState()
    frameTexture(ctx, in: side, rect: side.boundingBox, seed: seed)
    let top = CGRect(x: L.cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
    ctx.saveGState()
    ctx.addEllipse(in: top); ctx.clip()
    ctx.drawLinearGradient(makeGradient([fs.light.scaled(1.25).cg(), fs.light.scaled(1.05).cg(), fs.light.scaled(0.85).cg()], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: top.minY), end: CGPoint(x: 0, y: top.maxY), options: [])
    var g = RNG(s: seed &+ 77)
    ctx.setLineWidth(0.6)
    var k: CGFloat = 0.12
    while k < 0.98 {
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.05 + 0.06 * g.unit()))
        ctx.strokeEllipse(in: CGRect(x: L.cx - rx * k, y: cy - ry * k, width: rx * k * 2, height: ry * k * 2))
        k += 0.07 + 0.08 * g.unit()
    }
    specular(ctx, at: CGPoint(x: L.cx - rx * 0.35, y: cy - ry * 0.2), rx: rx * 0.45, ry: ry * 0.6, alpha: 0.22)
    ctx.restoreGState()
    ctx.addEllipse(in: top); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28)); ctx.setLineWidth(0.9); ctx.strokePath()
    // Darker seam along the underside
    ctx.saveGState()
    ctx.addPath(side); ctx.clip()
    ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)], [0, 1]),
                           start: CGPoint(x: 0, y: cy + thick - 4), end: CGPoint(x: 0, y: cy + thick + ry), options: [])
    ctx.restoreGState()
}

/// Smooth value noise in 0...1 (sum of sines with incommensurate periods), for flicker and sway.
@inline(__always) func wobble(_ t: CGFloat, _ seed: CGFloat = 0) -> CGFloat {
    let a = sin(t * 1.7 + seed) + 0.6 * sin(t * 3.1 + seed * 1.3 + 1) + 0.35 * sin(t * 6.3 + seed * 0.7 + 2) + 0.2 * sin(t * 11.7 + seed * 2.1)
    return 0.5 + a / 4.3
}

// MARK: - Sand and lava as modules

final class SandModule: StyleModule {
    let sim = SandSim()
    lazy var renderer = Renderer(sim: sim)
    lazy var scene = Scene(renderer: renderer)
    private var slideAvg: CGFloat = 0
    var body: TimerBody { sim }
    var container: CALayer { scene.container }
    let colourTitle = "Sand Colour"
    var colours: [(String, RGB)] { sandStyles.map { ($0.name, $0.color) } }
    var colourIndex = 0 { didSet { renderer.setSand(sandStyles[colourIndex].color) } }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        scene.update(renderer, ui: ui, in: bounds, scale: scale, angle: angle, backing: backing, texScale: texScale)
    }
    func still(_ ctx: CGContext, ui: UIState) { renderer.draw(ctx, ui: ui) }

    /// The live hourglass sound follows the simulation: how many grains land, whether they hit bare
    /// glass or sand, how far they fall, and any avalanches on the pile.
    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        if let p = previewPhase, !running {
            // Preview: glide from grains on glass to grains on sand, so the change can be heard.
            st.liveFlow = 0.85; st.liveBright = 1 - 0.9 * p; st.liveFall = 1 - 0.6 * p; st.liveSlide = 0
            return
        }
        // The flow of a real hourglass is constant, so the sound's level is too; only its tone moves.
        _ = slideAvg
        st.liveFlow = running || sim.emitting ? 1 : 0
        st.liveBright = Float(sim.impactBrightness)
        st.liveFall = Float(min(1, max(0.15, (sim.surfaceAt(sim.bot, L.cx) - L.neckBottom) / L.chamberH)))
        st.liveSlide = 0
    }
}

final class LavaModule: StyleModule {
    let sim = LavaSim()
    func pointer(_ p: CGPoint?, velocity: CGPoint) { sim.pointer = p }
    lazy var renderer = LavaRenderer(sim: sim)
    lazy var scene = LavaScene(renderer: renderer)
    private var previewClock: CGFloat = 0
    var body: TimerBody { sim }
    var container: CALayer { scene.container }
    let colourTitle = "Lava Colour"
    var colours: [(String, RGB)] { lavaStyles.map { ($0.name, $0.wax) } }
    var colourIndex = 0 { didSet { renderer.style = lavaStyles[colourIndex] } }

    func render(ui: UIState, bounds: CGRect, scale: CGFloat, angle: CGFloat, backing: CGFloat, texScale: CGFloat) {
        scene.update(renderer, ui: ui, in: bounds, scale: scale, angle: angle, backing: backing)
    }
    func still(_ ctx: CGContext, ui: UIState) { renderer.draw(ctx, ui: ui) }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        for e in sim.events { st.post(e) }
        sim.events.removeAll(keepingCapacity: true)
        _ = (dt, running, previewPhase, previewClock)
    }
}
