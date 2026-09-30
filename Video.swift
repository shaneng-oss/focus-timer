// Renders a short showcase video (for sharing) straight from the simulations: the hourglass in real
// time, a time-lapse of a full run, a quick tour of the other styles, and an end card, with the
// live sound underneath. Used by `--video out.mp4`.

import AVFoundation
import AppKit

struct VideoSegment {
    var style: StyleKind
    var colour: Int
    var frame: Int
    var minutes: Double
    var preroll: Double          // simulated seconds to run before the first frame
    var seconds: Double          // clip length in real seconds
    var speed: Double            // simulated seconds per real second (1 = real time)
    var caption: String
    var holdDone: Double = 0     // seconds to hold on "Done" once the timer ends (time-lapse only)
}

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

final class VideoRenderer {
    let W = 1080, H = 1350, fps = 30
    let scale: CGFloat = 3.3
    let sr = 44100
    var audio = Data()
    let st = NoiseState()

    private func frameText(_ ctx: CGContext, _ text: String, size: CGFloat, y: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .medium) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: para])
        str.draw(with: CGRect(x: 60, y: y, width: CGFloat(W) - 120, height: size * 1.5), options: [.usesLineFragmentOrigin])
    }

    private func background(_ ctx: CGContext) {
        ctx.drawLinearGradient(makeGradient([RGB(0.16, 0.19, 0.27).cg(), RGB(0.22, 0.26, 0.35).cg(), RGB(0.14, 0.16, 0.23).cg()], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(H)), options: [])
        softLight(ctx, at: CGPoint(x: CGFloat(W) * 0.5, y: CGFloat(H) * 0.42), radius: 620, color: RGB(0.6, 0.66, 0.8), alpha: 0.16)
    }

    func render(to path: String) throws {
        let tmpVideo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft_video_\(getpid()).mp4")
        let tmpAudio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft_audio_\(getpid()).wav")
        try? FileManager.default.removeItem(at: tmpVideo)
        let writer = try AVAssetWriter(outputURL: tmpVideo, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 9_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "video", code: 1) }
        writer.startSession(atSourceTime: .zero)

        st.gain = 1; st.target = 1; st.volume = 0.85
        let samplesPerFrame = sr / fps
        let l = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame), r = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerFrame)

        let segments: [VideoSegment] = [
            VideoSegment(style: .sand, colour: 0, frame: 0, minutes: 25, preroll: 0.5, seconds: 6, speed: 1, caption: "Pick a length. 25 minutes for me."),
            VideoSegment(style: .sand, colour: 0, frame: 0, minutes: 25, preroll: 0, seconds: 7, speed: 25 * 60 / 7, caption: "Then work. When the sand runs out, stop.", holdDone: 1.6),
            VideoSegment(style: .lava, colour: 0, frame: 1, minutes: 25, preroll: 5.5, seconds: 2.6, speed: 1, caption: "Not into sand?"),
            VideoSegment(style: .water, colour: 1, frame: 0, minutes: 25, preroll: 4, seconds: 2.6, speed: 1, caption: "Water clock"),
            VideoSegment(style: .candle, colour: 0, frame: 0, minutes: 25, preroll: 3, seconds: 2.6, speed: 1, caption: "Candle"),
            VideoSegment(style: .snow, colour: 0, frame: 0, minutes: 25, preroll: 4, seconds: 2.6, speed: 1, caption: "Snow globe"),
            VideoSegment(style: .zen, colour: 1, frame: 0, minutes: 25, preroll: 7.2, seconds: 3.2, speed: 1, caption: "Bamboo fountain"),
        ]
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
                    var s = Int16(max(-1, min(1, v * 1.4)) * 32767)
                    withUnsafeBytes(of: &s) { audio.append(contentsOf: $0) }
                }
            }
        }

        for seg in segments {
            let m = makeModule(seg.style)
            m.colourIndex = seg.colour
            let duration = seg.minutes * 60
            m.body.configure(forSeconds: duration)
            m.body.reset()
            let rate = m.body.totalMass / CGFloat(duration)
            let fs = frameStyles[seg.frame]
            var simT = 0.0
            var done = false
            var doneAt = 0.0
            func step(_ dt: Double) {
                m.body.update(CGFloat(dt), drain: done ? 0 : rate * CGFloat(dt))
                simT += dt
                if !done && m.body.topMass < 1e-3 && !m.body.inFlight { done = true; doneAt = simT }
            }
            var t = 0.0
            while t < seg.preroll { step(1.0 / 60); t += 1.0 / 60 }
            st.pending = seg.style.sounds[0]
            if st.kind == 0 { st.kind = st.pending; st.configure(st.kind) }
            let totalFrames = Int((seg.seconds + seg.holdDone) * Double(fps))
            var doneShownFor = 0.0
            for f in 0..<totalFrames {
                let realDt = 1.0 / Double(fps)
                if done {
                    doneShownFor += realDt
                    step(realDt)
                } else {
                    let simDt = realDt * seg.speed
                    let n = max(1, Int(ceil(simDt / (1.0 / 60))))
                    for _ in 0..<n where !done { step(simDt / Double(n)) }
                }
                m.feedSound(st, dt: CGFloat(realDt), running: !done, previewPhase: nil)
                let remaining = Double(max(0, m.body.topMass / rate))
                let s = Int(ceil(remaining - 0.05))
                let time = done ? "Done" : (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60))
                let glow: CGFloat = done ? CGFloat((0.55 + 0.45 * sin(doneShownFor * 4)) * max(0, 1 - doneShownFor / 9)) : 0
                let ui = UIState(time: time, paused: false, dimTime: false, task: "", frame: fs, glow: glow, shadow: 1, running: !done, done: done)
                let fadeIn = min(1, Double(f) / 8), fadeOut = min(1, Double(totalFrames - f) / 8)
                let alpha = CGFloat(min(fadeIn, fadeOut))
                try append { ctx in
                    background(ctx)
                    ctx.saveGState()
                    ctx.setAlpha(alpha)
                    ctx.translateBy(x: (CGFloat(W) - L.width * scale) / 2, y: 72)
                    ctx.scaleBy(x: scale, y: scale)
                    m.still(ctx, ui: ui)
                    ctx.restoreGState()
                    ctx.saveGState(); ctx.setAlpha(alpha)
                    frameText(ctx, seg.caption, size: 46, y: CGFloat(H) - 150, alpha: 0.92)
                    ctx.restoreGState()
                }
                audioFrame()
                if done && doneShownFor >= seg.holdDone { break }
            }
        }
        // End card
        st.target = 0
        let endFrames = Int(3.2 * Double(fps))
        for f in 0..<endFrames {
            let a = CGFloat(min(1, Double(f) / 10))
            try append { ctx in
                background(ctx)
                ctx.saveGState(); ctx.setAlpha(a)
                frameText(ctx, "Focus Timer", size: 88, y: 520, alpha: 0.96, weight: .semibold)
                frameText(ctx, "Free · open source · Mac", size: 40, y: 650, alpha: 0.8)
                frameText(ctx, "github.com/shaneng-oss/focus-timer", size: 36, y: 730, alpha: 0.7)
                ctx.restoreGState()
            }
            audioFrame()
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "video", code: 4) }

        // Audio track, then mux both into the final file
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
