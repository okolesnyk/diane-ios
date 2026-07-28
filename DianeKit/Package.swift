// swift-tools-version: 6.0
import PackageDescription

// DianeKit — the generated Diane API client (swift-openapi-generator build
// plugin over the vendored Sources/DianeKit/openapi.yaml) plus the
// hand-written glue the app needs around it: bearer-token middleware,
// Keychain-backed session storage, and the SSE stream client.
//
// macOS is in platforms only so `swift test` runs on the host without a
// simulator — keep UIKit out of this package.
let package = Package(
    name: "DianeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DianeKit", targets: ["DianeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DianeKit",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "DianeKitTests",
            dependencies: ["DianeKit"]
        ),
    ]
)
