// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dante",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dante", targets: ["DanteApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Models with no UI: themes, workspace, documents, lifecycle.
        .target(name: "DanteKit"),
        // The TextKit 2 code editor and syntax highlighting.
        .target(name: "DanteEditor", dependencies: ["DanteKit"]),
        // The SwiftUI app shell.
        .executableTarget(
            name: "DanteApp",
            dependencies: [
                "DanteKit",
                "DanteEditor",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "DanteKitTests", dependencies: ["DanteKit"]),
        .testTarget(name: "DanteEditorTests", dependencies: ["DanteEditor"]),
    ]
)
