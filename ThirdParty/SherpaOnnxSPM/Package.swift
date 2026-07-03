// swift-tools-version: 5.9
import PackageDescription

// Local repackaging of https://github.com/willwade/sherpa-onnx-spm (v1.13.2).
// Binaries/ is git-ignored; run scripts/setup-sherpa-onnx.sh once to populate it.
let package = Package(
    name: "SherpaOnnx",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SherpaOnnx", targets: ["SherpaOnnx"]),
    ],
    targets: [
        .binaryTarget(name: "sherpa-onnx", path: "Binaries/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Binaries/onnxruntime.xcframework"),
        .target(
            name: "SherpaOnnx",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            path: "Sources/SherpaOnnx",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
