// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoLab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "photolab", targets: ["photolab"]),
        .executable(name: "PhotoLabApp", targets: ["PhotoLabApp"]),
    ],
    targets: [
        .target(
            name: "PhotoLabCore",
            resources: [.copy("Resources/report.html"), .copy("Resources/studio")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "photolab", dependencies: ["PhotoLabCore"]),
        // The Mac app shell: a window with a WKWebView on the in-process studio server.
        .executableTarget(name: "PhotoLabApp", dependencies: ["PhotoLabCore"]),
    ]
)
