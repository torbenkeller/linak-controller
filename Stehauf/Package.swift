// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stehauf",
    platforms: [.macOS(.v14)],
    targets: [
        // Reine Logik ohne macOS-Abhängigkeiten: Protokoll, Erkennung, Regelwerk.
        .target(name: "StehaufCore"),
        // Die eigentliche App: Bluetooth, Sensoren, Oberfläche.
        .executableTarget(name: "Stehauf", dependencies: ["StehaufCore"]),
        .testTarget(name: "StehaufCoreTests", dependencies: ["StehaufCore"]),
    ]
)
