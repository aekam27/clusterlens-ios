// swift-tools-version: 5.9
import PackageDescription

// Offline policy/DNS-parser checks; this does not build or replace the iOS app.
let package = Package(
    name: "ClusterLensFoundation",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClusterLensCore",
            path: "ios/ClusterLens/Core",
            exclude: ["AppModel.swift", "MongoDirectClient.swift", "MongoBridge.c", "MongoBridge.h", "KeychainService.swift", "Theme.swift"],
            sources: ["JSONValue.swift", "Models.swift", "MongoConnectionString.swift", "FindQuery.swift", "DataExport.swift", "FindPresetStore.swift"]
        ),
        .testTarget(name: "ClusterLensCoreTests", dependencies: ["ClusterLensCore"], path: "ios/ClusterLensTests")
    ]
)
