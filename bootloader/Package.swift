// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "bootloader",
    products: [
        .executable(
            name: "Boot",
            targets: ["Boot"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Boot",
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
