@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import XCTest

@testable import MeetingFlowAI

final class OnlineTimelineAudioMixerTests: XCTestCase {
  func testMixesSystemAndMicrophoneSamplesAtSamePresentationTime() async throws {
    let frameCount = 4_800
    let systemBuffer = try makeBuffer(
      samples: [Float](repeating: 0.25, count: frameCount)
    )
    let microphoneBuffer = try makeBuffer(
      samples: [Float](repeating: 0.5, count: frameCount)
    )
    let fixture = try makeMixerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.fileURL) }

    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .system,
        buffer: systemBuffer,
        presentationTime: CMTime(value: 0, timescale: 48_000)
      )
    )
    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .microphone,
        buffer: microphoneBuffer,
        presentationTime: CMTime(value: 0, timescale: 48_000)
      )
    )
    try await fixture.mixer.finish()

    let output = try await collectSamples(from: fixture.stream)
    XCTAssertEqual(output.count, frameCount)
    assertSamples(output, equalTo: 0.75)
  }

  func testAlignsOffsetMicrophoneSamplesAndPreservesLeadingSystemAudio()
    async throws
  {
    let systemFrameCount = 4_800
    let microphoneStartFrame: Int64 = 2_400
    let microphoneFrameCount = 2_400
    let systemBuffer = try makeBuffer(
      samples: [Float](repeating: 0.25, count: systemFrameCount)
    )
    let microphoneBuffer = try makeBuffer(
      samples: [Float](repeating: 0.5, count: microphoneFrameCount)
    )
    let fixture = try makeMixerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.fileURL) }

    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .system,
        buffer: systemBuffer,
        presentationTime: CMTime(value: 0, timescale: 48_000)
      )
    )
    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .microphone,
        buffer: microphoneBuffer,
        presentationTime: CMTime(
          value: microphoneStartFrame,
          timescale: 48_000
        )
      )
    )
    try await fixture.mixer.finish()

    let output = try await collectSamples(from: fixture.stream)
    XCTAssertEqual(output.count, systemFrameCount)
    assertSamples(
      Array(output[..<Int(microphoneStartFrame)]),
      equalTo: 0.25
    )
    assertSamples(
      Array(output[Int(microphoneStartFrame)...]),
      equalTo: 0.75
    )
  }

  func testClampsMixedSamplesToPCMRange() async throws {
    let frameCount = 1_024
    let systemBuffer = try makeBuffer(
      samples: [Float](repeating: 0.75, count: frameCount)
    )
    let microphoneBuffer = try makeBuffer(
      samples: [Float](repeating: 0.75, count: frameCount)
    )
    let fixture = try makeMixerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.fileURL) }

    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .system,
        buffer: systemBuffer,
        presentationTime: .zero
      )
    )
    try await fixture.mixer.ingest(
      CapturedAudioSample(
        source: .microphone,
        buffer: microphoneBuffer,
        presentationTime: .zero
      )
    )
    try await fixture.mixer.finish()

    let output = try await collectSamples(from: fixture.stream)
    XCTAssertEqual(output.count, frameCount)
    assertSamples(output, equalTo: 1)
  }

  private func makeMixerFixture() throws -> MixerFixture {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("meeting-flow-ai-mixer-\(UUID().uuidString)")
      .appendingPathExtension("caf")
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: AudioSample.self,
      throwing: Error.self
    )
    let mixer = try OnlineTimelineAudioMixer(
      fileURL: fileURL,
      continuation: continuation
    )
    return MixerFixture(fileURL: fileURL, mixer: mixer, stream: stream)
  }

  private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: OnlineTimelineAudioMixer.sampleRate,
        channels: 1,
        interleaved: false
      )
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      )
    )
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      channel.update(from: baseAddress, count: samples.count)
    }
    return buffer
  }

  private func collectSamples(
    from stream: AsyncThrowingStream<AudioSample, Error>
  ) async throws -> [Float] {
    var result: [Float] = []
    for try await sample in stream {
      let frameCount = Int(sample.buffer.frameLength)
      let channel = try XCTUnwrap(sample.buffer.floatChannelData?[0])
      result.append(
        contentsOf: UnsafeBufferPointer(start: channel, count: frameCount)
      )
    }
    return result
  }

  private func assertSamples(
    _ samples: [Float],
    equalTo expected: Float,
    accuracy: Float = 0.000_1,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard
      let mismatch = samples.firstIndex(
        where: { abs($0 - expected) > accuracy }
      )
    else { return }

    XCTFail(
      "sample[\(mismatch)] は \(samples[mismatch]) でした。期待値: \(expected)",
      file: file,
      line: line
    )
  }
}

private struct MixerFixture {
  let fileURL: URL
  let mixer: OnlineTimelineAudioMixer
  let stream: AsyncThrowingStream<AudioSample, Error>
}
