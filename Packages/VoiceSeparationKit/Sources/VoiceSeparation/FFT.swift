import Foundation

/// 2 のべき乗の長さの複素 FFT（基数 2、その場で計算）。
/// Accelerate に頼らず Swift だけで書いてあるので、どの環境でも同じ結果になる。
final class FFTPlan {
  let size: Int
  private let cosines: [Float]
  private let sines: [Float]
  private let reversed: [Int32]

  init(size: Int) {
    precondition(size >= 2 && size & (size - 1) == 0, "FFT の長さは 2 のべき乗にする")
    self.size = size
    var cosines = [Float](repeating: 0, count: size / 2)
    var sines = [Float](repeating: 0, count: size / 2)
    for index in 0..<size / 2 {
      let angle = -2 * Double.pi * Double(index) / Double(size)
      cosines[index] = Float(cos(angle))
      sines[index] = Float(sin(angle))
    }
    self.cosines = cosines
    self.sines = sines

    let bits = size.trailingZeroBitCount
    var reversed = [Int32](repeating: 0, count: size)
    for index in 0..<size {
      var value = index
      var result = 0
      for _ in 0..<bits {
        result = (result << 1) | (value & 1)
        value >>= 1
      }
      reversed[index] = Int32(result)
    }
    self.reversed = reversed
  }

  /// `real`/`imag` を FFT する。`inverse` なら逆変換で、結果を長さで割って元の大きさに戻す。
  func transform(real: inout [Float], imag: inout [Float], inverse: Bool) {
    precondition(real.count == size && imag.count == size)
    real.withUnsafeMutableBufferPointer { re in
      imag.withUnsafeMutableBufferPointer { im in
        cosines.withUnsafeBufferPointer { cosines in
          sines.withUnsafeBufferPointer { sines in
            reversed.withUnsafeBufferPointer { reversed in
              Self.run(re: re, im: im, cosines: cosines, sines: sines, reversed: reversed, size: size, inverse: inverse)
            }
          }
        }
      }
    }
  }

  private static func run(
    re: UnsafeMutableBufferPointer<Float>,
    im: UnsafeMutableBufferPointer<Float>,
    cosines: UnsafeBufferPointer<Float>,
    sines: UnsafeBufferPointer<Float>,
    reversed: UnsafeBufferPointer<Int32>,
    size: Int,
    inverse: Bool
  ) {
    for index in 0..<size {
      let other = Int(reversed[index])
      if other > index {
        let r = re[index]; re[index] = re[other]; re[other] = r
        let i = im[index]; im[index] = im[other]; im[other] = i
      }
    }
    let direction: Float = inverse ? -1 : 1
    var length = 2
    while length <= size {
      let half = length / 2
      let step = size / length
      var start = 0
      while start < size {
        for offset in 0..<half {
          let wr = cosines[offset * step]
          let wi = direction * sines[offset * step]
          let upper = start + offset
          let lower = upper + half
          let tr = re[lower] * wr - im[lower] * wi
          let ti = re[lower] * wi + im[lower] * wr
          re[lower] = re[upper] - tr
          im[lower] = im[upper] - ti
          re[upper] += tr
          im[upper] += ti
        }
        start += length
      }
      length <<= 1
    }
    if inverse {
      let scale = 1 / Float(size)
      for index in 0..<size { re[index] *= scale; im[index] *= scale }
    }
  }
}
