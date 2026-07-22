import CoreImage

/// One shared `CIContext` for every filter in the app.
///
/// A `CIContext` is expensive to build and cheap to reuse; making one per filter
/// application is the classic Core Image performance mistake. Working in a linear
/// space keeps a Gaussian blur from darkening at the edges the way an sRGB-space
/// blur does; the output color space is pinned per call at `createCGImage`.
enum CIContextProvider {
    static let shared = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any
    ])
}
