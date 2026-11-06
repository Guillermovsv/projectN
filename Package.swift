// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ProjectN",
    // macOS 26: the built-in NVoice dictation uses Apple's on-device DictationTranscriber.
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        // NVoice: turns Objective-C exceptions from AVAudioEngine into Swift errors.
        .target(name: "ObjCSupport", path: "Sources/ObjCSupport"),
        .executableTarget(
            name: "ProjectN",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "ObjCSupport"],
            path: "Sources/ProjectN",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .testTarget(
            name: "ProjectNTests",
            dependencies: ["ProjectN"],
            path: "Tests/ProjectNTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
