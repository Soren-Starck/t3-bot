// swift-tools-version:5.9
// The part of the app that talks to T3 Code directly, as a package so it builds and is tested on a Mac
// (`swift test` in ios/Direct) without a simulator. The app and its extensions compile the same files
// (ios/project.yml lists Direct/Sources/T3Direct in each target), so there is no `import T3Direct` there.
import PackageDescription

let package = Package(
    name: "T3Direct",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "T3Direct", path: "Sources/T3Direct"),
        .testTarget(name: "T3DirectTests", dependencies: ["T3Direct"], path: "Tests/T3DirectTests", resources: [.copy("Fixtures")]),
    ]
)
