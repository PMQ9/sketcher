// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sketcher",
    platforms: [.macOS(.v15)],
    targets: [
        // NOTE: deliberately NOT `.defaultIsolation(MainActor.self)`.
        //
        // The reference project uses it, but there almost everything is UI. Here
        // the pure-data layer (Model, Rendering, Persistence, Raster) dominates
        // and MUST be callable off the main actor — flood fill, magic wand,
        // CIFilter application, PNG encode, and autosave all block the UI
        // otherwise. Defaulting to MainActor would isolate every `Codable`
        // conformance on those value types and invert the annotation burden
        // onto the majority of the code.
        //
        // Instead: data types are nonisolated by default, and the UI layer
        // (ViewModel, Views, Input, App, Windows, Document) is explicitly
        // `@MainActor`.
        .executableTarget(
            name: "Sketcher",
            path: "Sources/Sketcher",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SketcherTests",
            dependencies: ["Sketcher"],
            path: "Tests/SketcherTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
