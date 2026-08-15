// swift-tools-version: 6.0
// menubar-drawer — メニューバーのアイコン1つから、全ステータスアイテムを下に展開して操作する
import PackageDescription

let package = Package(
    name: "MenuBarDrawer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MenuBarDrawer",
            path: "Sources/MenuBarDrawer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
