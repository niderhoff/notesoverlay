// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotesOverlay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotesOverlay",
            path: "Sources/NotesOverlay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
