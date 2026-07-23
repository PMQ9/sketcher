import CoreGraphics
import Foundation

extension DrawObject {
    /// Kinds that carry a rotation angle. Lines and arrows rotate by moving
    /// their endpoints; freehand strokes are move-only.
    var isRotatable: Bool {
        switch kind {
        case .rectangle, .ellipse, .polygon, .text, .image, .filter: return true
        case .line, .polyline, .arrow, .stroke, .unknown: return false
        }
    }

    /// Kinds whose single-object `resized(handle:to:)` does real work. Freehand
    /// strokes and polylines have no meaningful per-handle resize, so they scale
    /// as a group instead; unknown objects render nothing.
    var supportsHandleResize: Bool {
        switch kind {
        case .stroke, .polyline, .unknown: return false
        default: return true
        }
    }

    /// The point rotation pivots around (the shape's unrotated center).
    var rotationCenter: CGPoint {
        switch kind {
        case .rectangle(let r, _), .ellipse(let r), .polygon(let r, _, _):
            return r.center
        case .image(let payload): return payload.rect.center
        case .filter(let payload): return payload.region.center
        default: return bounds.center
        }
    }

    /// The unrotated box a rotatable shape occupies, used for handles and the
    /// selection outline.
    var localBox: CGRect {
        switch kind {
        case .rectangle(let r, _), .ellipse(let r), .polygon(let r, _, _): return r
        case .image(let payload): return payload.rect
        case .filter(let payload): return payload.region
        default: return bounds
        }
    }

    /// Loose bounding box in canvas pixels, ignoring stroke width.
    var bounds: CGRect {
        switch kind {
        case .rectangle(let r, _), .ellipse(let r), .polygon(let r, _, _):
            return r
        case .line(let s, let e, let c):
            return CGRect(containing: c.map { [s, e, $0] } ?? [s, e])
        case .polyline(let points, _):
            return CGRect(containing: points)
        case .arrow(let payload):
            let pts = payload.control.map { [payload.start, payload.end, $0] }
                ?? [payload.start, payload.end]
            return CGRect(containing: pts)
        case .stroke(let payload):
            return CGRect(containing: payload.points)
        case .text(let payload):
            return TextMetrics.bounds(of: payload)
        case .image(let payload):
            return payload.rect
        case .filter(let payload):
            return payload.region
        case .unknown:
            return .null
        }
    }

    /// Bounds including stroke overhang — what a dirty-rect or cull test needs.
    var renderBounds: CGRect {
        let b = bounds
        guard !b.isNull else { return .null }
        var pad = style.strokeWidthPx / 2 + 1
        if case .stroke(let payload) = kind {
            pad = payload.brush.sizePx * payload.brush.widthMultiplier / 2 + 1
        }
        var r = b.insetBy(dx: -pad, dy: -pad)
        if let shadow = style.shadow {
            let shadowRect = r.offsetBy(dx: shadow.offset.width, dy: shadow.offset.height)
                .insetBy(dx: -shadow.blurRadiusPx, dy: -shadow.blurRadiusPx)
            r = r.unionIgnoringNull(shadowRect)
        }
        guard isRotatable, rotation != 0 else { return r }
        // A rotated rect's axis-aligned bound is the bound of its four corners.
        let c = rotationCenter
        return CGRect(containing: [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)
        ].map { $0.rotated(around: c, by: rotation) })
    }

    /// The 4 corners of the shape's box in world space (rotated if applicable).
    /// Order: TL, TR, BR, BL.
    var outlineCorners: [CGPoint] {
        let b = localBox
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        guard isRotatable, rotation != 0 else { return corners }
        let c = rotationCenter
        return corners.map { $0.rotated(around: c, by: rotation) }
    }

    mutating func translate(by delta: CGPoint) {
        func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: delta.x, dy: delta.y) }
        switch kind {
        case .rectangle(let r, let radius):
            kind = .rectangle(rect: moved(r), cornerRadius: radius)
        case .ellipse(let r):
            kind = .ellipse(rect: moved(r))
        case .polygon(let r, let sides, let ratio):
            kind = .polygon(rect: moved(r), sides: sides, starInnerRatio: ratio)
        case .line(let s, let e, let c):
            kind = .line(start: moved(s), end: moved(e), control: c.map(moved))
        case .polyline(let points, let closed):
            kind = .polyline(points: points.map(moved), closed: closed)
        case .arrow(var payload):
            payload.start = moved(payload.start)
            payload.end = moved(payload.end)
            payload.control = payload.control.map(moved)
            kind = .arrow(payload)
        case .stroke(var payload):
            payload.samples = payload.samples.map {
                StrokeSample(point: moved($0.point), pressure: $0.pressure,
                             tilt: $0.tilt, timestamp: $0.timestamp)
            }
            kind = .stroke(payload)
        case .text(var payload):
            payload.origin = moved(payload.origin)
            kind = .text(payload)
        case .image(var payload):
            payload.rect = moved(payload.rect)
            kind = .image(payload)
        case .filter(var payload):
            payload.region = moved(payload.region)
            kind = .filter(payload)
        case .unknown:
            break
        }
        if var erased = erasedGeometry {
            erased.subpaths = erased.subpaths.map { $0.map(moved) }
            erasedGeometry = erased
        }
    }

    /// Scale every point of this object by `(sx, sy)` about `pivot`, in canvas
    /// pixels. Used for group resize, where several objects scale together
    /// around the fixed opposite corner of their shared box.
    ///
    /// Geometry only: a shape's stroke weight is deliberately NOT scaled (Figma's
    /// default — a resized rectangle keeps its border weight), but a freehand
    /// stroke scales its brush width so the whole mark grows, and text scales its
    /// font size with the vertical factor.
    func scaled(sx: CGFloat, sy: CGFloat, around pivot: CGPoint) -> DrawObject {
        var copy = self
        func sp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: pivot.x + (p.x - pivot.x) * sx, y: pivot.y + (p.y - pivot.y) * sy)
        }
        func sr(_ r: CGRect) -> CGRect {
            CGRect(dragFrom: sp(CGPoint(x: r.minX, y: r.minY)),
                   to: sp(CGPoint(x: r.maxX, y: r.maxY)))
        }
        switch kind {
        case .rectangle(let r, let radius):
            copy.kind = .rectangle(rect: sr(r),
                                   cornerRadius: radius * Swift.min(abs(sx), abs(sy)))
        case .ellipse(let r):
            copy.kind = .ellipse(rect: sr(r))
        case .polygon(let r, let sides, let ratio):
            copy.kind = .polygon(rect: sr(r), sides: sides, starInnerRatio: ratio)
        case .line(let s, let e, let c):
            copy.kind = .line(start: sp(s), end: sp(e), control: c.map(sp))
        case .polyline(let points, let closed):
            copy.kind = .polyline(points: points.map(sp), closed: closed)
        case .arrow(var payload):
            payload.start = sp(payload.start)
            payload.end = sp(payload.end)
            payload.control = payload.control.map(sp)
            copy.kind = .arrow(payload)
        case .stroke(var payload):
            payload.samples = payload.samples.map {
                StrokeSample(point: sp($0.point), pressure: $0.pressure,
                             tilt: $0.tilt, timestamp: $0.timestamp)
            }
            payload.brush.sizePx *= (abs(sx) + abs(sy)) / 2
            copy.kind = .stroke(payload)
        case .text(var payload):
            let box = sr(TextMetrics.bounds(of: payload))
            payload.origin = box.origin
            payload.boxSize = box.size
            payload.fontSizePx *= abs(sy)
            payload.resize = .fixed
            copy.kind = .text(payload)
        case .image(var payload):
            payload.rect = sr(payload.rect)
            copy.kind = .image(payload)
        case .filter(var payload):
            payload.region = sr(payload.region)
            copy.kind = .filter(payload)
        case .unknown:
            break
        }
        if var erased = copy.erasedGeometry {
            erased.subpaths = erased.subpaths.map { $0.map(sp) }
            copy.erasedGeometry = erased
        }
        return copy
    }

    /// Clip a world-space rect out of this object (redaction of a partially
    /// covered shape). `erasedGeometry` lives in the object's LOCAL frame — the
    /// renderer applies it after rotating the context, and `hitTest` inverse-
    /// rotates the probe — so a rotated object maps the rect's corners into local
    /// space first.
    mutating func addErasedRect(_ rect: CGRect) {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let local = (isRotatable && rotation != 0)
            ? corners.map { $0.rotated(around: rotationCenter, by: -rotation) }
            : corners
        var geometry = erasedGeometry ?? PathGeometry(subpaths: [])
        geometry.subpaths.append(local)
        erasedGeometry = geometry
    }

    /// Clip a world-space polygon (a partial-vector eraser stroke's outline) out
    /// of this object. Like `addErasedRect`, the points are mapped into the
    /// object's LOCAL frame so a rotated object erases where the pointer swept.
    mutating func addErasedPolygon(_ worldPolygon: [CGPoint]) {
        guard worldPolygon.count >= 3 else { return }
        let local = (isRotatable && rotation != 0)
            ? worldPolygon.map { $0.rotated(around: rotationCenter, by: -rotation) }
            : worldPolygon
        var geometry = erasedGeometry ?? PathGeometry(subpaths: [])
        geometry.subpaths.append(local)
        erasedGeometry = geometry
    }

    /// Hit test in canvas pixels. Shapes hit on their BORDER BAND, not their
    /// interior, so an unfilled shape can be clicked through — unless it is
    /// filled, in which case the interior counts too.
    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        guard !isHidden else { return false }
        // Test in the shape's local (unrotated) frame — one line handles every
        // rotated kind, so no hit test needs its own rotation math.
        let q = (isRotatable && rotation != 0)
            ? p.rotated(around: rotationCenter, by: -rotation) : p

        // A point erased away is not a hit. Test each subpath independently so a
        // point in the overlap of two eraser strokes still reads as erased —
        // matching how the renderer punches the holes.
        if let erased = erasedGeometry, !erased.isEmpty {
            for sub in erased.subpaths where sub.count >= 3 {
                let path = CGMutablePath()
                path.addLines(between: sub)
                path.closeSubpath()
                if path.contains(q) { return false }
            }
        }

        let halfStroke = style.strokeWidthPx / 2
        let band = tolerance + halfStroke

        switch kind {
        case .rectangle(let rect, let radius):
            if style.fill.isVisible && rect.contains(q) { return true }
            if radius > 0 {
                let path = CGPath(roundedRect: rect.standardized,
                                  cornerWidth: min(radius, rect.width / 2),
                                  cornerHeight: min(radius, rect.height / 2),
                                  transform: nil)
                return path.copy(strokingWithWidth: band * 2, lineCap: .round,
                                 lineJoin: .round, miterLimit: 10).contains(q)
            }
            return rect.borderBandContains(q, band: band)

        case .ellipse(let rect):
            if style.fill.isVisible,
               CGPath(ellipseIn: rect, transform: nil).contains(q) { return true }
            return rect.ellipseBorderContains(q, band: band)

        case .polygon(let rect, let sides, let ratio):
            let path = ObjectPaths.polygonPath(in: rect, sides: sides, starInnerRatio: ratio)
            if style.fill.isVisible && path.contains(q) { return true }
            return path.copy(strokingWithWidth: band * 2, lineCap: .round,
                             lineJoin: .round, miterLimit: 10).contains(q)

        case .line(let s, let e, let c):
            if let c {
                return ObjectPaths.quadPath(from: s, control: c, to: e)
                    .copy(strokingWithWidth: band * 2, lineCap: .round,
                          lineJoin: .round, miterLimit: 10).contains(q)
            }
            return q.distanceToSegment(s, e) <= band

        case .polyline(let points, let closed):
            if closed, style.fill.isVisible,
               ObjectPaths.polylinePath(points, closed: true).contains(q) { return true }
            if q.isNear(polyline: points, within: band) { return true }
            if closed, let first = points.first, let last = points.last {
                return q.distanceToSegment(last, first) <= band
            }
            return false

        case .arrow(let payload):
            if let c = payload.control {
                return ObjectPaths.quadPath(from: payload.start, control: c, to: payload.end)
                    .copy(strokingWithWidth: band * 2, lineCap: .round,
                          lineJoin: .round, miterLimit: 10).contains(q)
            }
            return q.distanceToSegment(payload.start, payload.end) <= band

        case .stroke(let payload):
            // Effective width includes the brush multiplier, or a highlighter
            // is unclickable across most of its visible body.
            let w = payload.brush.sizePx * payload.brush.widthMultiplier / 2
            return q.isNear(polyline: payload.points, within: tolerance + w)

        case .text, .image, .filter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(q)

        case .unknown:
            return false
        }
    }

    /// Returns a copy with `handle` moved to `p`, anchored on the ORIGINAL
    /// geometry — callers must pass the pre-gesture object every frame so the
    /// result never accumulates float drift.
    func resized(handle: Handle, to p: CGPoint) -> DrawObject {
        var copy = self
        switch kind {
        case .rectangle(let rect, let radius):
            copy.kind = .rectangle(rect: resizedRect(rect, handle: handle, to: p),
                                   cornerRadius: radius)
        case .ellipse(let rect):
            copy.kind = .ellipse(rect: resizedRect(rect, handle: handle, to: p))
        case .polygon(let rect, let sides, let ratio):
            copy.kind = .polygon(rect: resizedRect(rect, handle: handle, to: p),
                                 sides: sides, starInnerRatio: ratio)
        case .image(var payload):
            payload.rect = resizedRect(payload.rect, handle: handle, to: p)
            copy.kind = .image(payload)
        case .filter(var payload):
            payload.region = resizedRect(payload.region, handle: handle, to: p)
            copy.kind = .filter(payload)
        case .line(let s, let e, let c):
            switch handle {
            case .start: copy.kind = .line(start: p, end: e, control: c)
            case .end: copy.kind = .line(start: s, end: p, control: c)
            default: break
            }
        case .arrow(var payload):
            switch handle {
            case .start: payload.start = p
            case .end: payload.end = p
            default: break
            }
            copy.kind = .arrow(payload)
        case .text(var payload):
            // Manual resize switches an auto-sized box to fixed (Figma's model).
            let box = resizedRect(bounds, handle: handle, to: p)
            payload.origin = box.origin
            payload.boxSize = box.size
            payload.resize = .fixed
            copy.kind = .text(payload)
        case .polyline, .stroke, .unknown:
            break
        }
        return copy
    }

    /// Resize a (possibly rotated) rect by dragging `handle` to world point `p`,
    /// keeping the opposite corner fixed IN WORLD SPACE. Reduces to the plain
    /// axis-aligned resize when rotation == 0.
    private func resizedRect(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        guard isRotatable, rotation != 0 else { return rect.movingCorner(handle, to: p) }
        let center = rect.center
        let fixedWorld = rect.oppositeCorner(handle).rotated(around: center, by: rotation)
        let newCenter = CGPoint(x: (fixedWorld.x + p.x) / 2, y: (fixedWorld.y + p.y) / 2)
        return CGRect(dragFrom: fixedWorld.rotated(around: newCenter, by: -rotation),
                      to: p.rotated(around: newCenter, by: -rotation))
    }
}
