// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MeetingFlowAI",
  platforms: [
    .macOS("15.0")
  ],
  products: [
    .executable(
      name: "MeetingFlowAI",
      targets: ["MeetingFlowAI"]
    )
  ],
  targets: [
    .executableTarget(
      name: "MeetingFlowAI",
      path: "MeetingFlowAI"
    ),
    .testTarget(
      name: "MeetingFlowAITests",
      dependencies: ["MeetingFlowAI"],
      path: "MeetingFlowAITests"
    ),
  ]
)
