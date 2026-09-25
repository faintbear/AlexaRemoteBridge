// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlexaRemoteProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"])]
        ),
        .executableTarget(
            name: "alexa-remote-probe",
            dependencies: ["COpus"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "alexa-gatt-probe",
            linkerSettings: [.linkedFramework("CoreBluetooth")]
        ),
        .executableTarget(
            name: "alexa-event-probe",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics"), .linkedFramework("IOKit")]
        )
    ]
)
