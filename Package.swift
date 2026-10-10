// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiteTranslation",
    platforms: [.macOS(.v26)],
    targets: [
        // Screen text recognition, context selection and the translation backends. No UI.
        .target(name: "LiteTranslationCore"),
        // The menu bar app.
        .executableTarget(name: "LiteTranslation", dependencies: ["LiteTranslationCore"]),
    ],
    swiftLanguageModes: [.v5]
)
