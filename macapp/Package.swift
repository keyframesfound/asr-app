// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LessonTranscriber",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LessonKit", targets: ["LessonKit"]),
        .executable(name: "LessonTranscriber", targets: ["LessonTranscriber"]),
        .executable(name: "ltctl", targets: ["ltctl"]),
    ],
    dependencies: [
        // SenseVoice-Small + Silero VAD on the Apple Neural Engine (CoreML).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "LessonKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/LessonKit"
        ),
        .executableTarget(
            name: "LessonTranscriber",
            dependencies: ["LessonKit"],
            path: "Sources/LessonTranscriber"
        ),
        .executableTarget(
            name: "ltctl",
            dependencies: ["LessonKit"],
            path: "Sources/ltctl"
        ),
    ]
)
