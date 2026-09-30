// Renders a short showcase video straight from the simulations, with the live sound underneath.
// Studio backdrop, a moving camera, animated captions, a sound-menu demo, a tour of the styles and a
// family shot at the end. Used by `--video out.mp4`.

import AVFoundation
import AppKit

func makeModule(_ k: StyleKind) -> StyleModule {
    switch k {
    case .sand: return SandModule()
    case .lava: return LavaModule()
    case .water: return WaterModule()
    case .candle: return CandleModule()
    case .snow: return SnowModule()
    case .zen: return ZenModule()
    }
}

/// A running style with its own clock, so one object can carry over several shots.
final class Player {
    let module: StyleModule
    let rate: CGFloat
    var done = false
    var doneFor = 0.0
    init(_ k: StyleKind, colour: Int, minutes: Double, preroll: Double) {
        module = makeModule(k)
        module.colourIndex = colour
        module.body.configure(forSeconds: minutes * 60)
        module.body.reset()
        rate = module.body.totalMass / CGFloat(minutes * 60)
        var t = 0.0
        while t < preroll { step(1.0 / 60); t += 1.0 / 60 }
    }
    func step(_ dt: Double) {
        module.body.update(CGFloat(dt), drain: done ? 0 : rate * CGFloat(dt))
        if !done && module.body.topMass < 1e-3 && !module.body.inFlight { done = true }
    }
    func advance(real dt: Double, speed: Double) {
        if done { doneFor += dt; step(dt); return }
        let simDt = dt * speed
        let n = max(1, Int(ceil(simDt / (1.0 / 60))))
        for _ in 0..<n where !done { step(simDt / Double(n)) }
    }
    func ui(frame: FrameStyle) -> UIState {
        let remaining = Double(max(0, module.body.topMass / rate))
        let s = Int(ceil(remaining - 0.05))
        let time = done ? "Done" : String(format: "%02d:%02d", s / 60, s % 60)
        let glow: CGFloat = done ? CGFloat((0.55 + 0.45 * sin(doneFor * 4)) * max(0, 1 - doneFor / 9)) : 0
        return UIState(time: time, paused: false, dimTime: false, task: "", frame: frame, glow: glow, shadow: 1, running: !done, done: done)
    }
}

struct Cam { var zoom: CGFloat; var focus: CGPoint; var dx: CGFloat = 0 }

struct Shot {
    var player: Player
    var frame: Int = 0
    var seconds: Double
    var speed: Double = 1
    var camFrom: Cam
    var camTo: Cam
    var camMove: (Double, Double) = (0, 0)     // seconds when the camera move starts and ends
    var label: String
    var caption: String
    var slideIn = false, slideOut = false
    var holdDone: Double = 0
    var soundCard = false
    var sound: Int? = nil                      // sound kind to play during the shot
}

@inline(__always) func smooth(_ t: Double) -> Double { let u = min(1, max(0, t)); return u * u * (3 - 2 * u) }

final class VideoRenderer {
    let W = 1080, H = 1350, fps = 30
    let sr = 44100
    var audio = Data()
    let st = NoiseState()
    let ink = NSColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
    lazy var grainImage: CGImage? = {
        let w = 540, h = 675
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        var r = RNG(s: 0xF11D)
        guard let data = c.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(c.bytesPerRow * h) { p[i] = UInt8(96 + Int(r.next() % 64)) }
        return c.makeImage()
    }()

    static let full = Cam(zoom: 3.3, focus: CGPoint(x: 112, y: 162))

    private func backdrop(_ ctx: CGContext) {
        ctx.drawLinearGradient(makeGradient([RGB(0.965, 0.955, 0.945).cg(), RGB(0.90, 0.885, 0.87).cg(), RGB(0.76, 0.74, 0.72).cg()], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(H)), options: [])
        softLight(ctx, at: CGPoint(x: CGFloat(W) * 0.5, y: 560), radius: 560, color: RGB(1, 1, 1), alpha: 0.5)
    }

    private func finish(_ ctx: CGContext) {
        // Film grain and a soft vignette pull everything into one photograph
        if let g = grainImage {
            ctx.saveGState()
            ctx.setBlendMode(.overlay)
            ctx.setAlpha(0.16)
            ctx.draw(g, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
            ctx.restoreGState()
        }
        let c = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        ctx.drawRadialGradient(makeGradient([CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.2)], [0, 0.55, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 980, options: [])
    }

    private func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, at p: CGPoint, alpha: CGFloat, tracking: CGFloat = 0, width: CGFloat = 900, align: NSTextAlignment = .left, color: NSColor? = nil) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: (color ?? ink).withAlphaComponent(alpha), .kern: tracking, .paragraphStyle: para])
        str.draw(with: CGRect(x: p.x, y: p.y, width: width, height: size * 3), options: [.usesLineFragmentOrigin])
    }

    /// Label + statement in the lower left, sliding up as they appear.
    private func captions(_ ctx: CGContext, label: String, caption: String, t: Double, total: Double) {
        let a = CGFloat(min(smooth(t / 0.45), smooth((total - t) / 0.3)))
        let rise = CGFloat(1 - smooth(t / 0.5)) * 26
        guard a > 0.01 else { return }
        text(ctx, label, size: 24, weight: .semibold, at: CGPoint(x: 84, y: 1168 + rise), alpha: a * 0.7, tracking: 5)
        text(ctx, caption, size: 50, weight: .medium, at: CGPoint(x: 82, y: 1204 + rise), alpha: a, tracking: -0.5)
    }

    static let soundRows = [("Grains on Glass", 7), ("Brown Noise", 1), ("Pink Noise", 2), ("Ocean Waves", 3), ("Gentle Rain", 15), ("Fireplace", 16)]

    /// A floating sound menu; the highlight steps through the ambient sounds as they play.
    private func soundCard(_ ctx: CGContext, t: Double, total: Double) -> Int {
        let a = CGFloat(min(smooth(t / 0.5), smooth((total - t) / 0.3)))
        let slide = CGFloat(1 - smooth(t / 0.55)) * 120
        let x: CGFloat = 690 + slide, y: CGFloat = 330, w: CGFloat = 330
        let rowH: CGFloat = 54
        let selected = t < 1.8 ? 0 : min(5, 1 + Int((t - 1.8) / 1.45))
        let h: CGFloat = 96 + rowH * 6 + 44
        let card = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.25))
        ctx.addPath(card); ctx.setFillColor(CGColor(gray: 1, alpha: 0.94)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setAlpha(a)
        text(ctx, "Sound", size: 30, weight: .semibold, at: CGPoint(x: x + 26, y: y + 24), alpha: 1, width: w)
        var ry = y + 86
        for (i, row) in VideoRenderer.soundRows.enumerated() {
            if i == 1 {
                ry += 8
                text(ctx, "AMBIENT", size: 18, weight: .semibold, at: CGPoint(x: x + 26, y: ry + 6), alpha: 0.5, tracking: 3, width: w)
                ry += 36
            }
            if i == selected {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x + 14, y: ry - 2, width: w - 28, height: rowH - 8), cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.setFillColor(RGB(0.24, 0.5, 0.95).cg(0.92)); ctx.fillPath()
            }
            text(ctx, row.0, size: 27, weight: .regular, at: CGPoint(x: x + 30, y: ry + 8), alpha: 1, width: w - 40, color: i == selected ? .white : ink)
            if i == 0 { text(ctx, "✓", size: 25, weight: .semibold, at: CGPoint(x: x + w - 58, y: ry + 8), alpha: 1, width: 40, color: i == selected ? .white : ink) }
            ry += rowH
        }
        ctx.restoreGState()
        return VideoRenderer.soundRows[selected].1
    }

    func render(to path: String) throws {
        let tmpVideo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft_video_\(getpid()).mp4")
        let tmpAudio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft_audio_\(getpid()).wav")
        try? FileManager.default.removeItem(at: tmpVideo)
        let writer = try AVAssetWriter(outputURL: tmpVideo, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "video", code: 1) }
        writer.startSession(atSourceTime: .zero)

        st.gain = 0; st.target = 1; st.volume = 0.36            // about a fifth of full volume, fading in
        let samplesPerFrame = sr / fps
        let l = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame), r = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame)
        var frameIndex = 0

        func append(_ draw: (CGContext) -> Void) throws {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "video", code: 2) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { throw NSError(domain: "video", code: 3) }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.translateBy(x: 0, y: CGFloat(H))
                ctx.scaleBy(x: 1, y: -1)
                let saved = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                draw(ctx)
                NSGraphicsContext.current = saved
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
            frameIndex += 1
        }
        func audioFrame() {
            st.render(l, r, samplesPerFrame)
            for i in 0..<samplesPerFrame {
                for v in [l[i], r[i]] {
                    var s = Int16(max(-1, min(1, v)) * 32767)
                    withUnsafeBytes(of: &s) { audio.append(contentsOf: $0) }
                }
            }
        }
        func setSound(_ k: Int) {
            if st.kind == 0 { st.kind = k; st.configure(k) }
            st.pending = k
        }
        func drawObject(_ ctx: CGContext, _ p: Player, frame: Int, cam: Cam, alpha: CGFloat) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.translateBy(x: CGFloat(W) / 2 + cam.dx, y: 600)
            ctx.scaleBy(x: cam.zoom, y: cam.zoom)
            ctx.translateBy(x: -cam.focus.x, y: -cam.focus.y)
            p.module.still(ctx, ui: p.ui(frame: frameStyles[frame]))
            ctx.restoreGState()
        }

        // ---- the shots
        let hourglass = Player(.sand, colour: 0, minutes: 45, preroll: 0.6)
        let hourglass2 = Player(.sand, colour: 0, minutes: 45, preroll: 130)
        let neck = Cam(zoom: 8.5, focus: CGPoint(x: L.cx, y: L.neckTop + 4))
        let left = Cam(zoom: 3.0, focus: CGPoint(x: 112, y: 162), dx: -180)
        let shots: [Shot] = [
            Shot(player: hourglass, seconds: 6, camFrom: neck, camTo: VideoRenderer.full, camMove: (1.6, 3.8),
                 label: "01 · SET", caption: "Pick a length. 45 minutes for me, then a quick 5-minute break.", sound: 7),
            Shot(player: hourglass, seconds: 7.5, speed: 45 * 60 / 7.5, camFrom: VideoRenderer.full, camTo: Cam(zoom: 3.55, focus: CGPoint(x: 112, y: 175)), camMove: (0, 7.5),
                 label: "02 · WORK", caption: "Then work. When the sand runs out, stop.", holdDone: 1.8, sound: 7),
            Shot(player: hourglass2, seconds: 9.2, camFrom: left, camTo: left, label: "03 · SOUND",
                 caption: "Don't like the default sound? Choose from a range of ambient sounds for extra focus.", soundCard: true),
            Shot(player: Player(.lava, colour: 0, minutes: 25, preroll: 5.5), frame: 1, seconds: 2.8, camFrom: VideoRenderer.full, camTo: VideoRenderer.full,
                 label: "04 · STYLES", caption: "Not into sand? Lava lamp.", slideIn: true, slideOut: true, sound: 9),
            Shot(player: Player(.water, colour: 1, minutes: 25, preroll: 4), seconds: 2.8, camFrom: VideoRenderer.full, camTo: VideoRenderer.full,
                 label: "04 · STYLES", caption: "Water clock.", slideIn: true, slideOut: true, sound: 10),
            Shot(player: Player(.candle, colour: 0, minutes: 25, preroll: 3), seconds: 2.8, camFrom: VideoRenderer.full, camTo: VideoRenderer.full,
                 label: "04 · STYLES", caption: "Candle.", slideIn: true, slideOut: true, sound: 12),
            Shot(player: Player(.snow, colour: 0, minutes: 25, preroll: 4), seconds: 2.8, camFrom: VideoRenderer.full, camTo: VideoRenderer.full,
                 label: "04 · STYLES", caption: "Snow globe.", slideIn: true, slideOut: true, sound: 13),
            Shot(player: Player(.zen, colour: 1, minutes: 25, preroll: 17.3), seconds: 3.4, camFrom: VideoRenderer.full, camTo: VideoRenderer.full,
                 label: "04 · STYLES", caption: "Bamboo fountain.", slideIn: true, slideOut: true, sound: 14),
        ]

        for shot in shots {
            if let k = shot.sound { setSound(k) }
            let total = shot.seconds + shot.holdDone
            let frames = Int(total * Double(fps))
            for f in 0..<frames {
                let t = Double(f) / Double(fps)
                let dt = 1.0 / Double(fps)
                shot.player.advance(real: dt, speed: shot.speed)
                if shot.soundCard {
                    // The menu picks the sound; the highlight in the card is drawn from the same clock.
                    let selected = t < 1.8 ? 0 : min(5, 1 + Int((t - 1.8) / 1.45))
                    setSound(VideoRenderer.soundRows[selected].1)
                }
                shot.player.module.feedSound(st, dt: CGFloat(dt), running: !shot.player.done, previewPhase: nil)
                let u = CGFloat(smooth((t - shot.camMove.0) / max(0.001, shot.camMove.1 - shot.camMove.0)))
                var cam = Cam(zoom: shot.camFrom.zoom + (shot.camTo.zoom - shot.camFrom.zoom) * u,
                              focus: CGPoint(x: shot.camFrom.focus.x + (shot.camTo.focus.x - shot.camFrom.focus.x) * u,
                                             y: shot.camFrom.focus.y + (shot.camTo.focus.y - shot.camFrom.focus.y) * u),
                              dx: shot.camFrom.dx + (shot.camTo.dx - shot.camFrom.dx) * u)
                var alpha: CGFloat = 1
                if shot.slideIn { let s = smooth(t / 0.42); cam.dx += CGFloat(1 - s) * 620; alpha = min(alpha, CGFloat(s)) }
                if shot.slideOut { let s = smooth((total - t) / 0.36); cam.dx -= CGFloat(1 - s) * 620; alpha = min(alpha, CGFloat(s)) }
                if !shot.slideIn { alpha = min(alpha, CGFloat(smooth(t / 0.4))) }
                if !shot.slideOut { alpha = min(alpha, CGFloat(smooth((total - t) / 0.3))) }
                try append { ctx in
                    backdrop(ctx)
                    drawObject(ctx, shot.player, frame: shot.frame, cam: cam, alpha: alpha)
                    if shot.soundCard { _ = soundCard(ctx, t: t, total: total) }
                    captions(ctx, label: shot.label, caption: shot.caption, t: t, total: total)
                    finish(ctx)
                }
                audioFrame()
                if shot.player.done && shot.player.doneFor >= shot.holdDone && shot.holdDone > 0 { break }
            }
        }

        // ---- family shot and title
        setSound(7)
        let family = StyleKind.allCases.map { Player($0, colour: $0 == .lava ? 0 : ($0 == .water ? 1 : 0), minutes: 5, preroll: 120) }
        let endFrames = Int(4.2 * Double(fps))
        for f in 0..<endFrames {
            let t = Double(f) / Double(fps)
            if t > 2.6 { st.target = 0 }
            for p in family { p.advance(real: 1.0 / Double(fps), speed: 1) }
            let a = CGFloat(smooth(t / 0.6))
            try append { ctx in
                backdrop(ctx)
                ctx.saveGState(); ctx.setAlpha(a)
                text(ctx, "Focus Timer", size: 92, weight: .semibold, at: CGPoint(x: 0, y: 250 + CGFloat(1 - smooth(t / 0.7)) * 30), alpha: 1, tracking: -1, width: CGFloat(W), align: .center)
                text(ctx, "A timer you can watch. Six styles, each with its own sound.", size: 34, weight: .regular, at: CGPoint(x: 0, y: 372), alpha: 0.75, width: CGFloat(W), align: .center)
                let s: CGFloat = 0.74, gap: CGFloat = 4
                let rowW = CGFloat(family.count) * (L.width * s + gap)
                for (i, p) in family.enumerated() {
                    let rise = CGFloat(1 - smooth((t - 0.15 * Double(i)) / 0.7)) * 40
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(smooth((t - 0.15 * Double(i)) / 0.6)))
                    ctx.translateBy(x: (CGFloat(W) - rowW) / 2 + CGFloat(i) * (L.width * s + gap), y: 470 + rise)
                    ctx.scaleBy(x: s, y: s)
                    p.module.still(ctx, ui: p.ui(frame: frameStyles[i == 1 ? 1 : 0]))
                    ctx.restoreGState()
                }
                text(ctx, "Free · open source · Mac", size: 34, weight: .medium, at: CGPoint(x: 0, y: 790), alpha: 0.85, width: CGFloat(W), align: .center)
                text(ctx, "github.com/shaneng-oss/focus-timer", size: 32, weight: .regular, at: CGPoint(x: 0, y: 842), alpha: 0.65, width: CGFloat(W), align: .center)
                ctx.restoreGState()
                finish(ctx)
            }
            audioFrame()
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "video", code: 4) }

        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + audio.count)); h.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(audio.count))
        try (h + audio).write(to: tmpAudio)

        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: tmpVideo), aAsset = AVURLAsset(url: tmpAudio)
        guard let vSrc = vAsset.tracks(withMediaType: .video).first, let aSrc = aAsset.tracks(withMediaType: .audio).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NSError(domain: "video", code: 5) }
        try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: vSrc, at: .zero)
        try aDst.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: aSrc, at: .zero)
        let out = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw NSError(domain: "video", code: 6) }
        export.outputURL = out
        export.outputFileType = .mp4
        let sem2 = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem2.signal() }
        sem2.wait()
        guard export.status == .completed else { throw export.error ?? NSError(domain: "video", code: 7) }
        try? FileManager.default.removeItem(at: tmpVideo)
        try? FileManager.default.removeItem(at: tmpAudio)
        print("wrote \(path): \(frameIndex) frames, \(Double(frameIndex) / Double(fps)) s")
    }
}
