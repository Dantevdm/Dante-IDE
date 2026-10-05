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
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0"),
        // Tree-sitter and its grammars. The 0.23 grammar tags list scanner.c explicitly;
        // later ones look for it relative to the working directory and drop it as dependencies.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    ],
    targets: [
        // Models with no UI: themes, workspace, documents, lifecycle, tasks, Claude.
        .target(name: "DanteKit", dependencies: [.product(name: "Yams", package: "Yams")]),
        // The TextKit 2 code editor and syntax highlighting.
        .target(
            name: "DanteEditor",
            dependencies: [
                "DanteKit",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            ]
        ),
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
