// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlexaRemoteProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "alexa-remote-probe",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
