// Focus tree: a sapling in a terracotta pot that grows as you work and blossoms at the end of the
// block. During a break the petals let go and drift down to the soil, and the next block starts a
// new tree. Progress you can see, with a small reward built in.
//
// The tree is an articulated chain: every branch is a damped rotational spring hanging off its
// parent, driven by a wind field with slow gusts and fine turbulence. Thick wood barely moves; thin
// twigs with leaves on them sway and flutter. Growth follows a sigmoid per branch (length first,
// then thickening), leaves unfold once their twig has reached them, and a petal falls as a real one
// does: at terminal velocity, side-slipping in the breeze, until it rests on the soil.

import AppKit
import QuartzCore

enum TL {
    static let cx = L.cx
    static let rimTop: CGFloat = 241, potTop: CGFloat = 248, potBottom: CGFloat = 281
    static let potTopHalf: CGFloat = 36, potBottomHalf: CGFloat = 27, rimHalf: CGFloat = 38
    static let soilY: CGFloat = 243
    static let discY: CGFloat = 282
    static let groundY: CGFloat = 298
}

struct TreeStyle {
    let name: String
    let leafLight: RGB, leafDark: RGB
    let bloom: RGB, bloomCentre: RGB
    let bark: RGB
    let turns: Bool          // the leaves change colour at the end instead of flowering
    let leafScale: CGFloat
}
let treeStyles: [TreeStyle] = [
    .init(name: "Cherry", leafLight: RGB(0.46, 0.72, 0.33), leafDark: RGB(0.27, 0.52, 0.23), bloom: RGB(0.98, 0.74, 0.82), bloomCentre: RGB(0.94, 0.38, 0.52), bark: RGB(0.38, 0.25, 0.17), turns: false, leafScale: 1),
    .init(name: "Maple", leafLight: RGB(0.50, 0.70, 0.30), leafDark: RGB(0.31, 0.50, 0.20), bloom: RGB(0.90, 0.32, 0.14), bloomCentre: RGB(0.80, 0.22, 0.10), bark: RGB(0.36, 0.28, 0.22), turns: true, leafScale: 1.15),
    .init(name: "Olive", leafLight: RGB(0.64, 0.71, 0.53), leafDark: RGB(0.42, 0.52, 0.37), bloom: RGB(0.99, 0.97, 0.86), bloomCentre: RGB(0.92, 0.80, 0.42), bark: RGB(0.44, 0.38, 0.30), turns: false, leafScale: 0.85),
    .init(name: "Jacaranda", leafLight: RGB(0.50, 0.70, 0.42), leafDark: RGB(0.30, 0.50, 0.29), bloom: RGB(0.60, 0.48, 0.88), bloomCentre: RGB(0.42, 0.30, 0.72), bark: RGB(0.35, 0.27, 0.21), turns: false, leafScale: 0.9),
    .init(name: "Magnolia", leafLight: RGB(0.37, 0.57, 0.33), leafDark: RGB(0.23, 0.41, 0.23), bloom: RGB(0.99, 0.93, 0.95), bloomCentre: RGB(0.93, 0.64, 0.74), bark: RGB(0.42, 0.35, 0.30), turns: false, leafScale: 1.3),
]

struct Branch {
    var parent: Int
    var at: CGFloat            // where on the parent it grows from (0...1)
    var len, rest, width, birth: CGFloat
    var order: Int
    var curve: CGFloat         // a little bend along the branch
    var sway: CGFloat = 0, vel: CGFloat = 0
    var absAngle: CGFloat = 0
    var base = CGPoint.zero, tip = CGPoint.zero, ctrl = CGPoint.zero
    var curLen: CGFloat = 0, curW: CGFloat = 0
    var leafCount = 0
}
struct Leaf { var branch: Int; var at, side, size, angle, birth, phase, fallAt: CGFloat; var gone = false }
struct Bloom { var branch: Int; var at, size, fallAt, phase: CGFloat; var gone = false }
struct Petal { var x, y, vx, vy, angle, spin, phase, size: CGFloat; var leaf: Bool; var landed = false }

@inline(__always) func grown(_ g: CGFloat, _ birth: CGFloat, _ dur: CGFloat) -> CGFloat {
    let t = max(0, min(1, (g - birth) / dur))
    return t * t * (3 - 2 * t)
}

final class TreeSim: TimerBody {
    var totalMass: CGFloat = 1
    var topMass: CGFloat = 1
    var busy = true
    var inFlight: Bool { false }
    var seconds: Double = 1500
    var onBreak = false
    var branches: [Branch] = [], leaves: [Leaf] = [], blooms: [Bloom] = [], petals: [Petal] = []
    var rng = RNG(s: 0x9E37_79B9_7F4A_7C15)
    var time: CGFloat = 0
    var wind: CGFloat = 4, turb: CGFloat = 0
    var pointer: CGPoint?, pointerV = CGPoint.zero
    var puff: CGFloat = 0, puffAt = CGPoint.zero, puffDir: CGFloat = 1
    var running = false
    var generation = 0

    var elapsed: CGFloat { max(0, min(1, 1 - topMass / totalMass)) }
    /// A block starts with a sapling already up (a bare timer would show an empty pot for minutes).
    var growth: CGFloat { onBreak ? 1 : 0.28 + 0.72 * elapsed }
    var fall: CGFloat { onBreak ? elapsed : 0 }
    /// How far the end-of-block bloom (or autumn turn) has come.
    var bloomOpen: CGFloat { grown(growth, 0.86, 0.14) }
    var gust: CGFloat { max(0, min(1, (wind - 3) / 14 + puff)) }

    init() { grow() }

    func configure(forSeconds s: Double) { seconds = s }

    func reset() {
        topMass = totalMass
        petals.removeAll()
        if onBreak {
            // The grown tree stays for the break; its petals are all still on
            for i in blooms.indices { blooms[i].gone = false }
            for i in leaves.indices { leaves[i].gone = false }
        } else {
            generation += 1
            grow()
        }
    }
    func flip() { topMass = totalMass - topMass }
    func catchUp(_ amount: CGFloat) { topMass -= min(amount, topMass) }
    func landAll() {}

    private func absoluteRest(_ b: Branch) -> CGFloat {
        var a = b.rest, p = b.parent
        while p >= 0 { a += branches[p].rest; p = branches[p].parent }
        return a
    }

    /// Lay out a new tree: a trunk, three or four orders of branches, leaves along the twigs and
    /// buds near their tips. Each has a birth time so the tree fills in over the block.
    private func grow() {
        branches.removeAll(); leaves.removeAll(); blooms.removeAll()
        var r = RNG(s: 0x1234_5678_9ABC_DEF1 &+ UInt64(generation) &* 0x9E37_79B9_7F4A_7C15)
        branches.append(Branch(parent: -1, at: 0, len: 56 + r.unit() * 8, rest: r.signed() * 0.06, width: 4.4, birth: 0, order: 0, curve: r.signed() * 0.12))
        var i = 0
        while i < branches.count {
            let b = branches[i]
            if b.order < 4 && branches.count < 160 {
                let n = b.order == 0 ? 4 : (b.order == 1 ? 3 : 2 + Int(r.unit() * 1.7))
                var side: CGFloat = r.unit() < 0.5 ? 1 : -1
                let pa = absoluteRest(b)
                for k in 0..<n {
                    let at = min(1, (b.order == 0 ? 0.4 : 0.45) + (1 - (b.order == 0 ? 0.4 : 0.45)) * CGFloat(k) / CGFloat(max(1, n - 1)) + r.signed() * 0.05)
                    let tipChild = at > 0.9
                    let spread = tipChild ? 0.15 + 0.3 * r.unit() : 0.5 + 0.5 * r.unit()
                    var rest = side * spread
                    if abs(pa + rest) > 1.2 { rest = -rest * 0.6 }          // keep the canopy upright
                    let len = b.len * (tipChild ? 0.74 : 0.54) * (0.85 + 0.3 * r.unit())
                    let birth = min(0.74, b.birth + (b.order == 0 ? 0.02 + at * 0.1 : 0.05 + at * 0.14) + r.unit() * 0.07)
                    branches.append(Branch(parent: i, at: at, len: len, rest: rest, width: b.width * (tipChild ? 0.78 : 0.58),
                                           birth: birth, order: b.order + 1, curve: r.signed() * 0.3))
                    side = -side
                }
            }
            i += 1
        }
        for (bi, b) in branches.enumerated() where b.order >= 1 {
            let n = b.order == 1 ? 2 : 3 + Int(r.unit() * 3)
            for _ in 0..<n {
                let at = 0.25 + 0.75 * r.unit()
                leaves.append(Leaf(branch: bi, at: at, side: r.unit() < 0.5 ? 1 : -1, size: 3 + 1.8 * r.unit(), angle: 0.55 + 0.6 * r.unit(),
                                   birth: min(0.9, b.birth + 0.08 + at * 0.14 + r.unit() * 0.06), phase: r.unit() * 6.28, fallAt: r.unit()))
            }
            branches[bi].leafCount = n
            if b.order >= 2 {
                let m = b.order >= 3 ? 1 + Int(r.unit() * 2) : 1
                for k in 0..<m {
                    blooms.append(Bloom(branch: bi, at: k == 0 ? 1 : 0.5 + 0.4 * r.unit(), size: 2.6 + 1.6 * r.unit(), fallAt: r.unit() * 0.92, phase: r.unit() * 6.28))
                }
            }
        }
    }

    /// A point along a branch (on its bent centre line).
    func point(on b: Branch, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * b.base.x + 2 * u * t * b.ctrl.x + t * t * b.tip.x,
                       y: u * u * b.base.y + 2 * u * t * b.ctrl.y + t * t * b.tip.y)
    }

    func update(_ dt: CGFloat, drain: CGFloat) {
        running = drain > 0
        if running { topMass -= min(drain, topMass) }
        time += dt
        // Wind: a breeze from the left with slow gusts and fine turbulence
        let slow = wobble(time * 0.3, 3)
        turb += (rng.signed() * 18 - turb) * min(1, dt * 2.5)
        wind = 3 + 11 * slow + turb * 0.35
        // A fast cursor is a puff of air on the canopy
        if let p = pointer {
            let sp = hypot(pointerV.x, pointerV.y)
            if sp > 60 { puff = min(1, puff + sp * 0.0009); puffAt = p; puffDir = pointerV.x >= 0 ? 1 : -1 }
            pointerV = CGPoint(x: pointerV.x * 0.8, y: pointerV.y * 0.8)
        }
        puff *= exp(-dt * 2.4)

        let g = growth
        let root = CGPoint(x: TL.cx, y: TL.soilY)
        let n = 2
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            for i in branches.indices {
                var b = branches[i]
                let parentAbs: CGFloat, start: CGPoint
                if b.parent >= 0 {
                    let p = branches[b.parent]
                    parentAbs = p.absAngle
                    start = point(on: p, at: b.at)
                } else {
                    parentAbs = 0
                    start = root
                }
                b.curLen = b.len * grown(g, b.birth, 0.3)
                b.curW = b.width * (0.3 + 0.7 * grown(g, b.birth, 0.95))
                b.absAngle = parentAbs + b.rest + b.sway
                b.base = start
                let d = CGPoint(x: sin(b.absAngle), y: -cos(b.absAngle)), nrm = CGPoint(x: cos(b.absAngle), y: sin(b.absAngle))
                b.tip = CGPoint(x: start.x + d.x * b.curLen, y: start.y + d.y * b.curLen)
                b.ctrl = CGPoint(x: start.x + d.x * b.curLen * 0.5 + nrm.x * b.curve * b.curLen * 0.5,
                                 y: start.y + d.y * b.curLen * 0.5 + nrm.y * b.curve * b.curLen * 0.5)
                // Wind torque on the branch and its leaves, against the stem's stiffness and damping
                var w = wind
                if puff > 0.01 {
                    let dd = hypot(b.tip.x - puffAt.x, b.tip.y - puffAt.y)
                    w += puffDir * puff * 110 * exp(-dd * dd / 1600)
                }
                let leafArea = CGFloat(b.leafCount) * grown(g, b.birth + 0.1, 0.3)
                let torque = w * cos(b.absAngle) * b.curLen * (0.3 + leafArea * 0.35) * 0.0025
                let inertia = 0.5 + b.curW * b.curW * 0.9 + b.curLen * 0.01
                let period = 0.32 + 0.016 * b.len + (b.order == 0 ? 0.6 : 0)
                let omega = 2 * .pi / period
                let zeta = 0.12 + 0.03 * CGFloat(b.order)
                let acc = torque / inertia - omega * omega * b.sway - 2 * zeta * omega * b.vel
                b.vel += acc * h
                b.sway = max(-0.45, min(0.45, b.sway + b.vel * h))
                branches[i] = b
            }
        }
        // During a break the blossom lets go, and a few leaves with it
        if onBreak {
            let f = fall
            for i in blooms.indices where !blooms[i].gone && blooms[i].fallAt < f {
                blooms[i].gone = true
                let p = point(on: branches[blooms[i].branch], at: blooms[i].at)
                for _ in 0..<4 {
                    petals.append(Petal(x: p.x + rng.signed() * 2, y: p.y, vx: 0, vy: 0, angle: rng.unit() * 6.28, spin: rng.signed() * 3,
                                        phase: rng.unit() * 6.28, size: 1.3 + rng.unit() * 0.8, leaf: false))
                }
            }
            for i in leaves.indices where !leaves[i].gone && leaves[i].fallAt < f * 0.5 {
                leaves[i].gone = true
                let p = point(on: branches[leaves[i].branch], at: leaves[i].at)
                petals.append(Petal(x: p.x, y: p.y, vx: 0, vy: 0, angle: rng.unit() * 6.28, spin: rng.signed() * 2.5,
                                    phase: rng.unit() * 6.28, size: leaves[i].size * 0.7, leaf: true))
            }
        }
        // Falling petals: terminal velocity, side-slipping in the breeze, until they rest
        var k = 0
        while k < petals.count {
            var p = petals[k]
            if !p.landed {
                let term: CGFloat = p.leaf ? 36 : 26
                p.vy += (term - p.vy) * min(1, dt * 2.5)
                p.vx = wind * 0.4 + (p.leaf ? 20 : 15) * sin(time * 2.3 + p.phase)
                p.x += p.vx * dt
                p.y += p.vy * dt
                p.angle += (p.spin + 0.6 * sin(time * 3 + p.phase)) * dt
                let inPot = abs(p.x - TL.cx) < TL.potTopHalf - 4
                let dx = (p.x - TL.cx) / 34
                let floorY = inPot ? TL.soilY - 2.5 + 5 * sqrt(max(0, 1 - dx * dx)) * p.phase.truncatingRemainder(dividingBy: 1) : TL.groundY - 5 + 4 * p.phase.truncatingRemainder(dividingBy: 1)
                if p.y >= floorY { p.y = floorY; p.landed = true }
                if p.x < -10 || p.x > L.ow + 10 { petals.remove(at: k); continue }
            }
            petals[k] = p
            k += 1
        }
        busy = true
    }
}

// MARK: - Rendering

final class TreeRenderer {
    let sim: TreeSim
    var style = treeStyles[0]
    init(sim: TreeSim) { self.sim = sim }

    /// A circle traced the same way round as the branch quads, so overlaps fill as one shape.
    private func blob(_ p: CGMutablePath, _ c: CGPoint, _ r: CGFloat) {
        guard r > 0.05 else { return }
        for k in 0..<10 {
            let t = -CGFloat(k) * 2 * .pi / 10
            let q = CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r)
            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
    }

    func branchPath() -> CGPath {
        let p = CGMutablePath()
        for b in sim.branches where b.curLen > 0.4 {
            let n = CGPoint(x: cos(b.absAngle), y: sin(b.absAngle))
            let w0 = b.curW, w1 = max(0.35, b.curW * 0.55)
            let wm = (w0 + w1) / 2
            p.move(to: CGPoint(x: b.base.x + n.x * w0, y: b.base.y + n.y * w0))
            p.addQuadCurve(to: CGPoint(x: b.tip.x + n.x * w1, y: b.tip.y + n.y * w1), control: CGPoint(x: b.ctrl.x + n.x * wm, y: b.ctrl.y + n.y * wm))
            p.addLine(to: CGPoint(x: b.tip.x - n.x * w1, y: b.tip.y - n.y * w1))
            p.addQuadCurve(to: CGPoint(x: b.base.x - n.x * w0, y: b.base.y - n.y * w0), control: CGPoint(x: b.ctrl.x - n.x * wm, y: b.ctrl.y - n.y * wm))
            p.closeSubpath()
            blob(p, b.base, w0)
            blob(p, b.tip, w1)
        }
        // The trunk flares into the soil
        if let t = sim.branches.first, t.curLen > 0.4 {
            blob(p, CGPoint(x: t.base.x, y: t.base.y - t.curW * 0.3), t.curW * 1.25)
        }
        return p
    }

    func leafPaths() -> (CGPath, CGPath) {
        let light = CGMutablePath(), dark = CGMutablePath()
        let g = sim.growth
        let t = sim.time
        let flutterAmp = 0.06 + 0.16 * sim.gust
        for (i, lf) in sim.leaves.enumerated() where !lf.gone {
            let b = sim.branches[lf.branch]
            let s = lf.size * style.leafScale * grown(g, lf.birth, 0.08)
            guard s > 0.2 else { continue }
            let c = sim.point(on: b, at: lf.at)
            let flutter = flutterAmp * sin(t * (5 + 2 * lf.phase.truncatingRemainder(dividingBy: 1)) + lf.phase)
            let a = b.absAngle + lf.side * lf.angle + flutter
            let d = CGPoint(x: sin(a), y: -cos(a))
            let centre = CGPoint(x: c.x + d.x * s * 0.6 + lf.side * cos(b.absAngle) * b.curW * 0.4, y: c.y + d.y * s * 0.6 + lf.side * sin(b.absAngle) * b.curW * 0.4)
            var tr = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: a)
            let rect = CGRect(x: -s * 0.38, y: -s * 0.7, width: s * 0.76, height: s * 1.4)
            (i & 1 == 0 ? light : dark).addEllipse(in: rect, transform: tr)
            _ = tr
            tr = .identity
        }
        return (light, dark)
    }

    func bloomPaths() -> (CGPath, CGPath) {
        let petals = CGMutablePath(), centres = CGMutablePath()
        let open = sim.bloomOpen
        guard !style.turns, open > 0.01 else { return (petals, centres) }
        for bl in sim.blooms where !bl.gone {
            let b = sim.branches[bl.branch]
            guard b.curLen > b.len * 0.9 else { continue }
            let c = sim.point(on: b, at: bl.at)
            let s = bl.size * open * style.leafScale
            for k in 0..<5 {
                let a = bl.phase + CGFloat(k) * 2 * .pi / 5 + sim.time * 0.1 * sim.gust
                let pc = CGPoint(x: c.x + cos(a) * s * 0.55, y: c.y + sin(a) * s * 0.55)
                petals.addEllipse(in: CGRect(x: pc.x - s * 0.42, y: pc.y - s * 0.42, width: s * 0.84, height: s * 0.84))
            }
            centres.addEllipse(in: CGRect(x: c.x - s * 0.22, y: c.y - s * 0.22, width: s * 0.44, height: s * 0.44))
        }
        return (petals, centres)
    }

    func petalPaths() -> (CGPath, CGPath) {
        let petals = CGMutablePath(), leaves = CGMutablePath()
        for p in sim.petals {
            let tr = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: p.angle)
            let s = p.size
            (p.leaf ? leaves : petals).addEllipse(in: CGRect(x: -s * 0.4, y: -s * 0.75, width: s * 0.8, height: s * 1.5), transform: tr)
        }
        return (petals, leaves)
    }

    var leafLight: CGColor { style.turns ? style.leafLight.mixed(style.bloom, sim.bloomOpen).cg() : style.leafLight.cg() }
    var leafDark: CGColor { style.turns ? style.leafDark.mixed(style.bloomCentre, sim.bloomOpen).cg() : style.leafDark.cg() }
    var fallenLeaf: CGColor { style.turns ? style.bloom.scaled(0.9).cg() : style.leafDark.mixed(RGB(0.6, 0.45, 0.2), 0.5).cg() }
    var barkShadow: CGColor { style.bark.scaled(0.55).cg() }

    func drawBack(_ ctx: CGContext, ui: UIState) {
        let fs = ui.frame
        groundShadow(ctx, y: TL.groundY + 1, strength: ui.shadow, radius: 72)
        woodDisc(ctx, cy: TL.discY, rx: 54, ry: 8, thick: 7, fs: fs, seed: 9)
        // Terracotta pot: a tapered body with a thicker rim, glazed just enough to catch the light
        let body = CGMutablePath()
        body.move(to: CGPoint(x: TL.cx - TL.potTopHalf, y: TL.potTop))
        body.addLine(to: CGPoint(x: TL.cx + TL.potTopHalf, y: TL.potTop))
        body.addLine(to: CGPoint(x: TL.cx + TL.potBottomHalf, y: TL.potBottom - 3))
        body.addQuadCurve(to: CGPoint(x: TL.cx + TL.potBottomHalf - 3, y: TL.potBottom), control: CGPoint(x: TL.cx + TL.potBottomHalf, y: TL.potBottom))
        body.addLine(to: CGPoint(x: TL.cx - TL.potBottomHalf + 3, y: TL.potBottom))
        body.addQuadCurve(to: CGPoint(x: TL.cx - TL.potBottomHalf, y: TL.potBottom - 3), control: CGPoint(x: TL.cx - TL.potBottomHalf, y: TL.potBottom))
        body.closeSubpath()
        let clay = RGB(0.80, 0.47, 0.32), clayDark = RGB(0.50, 0.26, 0.16)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(body); ctx.setFillColor(clayDark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        ctx.drawLinearGradient(makeGradient([clayDark.scaled(0.9).cg(), clay.scaled(0.95).cg(), clay.scaled(1.12).cg(), clay.cg(), clayDark.cg()], [0, 0.2, 0.4, 0.72, 1]),
                               start: CGPoint(x: TL.cx - TL.potTopHalf, y: 0), end: CGPoint(x: TL.cx + TL.potTopHalf, y: 0), options: [])
        // Darker toward the base, and a water line
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.25)], [0, 1]),
                               start: CGPoint(x: 0, y: TL.potTop + 10), end: CGPoint(x: 0, y: TL.potBottom), options: [])
        grain(ctx, in: body, rect: body.boundingBox, alpha: 0.05, seed: 77)
        ctx.restoreGState()
        // Rim
        let rim = CGPath(roundedRect: CGRect(x: TL.cx - TL.rimHalf, y: TL.rimTop, width: TL.rimHalf * 2, height: TL.potTop - TL.rimTop + 1), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(rim); ctx.setFillColor(clayDark.cg()); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rim); ctx.clip()
        ctx.drawLinearGradient(makeGradient([clayDark.scaled(0.9).cg(), clay.scaled(1.05).cg(), clay.scaled(1.15).cg(), clay.cg(), clayDark.cg()], [0, 0.2, 0.4, 0.72, 1]),
                               start: CGPoint(x: TL.cx - TL.rimHalf, y: 0), end: CGPoint(x: TL.cx + TL.rimHalf, y: 0), options: [])
        ctx.drawLinearGradient(makeGradient([CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0.18)], [0, 0.5, 1]),
                               start: CGPoint(x: 0, y: TL.rimTop), end: CGPoint(x: 0, y: TL.potTop), options: [])
        ctx.restoreGState()
        // The opening, and soil inside it
        let mouth = CGRect(x: TL.cx - TL.rimHalf + 1, y: TL.rimTop - 4.5, width: (TL.rimHalf - 1) * 2, height: 9)
        ctx.saveGState()
        ctx.addEllipse(in: mouth); ctx.clip()
        ctx.drawLinearGradient(makeGradient([clayDark.scaled(0.6).cg(), clay.scaled(0.7).cg()], [0, 1]),
                               start: CGPoint(x: 0, y: mouth.minY), end: CGPoint(x: 0, y: mouth.maxY), options: [])
        ctx.restoreGState()
        let soil = CGRect(x: TL.cx - 34, y: TL.soilY - 3.6, width: 68, height: 7.2)
        ctx.saveGState()
        ctx.addEllipse(in: soil); ctx.clip()
        ctx.drawLinearGradient(makeGradient([RGB(0.26, 0.18, 0.12).cg(), RGB(0.36, 0.26, 0.17).cg(), RGB(0.30, 0.21, 0.14).cg()], [0, 0.5, 1]),
                               start: CGPoint(x: 0, y: soil.minY), end: CGPoint(x: 0, y: soil.maxY), options: [])
        var r = RNG(s: 0x50115)
        for _ in 0..<22 {
            let x = soil.midX + r.signed() * 30, y = soil.midY + r.signed() * 2.4
            let s = 0.6 + r.unit() * 1.2
            ctx.setFillColor(r.unit() < 0.6 ? RGB(0.46, 0.36, 0.26).cg(0.7) : RGB(0.18, 0.13, 0.09).cg(0.7))
            ctx.fillEllipse(in: CGRect(x: x - s / 2, y: y - s / 3, width: s, height: s * 0.66))
        }
        ctx.restoreGState()
        ctx.addEllipse(in: mouth); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); ctx.setLineWidth(0.8); ctx.strokePath()
    }

    func drawFront(_ ctx: CGContext, ui: UIState) {
        if ui.glow > 0.01 {
            let c = CGPoint(x: TL.cx, y: TL.soilY - 90)
            softLight(ctx, at: c, radius: 90, color: style.bloom, alpha: 0.5 * ui.glow)
        }
        drawBadge(ctx, ui: ui, accent: style.turns ? style.bloom : style.bloomCentre.mixed(style.bloom, 0.4))
    }

    func draw(_ ctx: CGContext, ui: UIState) {
        drawBack(ctx, ui: ui)
        let bp = branchPath()
        ctx.saveGState()
        ctx.translateBy(x: 0.7, y: 0.9)
        ctx.addPath(bp); ctx.setFillColor(barkShadow); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(bp); ctx.setFillColor(style.bark.cg()); ctx.fillPath()
        let (light, dark) = leafPaths()
        ctx.addPath(dark); ctx.setFillColor(leafDark); ctx.fillPath()
        ctx.addPath(light); ctx.setFillColor(leafLight); ctx.fillPath()
        let (petals, centres) = bloomPaths()
        ctx.addPath(petals); ctx.setFillColor(style.bloom.cg()); ctx.fillPath()
        ctx.addPath(centres); ctx.setFillColor(style.bloomCentre.cg()); ctx.fillPath()
        let (fp, fl) = petalPaths()
        ctx.addPath(fl); ctx.setFillColor(fallenLeaf); ctx.fillPath()
        ctx.addPath(fp); ctx.setFillColor(style.bloom.cg()); ctx.fillPath()
        drawFront(ctx, ui: ui)
    }
}

final class TreeModule: StyleModule {
    let sim = TreeSim()
    lazy var r = TreeRenderer(sim: sim)
    let container = CALayer()
    private let back = CALayer(), front = CALayer()
    private let barkShadow = shapeLayer(), bark = shapeLayer()
    private let leavesDark = shapeLayer(), leavesLight = shapeLayer()
    private let blooms = shapeLayer(), bloomCentres = shapeLayer()
    private let fallenLeaves = shapeLayer(), fallenPetals = shapeLayer()
    private var backKey = "", frontKey = ""
    private var built = false

    var body: TimerBody { sim }
    let colourTitle = "Tree"
    var colours: [(String, RGB)] { treeStyles.map { ($0.name, $0.turns ? $0.bloom : $0.bloom.mixed($0.bloomCentre, 0.5)) } }
    var colourIndex = 0 { didSet { r.style = treeStyles[colourIndex] } }

    func setPhase(onBreak: Bool) { sim.onBreak = onBreak }

    private func build() {
        built = true
        container.isGeometryFlipped = true
        container.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        barkShadow.frame = CGRect(x: 0.7, y: -0.9, width: L.width, height: L.height)
        for l in [back, barkShadow, bark, leavesDark, leavesLight, blooms, bloomCentres, fallenLeaves, fallenPetals, front] {
            if l !== barkShadow { l.frame = container.bounds }
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
        for l in [back, front, barkShadow, bark, leavesDark, leavesLight, blooms, bloomCentres, fallenLeaves, fallenPetals] { l.contentsScale = ps }
        let bk = "\(ui.frame.name)|\(ps)|\((ui.shadow * 10).rounded())"
        if bk != backKey { backKey = bk; back.contents = layerImage(ps) { r.drawBack($0, ui: ui) } }
        let fk = "\(ps)|\(r.style.name)|" + ui.frontKey
        if fk != frontKey { frontKey = fk; front.contents = layerImage(ps) { r.drawFront($0, ui: ui) } }
        let bp = flipY(r.branchPath())
        barkShadow.path = bp
        barkShadow.fillColor = r.barkShadow
        bark.path = bp
        bark.fillColor = r.style.bark.cg()
        let (light, dark) = r.leafPaths()
        leavesDark.path = flipY(dark); leavesDark.fillColor = r.leafDark
        leavesLight.path = flipY(light); leavesLight.fillColor = r.leafLight
        let (petals, centres) = r.bloomPaths()
        blooms.path = flipY(petals); blooms.fillColor = r.style.bloom.cg()
        bloomCentres.path = flipY(centres); bloomCentres.fillColor = r.style.bloomCentre.cg()
        let (fp, fl) = r.petalPaths()
        fallenLeaves.path = flipY(fl); fallenLeaves.fillColor = r.fallenLeaf
        fallenPetals.path = flipY(fp); fallenPetals.fillColor = r.style.bloom.cg()
        CATransaction.commit()
    }

    func still(_ ctx: CGContext, ui: UIState) { r.draw(ctx, ui: ui) }

    func pointer(_ p: CGPoint?, velocity: CGPoint) {
        sim.pointer = p
        if p != nil { sim.pointerV = velocity }
    }

    func feedSound(_ st: NoiseState, dt: CGFloat, running: Bool, previewPhase: Float?) {
        if let p = previewPhase, !running {
            st.ex.inGust = 0.2 + 0.6 * sin(p * .pi)
        } else {
            st.ex.inGust = Float(sim.gust)
        }
    }
}
