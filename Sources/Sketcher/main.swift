import AppKit

// Headless modes exit BEFORE NSApplication is touched: no window server, no run
// loop, no app bundle. That ordering is what makes the pixel-verification
// harness runnable from a bare binary in CI — and it must stay first.
if TestRenderMode.shouldHandle(CommandLine.arguments) {
    exit(TestRenderMode.run(arguments: CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Instantiating the shared controller registers sketcher's document types
// before the first untitled document is created.
_ = NSDocumentController.shared
app.run()
