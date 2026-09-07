// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "flappy",
    products: [
        .executable(
            name: "Game",
            targets: ["Game"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Game",
            dependencies: [
                "Asm",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .target(name: "Asm"),
    ]
)
