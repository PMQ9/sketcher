import AppKit
import SwiftUI

/// The drawing surface: workspace backdrop, artboard, document content, and
/// interaction chrome — with all input handled by the AppKit overlay on top.
///
/// Document content goes through `SceneRenderer` and nothing else. Chrome is
/// drawn here and ONLY here, so it can never leak into an export.
struct CanvasView: View {
    @Bindable var viewModel: EditorViewModel

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

                CanvasEventLayer(viewModel: viewModel)
            }
            .onAppear { viewModel.layoutIfNeeded(viewSize: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.viewSize = newSize
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

        // Marquee rubber band.
        if case .marquee(let anchor, let current) = viewModel.interaction {
            let rect = transform.toView(CGRect(dragFrom: anchor, to: current))
            context.fill(Path(rect), with: .color(accent.opacity(0.12)))
            context.stroke(Path(rect), with: .color(accent), lineWidth: 1)
        }

        // Selected object outlines. Handles arrive with the select tool in M3.
        for id in viewModel.selection.objectIDs {
            guard let object = viewModel.scene.object(with: id) else { continue }
            let corners = object.outlineCorners.map(transform.toView)
            guard corners.count == 4 else { continue }
            var path = Path()
            path.move(to: corners[0])
            for corner in corners.dropFirst() { path.addLine(to: corner) }
            path.closeSubpath()
            context.stroke(path, with: .color(accent), lineWidth: 1.5)
        }
    }
}
