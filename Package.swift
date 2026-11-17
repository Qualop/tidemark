// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tidemark",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Tidemark", targets: ["Tidemark"]),
    ],
    targets: [
        .target(name: "TidemarkCore"),
        .executableTarget(
            name: "Tidemark",
            dependencies: ["TidemarkCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "TidemarkChecks", dependencies: ["TidemarkCore"], path: "Tests/TidemarkChecks"),
    ]
)
