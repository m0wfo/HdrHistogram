// swift-tools-version:5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HdrHistogram",
    products: [
        .library(
            name: "HdrHistogram",
            targets: ["HdrHistogram"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "HdrHistogram",
            dependencies: []),
        .testTarget(
            name: "HdrHistogramTests",
            dependencies: ["HdrHistogram"]),
    ]
)
