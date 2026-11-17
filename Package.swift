// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tidemark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tidemark", targets: ["Tidemark"]),
    ],
    dependencies: [
        // macOS Genie warp for the hover card (MIT). Pinned for reproducible builds.
        .package(url: "https://github.com/usagimaru/GenieWarpMesh.git", exact: "1.0.1"),
    ],
    targets: [
        .target(name: "TidemarkCore"),
        .executableTarget(
            name: "Tidemark",
            dependencies: [
                "TidemarkCore",
                .product(name: "GenieWarpMesh", package: "GenieWarpMesh"),
            ],
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
