import AppKit

/// The menu bar, built from the `Command` enum so there is exactly one list of
/// what the app can do. macOS's Help-menu search then indexes it for free,
/// which is a command palette nobody had to build.
@MainActor
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu: appMenu(appName: appName), title: appName)
        main.addItem(submenu: fileMenu(), title: "File")
        main.addItem(submenu: editMenu(), title: "Edit")
        main.addItem(submenu: arrangeMenu(), title: "Arrange")
        main.addItem(submenu: toolsMenu(), title: "Tools")
        main.addItem(submenu: canvasMenu(), title: "Canvas")
        main.addItem(submenu: colorMenu(), title: "Color")
        main.addItem(submenu: formatMenu(), title: "Format")
        main.addItem(submenu: viewMenu(), title: "View")
        main.addItem(submenu: windowMenu(), title: "Window")
        return main
    }

    // MARK: - Menus

    private static func appMenu(appName: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New",
                     action: #selector(NSDocumentController.newDocument(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Save…",
                     action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = menu.addItem(withTitle: "Save As…",
                                  action: #selector(NSDocument.saveAs(_:)),
                                  keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Revert to Saved",
                     action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addCommand(.exportImage)
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Custom selectors, NOT the standard undo:/redo: — see
        // EditorWindowController for why the standard ones are dead here.
        menu.addCommand(.undo, action: #selector(EditorWindowController.performUndo(_:)))
        menu.addCommand(.redo, action: #selector(EditorWindowController.performRedo(_:)))
        menu.addItem(.separator())
        menu.addCommand(.cut)
        menu.addCommand(.copy)
        menu.addCommand(.paste)
        menu.addCommand(.pasteInPlace)
        menu.addCommand(.duplicate)
        menu.addItem(.separator())
        menu.addCommand(.selectAll)
        menu.addCommand(.deselect)
        menu.addCommand(.delete)
        return menu
    }

    private static func arrangeMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrange")
        menu.addCommand(.bringForward)
        menu.addCommand(.sendBackward)
        menu.addCommand(.bringToFront)
        menu.addCommand(.sendToBack)
        menu.addItem(.separator())
        menu.addCommand(.group)
        menu.addCommand(.ungroup)
        menu.addItem(.separator())
        let align = NSMenu(title: "Align")
        for command in [Command.alignLeft, .alignHCenter, .alignRight,
                        .alignTop, .alignVCenter, .alignBottom] {
            align.addCommand(command)
        }
        align.addItem(.separator())
        align.addCommand(.distributeHorizontally)
        align.addCommand(.distributeVertically)
        menu.addItem(submenu: align, title: "Align")
        menu.addItem(.separator())
        menu.addCommand(.toggleLock)
        menu.addCommand(.toggleHidden)
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        let tools: [(Command, Tool)] = [
            (.toolSelect, .select), (.toolBrush, .brush), (.toolEraser, .eraser),
            (.toolRectangle, .rectangle), (.toolEllipse, .ellipse),
            (.toolLine, .line), (.toolArrow, .arrow), (.toolPolygon, .polygon),
            (.toolRedact, .redact), (.toolEyedropper, .eyedropper),
            (.toolHand, .hand), (.toolZoom, .zoom)
        ]
        for (command, tool) in tools {
            let item = menu.addCommand(command)
            // Shown as a hint only. The actual binding lives in CanvasEventView,
            // because a menu key equivalent would fire while typing in a field.
            if let key = KeyMap.toolKeys.first(where: { $0.value == tool })?.key {
                item.title = "\(command.title)  (\(key.uppercased()))"
            }
        }
        menu.addItem(.separator())
        menu.addCommand(.brushSizeDown)
        menu.addCommand(.brushSizeUp)
        return menu
    }

    private static func canvasMenu() -> NSMenu {
        let menu = NSMenu(title: "Canvas")
        menu.addCommand(.backgroundLight)
        menu.addCommand(.backgroundDark)
        menu.addCommand(.backgroundTransparent)
        menu.addItem(.separator())
        menu.addCommand(.toggleCanvasMode)
        return menu
    }

    private static func colorMenu() -> NSMenu {
        let menu = NSMenu(title: "Color")
        // Single-key bindings live in CanvasEventView (they must not fire while a
        // text field owns the keyboard), so these carry the hint in the title.
        let swap = menu.addCommand(.swapColors); swap.title = "Swap Colors  (X)"
        let reset = menu.addCommand(.resetColors); reset.title = "Reset to Black & White  (D)"
        menu.addItem(.separator())
        let eyedropper = menu.addCommand(.toolEyedropper); eyedropper.title = "Eyedropper  (I)"
        let screen = menu.addCommand(.screenEyedropper)
        screen.title = "Screen Eyedropper\u{2026}  (\u{21E7}I)"
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addCommand(.fontPanel)
        menu.addItem(.separator())
        menu.addCommand(.textBold)
        menu.addCommand(.textItalic)
        menu.addCommand(.textUnderline)
        menu.addItem(.separator())
        let align = NSMenu(title: "Text Alignment")
        align.addCommand(.textAlignLeft)
        align.addCommand(.textAlignCenter)
        align.addCommand(.textAlignRight)
        menu.addItem(submenu: align, title: "Text Alignment")
        menu.addItem(.separator())
        menu.addCommand(.textPlate)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addCommand(.zoomIn)
        menu.addCommand(.zoomOut)
        menu.addCommand(.zoomActualSize)
        menu.addCommand(.zoomToFit)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

// MARK: - Command <-> NSMenuItem

extension NSMenuItem {
    /// The `Command` this item performs, if any.
    ///
    /// Stored in `representedObject` rather than an associated object: it is
    /// exactly the field AppKit provides for this, and it avoids a mutable
    /// global key that Swift 6 rejects as unsafe shared state.
    var sketcherCommand: Command? {
        get { representedObject as? Command }
        set { representedObject = newValue }
    }
}

extension NSMenu {
    @discardableResult
    func addCommand(_ command: Command, action: Selector? = nil) -> NSMenuItem {
        let selector = action ?? #selector(EditorWindowController.performSketcherCommand(_:))
        let item = NSMenuItem(title: command.title, action: selector, keyEquivalent: "")
        if let shortcut = command.keyEquivalent {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(shortcut.modifiers)
        }
        item.sketcherCommand = command
        addItem(item)
        return item
    }

    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension NSEvent.ModifierFlags {
    init(_ modifiers: CommandModifiers) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        self = flags
    }
}
