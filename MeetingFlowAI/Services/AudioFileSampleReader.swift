@preconcurrency import AVFoundation
import Foundation

/// ユーザーが選択した既存音声を、録音時と同じ音声認識処理へ渡せる単位で
/// 順次読み込みます。音声全体をメモリへ載せず、元ファイルも変更しません。
struct AudioFileSampleReader: Sendable {
  func samples(
    from url: URL
  ) -> AsyncThrowingStream<AudioSample, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          let audioFile = try AVAudioFile(forReading: url)
          let frameCapacity: AVAudioFrameCount = 4_096

          while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            guard
              let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCapacity
              )
            else {
              throw AppError.speech("音声ファイルのバッファを準備できませんでした。")
            }

            try audioFile.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0 else { break }
            guard let sample = AudioSample(copying: buffer, time: nil) else {
              throw AppError.speech("音声ファイルを読み込めませんでした。")
            }

            switch continuation.yield(sample) {
            case .enqueued:
              break
            case .dropped:
              throw AppError.speech("音声ファイルの処理が追いつきませんでした。")
            case .terminated:
              throw CancellationError()
            @unknown default:
              throw AppError.speech("音声ファイルの処理を継続できませんでした。")
            }
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
