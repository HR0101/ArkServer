// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "VoiceSeparationKit",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    // 人の声と、それ以外の音（効果音・環境音）を分ける。信号処理だけで動き、外部依存はない。
    .library(name: "VoiceSeparation", targets: ["VoiceSeparation"]),
    // 「いつ声があるか」を Apple 標準の音分類（SoundAnalysis）で調べ、分離の手がかりにする。
    .library(name: "VoiceSeparationSoundAnalysis", targets: ["VoiceSeparationSoundAnalysis"]),
  ],
  targets: [
    .target(name: "VoiceSeparation"),
    .target(name: "VoiceSeparationSoundAnalysis", dependencies: ["VoiceSeparation"]),
    .testTarget(
      name: "VoiceSeparationTests",
      dependencies: ["VoiceSeparation", "VoiceSeparationSoundAnalysis"]
    ),
  ]
)
