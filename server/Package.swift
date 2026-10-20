// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TrainTimesServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TrainTimesServer", targets: ["TrainTimesServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "7.1.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        // stations.json and equipment.json, copies of ../ios/Shared's that
        // tools/make_stations.py writes (a symlinked resource is bundled as the
        // link, which doesn't resolve from the bundle). A target of their own,
        // so TrainCore can stand in for `Bundle` (see Shims.swift).
        .target(
            name: "TrainResources",
            resources: [.copy("Resources/stations.json"), .copy("Resources/equipment.json")]
        ),
        // The app's own feed code (Shared/, symlinked from ../ios/Shared), and
        // the server's logic, which needs its internal types. SQLite is the
        // system's libsqlite3 (`import SQLite3`), a module only macOS's SDK has.
        .target(
            name: "TrainCore",
            dependencies: [
                "TrainResources",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .executableTarget(
            name: "TrainTimesServer",
            dependencies: ["TrainCore"]
        ),
        .testTarget(
            name: "TrainCoreTests",
            dependencies: [
                "TrainCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
