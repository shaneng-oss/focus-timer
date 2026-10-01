// Sounds for the lava lamp, water clock, candle, snow globe, focus disc, horizon and tree, plus
// white noise, rain and fire ambience. Everything is synthesised live from small physical building blocks: short sine "voices"
// (a bubble's chirp, a wooden knock, a glass ring), filtered noise bursts (splashes, crackles) and
// slowly modulated noise beds (wind, a flame's flutter, a fire's roar).

import Foundation

final class ExtraSynth {
    let sr: Float = 44100
    var rng = RNG(s: 0x1357_9BDF_2468_ACE0)
    var kind = 0

    // Live inputs written by the main thread; smoothed copies are used on the audio thread.
    var inFlow: Float = 1      // candle: flame intensity · disc: running · horizon: how fresh the breeze is
    var inFill: Float = 0.5    // water: basin depth 0...1
    var inGust: Float = 0      // candle: gust strength · tree: the wind on the canopy
    var inAir: Float = 1       // snow: share of snow still in the air
    var sFlow: Float = 0, sFill: Float = 0.5, sGust: Float = 0, sAir: Float = 1

    struct Voice {
        var on = false
        var type: UInt8 = 0            // 0 sine (with optional chirp), 1 band-passed noise, 2 low-passed noise
        var t: Float = 0
        var dec: Float = 1
        var decMul: Float = 1
        var attack: Float = 0.001
        var amp: Float = 0
        var ph: Float = 0
        var f: Float = 440
        var fEnd: Float = 440
        var fMul: Float = 1
        var filt = SVF()
        var gl: Float = 0.7, gr: Float = 0.7
    }
    var voices = [Voice](repeating: Voice(), count: 16)

    var brown: Float = 0
    var pb0: Float = 0, pb1: Float = 0, pb2: Float = 0
    var bedLP = SVF(), hissBP = SVF(), windBP = SVF(), tubeBP = SVF(), pourBP = SVF(), rainBP = SVF(), rainLP = SVF(), lowLP = SVF()
    var slow: Float = 0.5, slowT: Float = 0.5
    var slow2: Float = 0.5, slow2T: Float = 0.5
    var windN: Float = 0.2, windT: Float = 0.3
    var counter = 0
    var t: Float = 0
    var nextDrip: Float = 0.8, nextCrackle: Float = 0.2, nextPop: Float = 1.5, nextTinkle: Float = 5
    var pourT: Float = -1, pourLen: Float = 0.9
    var humPh: Float = 0, humPh2: Float = 0, humPh3: Float = 0
    var phA: Float = 0, phB: Float = 0, phC: Float = 0     // slow modulation phases (wrapped, so they never lose precision)
    var secPh: Float = 0
    // Cave reverb: three damped feedback combs
    var c0 = [Float](repeating: 0, count: 1493), c1 = [Float](repeating: 0, count: 1949), c2 = [Float](repeating: 0, count: 2411)
    var p0 = 0, p1 = 0, p2 = 0
    var lp0: Float = 0, lp1: Float = 0, lp2: Float = 0
    var tap = [Float](repeating: 0, count: 4096), tapPos = 0
    var room: Float = 0.15
    var wet: Float = 0

    // Recorded drips (Resources/drip*.wav, if present): played back for the water clock instead of synthesis.
    var samples: [[Float]] = ExtraSynth.loadDrips()
    struct SamplePlay { var idx: Int; var pos: Float; var rate: Float; var gain: Float; var gl: Float; var gr: Float }
    var plays: [SamplePlay] = []
    var lastSample = -1

    static func loadDrips() -> [[Float]] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        dirs.append(exe.appendingPathComponent("Resources"))
        dirs.append(exe)
        var out: [[Float]] = []
        for d in dirs {
            for i in 0..<16 {
                let u = d.appendingPathComponent("drip\(i).wav")
                if let s = ExtraSynth.readWav(u) { out.append(s) }
            }
            if !out.isEmpty { break }
        }
        return out
    }

    /// Minimal WAV reader: 16-bit PCM, mono or stereo, 44.1 kHz.
    static func readWav(_ url: URL) -> [Float]? {
        guard let d = try? Data(contentsOf: url), d.count > 44 else { return nil }
        var pos = 12
        var channels = 1, bits = 16, rate = 44100
        var pcm: Data?
        while pos + 8 <= d.count {
            let id = String(data: d[pos..<pos + 4], encoding: .ascii) ?? ""
            let size = Int(d[pos + 4]) | Int(d[pos + 5]) << 8 | Int(d[pos + 6]) << 16 | Int(d[pos + 7]) << 24
            let body = pos + 8
            if id == "fmt " && body + 16 <= d.count {
                channels = Int(d[body + 2]) | Int(d[body + 3]) << 8
                rate = Int(d[body + 4]) | Int(d[body + 5]) << 8 | Int(d[body + 6]) << 16 | Int(d[body + 7]) << 24
                bits = Int(d[body + 14]) | Int(d[body + 15]) << 8
            } else if id == "data" {
                pcm = d[body..<min(d.count, body + size)]
                break
            }
            pos = body + size + (size & 1)
        }
        guard let p = pcm, bits == 16, rate == 44100, channels >= 1 else { return nil }
        let n = p.count / (2 * channels)
        var out = [Float](repeating: 0, count: n)
        p.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += Float(Int16(littleEndian: s[i * channels + c])) }
                out[i] = v / (32768 * Float(channels))
            }
        }
        return out
    }

    func triggerSample(gain: Float, pan: Float, rate: Float) {
        guard !samples.isEmpty else { return }
        var idx = Int(rng.next() % UInt64(samples.count))
        if samples.count > 1 && idx == lastSample { idx = (idx + 1) % samples.count }
        lastSample = idx
        let a = (pan + 1) * Float.pi / 4
        if plays.count >= 8 { plays.removeFirst() }
        plays.append(SamplePlay(idx: idx, pos: 0, rate: rate, gain: gain, gl: cosf(a), gr: sinf(a)))
    }

    @inline(__always) private func samplesMix() -> (Float, Float) {
        var l: Float = 0, r: Float = 0
        var i = 0
        while i < plays.count {
            let p = plays[i]
            let s = samples[p.idx]
            let k = Int(p.pos)
            if k + 1 >= s.count { plays.remove(at: i); continue }
            let t = p.pos - Float(k)
            let v = (s[k] * (1 - t) + s[k + 1] * t) * p.gain
            l += v * p.gl; r += v * p.gr
            plays[i].pos += p.rate
            i += 1
        }
        return (l, r)
    }

    @inline(__always) func unit() -> Float { Float(rng.next() >> 40) / 16_777_216 }
    @inline(__always) func white() -> Float { unit() * 2 - 1 }
    @inline(__always) func pink(_ w: Float) -> Float {
        pb0 = 0.99765 * pb0 + w * 0.0990460
        pb1 = 0.96300 * pb1 + w * 0.2965164
        pb2 = 0.57000 * pb2 + w * 1.0526913
        return (pb0 + pb1 + pb2 + w * 0.1848) * 0.25
    }
    @inline(__always) func brownStep() -> Float {
        brown = (brown + 0.02 * white()) / 1.02
        return brown * 3.5
    }

    func configure(_ k: Int) {
        kind = k
        for i in voices.indices { voices[i].on = false }
        for i in tap.indices { tap[i] = 0 }
        for i in c0.indices { c0[i] = 0 }
        for i in c1.indices { c1[i] = 0 }
        for i in c2.indices { c2[i] = 0 }
        pourT = -1
        room = 0.15
        wet = 0
        switch k {
        case 9: bedLP = SVF(90, 0.7, sr); room = 0.1
        case 10: room = 0.05
        case 11: room = 0.05; wet = 0.5; bedLP = SVF(100, 0.7, sr)
        case 12: bedLP = SVF(140, 1.0, sr); lowLP = SVF(320, 1.4, sr); hissBP = SVF(5000, 0.8, sr); room = 0.05
        case 13: windBP = SVF(400, 2.5, sr); lowLP = SVF(180, 0.7, sr); room = 0.2
        case 14: lowLP = SVF(7500, 0.55, sr); room = 0
        case 17: bedLP = SVF(130, 2.2, sr); hissBP = SVF(900, 1.6, sr); lowLP = SVF(60, 0.7, sr); room = 0.08
        case 18: windBP = SVF(380, 2.0, sr); lowLP = SVF(140, 0.7, sr); hissBP = SVF(3200, 0.8, sr); room = 0.25
        case 19: hissBP = SVF(4500, 0.5, sr); rainLP = SVF(9000, 0.6, sr); lowLP = SVF(150, 0.7, sr); room = 0.12
        case 15: rainLP = SVF(2200, 0.6, sr); room = 0.22
        case 16: lowLP = SVF(170, 0.7, sr); hissBP = SVF(4000, 0.8, sr); room = 0.12
        default: break
        }
    }

    func fire(_ type: UInt8, f0: Float = 0, f1: Float? = nil, chirpTau: Float = 0.02, tau: Float, amp: Float, attack: Float = 0.001,
              filtF: Float = 1000, filtQ: Float = 1, pan: Float = 0) {
        var idx = -1
        var quiet: Float = 1e9
        for i in voices.indices {
            if !voices[i].on { idx = i; break }
            let l = voices[i].amp * voices[i].dec
            if l < quiet { quiet = l; idx = i }
        }
        var v = Voice()
        v.on = true
        v.type = type
        v.amp = amp
        v.attack = max(attack, 1 / sr)
        v.decMul = expf(-1 / (tau * sr))
        v.f = f0
        v.fEnd = f1 ?? f0
        v.fMul = f1 == nil ? 1 : expf(-1 / (chirpTau * sr))
        let a = (pan + 1) * Float.pi / 4
        v.gl = cosf(a); v.gr = sinf(a)
        if type != 0 { v.filt = SVF(filtF, filtQ, sr) }
        voices[idx] = v
    }

    /// One drip landing in water, matched to a reference recording: the air bubble's note between
    /// 1.3 and 2.1 kHz drifting slightly down over 50-100 ms, a bright broadband splash, hardly any
    /// low body, and dry. As the water deepens the note softens and lengthens a little.
    func plink(depth d: Float, size s: Float, pan: Float) {
        let f0 = 1300 * powf(2, unit() * 0.7) * (1 - 0.08 * d)
        fire(0, f0: f0, f1: f0 * 0.95, chirpTau: 0.06, tau: 0.028 + 0.02 * unit() + 0.012 * d, amp: 0.5 * s, attack: 0.002, pan: pan)
        fire(1, tau: 0.018 + 0.01 * s, amp: 0.56 * s, attack: 0.0008, filtF: 3200, filtQ: 0.6, pan: pan)
        fire(1, tau: 0.011, amp: 0.22 * s, attack: 0.0005, filtF: 6000, filtQ: 0.7, pan: pan)
        fire(2, tau: 0.02, amp: 0.12 * s, attack: 0.002, filtF: 400, filtQ: 0.8, pan: pan)
    }

    func handle(_ e: SoundEvent) {
        switch (kind, e.kind) {
        case (10, .drop), (11, .drop):
            if samples.isEmpty {
                plink(depth: e.a, size: max(0.3, e.b), pan: unit() * 0.5 - 0.25)
            } else {
                // The recording itself, with a little variation and a touch lower as the water deepens
                triggerSample(gain: 0.75 * (0.7 + 0.3 * max(0.3, e.b)), pan: unit() * 0.5 - 0.25, rate: (0.97 + 0.06 * unit()) * (1 - 0.05 * e.a))
            }
        case (12, .light):
            fire(2, tau: 0.22, amp: 0.55, attack: 0.04, filtF: 380, filtQ: 0.8)
        case (12, .extinguish):
            fire(1, tau: 0.05, amp: 0.35, attack: 0.004, filtF: 2200, filtQ: 0.6)
            fire(2, tau: 0.15, amp: 0.25, attack: 0.01, filtF: 300, filtQ: 0.8)
        case (13, .swish):
            fire(1, tau: 0.22, amp: 0.5, attack: 0.05, filtF: 1400, filtQ: 0.7)
        default:
            break
        }
    }

    @inline(__always) private func voicesSample() -> (Float, Float) {
        var l: Float = 0, r: Float = 0
        let inv = 1 / sr
        voices.withUnsafeMutableBufferPointer { vs in
            for i in 0..<vs.count where vs[i].on {
                let env = vs[i].amp * min(1, vs[i].t / vs[i].attack) * vs[i].dec
                var s: Float
                switch vs[i].type {
                case 0:
                    vs[i].ph += 2 * Float.pi * vs[i].f * inv
                    if vs[i].ph > 2 * Float.pi { vs[i].ph -= 2 * Float.pi }
                    s = sinf(vs[i].ph) * env
                    vs[i].f = vs[i].fEnd + (vs[i].f - vs[i].fEnd) * vs[i].fMul
                case 1:
                    s = vs[i].filt.tick(unit() * 2 - 1).bp * env
                default:
                    s = vs[i].filt.tick(unit() * 2 - 1).lp * env
                }
                vs[i].t += inv
                vs[i].dec *= vs[i].decMul
                if vs[i].dec < 0.0004 { vs[i].on = false }
                l += s * vs[i].gl
                r += s * vs[i].gr
            }
        }
        return (l, r)
    }

    @inline(__always) private func cave(_ x: Float) -> Float {
        let y0 = c0[p0], y1 = c1[p1], y2 = c2[p2]
        lp0 += (y0 - lp0) * 0.35; lp1 += (y1 - lp1) * 0.35; lp2 += (y2 - lp2) * 0.35
        c0[p0] = x + lp0 * 0.62; c1[p1] = x + lp1 * 0.62; c2[p2] = x + lp2 * 0.62
        p0 += 1; if p0 == c0.count { p0 = 0 }
        p1 += 1; if p1 == c1.count { p1 = 0 }
        p2 += 1; if p2 == c2.count { p2 = 0 }
        return (y0 + y1 + y2) * 0.33
    }

    func sample() -> (Float, Float) {
        counter &+= 1
        let inv = 1 / sr
        t += inv
        if counter & 255 == 0 {
            sFlow += (inFlow - sFlow) * 0.02
            sFill += (inFill - sFill) * 0.01
            sGust += (inGust - sGust) * 0.05
            sAir += (inAir - sAir) * 0.01
            slow += (slowT - slow) * 0.01
            if unit() < 0.004 { slowT = unit() }
            slow2 += (slow2T - slow2) * 0.004
            if unit() < 0.0015 { slow2T = unit() }
            windN += (windT - windN) * 0.006
            if unit() < 0.002 { windT = unit() * 1.8 - 0.5 }
        }
        let w = white()
        var mono: Float = 0
        var (vl, vr) = voicesSample()
        switch kind {
        case 9:
            // A warm transformer hum from the lamp's base (harmonics carry on small speakers), over a soft low bed.
            humPh += 2 * Float.pi * 52 * inv; if humPh > 2 * Float.pi { humPh -= 2 * Float.pi }
            humPh2 += 2 * Float.pi * 104 * inv; if humPh2 > 2 * Float.pi { humPh2 -= 2 * Float.pi }
            humPh3 += 2 * Float.pi * 156 * inv; if humPh3 > 2 * Float.pi { humPh3 -= 2 * Float.pi }
            let am = 1 + 0.18 * sinf(2 * Float.pi * 0.21 * t)
            mono = (sinf(humPh) * 0.4 + sinf(humPh2) * 0.25 + sinf(humPh3) * 0.12) * am * 0.32 + bedLP.tick(brownStep()).lp * 0.55
        case 10:
            mono = 0
        case 11:
            nextDrip -= inv
            if nextDrip <= 0 {
                if samples.isEmpty {
                    plink(depth: 0.3 + 0.55 * unit(), size: 0.7 + 0.5 * unit(), pan: unit() * 1.2 - 0.6)
                } else {
                    triggerSample(gain: 0.7 * (0.6 + 0.4 * unit()), pan: unit() * 1.2 - 0.6, rate: 0.94 + 0.1 * unit())
                }
                let u = unit()
                nextDrip = 0.35 + 3.2 * u * u
            }
            mono = bedLP.tick(brownStep()).lp * 0.25
        case 12:
            // A flame in still air is nearly silent: a faint low flutter, a whisper of hiss, and the
            // occasional tiny sizzle from the wick. Gusts add only a little.
            let inten = sFlow
            let bn = brownStep()
            let flut = bedLP.tick(bn).bp + lowLP.tick(bn).bp * 0.5
            let mod = 0.6 + 0.4 * slow + 0.45 * sGust
            let hiss = hissBP.tick(pink(w)).bp * 0.05
            nextCrackle -= inv
            if nextCrackle <= 0 {
                if inten > 0.3 { let u = unit(); fire(1, tau: 0.0025, amp: 0.3 * u * u, attack: 0.0003, filtF: 2200 + 1800 * unit(), filtQ: 1.5) }
                nextCrackle = 0.15 + 1.1 * unit()
            }
            mono = (flut * 0.8 * mod + hiss) * inten
        case 13:
            if counter & 63 == 0 { windBP.set(300 * powf(2, windN), 2.5, sr) }
            let wind = windBP.tick(pink(w)).bp * 1.6 * (0.35 + 0.65 * slow2 * slow2)
            let hush = lowLP.tick(brownStep()).lp * 0.5
            nextTinkle -= inv
            if nextTinkle <= 0 {
                fire(0, f0: 5000 * powf(2, unit() * 0.7), tau: 0.06, amp: 0.05, attack: 0.001, pan: unit() - 0.5)
                nextTinkle = 4 + 10 * unit()
            }
            mono = (wind + hush) * (0.35 + 0.65 * sAir)
        case 14:
            // White noise, rolled off gently above 7 kHz so it is bright without being harsh on small speakers.
            mono = lowLP.tick(w).lp * 0.5
        case 15:
            // Rain is thousands of tiny broadband splashes over a soft wash; no tones anywhere.
            let g = 0.75 + 0.25 * slow2
            if unit() < 650 * g * inv {
                let u = unit()
                fire(1, tau: 0.0008 + 0.0012 * unit(), amp: 0.55 * u * u * u, attack: 0.0002, filtF: 1500 * powf(2, unit() * 2), filtQ: 0.7, pan: unit() - 0.5)
            }
            if unit() < 4 * inv {
                // A heavier drop on the sill: a short low thump plus its splash
                fire(2, tau: 0.008, amp: 0.35 * (0.5 + 0.5 * unit()), attack: 0.0005, filtF: 420, filtQ: 0.8, pan: unit() - 0.5)
                fire(1, tau: 0.004, amp: 0.25, attack: 0.0003, filtF: 3200, filtQ: 0.6, pan: unit() - 0.5)
            }
            mono = rainLP.tick(pink(w)).lp * 0.42 * g
        case 16:
            let roar = lowLP.tick(brownStep()).lp * 0.8 * (0.7 + 0.3 * slow)
            if unit() < 9 * inv {
                let u = unit()
                fire(1, tau: 0.002 + 0.004 * unit(), amp: 0.8 * powf(u, 3.5), attack: 0.0002, filtF: 1500 * powf(2, unit() * 1.5), filtQ: 1.5, pan: unit() * 0.8 - 0.4)
            }
            nextPop -= inv
            if nextPop <= 0 {
                // A knot popping: a low thump with a sharp broadband snap on top
                fire(2, tau: 0.03, amp: 0.45, attack: 0.001, filtF: 260, filtQ: 0.8, pan: unit() * 0.6 - 0.3)
                fire(1, tau: 0.004, amp: 0.7, attack: 0.0002, filtF: 2400 * powf(2, unit() * 0.8), filtQ: 0.5, pan: unit() * 0.6 - 0.3)
                nextPop = 0.6 + 3 * unit()
            }
            mono = roar + hissBP.tick(pink(w)).bp * 0.03
        case 17:
            // A quartz desk clock's movement heard up close: a soft mechanical whir with the faintest
            // breath from the stepper once a second. No tick.
            secPh += inv; if secPh >= 1 { secPh -= 1 }
            let breath = 1 + 0.1 * expf(-secPh * 7)
            let whir = bedLP.tick(brownStep()).bp * 1.6 + hissBP.tick(pink(w)).bp * 0.12
            mono = (whir * breath + lowLP.tick(brownStep()).lp * 0.3) * (0.7 + 0.3 * sFlow)
        case 18:
            // Evening air at a window on the sea: a breeze that wanders in pitch, distant surf swelling
            // every nine seconds or so, and a whisper of high air. Nothing sudden.
            if counter & 63 == 0 { windBP.set(300 * powf(2, windN * 0.8 + 0.2), 2.0, sr) }
            phA += 2 * Float.pi * inv / 9.5; if phA > 2 * Float.pi { phA -= 2 * Float.pi }
            let breeze = windBP.tick(pink(w)).bp * 1.2 * (0.4 + 0.6 * slow2 * slow2) * (0.5 + 0.5 * sFlow)
            let swell = 0.5 + 0.5 * sinf(phA + slow * 2)
            let surf = lowLP.tick(brownStep()).lp * (0.25 + 0.75 * swell * swell) * 0.9
            mono = breeze + surf + hissBP.tick(pink(w)).bp * 0.04
        case 19:
            // Leaves: thousands of tiny papery flicks, not a wash. Short bright noise grains (2-5 ms,
            // 2.5-8 kHz) at a rate that climbs steeply with the gust moving the tree, arriving in
            // little clusters the way one leaf flicking sets off its neighbours. Almost nothing below
            // 1 kHz, and only a trace of the far canopy's blur underneath.
            let g = sGust
            phB += 2 * Float.pi * (6 + 6 * slow) * inv; if phB > 2 * Float.pi { phB -= 2 * Float.pi }
            let cluster = 0.55 + 0.45 * sinf(phB) * sinf(phB * 0.37 + slow2 * 7)
            let rate = (60 + 1300 * powf(g, 1.6)) * (0.6 + 0.8 * cluster)
            if unit() < rate * inv {
                let u = unit(), v = unit()
                fire(1, tau: 0.002 + 0.004 * v, amp: 0.9 * u * u * (0.6 + 0.4 * g), attack: 0.0004,
                     filtF: 2000 * powf(2, unit() * 1.5), filtQ: 0.7 + 0.6 * v, pan: unit() * 1.4 - 0.7)
            }
            mono = rainLP.tick(hissBP.tick(pink(w)).bp).lp * 0.03 * (0.3 + 0.7 * g) + lowLP.tick(brownStep()).lp * 0.06 * g
        default:
            mono = 0
        }
        let (sl, sr2) = samplesMix()
        vl += sl; vr += sr2
        let dry = mono + (vl + vr) * 0.5
        tap[tapPos] = dry
        var l = mono + vl + (tap[(tapPos - 613) & 4095] + 0.5 * tap[(tapPos - 1571) & 4095]) * room
        var r = mono + vr + (tap[(tapPos - 887) & 4095] + 0.5 * tap[(tapPos - 1901) & 4095]) * room
        tapPos = (tapPos + 1) & 4095
        if wet > 0 {
            let c = cave(dry)
            l += c * wet; r += c * wet * 0.9
        }
        return (l, r)
    }
}
