// Sounds for the lava lamp, water clock, candle, snow globe and zen garden, plus rain and fire
// ambience. Everything is synthesised live from small physical building blocks: short sine "voices"
// (a bubble's chirp, a wooden knock, a glass ring), filtered noise bursts (splashes, crackles) and
// slowly modulated noise beds (wind, a flame's flutter, a fire's roar).

import Foundation

final class ExtraSynth {
    let sr: Float = 44100
    var rng = RNG(s: 0x1357_9BDF_2468_ACE0)
    var kind = 0

    // Live inputs written by the main thread; smoothed copies are used on the audio thread.
    var inFlow: Float = 1      // candle: flame intensity · zen: stream flowing · snow: unused
    var inFill: Float = 0.5    // water: basin depth 0...1 · zen: how full the bamboo tube is
    var inGust: Float = 0      // candle: gust strength
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
    // Cave reverb: three damped feedback combs
    var c0 = [Float](repeating: 0, count: 1493), c1 = [Float](repeating: 0, count: 1949), c2 = [Float](repeating: 0, count: 2411)
    var p0 = 0, p1 = 0, p2 = 0
    var lp0: Float = 0, lp1: Float = 0, lp2: Float = 0
    var tap = [Float](repeating: 0, count: 4096), tapPos = 0
    var room: Float = 0.15
    var wet: Float = 0

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
        case 10: room = 0.18
        case 11: room = 0.08; wet = 0.5; bedLP = SVF(100, 0.7, sr)
        case 12: bedLP = SVF(140, 1.0, sr); lowLP = SVF(320, 1.4, sr); hissBP = SVF(5000, 0.8, sr); room = 0.05
        case 13: windBP = SVF(400, 2.5, sr); lowLP = SVF(180, 0.7, sr); room = 0.2
        case 14: rainBP = SVF(2800, 0.6, sr); tubeBP = SVF(500, 4, sr); pourBP = SVF(1200, 0.8, sr); room = 0.22
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

    /// One drip landing in water: a glass tick when the basin is bare, the air bubble's rising chirp,
    /// a splash, and a low thump whose pitch rises as the basin fills.
    func plink(depth d: Float, size s: Float, pan: Float) {
        let g = powf(max(0, 1 - d), 1.5)
        if g > 0.02 {
            fire(0, f0: 4300 * (0.92 + 0.16 * unit()), tau: 0.009, amp: 0.45 * g * s, attack: 0.0004, pan: pan)
            fire(0, f0: 6400 * (0.95 + 0.1 * unit()), tau: 0.006, amp: 0.25 * g * s, attack: 0.0004, pan: pan)
            fire(1, tau: 0.003, amp: 0.7 * g * s, attack: 0.0003, filtF: 6500, filtQ: 0.7, pan: pan)
        }
        let b = min(1, 0.15 + 2.5 * d) * s
        let f0 = 1800 * powf(2, unit() * 1.3)
        fire(0, f0: f0, f1: f0 * 1.35, chirpTau: 0.02, tau: 0.03 + 0.035 * unit(), amp: 0.55 * b, attack: 0.002, pan: pan)
        if d > 0.03 { fire(1, tau: 0.02 + 0.02 * s, amp: 0.35 * s * min(1, d * 4), attack: 0.001, filtF: 3800, filtQ: 0.8, pan: pan) }
        if d > 0.04 {
            let fb = 150 + 320 * powf(d, 1.3)
            fire(0, f0: fb, f1: fb * 0.97, chirpTau: 0.05, tau: 0.11, amp: 0.35 * powf(d, 0.7) * s, attack: 0.004, pan: pan)
        }
    }

    func handle(_ e: SoundEvent) {
        switch (kind, e.kind) {
        case (9, .bloop):
            let f0 = 190 * (0.85 + 0.3 * unit())
            fire(0, f0: f0, f1: f0 * 0.45, chirpTau: 0.13, tau: 0.26, amp: 0.8 * (0.6 + 0.4 * e.a), attack: 0.012)
            fire(2, tau: 0.07, amp: 0.45, attack: 0.004, filtF: 420, filtQ: 0.7)
        case (9, .plip):
            fire(0, f0: 100, f1: 160, chirpTau: 0.09, tau: 0.13, amp: 0.3, attack: 0.006)
        case (10, .drop):
            plink(depth: e.a, size: max(0.3, e.b), pan: unit() * 0.5 - 0.25)
        case (12, .light):
            fire(2, tau: 0.22, amp: 0.55, attack: 0.04, filtF: 380, filtQ: 0.8)
        case (12, .extinguish):
            fire(1, tau: 0.05, amp: 0.35, attack: 0.004, filtF: 2200, filtQ: 0.6)
            fire(2, tau: 0.15, amp: 0.25, attack: 0.01, filtF: 300, filtQ: 0.8)
        case (13, .swish):
            fire(1, tau: 0.22, amp: 0.5, attack: 0.05, filtF: 1400, filtQ: 0.7)
        case (14, .tock):
            fire(0, f0: 165, tau: 0.10, amp: 0.9, attack: 0.0006, pan: 0.45)
            fire(0, f0: 410, tau: 0.05, amp: 0.5, attack: 0.0006, pan: 0.45)
            fire(0, f0: 980, tau: 0.02, amp: 0.35, attack: 0.0006, pan: 0.45)
            fire(0, f0: 2100, tau: 0.006, amp: 0.2, attack: 0.0004, pan: 0.45)
            fire(1, tau: 0.0015, amp: 0.6, attack: 0.0002, filtF: 1500, filtQ: 1, pan: 0.45)
        case (14, .pour):
            pourT = 0
            pourLen = 0.5 + 0.5 * e.a
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
                plink(depth: 0.3 + 0.55 * unit(), size: 0.7 + 0.5 * unit(), pan: unit() * 1.2 - 0.6)
                let u = unit()
                nextDrip = 0.35 + 3.2 * u * u
            }
            mono = bedLP.tick(brownStep()).lp * 0.25
        case 12:
            let inten = sFlow
            let bn = brownStep()
            let flut = bedLP.tick(bn).bp + lowLP.tick(bn).bp * 0.5
            let mod = 0.55 + 0.45 * slow + 1.6 * sGust
            let hiss = hissBP.tick(pink(w)).bp * 0.06
            nextCrackle -= inv
            if nextCrackle <= 0 {
                if inten > 0.3 { let u = unit(); fire(1, tau: 0.003, amp: 0.4 * u * u, attack: 0.0003, filtF: 2000 + 1500 * unit(), filtQ: 2) }
                nextCrackle = 0.2 + 1.6 * unit()
            }
            mono = (flut * 2.2 * mod + hiss) * inten
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
            let fl = sFlow
            if fl > 0.01 && unit() < 70 * fl * inv {
                let f0 = 1400 * powf(2, unit() * 1.7), u = unit()
                fire(0, f0: f0, f1: f0 * 1.3, chirpTau: 0.008, tau: 0.005 + 0.008 * unit(), amp: 0.35 * powf(u, 2.5), attack: 0.0008, pan: -0.35)
            }
            if counter & 63 == 0 { tubeBP.set(280 + 520 * sFill, 4, sr) }
            // The tube's air column colours the trickle and rises in pitch as the tube fills.
            let vs = (vl + vr) * 0.5
            let res = tubeBP.tick(vs).bp * 0.9 * fl
            vl += res * 0.6; vr += res * 0.4
            mono = rainBP.tick(w).bp * 0.05 * fl
            if pourT >= 0 {
                pourT += inv
                let e = min(1, pourT / 0.12) * (pourT < pourLen - 0.3 ? 1 : max(0, (pourLen - pourT) / 0.3))
                let gur = 1 + 0.5 * sinf(2 * Float.pi * 6.5 * pourT)
                mono += pourBP.tick(w).bp * 0.4 * e * gur
                if unit() < 160 * inv {
                    let f0 = 900 * powf(2, unit() * 1.5), u = unit()
                    fire(0, f0: f0, f1: f0 * 1.25, chirpTau: 0.01, tau: 0.01 + 0.01 * unit(), amp: 0.3 * u * u * e, attack: 0.001, pan: -0.3)
                }
                if pourT > pourLen { pourT = -1 }
            }
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
        default:
            mono = 0
        }
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
