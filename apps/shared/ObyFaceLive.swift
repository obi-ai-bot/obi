import SwiftUI

/// Oby's face while it works (Sangam's ObyFaceLive.tsx): the flat face spins round as it shrinks
/// into a ball, which melts into three dots that bounce in a wave while Oby works; once its words
/// land the dots run back together into a ball that swells into the face as it spins to face you.
/// Damped springs chasing targets on his timeline, with his presets. At rest it's the still face.
nonisolated struct ObyLiveMotion {
    enum Name: CaseIterable { case ry, sq, inflate, scale, dR, dSpread, dBounce }
    enum Preset { case body, jelly, pop, fast, slow, melt, spread }
    struct Spring { var value: Double; var velocity = 0.0; var target: Double; var preset: Preset }

    /// [stiffness, damping], from the mascot's PRESET.
    static func constants(_ preset: Preset) -> (k: Double, c: Double) {
        switch preset {
        case .body: (120, 16)
        case .jelly: (260, 13)
        case .pop: (280, 15)
        case .fast: (500, 30)
        case .slow: (26, 10)
        case .melt: (55, 13)
        case .spread: (70, 7)
        }
    }

    static let rest: [Name: (Double, Preset)] = [
        .ry: (0, .body), .sq: (1, .jelly), .inflate: (0.17, .pop), .scale: (1, .body),
        .dR: (0, .pop), .dSpread: (0, .spread), .dBounce: (0, .body),
    ]
    /// The mascot's Loading keys: when, what, on which spring.
    static let keys: [(Double, [Name: Double], Preset)] = [
        (0, [.ry: -0.3, .sq: 0.92], .fast),                                  // wind-up
        (0.2, [.ry: .pi, .sq: 1, .inflate: 1, .scale: 0.5], .body),          // spins round as it shrinks into a ball
        (0.5, [.dR: 1], .pop),
        (0.5, [.scale: 0.04], .melt),                                        // the ball melts…
        (0.6, [.dSpread: 1], .spread),                                       // …and pulls apart into dots
        (1.1, [.dBounce: 1], .slow),
        (4.0, [.dBounce: 0], .fast),
        (4.1, [.dSpread: 0], .spread),                                       // dots run back together
        (4.25, [.scale: 0.5], .melt),                                        // into a ball
        (4.45, [.inflate: 0.17, .scale: 1, .ry: 2 * .pi], .body),           // that swells into the face as it spins to face you
        (4.5, [.dR: 0], .body),
    ]
    /// While Oby works it holds just before `wrapUp` (the dots bouncing); its words in, it skips
    /// there, and it's done after `last`, once settled.
    static let wrapUp = 4.0, last = 4.5

    private(set) var springs: [Name: Spring]
    private var time = 0.0, next = 0
    /// Seconds since it started, for the bounce's wave.
    private(set) var clock = 0.0
    /// Settled back into the still face.
    private(set) var settled = false

    /// `working`: already at work (the dots bouncing), as a view that takes over from another one is.
    init(working: Bool = false) {
        springs = Self.rest.mapValues { Spring(value: $0.0, target: $0.0, preset: $0.1) }
        advance(to: 0)
        if working { for _ in 0..<240 { step(1 / 60, live: true) } }
    }

    subscript(_ name: Name) -> Double { springs[name]?.value ?? 0 }

    private mutating func advance(to: Double) {
        while next < Self.keys.count, Self.keys[next].0 <= to {
            let (_, set, preset) = Self.keys[next]
            for (name, value) in set { springs[name]?.target = value; springs[name]?.preset = preset }
            next += 1
        }
        time = to
    }

    /// One frame: the timeline moves on (held before the wrap-up while `live`), and every spring
    /// steps in small slices so the stiff ones stay steady.
    mutating func step(_ dt: Double, live: Bool) {
        guard !settled else { return }
        let dt = min(0.05, dt)
        clock += dt
        if live, time >= Self.wrapUp { next = 0; advance(to: 0) }     // back to work while coming together
        if !live, time < Self.wrapUp {                                   // words in: skip to coming together
            next = Self.keys.firstIndex { $0.0 >= Self.wrapUp } ?? Self.keys.count
            time = Self.wrapUp
        }
        advance(to: live ? min(time + dt, Self.wrapUp - 1e-3) : time + dt)
        let slices = Int((dt * 240).rounded(.up)), h = dt / Double(max(1, slices))
        for _ in 0..<max(1, slices) {
            for name in Name.allCases {
                guard var spring = springs[name] else { continue }
                let (k, c) = Self.constants(spring.preset)
                spring.velocity += (k * (spring.target - spring.value) - c * spring.velocity) * h
                spring.value += spring.velocity * h
                springs[name] = spring
            }
        }
        if !live, time > Self.last, springs.values.allSatisfy({ abs($0.target - $0.value) < 1e-3 && abs($0.velocity) < 1e-2 }) {
            settled = true
        }
    }
}

/// Oby's 22-point face, live while `live`: the melt into dots and back (`ObyLiveMotion`), drawn at
/// 30 fps; still (the plain face) otherwise. Reduce Motion: three still dots while it works.
struct ObyFaceLive: View {
    var live: Bool
    var size: CGFloat = 22
    /// Taking over from a face that was already at work: start with the dots bouncing.
    var working = false
    @State private var motion: ObyLiveMotion?
    @State private var last: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let body = Color(hex: 0xF1F1EE), eye = Color(hex: 0x0D0D0E)

    var body: some View {
        Group {
            if reduceMotion {
                if live { stillDots } else { ObyMark(size: size) }
            } else if let motion, !motion.settled {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Canvas { canvas, _ in draw(motion, in: &canvas) }
                        .onChange(of: context.date) { _, now in
                            let dt = last.map { now.timeIntervalSince($0) } ?? 1.0 / 30
                            last = now
                            self.motion?.step(dt, live: live)
                        }
                }
            } else {
                ObyMark(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: live, initial: true) { _, live in
            if live, motion?.settled ?? true { motion = ObyLiveMotion(working: working); last = nil }
            if !live, working, motion == nil { motion = ObyLiveMotion(working: true); last = nil }
        }
    }

    private var stillDots: some View {
        Canvas { canvas, box in
            let unit = box.width / 24
            for i in -1...1 {
                canvas.fill(Path(ellipseIn: CGRect(x: (12 + Double(i) * 8.4 - 2.1) * unit, y: (14.25 - 2.1) * unit, width: 4.2 * unit, height: 4.2 * unit)),
                            with: .color(Self.body))
            }
        }
    }

    /// His SVG, in a 24-unit square: the body and ears squashed and spun, the eyes on the front
    /// only, and the dots; gooey (a blur, then a hard alpha edge) only while there are dots.
    private func draw(_ m: ObyLiveMotion, in canvas: inout GraphicsContext) {
        let unit = size / 24, cx = 12.0, cy = 14.25
        let b = min(1, max(0, (m[.inflate] - 0.17) / 0.83))        // 0 the face … 1 a ball
        let melt = min(1, max(0, 1 - (m[.scale] - 0.04) / 0.46))
        let cosine = cos(m[.ry])
        let sx = (abs(cosine) + (1 - abs(cosine)) * b) * m[.scale] / m[.sq].squareRoot()
        let sy = m[.scale] * m[.sq]
        func lerp(_ a: Double, _ z: Double) -> Double { a + (z - a) * b }
        let squash = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: sx, y: sy).translatedBy(x: -cx, y: -cy)
        let toView = CGAffineTransform(scaleX: unit, y: unit)

        let w = lerp(21, 17), h = lerp(16.5, 17)
        var body = Path(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerRadius: lerp(5, 8.5))
        var ears = Path()
        ears.addLines([CGPoint(x: 5, y: 6.6), CGPoint(x: 7.9, y: 3.6), CGPoint(x: 8.9, y: 6.6)]); ears.closeSubpath()
        ears.addLines([CGPoint(x: 19, y: 6.6), CGPoint(x: 16.1, y: 3.6), CGPoint(x: 15.1, y: 6.6)]); ears.closeSubpath()
        // The ears fold down into the ball.
        ears = ears.applying(CGAffineTransform(translationX: 0, y: 6.6).scaledBy(x: 1, y: 1 - b).translatedBy(x: 0, y: -6.6))
        body.addPath(ears.strokedPath(StrokeStyle(lineWidth: 1.2, lineJoin: .round)))
        body.addPath(ears)
        body = body.applying(squash).applying(toView)

        let k = m[.dR], spread = m[.dSpread]
        let radius = max(0, 2.1 * (1 + 0.9 * (1 - spread)) * k)
        var dots = Path()
        for i in 0..<3 {
            let hop = m[.dBounce] * 3 * max(0, sin(m.clock * 7 - Double(i) * 0.9))
            let x = cx + Double(i - 1) * 8.4 * spread, y = cy - hop
            dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        dots = dots.applying(toView)

        if k > 0.01 {
            canvas.drawLayer { layer in
                layer.addFilter(.alphaThreshold(min: 0.5, color: Self.body))
                layer.addFilter(.blur(radius: 0.9 * unit))
                layer.fill(body, with: .color(.black))
                layer.fill(dots, with: .color(.black))
            }
        } else {
            canvas.fill(body, with: .color(Self.body))
        }
        let eyesOn = min(1, max(0, cosine * 3)) * (1 - melt)
        if eyesOn > 0.01 {
            var eyes = Path()
            for x in [6.0, 14.6] { eyes.addRoundedRect(in: CGRect(x: x, y: 10.6, width: 2.8, height: 5), cornerSize: CGSize(width: 1.4, height: 1.4)) }
            canvas.fill(eyes.applying(squash).applying(toView), with: .color(Self.eye.opacity(eyesOn)))
        }
    }
}
