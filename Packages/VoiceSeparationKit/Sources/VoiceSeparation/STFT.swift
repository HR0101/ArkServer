import Foundation

/// 短時間フーリエ変換の結果。`frames` 個の時間枠それぞれに、0 Hz からナイキスト周波数までの `bins` 個の複素数を持つ。
struct Spectrogram {
  let frames: Int
  let bins: Int
  var real: [Float]
  var imag: [Float]

  init(frames: Int, bins: Int) {
    self.frames = frames
    self.bins = bins
    real = [Float](repeating: 0, count: frames * bins)
    imag = [Float](repeating: 0, count: frames * bins)
  }

  /// 振幅（複素数の絶対値）。
  func magnitudes() -> [Float] {
    var result = [Float](repeating: 0, count: real.count)
    for index in 0..<result.count {
      result[index] = (real[index] * real[index] + imag[index] * imag[index]).squareRoot()
    }
    return result
  }
}

/// 窓をずらしながら FFT し、逆変換で元の波形に戻せる（ハン窓、重ね合わせ加算）。
///
/// 時間枠 `t` の中心は `t * hop` サンプル目。先頭と末尾も窓に覆われるよう、前後に半枠ぶんはみ出して並べる。
final class STFT {
  let fftSize: Int
  let hop: Int
  let bins: Int
  private let plan: FFTPlan
  private let window: [Float]

  init(fftSize: Int, hop: Int) {
    precondition(hop > 0 && hop <= fftSize / 2, "hop は窓の半分以下にする")
    self.fftSize = fftSize
    self.hop = hop
    bins = fftSize / 2 + 1
    plan = FFTPlan(size: fftSize)
    window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
  }

  func frameCount(forLength length: Int) -> Int {
    length <= 0 ? 0 : (length + hop - 1) / hop + 1
  }

  /// 時間枠 `frame` の中心の時刻（秒）。
  func centerTime(ofFrame frame: Int, sampleRate: Double) -> Double {
    Double(frame * hop) / sampleRate
  }

  func analyze(_ samples: [Float]) -> Spectrogram {
    let frames = frameCount(forLength: samples.count)
    var spectrogram = Spectrogram(frames: frames, bins: bins)
    var real = [Float](repeating: 0, count: fftSize)
    var imag = [Float](repeating: 0, count: fftSize)
    for frame in 0..<frames {
      let start = frame * hop - fftSize / 2
      for index in 0..<fftSize {
        let source = start + index
        real[index] = (source >= 0 && source < samples.count) ? samples[source] * window[index] : 0
        imag[index] = 0
      }
      plan.transform(real: &real, imag: &imag, inverse: false)
      let base = frame * bins
      for bin in 0..<bins {
        spectrogram.real[base + bin] = real[bin]
        spectrogram.imag[base + bin] = imag[bin]
      }
    }
    return spectrogram
  }

  func synthesize(_ spectrogram: Spectrogram, length: Int) -> [Float] {
    var output = [Float](repeating: 0, count: length)
    var weight = [Float](repeating: 0, count: length)
    var real = [Float](repeating: 0, count: fftSize)
    var imag = [Float](repeating: 0, count: fftSize)
    for frame in 0..<spectrogram.frames {
      let base = frame * bins
      for bin in 0..<bins {
        real[bin] = spectrogram.real[base + bin]
        imag[bin] = spectrogram.imag[base + bin]
      }
      // 実数の波形に戻るよう、負の周波数側は共役にする。
      imag[0] = 0
      imag[bins - 1] = 0
      for bin in 1..<(bins - 1) {
        real[fftSize - bin] = real[bin]
        imag[fftSize - bin] = -imag[bin]
      }
      plan.transform(real: &real, imag: &imag, inverse: true)
      let start = frame * hop - fftSize / 2
      for index in 0..<fftSize {
        let target = start + index
        guard target >= 0 && target < length else { continue }
        output[target] += real[index] * window[index]
        weight[target] += window[index] * window[index]
      }
    }
    for index in 0..<length { output[index] /= max(weight[index], 1e-3) }
    return output
  }
}
