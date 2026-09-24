import AppKit
import SwiftUI

// MARK: - SignaturePad (native port of signature_pad)
//
// Swift/AppKit port of signature_pad 5.1.4 by Szymon Nowak — the open-source
// smooth-signature library (MIT, https://github.com/szimek/signature_pad,
// npm tarball sha512-q0wO5a+U…WM9jCrg==). Ported 1:1: Point (distance,
// velocity), Bezier.fromPoints with its control points and approximate
// length, the velocity-filtered stroke width (maxWidth / (v + 1), never below
// minWidth), min-distance sample filtering and the stroke replay of
// `fromData`. The canvas disc painting is replaced by CoreGraphics strokes so
// the same ink renders live, in thumbnails and as vector art in signed PDFs.
//
// One deliberate difference: signature_pad 3+ hands the two control points to
// a Bezier constructor declared (control2, control1), which swaps them and
// flattens every segment. This port keeps the 2.x order (start, c2, c3, end)
// of the reference algorithm. The upstream MIT notice is at the end of the file.

/// One sample of a stroke — signature_pad's `BasicPoint`. Coordinates are pad
/// points with y pointing down (canvas space); `time` is in milliseconds so
/// velocities come out in points per millisecond, exactly like upstream.
struct SignaturePoint: Codable, Equatable {
    var x: Double
    var y: Double
    var time: Double
    var pressure: Double

    enum CodingKeys: String, CodingKey {
        case x, y, time = "t", pressure = "p"
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    func distance(to other: SignaturePoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    func velocity(from start: SignaturePoint) -> Double {
        time != start.time ? distance(to: start) / (time - start.time) : 0
    }
}

/// signature_pad's point-group options. Stored with the ink so a replay draws
/// exactly what the pad showed. Widths are radii in pad points.
struct SignaturePen: Codable, Equatable {
    var minWidth: Double = 0.8
    var maxWidth: Double = 3.2
    var dotSize: Double = 0
    var velocityFilterWeight: Double = 0.7

    var dotRadius: Double { dotSize > 0 ? dotSize : (minWidth + maxWidth) / 2 }
}

/// signature_pad's `Bezier`: one cubic between two samples, with the stroke
/// radius at each end.
struct SignatureCurve: Equatable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint
    var startWidth: Double
    var endWidth: Double

    /// `Bezier.fromPoints`: the curve between points[1] and points[2].
    static func fromPoints(_ points: [SignaturePoint], startWidth: Double, endWidth: Double) -> SignatureCurve {
        let c2 = controlPoints(points[0], points[1], points[2]).c2
        let c3 = controlPoints(points[1], points[2], points[3]).c1
        return SignatureCurve(start: points[1].cgPoint, control1: c2, control2: c3,
                              end: points[2].cgPoint, startWidth: startWidth, endWidth: endWidth)
    }

    private static func controlPoints(_ s1: SignaturePoint, _ s2: SignaturePoint,
                                      _ s3: SignaturePoint) -> (c1: CGPoint, c2: CGPoint) {
        let dx1 = s1.x - s2.x, dy1 = s1.y - s2.y
        let dx2 = s2.x - s3.x, dy2 = s2.y - s3.y

        let m1x = (s1.x + s2.x) / 2, m1y = (s1.y + s2.y) / 2
        let m2x = (s2.x + s3.x) / 2, m2y = (s2.y + s3.y) / 2

        let l1 = (dx1 * dx1 + dy1 * dy1).squareRoot()
        let l2 = (dx2 * dx2 + dy2 * dy2).squareRoot()

        let dxm = m1x - m2x, dym = m1y - m2y

        let k = l1 + l2 == 0 ? 0 : l2 / (l1 + l2)
        let cmx = m2x + dxm * k, cmy = m2y + dym * k

        let tx = s2.x - cmx, ty = s2.y - cmy

        return (CGPoint(x: m1x + tx, y: m1y + ty), CGPoint(x: m2x + tx, y: m2y + ty))
    }

    /// Approximated length (10 chords), as in signature_pad.
    func length() -> Double {
        let steps = 10
        var length = 0.0
        var previous = start
        for i in 1...steps {
            let p = point(at: Double(i) / Double(steps))
            let dx = p.x - previous.x, dy = p.y - previous.y
            length += (dx * dx + dy * dy).squareRoot()
            previous = p
        }
        return length
    }

    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// Exact sub-curve for t in [t0, t1] (de Casteljau, split twice).
    func piece(from t0: Double, to t1: Double) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func split(_ p: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: Double)
            -> (left: (CGPoint, CGPoint, CGPoint, CGPoint), right: (CGPoint, CGPoint, CGPoint, CGPoint)) {
            let p01 = lerp(p.0, p.1, t), p12 = lerp(p.1, p.2, t), p23 = lerp(p.2, p.3, t)
            let p012 = lerp(p01, p12, t), p123 = lerp(p12, p23, t)
            let mid = lerp(p012, p123, t)
            return ((p.0, p01, p012, mid), (mid, p123, p23, p.3))
        }
        let head = split((start, control1, control2, end), t1).left
        return t1 > 0 ? split(head, t0 / t1).right : head
    }
}

enum SignatureSegment: Equatable {
    case curve(SignatureCurve)
    case dot(CGPoint, radius: Double)
    case line(CGPoint, CGPoint, width: Double)
}

/// signature_pad's per-stroke state (`_lastPoints`, `_lastVelocity`,
/// `_lastWidth`) with its `_addPoint` / `_calculateCurveWidths` logic.
struct SignatureStrokeBuilder {
    let pen: SignaturePen
    private var lastPoints: [SignaturePoint] = []
    private var lastVelocity = 0.0
    private var lastWidth: Double

    init(pen: SignaturePen) {
        self.pen = pen
        lastWidth = (pen.minWidth + pen.maxWidth) / 2
    }

    /// Add a sample; returns a new curve once there are enough points (3).
    mutating func addPoint(_ point: SignaturePoint) -> SignatureCurve? {
        lastPoints.append(point)
        guard lastPoints.count > 2 else { return nil }
        // To reduce the initial lag make it work with 3 points by copying the
        // first point to the beginning.
        if lastPoints.count == 3 { lastPoints.insert(lastPoints[0], at: 0) }
        let widths = calculateCurveWidths(lastPoints[1], lastPoints[2])
        let curve = SignatureCurve.fromPoints(lastPoints, startWidth: widths.start, endWidth: widths.end)
        // Keep at most 4 points at any time.
        lastPoints.removeFirst()
        return curve
    }

    private mutating func calculateCurveWidths(_ start: SignaturePoint,
                                               _ end: SignaturePoint) -> (start: Double, end: Double) {
        let velocity = pen.velocityFilterWeight * end.velocity(from: start)
            + (1 - pen.velocityFilterWeight) * lastVelocity
        let newWidth = max(pen.maxWidth / (velocity + 1), pen.minWidth)
        let widths = (start: lastWidth, end: newWidth)
        lastVelocity = velocity
        lastWidth = newWidth
        return widths
    }

    /// `_fromData` for one point group: curves for 3+ samples, a line for 2,
    /// a dot for 1.
    static func segments(for points: [SignaturePoint], pen: SignaturePen) -> [SignatureSegment] {
        if points.count > 2 {
            var builder = SignatureStrokeBuilder(pen: pen)
            return points.compactMap { builder.addPoint($0).map(SignatureSegment.curve) }
        } else if points.count == 2 {
            return [.line(points[0].cgPoint, points[1].cgPoint, width: pen.dotRadius * 2)]
        } else if let only = points.first {
            return [.dot(only.cgPoint, radius: pen.dotRadius)]
        }
        return []
    }
}

/// A finished drawing: the raw samples (so it can be replayed at any size)
/// plus the pen they were captured with.
struct SignatureInk: Codable, Equatable {
    var strokes: [[SignaturePoint]] = []
    var pen = SignaturePen()

    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    func segments() -> [SignatureSegment] {
        strokes.flatMap { SignatureStrokeBuilder.segments(for: $0, pen: pen) }
    }
}

// MARK: - Rendering

enum SignatureInkRenderer {
    /// Paints segments in ink space. signature_pad fills discs of radius
    /// `startWidth + t³·Δ` along each curve; here every curve is cut into a few
    /// exact sub-curves stroked (round caps) at that radius, which gives the
    /// same taper as a handful of vector strokes instead of hundreds of discs.
    static func draw(_ segments: [SignatureSegment], pen: SignaturePen, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for segment in segments {
            switch segment {
            case .curve(let c):
                let pieces = max(1, min(6, Int((c.length() / 4).rounded(.up))))
                let delta = c.endWidth - c.startWidth
                for i in 0..<pieces {
                    let t0 = Double(i) / Double(pieces), t1 = Double(i + 1) / Double(pieces)
                    let tm = (t0 + t1) / 2
                    let radius = min(c.startWidth + tm * tm * tm * delta, pen.maxWidth)
                    let p = c.piece(from: t0, to: t1)
                    ctx.setLineWidth(radius * 2)
                    ctx.move(to: p.0)
                    ctx.addCurve(to: p.3, control1: p.1, control2: p.2)
                    ctx.strokePath()
                }
            case .dot(let p, let radius):
                ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            case .line(let a, let b, let width):
                ctx.setLineWidth(width)
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// Tight ink box (curve samples grown by their stroke radius).
    static func bounds(of segments: [SignatureSegment], pen: SignaturePen) -> CGRect {
        var box = CGRect.null
        func add(_ p: CGPoint, _ r: Double) {
            box = box.union(CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        for segment in segments {
            switch segment {
            case .curve(let c):
                let r = min(max(c.startWidth, c.endWidth), pen.maxWidth)
                for i in 0...8 { add(c.point(at: Double(i) / 8), r) }
            case .dot(let p, let radius):
                add(p, radius)
            case .line(let a, let b, let width):
                add(a, width / 2)
                add(b, width / 2)
            }
        }
        return box
    }
}

// MARK: - Pad view

/// Drawing surface for a new signature — signature_pad's canvas and its
/// stroke begin / update / end event flow, on NSView mouse events.
final class SignaturePadView: NSView {
    var pen = SignaturePen()
    /// signature_pad `minDistance`: samples closer than this are skipped.
    var minDistance = 5.0
    var inkColor: NSColor = .black {
        didSet { needsDisplay = true }
    }
    var onChange: ((SignatureInk) -> Void)?

    private var strokes: [[SignaturePoint]] = []
    private var committed: [SignatureSegment] = []
    private var active: [SignaturePoint]?

    var ink: SignatureInk { SignatureInk(strokes: strokes, pen: pen) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func clear() {
        strokes = []
        committed = []
        active = nil
        needsDisplay = true
        onChange?(ink)
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        committed = ink.segments()
        needsDisplay = true
        onChange?(ink)
    }

    // Stroke begin / update / end (signature_pad `_strokeBegin`, `_strokeUpdate`, `_strokeEnd`).

    override func mouseDown(with event: NSEvent) {
        active = []
        strokeUpdate(event)
    }

    override func mouseDragged(with event: NSEvent) {
        strokeUpdate(event)
    }

    override func mouseUp(with event: NSEvent) {
        strokeUpdate(event)
        guard let stroke = active else { return }
        active = nil
        if !stroke.isEmpty {
            strokes.append(stroke)
            committed += SignatureStrokeBuilder.segments(for: stroke, pen: pen)
        }
        needsDisplay = true
        onChange?(ink)
    }

    private func strokeUpdate(_ event: NSEvent) {
        guard active != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        let point = SignaturePoint(x: location.x, y: location.y,
                                   time: event.timestamp * 1000,
                                   pressure: Double(event.pressure))
        // Skip this point if it's too close to the previous one.
        if let last = active?.last, point.distance(to: last) <= minDistance { return }
        active?.append(point)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Paper stays white in Dark Mode too: ink is chosen for white paper.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(bounds)

        // Signing line with a small "×", like a paper form.
        let baseline = (bounds.height * 0.72).rounded() + 0.5
        let guide = NSColor(white: 0.80, alpha: 1).cgColor
        ctx.setStrokeColor(guide)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.move(to: CGPoint(x: 44, y: baseline))
        ctx.addLine(to: CGPoint(x: bounds.width - 28, y: baseline))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: 24, y: baseline - 14))
        ctx.addLine(to: CGPoint(x: 34, y: baseline - 4))
        ctx.move(to: CGPoint(x: 34, y: baseline - 14))
        ctx.addLine(to: CGPoint(x: 24, y: baseline - 4))
        ctx.strokePath()

        var segments = committed
        if let active { segments += SignatureStrokeBuilder.segments(for: active, pen: pen) }
        SignatureInkRenderer.draw(segments, pen: pen, color: inkColor.cgColor, in: ctx)
    }
}

// MARK: - SwiftUI bridge

@MainActor
final class SignaturePadController: ObservableObject {
    @Published private(set) var isEmpty = true
    fileprivate weak var view: SignaturePadView?

    var ink: SignatureInk { view?.ink ?? SignatureInk() }

    func clear() { view?.clear() }
    func undo() { view?.undo() }

    fileprivate func inkChanged(_ ink: SignatureInk) {
        isEmpty = ink.isEmpty
    }
}

struct SignaturePadRepresentable: NSViewRepresentable {
    let controller: SignaturePadController
    var inkColor: NSColor

    func makeNSView(context: Context) -> SignaturePadView {
        let view = SignaturePadView()
        view.inkColor = inkColor
        view.onChange = { [weak controller] ink in controller?.inkChanged(ink) }
        controller.view = view
        return view
    }

    func updateNSView(_ view: SignaturePadView, context: Context) {
        view.inkColor = inkColor
        controller.view = view
    }
}

// signature_pad — https://github.com/szimek/signature_pad
//
// MIT License
//
// Copyright (c) 2018 Szymon Nowak
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
