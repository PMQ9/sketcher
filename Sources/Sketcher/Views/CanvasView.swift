import AppKit
import SwiftUI

/// The drawing surface: workspace backdrop, artboard, document content, and
/// interaction chrome — with all input handled by the AppKit overlay on top.
///
/// Document content goes through `SceneRenderer` and nothing else. Chrome is
/// drawn here and ONLY here, so it can never leak into an export.
struct CanvasView: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                workspaceBackdrop

                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size)
                }
                // SwiftUI coalesces redraws; the id forces a redraw whenever
                // anything the renderer reads has changed.
                .drawingGroup(opaque: false)

                marchingAntsOverlay

                CanvasEventLayer(viewModel: viewModel,
                                 editingTextID: viewModel.editingTextID,
                                 sceneRevision: viewModel.sceneRevision,
                                 transform: viewModel.transform)
            }
            .onAppear { viewModel.layoutIfNeeded(viewSize: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.viewSize = newSize
            }
        }
    }

    /// Marching ants + in-progress region preview, on their own animated layer
    /// so the main content Canvas is not re-run every animation tick. Honors
    /// Reduce Motion (a static dash). Never hit-tests, so input still reaches
    /// the AppKit overlay above it.
    @ViewBuilder private var marchingAntsOverlay: some View {
        if viewModel.showsSelectionOverlay {
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
                Canvas(rendersAsynchronously: false) { context, _ in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    drawSelectionRegion(in: &context, phase: reduceMotion ? 0 : -CGFloat(seconds * 8))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var workspaceBackdrop: some View {
        Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let transform = viewModel.transform
        let scene = viewModel.scene
        let pageRect = scene.canvas.pageRect
        let pageInView = transform.toView(pageRect)

        drawArtboardChrome(pageInView, scene: scene, in: &context)

        // Document content. Everything below this line is the shared renderer;
        // the context is transformed so 1 unit == 1 canvas pixel, y-down.
        context.drawLayer { layer in
            layer.clip(to: Path(pageInView.insetBy(dx: -0.5, dy: -0.5)))
            layer.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: transform.offset.x, y: transform.offset.y)
                cg.scaleBy(x: transform.scale, y: transform.scale)

                drawCommitted(scene: scene, transform: transform, into: cg)
                drawLive(scene: scene, into: cg)

                cg.restoreGState()
            }
        }

        drawSelectionChrome(in: &context, transform: transform)
    }

    /// Committed content: everything except what is being drawn or dragged
    /// right now.
    ///
    /// At or below 100% this is a single cached blit (~0.34 ms measured,
    /// independent of scene complexity). Above 100% the cache is bypassed and
    /// the scene renders live, clipped to the visible rect — bounded, because
    /// the visible canvas area shrinks as scale grows.
    private func drawCommitted(scene: Scene, transform: CanvasTransform,
                               into cg: CGContext) {
        let excluded = viewModel.liveObjectIDs

        if transform.scale <= RenderCaches.cacheScaleCeiling,
           let cached = viewModel.caches.committedImage(for: scene,
                                                        surfaces: viewModel.surfaces,
                                                        revision: viewModel.sceneRevision,
                                                        excluding: excluded) {
            cg.interpolationQuality = .high
            cg.drawImageYDown(cached, in: scene.canvas.pageRect)
            return
        }

        // Live path. Clip to what is actually visible so off-screen objects
        // cost nothing, and keep pixel art crisp when zoomed well in.
        cg.saveGState()
        if viewModel.viewSize != .zero {
            cg.clip(to: transform.visibleCanvasRect(viewSize: viewModel.viewSize))
        }
        cg.interpolationQuality = transform.scale > 4 ? .none : .high
        SceneRenderer.draw(scene,
                           surfaces: viewModel.surfaces,
                           into: cg,
                           excluding: excluded,
                           clipToPage: scene.canvas.mode.clipsToPage)
        cg.restoreGState()
    }

    /// The in-flight draft (not in the scene yet) plus any objects excluded
    /// from the committed pass because they are being dragged.
    private func drawLive(scene: Scene, into cg: CGContext) {
        if let draft = viewModel.draftObject {
            SceneRenderer.draw(draft, surfaces: viewModel.surfaces, into: cg)
        }
        for id in viewModel.liveObjectIDs {
            if let object = scene.object(with: id) {
                SceneRenderer.draw(object, surfaces: viewModel.surfaces, into: cg)
            }
        }
        // Lifted floating pixels ride above the content under their live
        // transform. This is the SAME draw `compositeFloat` bakes on drop, so
        // the preview and the committed result are identical by construction.
        if let floating = viewModel.selection.floating,
           let image = viewModel.surfaces.image(floating.surface) {
            cg.saveGState()
            cg.concatenate(floating.transform)
            cg.drawImageYDown(image, in: floating.sourceRect)
            cg.restoreGState()
        }
    }

    /// Hairline border plus a drop shadow. Without these a white canvas is
    /// invisible against light chrome and a dark one against dark chrome —
    /// which is exactly the pair of backgrounds this app leads with.
    private func drawArtboardChrome(_ pageInView: CGRect, scene: Scene,
                                    in context: inout GraphicsContext) {
        let page = Path(pageInView)

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 12, y: 4))
            layer.fill(page, with: .color(.black.opacity(0.001)))
        }

        if scene.canvas.background.isTransparent {
            drawCheckerboard(pageInView, in: &context)
        }

        context.stroke(page, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
    }

    /// Transparency checkerboard. Fixed 8pt in VIEW space so it does not scale
    /// with zoom, and drawn here rather than in the renderer so it can never
    /// appear in an exported file.
    private func drawCheckerboard(_ rect: CGRect, in context: inout GraphicsContext) {
        let square: CGFloat = 8
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.fill(Path(rect), with: .color(Color(white: 1.0)))
            var dark = Path()
            var row = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX + (row.isMultiple(of: 2) ? 0 : square)
                while x < rect.maxX {
                    dark.addRect(CGRect(x: x, y: y, width: square, height: square))
                    x += square * 2
                }
                y += square
                row += 1
            }
            layer.fill(dark, with: .color(Color(white: 0.87)))
        }
    }

    private func drawSelectionChrome(in context: inout GraphicsContext,
                                     transform: CanvasTransform) {
        let accent = Color(nsColor: .controlAccentColor)

        // Redaction region preview — the filter draft draws nothing through the
        // renderer, so show a dimmed rect while the region is dragged out.
        if case .filter(let payload)? = viewModel.draftObject?.kind {
            let rect = transform.toView(payload.region)
            context.fill(Path(rect), with: .color(.black.opacity(0.28)))
            context.stroke(Path(rect), with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Text being edited: a faint dashed box so an empty or fixed box is
        // visible while the caret (drawn by the sink) blinks inside it. Selection
        // chrome is naturally absent here — editing clears the selection.
        if let object = viewModel.editingTextObject {
            let rect = transform.toView(object.bounds).insetBy(dx: -1, dy: -1)
            context.stroke(Path(rect), with: .color(accent.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }

        // Marquee rubber band.
        var marqueeing = false
        if case .marquee(let anchor, let current) = viewModel.interaction {
            marqueeing = true
            let rect = transform.toView(CGRect(dragFrom: anchor, to: current))
            context.fill(Path(rect), with: .color(accent.opacity(0.12)))
            context.stroke(Path(rect), with: .color(accent), lineWidth: 1)
        }

        // A thin border on each selected shape (each in its own rotated frame).
        for id in viewModel.selection.objectIDs {
            guard let object = viewModel.scene.object(with: id) else { continue }
            let corners = object.outlineCorners.map(transform.toView)
            guard corners.count == 4 else { continue }
            var path = Path()
            path.move(to: corners[0])
            for corner in corners.dropFirst() { path.addLine(to: corner) }
            path.closeSubpath()
            context.stroke(path, with: .color(accent), lineWidth: 1)
        }

        // The interactive frame: a group bounding box plus resize and rotate
        // handles. Hidden while dragging out a marquee, where the selection is
        // still being assembled.
        if !marqueeing, let frame = viewModel.selectionFrame {
            drawFrame(frame, in: &context, transform: transform)
        }
    }

    /// Pixel-region chrome: the committed selection's marching ants (a lifted
    /// float outlines its transformed rect) plus the in-progress marquee/lasso
    /// preview. Two strokes — white under an animated black dash — so the ants
    /// read on any canvas color. `phase` marches the dash; it is 0 under Reduce
    /// Motion. View space, never through `SceneRenderer`, so it can't export.
    private func drawSelectionRegion(in context: inout GraphicsContext, phase: CGFloat) {
        let transform = viewModel.transform

        var previewPath: Path?
        switch viewModel.interaction {
        case .selectingRegion(let tool, let anchor, let current, _) where tool != .wand:
            let rect = transform.toView(CGRect(dragFrom: anchor, to: current))
            previewPath = viewModel.marqueeEllipse ? Path(ellipseIn: rect) : Path(rect)
        case .selectingLasso(let points, _):
            var path = Path()
            let viewPoints = points.map(transform.toView)
            if let first = viewPoints.first {
                path.move(to: first)
                for point in viewPoints.dropFirst() { path.addLine(to: point) }
            }
            previewPath = path
        default:
            break
        }

        var antsPath = Path()
        for contour in viewModel.antContours() where contour.count >= 2 {
            let viewPoints = contour.map(transform.toView)
            antsPath.move(to: viewPoints[0])
            for point in viewPoints.dropFirst() { antsPath.addLine(to: point) }
            antsPath.closeSubpath()
        }

        for path in [previewPath, antsPath].compactMap({ $0 }) where !path.isEmpty {
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1)
            context.stroke(path, with: .color(.black),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase))
        }
    }

    /// Resize handles (white squares) and the rotate handle (a stalked circle).
    /// Drawn in VIEW space so they stay a constant size at every zoom, and only
    /// here — never through `SceneRenderer` — so they can never reach an export.
    private func drawFrame(_ frame: SelectionFrame, in context: inout GraphicsContext,
                           transform: CanvasTransform) {
        let accent = Color(nsColor: .controlAccentColor)

        // Group bounding box; single-object boxes are already outlined above.
        if frame.style == .group {
            context.stroke(Path(transform.toView(frame.box)),
                           with: .color(accent), lineWidth: 1)
        }

        // Rotate handle: a stalk from the top-edge midpoint to a small circle.
        if let rotate = frame.handles[.rotate], let top = frame.handles[.top] {
            let a = transform.toView(top), b = transform.toView(rotate)
            var stalk = Path()
            stalk.move(to: a)
            stalk.addLine(to: b)
            context.stroke(stalk, with: .color(accent), lineWidth: 1)
            let r: CGFloat = 4.5
            let circle = Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r,
                                                width: r * 2, height: r * 2))
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(accent), lineWidth: 1.5)
        }

        // Resize handles: white squares with an accent border, legible on any
        // canvas color.
        let s: CGFloat = 7
        for (handle, point) in frame.handles where handle != .rotate {
            let v = transform.toView(point)
            let rect = CGRect(x: v.x - s / 2, y: v.y - s / 2, width: s, height: s)
            context.fill(Path(rect), with: .color(.white))
            context.stroke(Path(rect), with: .color(accent), lineWidth: 1.5)
        }
    }
}
