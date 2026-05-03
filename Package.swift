// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalFTPServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FTPServerCore", targets: ["FTPServerCore"]),
        .executable(name: "LocalFTP", targets: ["LocalFTPApp"])
    ],
    targets: [
        .target(name: "FTPServerCore"),
        .executableTarget(
            name: "LocalFTPApp",
            dependencies: ["FTPServerCore"],
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "FTPServerCoreTests",
            dependencies: ["FTPServerCore"]
        )
    ]
)
