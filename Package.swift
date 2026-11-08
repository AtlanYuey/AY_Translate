// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScreenTranslationCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ScreenTranslationCore", targets: ["ScreenTranslationCore"])],
    targets: [
        .target(name: "ScreenTranslationCore", path: "ScreenTranslate/Core", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ScreenTranslationCoreTests", dependencies: ["ScreenTranslationCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
