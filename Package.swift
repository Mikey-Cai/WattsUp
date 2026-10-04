// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WattsUp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WattsUp", targets: ["WattsUp"]),
               .executable(name: "WattsUpWidget", targets: ["WattsUpWidget"])],
    targets: [
        .target(name: "WattsUpCore"),
        .target(name: "CSensors", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "WattsUpHardware", dependencies: ["WattsUpCore", "CSensors"]),
        .executableTarget(name: "WattsUp", dependencies: ["WattsUpCore", "WattsUpHardware"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("WidgetKit")]),
        // Desktop widget extension binary; build.sh wraps it into
        // WattsUp.app/Contents/PlugIns/WattsUpWidget.appex and signs it sandboxed.
        .executableTarget(name: "WattsUpWidget", dependencies: ["WattsUpCore"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("WidgetKit"),
                                           .unsafeFlags(["-Xlinker", "-application_extension"])]),
        .testTarget(name: "WattsUpCoreTests", dependencies: ["WattsUpCore"])
    ],
    swiftLanguageVersions: [.v5]
)
