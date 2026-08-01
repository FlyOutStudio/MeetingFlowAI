@preconcurrency import AVFoundation
import Foundation

/// AVAudioEngine のコールバック外でも安全に扱える、所有権を持つ音声バッファです。
///
/// `AVAudioPCMBuffer` 自体は Sendable ではありませんが、この型は入力バッファを
/// ディープコピーし、生成後は変更しないため actor 間で受け渡せます。
struct AudioSample: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  let time: AVAudioTime?

  init?(copying source: AVAudioPCMBuffer, time: AVAudioTime?) {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: source.format,
        frameCapacity: source.frameLength
      )
    else {
      return nil
    }

    copy.frameLength = source.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
      source.mutableAudioBufferList
    )
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(
      copy.mutableAudioBufferList
    )

    guard sourceBuffers.count == destinationBuffers.count else {
      return nil
    }

    for index in sourceBuffers.indices {
      let sourceBuffer = sourceBuffers[index]
      var destinationBuffer = destinationBuffers[index]
      guard
        let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffer.mData
      else {
        return nil
      }

      memcpy(
        destinationData,
        sourceData,
        Int(sourceBuffer.mDataByteSize)
      )
      destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
      destinationBuffers[index] = destinationBuffer
    }

    buffer = copy
    self.time = time
  }
}

struct RecordingSession: Sendable {
  let fileURL: URL
  let samples: AsyncThrowingStream<AudioSample, Error>
}
