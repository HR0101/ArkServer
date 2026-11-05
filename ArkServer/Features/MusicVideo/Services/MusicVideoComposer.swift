// ArkServer/Features/MusicVideo/Services/MusicVideoComposer.swift

import AVFoundation
import CoreGraphics
import Foundation

/// 完成映像の画面サイズとフレームレート。
nonisolated struct MusicVideoRenderSettings: Equatable, Sendable {
  var width: Int
  var height: Int
  var framesPerSecond: Int

  static let landscapeFullHD = MusicVideoRenderSettings(width: 1920, height: 1080, framesPerSecond: 30)
  static let landscapeHD = MusicVideoRenderSettings(width: 1280, height: 720, framesPerSecond: 30)
  static let portraitFullHD = MusicVideoRenderSettings(width: 1080, height: 1920, framesPerSecond: 30)
  static let portraitHD = MusicVideoRenderSettings(width: 720, height: 1280, framesPerSecond: 30)

  var size: CGSize { CGSize(width: width, height: height) }
}

nonisolated enum MusicVideoComposerError: LocalizedError {
  case emptyPlan
  case missingSource(UUID)
  case noVideoTrack(String)
  case noAudioTrack
  case cannotCreateTrack
  case cannotCreateExporter
  case exportFailed(String)
  case invalidOutput(String)

  var errorDescription: String? {
    switch self {
    case .emptyPlan:
      return "カット割りが空です．"
    case .missingSource:
      return "素材動画のファイルが見つかりません．"
    case .noVideoTrack(let name):
      return "素材動画に映像トラックがありません．（\(name)）"
    case .noAudioTrack:
      return "音楽ファイルに音声トラックがありません．"
    case .cannotCreateTrack:
      return "合成用のトラックを作成できませんでした．"
    case .cannotCreateExporter:
      return "書き出しを開始できませんでした．"
    case .exportFailed(let reason):
      return "書き出しに失敗しました．\(reason)"
    case .invalidOutput(let reason):
      return "書き出した動画が正しくありません．\(reason)"
    }
  }
}

/// プレビュー再生と書き出しの両方に使う、合成済みの映像。
nonisolated struct MusicVideoComposition: @unchecked Sendable {
  let composition: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  /// 音のフェード。フェードしないときは nil。
  var audioMix: AVAudioMix?
  /// 完成映像の長さ（秒）。
  let duration: Double
  /// 画面サイズとフレームレート。書き出しのビットレートの計算にも使う。
  let render: MusicVideoRenderSettings

  func makePlayerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    return item
  }
}

/// `CutPlan` から1本の映像を組み立て、mp3 などの音楽を付けて書き出す。
///
/// 1拍ごとのカットだと数百カットになるので、既定では映像トラックを1本使い回し、
/// 画面に収める変換だけをカットの切り替え時刻ごとに差し替える。クロスフェードのときだけ、前後を重ねるために2本を交互に使う。
nonisolated struct MusicVideoComposer: Sendable {
  /// 時刻を丸める分解能。30/24/25fps のどれの1フレームも割り切れる値。
  private static let timescale: CMTimeScale = 600

  // MARK: - 合成

  /// `plan` のカット割りから、プレビューと書き出しに使う合成を組み立てる。
  /// - Parameters:
  ///   - look: 画面の合わせ方・切り替え効果・フェード。既定(画面いっぱい・そのまま切り替え・フェードなし)では、
  ///     映像トラックを1本だけ使う。
  ///   - audioStart: 音楽ファイルの何秒目を、映像の 0 秒に合わせるか(曲の一部だけを使うとき)。
  ///   - audioSeparator: 素材の音から一部の成分だけを残すとき(`look.sourceParts` が全部ではない)に使う。分けた音の保存先を持つ。
  func makeComposition(
    plan: CutPlan,
    sourceURLs: [UUID: URL],
    audioURL: URL,
    render: MusicVideoRenderSettings,
    look: MusicVideoLookTuning = MusicVideoLookTuning(),
    audioStart: Double = 0,
    audioSeparator: SourceAudioSeparator = .standard
  ) async throws -> MusicVideoComposition {
    guard !plan.cuts.isEmpty else { throw MusicVideoComposerError.emptyPlan }

    let composition = AVMutableComposition()
    let fade = min(max(0, look.fadeSeconds), plan.duration / 2)

    let placement: Placement
    switch look.transition {
    case .crossfade:
      placement = try await placeCrossfade(plan: plan, sourceURLs: sourceURLs, render: render, look: look, fade: fade, into: composition)
    case .cut, .flash:
      placement = try await placeSingleTrack(plan: plan, sourceURLs: sourceURLs, render: render, look: look, fade: fade, into: composition)
    }

    // 音楽を先に入れる(音声トラックの先頭が音楽)。素材の音は、その上に重ねる。
    var audioParameters: [AVMutableAudioMixInputParameters] = []
    if let musicParameters = try await addAudio(
      from: audioURL,
      to: composition,
      duration: Self.time(plan.duration),
      startOffset: audioStart,
      fade: fade
    ) {
      audioParameters.append(musicParameters)
    }
    if let sourceParameters = try await addSourceAudio(
      plan: plan,
      sourceURLs: sourceURLs,
      volume: look.sourceAudio.volume,
      fade: fade,
      parts: look.sourceParts,
      audioSeparator: audioSeparator,
      into: composition
    ) {
      audioParameters.append(sourceParameters)
    }
    var audioMix: AVAudioMix?
    if !audioParameters.isEmpty {
      let mix = AVMutableAudioMix()
      mix.inputParameters = audioParameters
      audioMix = mix
    }

    // 音声のほうが長いときも、映像の指示が全体を覆うように、最後の区間を合成の終わりまで延ばす。
    var segments = placement.segments
    if let last = segments.last, composition.duration > last.range.end {
      segments[segments.count - 1].range = CMTimeRange(start: last.range.start, end: composition.duration)
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.instructions = Self.makeInstructions(
      segments: segments,
      totalDuration: composition.duration,
      fade: fade
    )
    videoComposition.renderSize = render.size
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(render.framesPerSecond))
    // 色の扱いを BT.709 に固定する(書き出し側の指定と揃えて、色味が変わらないようにする)。
    videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    return MusicVideoComposition(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      duration: composition.duration.seconds,
      render: render
    )
  }

  // MARK: 合成の部品

  private struct SourceTrack {
    /// トラックは元のアセットが解放されると使えなくなる(挿入時に -12780 で失敗する)ので、アセットも持ち続ける。
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
  }

  /// 映像の1つの層。どのトラックを、どの変換で映すか。
  private struct LayerSpec {
    var track: AVMutableCompositionTrack
    /// (時刻, 変換)。カットが替わる時刻で変換を差し替える。
    var transforms: [(time: CMTime, transform: CGAffineTransform)]
    /// この区間のあいだに 1→0 へ消える(クロスフェードで、前の映像を消す側)。
    var fadesOut = false
    /// この区間のあいだに 0→1 へ現れる(フラッシュのあと、映像が戻る側)。
    var fadesIn = false
  }

  /// 同じ見え方が続く時間の区間。`layers` の先頭が一番上に重なる。
  private struct Segment {
    var range: CMTimeRange
    var layers: [LayerSpec]
    var background: CGColor
  }

  private struct Placement {
    var segments: [Segment]
  }

  // 背景色は RGB で指定する(グレースケールの色は AVFoundation に無視されて、常に黒になる)。
  private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
  private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

  private func loadedSource(
    for videoID: UUID,
    urls: [UUID: URL],
    cache: inout [UUID: SourceTrack]
  ) async throws -> SourceTrack {
    if let known = cache[videoID] { return known }
    guard let url = urls[videoID] else { throw MusicVideoComposerError.missingSource(videoID) }
    let loaded = try await loadSource(url: url)
    cache[videoID] = loaded
    return loaded
  }

  /// 映像トラックを1本だけ使う。そのまま切り替える(既定)か、切り替えのたびに白く光らせる。
  private func placeSingleTrack(
    plan: CutPlan,
    sourceURLs: [UUID: URL],
    render: MusicVideoRenderSettings,
    look: MusicVideoLookTuning,
    fade: Double,
    into composition: AVMutableComposition
  ) async throws -> Placement {
    guard let videoTrack = composition.addMutableTrack(
      withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw MusicVideoComposerError.cannotCreateTrack
    }

    var sources: [UUID: SourceTrack] = [:]
    var placed: [(cutIndex: Int, start: CMTime, transform: CGAffineTransform)] = []

    for (index, cut) in plan.cuts.enumerated() {
      try Task.checkCancellation()
      let source = try await loadedSource(for: cut.videoID, urls: sourceURLs, cache: &sources)

      // 開始・終了をそれぞれ丸めて差を長さにすることで、カット間に隙間やずれを作らない。
      let start = Self.time(cut.timelineStart)
      let end = Self.time(cut.timelineEnd)
      let length = CMTimeSubtract(end, start)
      guard length > .zero else { continue }

      var sourceStart = Self.time(cut.sourceStart)
      let sourceEnd = CMTimeAdd(sourceStart, length)
      // 素材の終わりを少しでも越えるなら、範囲に収まるまで手前にずらす。
      if sourceEnd > source.timeRange.end {
        sourceStart = max(source.timeRange.start, CMTimeSubtract(source.timeRange.end, length))
      }
      try videoTrack.insertTimeRange(
        CMTimeRange(start: sourceStart, duration: length),
        of: source.track,
        at: start
      )
      placed.append((index, start, Self.transform(for: source, renderSize: render.size, fit: look.fitMode)))
    }

    let videoEnd = videoTrack.timeRange.end
    guard !placed.isEmpty else { throw MusicVideoComposerError.emptyPlan }

    // そのまま切り替えるなら、全体で1つの区間にして、変換だけを時刻ごとに差し替える。
    if look.transition == .cut {
      let layer = LayerSpec(track: videoTrack, transforms: placed.map { ($0.start, $0.transform) })
      return Placement(segments: [
        Segment(range: CMTimeRange(start: .zero, end: videoEnd), layers: [layer], background: Self.black)
      ])
    }

    // フラッシュ: 各カットの頭で、白い背景から映像が 0→1 に戻る短い区間を挟む。
    var segments: [Segment] = []
    for (position, item) in placed.enumerated() {
      let segmentStart = position == 0 ? CMTime.zero : item.start
      let segmentEnd = position + 1 < placed.count ? placed[position + 1].start : videoEnd
      guard segmentEnd > segmentStart else { continue }
      let boundary = plan.cuts[item.cutIndex].timelineStart
      let length = (segmentEnd - segmentStart).seconds
      let flashLength = min(look.transition.duration, length / 2)
      let flashes = position > 0 && flashLength >= 0.04 && !Self.isInFadeZone(
        boundary, halfWidth: flashLength, fade: fade, total: plan.duration
      )

      if flashes {
        let flashEnd = CMTimeAdd(segmentStart, Self.time(flashLength))
        segments.append(Segment(
          range: CMTimeRange(start: segmentStart, end: flashEnd),
          layers: [LayerSpec(track: videoTrack, transforms: [(segmentStart, item.transform)], fadesIn: true)],
          background: Self.white
        ))
        segments.append(Segment(
          range: CMTimeRange(start: flashEnd, end: segmentEnd),
          layers: [LayerSpec(track: videoTrack, transforms: [(flashEnd, item.transform)])],
          background: Self.black
        ))
      } else {
        segments.append(Segment(
          range: CMTimeRange(start: segmentStart, end: segmentEnd),
          layers: [LayerSpec(track: videoTrack, transforms: [(segmentStart, item.transform)])],
          background: Self.black
        ))
      }
    }
    return Placement(segments: segments)
  }

  /// 映像トラックを2本、交互に使い、切り替えの前後を重ねて消し合う(クロスフェード)。
  /// 切り替えは拍の位置を中心にし、前のカットは拍のあとへ、次のカットは拍の前へ、素材を少しはみ出して使う。
  private func placeCrossfade(
    plan: CutPlan,
    sourceURLs: [UUID: URL],
    render: MusicVideoRenderSettings,
    look: MusicVideoLookTuning,
    fade: Double,
    into composition: AVMutableComposition
  ) async throws -> Placement {
    guard
      let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw MusicVideoComposerError.cannotCreateTrack
    }
    let tracks = [trackA, trackB]
    let cuts = plan.cuts
    let count = cuts.count

    // 各カットの開始位置。最後のカットの終わりも含める。時刻は一度だけ丸め、前後の区間で同じ値を使う。
    var bounds = cuts.map { Self.time($0.timelineStart) }
    bounds.append(Self.time(cuts[count - 1].timelineEnd))

    // overlap[i]: i 番目のカットの頭の切り替えの長さ(秒)。0 なら重ねない。
    var overlap = [Double](repeating: 0, count: count + 1)
    if count > 1 {
      for index in 1..<count {
        let shorter = min(cuts[index - 1].duration, cuts[index].duration)
        let length = min(look.transition.duration, shorter / 2)
        if length >= 0.04, !Self.isInFadeZone(cuts[index].timelineStart, halfWidth: length / 2, fade: fade, total: plan.duration) {
          overlap[index] = length
        }
      }
    }
    func half(_ index: Int) -> CMTime { Self.time(overlap[index] / 2) }

    var sources: [UUID: SourceTrack] = [:]
    var transforms: [CGAffineTransform] = []
    for (index, cut) in cuts.enumerated() {
      try Task.checkCancellation()
      let source = try await loadedSource(for: cut.videoID, urls: sourceURLs, cache: &sources)
      transforms.append(Self.transform(for: source, renderSize: render.size, fit: look.fitMode))

      // このカットが占める時間: 前の切り替えの半分だけ早く始まり、次の切り替えの半分だけ遅く終わる。
      let timelineStart = CMTimeSubtract(bounds[index], half(index))
      let timelineEnd = CMTimeAdd(bounds[index + 1], half(index + 1))
      let length = CMTimeSubtract(timelineEnd, timelineStart)
      guard length > .zero else { continue }

      // 素材も同じだけ前にずらして使う。素材の範囲を越えるときは、収まるまで動かす。
      var sourceStart = CMTimeSubtract(Self.time(cut.sourceStart), half(index))
      if sourceStart < source.timeRange.start { sourceStart = source.timeRange.start }
      if CMTimeAdd(sourceStart, length) > source.timeRange.end {
        sourceStart = max(source.timeRange.start, CMTimeSubtract(source.timeRange.end, length))
      }
      try tracks[index % 2].insertTimeRange(
        CMTimeRange(start: sourceStart, duration: length),
        of: source.track,
        at: timelineStart
      )
    }

    var segments: [Segment] = []
    for index in 0..<count {
      if index > 0, overlap[index] > 0 {
        // 切り替え: 前のカットを上に重ね、1→0 に消していく。
        let start = CMTimeSubtract(bounds[index], half(index))
        let end = CMTimeAdd(bounds[index], half(index))
        segments.append(Segment(
          range: CMTimeRange(start: start, end: end),
          layers: [
            LayerSpec(track: tracks[(index - 1) % 2], transforms: [(start, transforms[index - 1])], fadesOut: true),
            LayerSpec(track: tracks[index % 2], transforms: [(start, transforms[index])])
          ],
          background: Self.black
        ))
      }
      let soloStart = CMTimeAdd(bounds[index], half(index))
      let soloEnd = CMTimeSubtract(bounds[index + 1], half(index + 1))
      guard soloEnd > soloStart else { continue }
      segments.append(Segment(
        range: CMTimeRange(start: soloStart, end: soloEnd),
        layers: [LayerSpec(track: tracks[index % 2], transforms: [(soloStart, transforms[index])])],
        background: Self.black
      ))
    }
    guard !segments.isEmpty else { throw MusicVideoComposerError.emptyPlan }
    return Placement(segments: segments)
  }

  /// 切り替えが、最初・最後のフェードと重なるか。重なるときは、切り替えの効果は付けない(透明度の指定が競合するため)。
  private static func isInFadeZone(_ boundary: Double, halfWidth: Double, fade: Double, total: Double) -> Bool {
    guard fade > 0 else { return false }
    return boundary - halfWidth < fade || boundary + halfWidth > total - fade
  }

  /// 区間ごとの指示を作る。最初と最後の `fade` 秒は、全体の透明度を 0↔1 に変える。
  private static func makeInstructions(
    segments: [Segment],
    totalDuration: CMTime,
    fade: Double
  ) -> [AVMutableVideoCompositionInstruction] {
    let total = totalDuration.seconds
    let fadeTime = time(fade)
    let fadeInZone = CMTimeRange(start: .zero, duration: fadeTime)
    let fadeOutZone = CMTimeRange(start: CMTimeSubtract(totalDuration, fadeTime), duration: fadeTime)

    return segments.map { segment in
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = segment.range
      instruction.backgroundColor = segment.background

      instruction.layerInstructions = segment.layers.map { layer in
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: layer.track)
        for entry in layer.transforms {
          layerInstruction.setTransform(entry.transform, at: entry.time)
        }
        if layer.fadesOut {
          layerInstruction.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: segment.range)
        }
        if layer.fadesIn {
          layerInstruction.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: segment.range)
        }
        if fade > 0 {
          let intoVideo = segment.range.intersection(fadeInZone)
          if intoVideo.duration > .zero {
            layerInstruction.setOpacityRamp(
              fromStartOpacity: Float(intoVideo.start.seconds / fade),
              toEndOpacity: Float(intoVideo.end.seconds / fade),
              timeRange: intoVideo
            )
          }
          let outOfVideo = segment.range.intersection(fadeOutZone)
          if outOfVideo.duration > .zero {
            layerInstruction.setOpacityRamp(
              fromStartOpacity: Float((total - outOfVideo.start.seconds) / fade),
              toEndOpacity: Float((total - outOfVideo.end.seconds) / fade),
              timeRange: outOfVideo
            )
          }
        }
        return layerInstruction
      }
      return instruction
    }
  }

  private func loadSource(url: URL) async throws -> SourceTrack {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw MusicVideoComposerError.noVideoTrack(url.lastPathComponent)
    }
    let (timeRange, naturalSize, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)
    return SourceTrack(
      asset: asset,
      track: track,
      timeRange: timeRange,
      naturalSize: naturalSize,
      preferredTransform: transform
    )
  }

  /// 音楽を映像の 0 秒に合わせて入れる。`fade` が 0 より大きければ、最初と最後で音量を 0↔1 に変える指定を返す。
  private func addAudio(
    from url: URL,
    to composition: AVMutableComposition,
    duration: CMTime,
    startOffset: Double,
    fade: Double
  ) async throws -> AVMutableAudioMixInputParameters? {
    let asset = AVURLAsset(url: url)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw MusicVideoComposerError.noAudioTrack
    }
    guard let audioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw MusicVideoComposerError.cannotCreateTrack
    }
    let available = try await sourceTrack.load(.timeRange)
    let offset = Self.time(max(0, startOffset))
    let start = min(CMTimeAdd(available.start, offset), available.end)
    let length = min(duration, CMTimeSubtract(available.end, start))
    guard length > .zero else { throw MusicVideoComposerError.noAudioTrack }
    try audioTrack.insertTimeRange(
      CMTimeRange(start: start, duration: length),
      of: sourceTrack,
      at: .zero
    )

    guard fade > 0 else { return nil }
    let fadeTime = Self.time(fade)
    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fadeTime))
    parameters.setVolumeRamp(
      fromStartVolume: 1,
      toEndVolume: 0,
      timeRange: CMTimeRange(start: CMTimeSubtract(length, fadeTime), duration: fadeTime)
    )
    return parameters
  }

  /// カットのつなぎ目の前後で、素材の音を 0 まで絞る時間(秒)。音が飛ぶ所で出る「ぷつっ」という雑音を防ぐ。
  /// AVFoundation の音量は約 30ms より速く変えられない(これより短いと 0 まで下がりきらない)ので、その長さにする。
  private static let sourceAudioSeam = 0.03

  /// 各カットの素材の音を、映像と同じ位置に入れる。`volume` が 0 なら何も入れない。
  ///
  /// 映像と同じ素材の位置を使うので、クロスフェードでも映像と音は合ったまま。
  /// 音声トラックを持たない素材のカットは、無音になる。
  /// 最初と最後のフェード(`fade`)と、カットのつなぎ目の絞りが重ならないよう、フェードの間は絞りを入れない。
  private func addSourceAudio(
    plan: CutPlan,
    sourceURLs: [UUID: URL],
    volume: Float,
    fade: Double,
    parts: SourceAudioParts,
    audioSeparator: SourceAudioSeparator,
    into composition: AVMutableComposition
  ) async throws -> AVMutableAudioMixInputParameters? {
    // 音量が 0 か、残す成分が無ければ、素材の音は入れない。
    guard volume > 0, !parts.isEmpty else { return nil }
    guard let audioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw MusicVideoComposerError.cannotCreateTrack
    }

    // 素材の音声トラックは、元のアセットが解放されると使えなくなるので、アセットごと持ち続ける。
    struct SourceAudio {
      let asset: AVURLAsset
      let track: AVAssetTrack?
      let audioRange: CMTimeRange
      /// 映像側が素材の終わりに収めるときの基準。音も同じだけずらして、映像と音を合わせる。
      let videoRange: CMTimeRange
    }
    var sources: [UUID: SourceAudio] = [:]

    func loadedAudio(for videoID: UUID) async throws -> SourceAudio {
      if let known = sources[videoID] { return known }
      guard let url = sourceURLs[videoID] else { throw MusicVideoComposerError.missingSource(videoID) }
      let asset = AVURLAsset(url: url)
      let videoRange = try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange)
        ?? CMTimeRange(start: .zero, duration: .positiveInfinity)
      let track = try await asset.loadTracks(withMediaType: .audio).first
      let audioRange = try await track?.load(.timeRange) ?? .zero
      let loaded = SourceAudio(asset: asset, track: track, audioRange: audioRange, videoRange: videoRange)
      sources[videoID] = loaded
      return loaded
    }

    let seam = Self.time(Self.sourceAudioSeam)
    let total = plan.duration
    let fadeTime = Self.time(fade)
    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
    parameters.setVolume(volume, at: .zero)

    // 最初と最後のフェード。
    if fade > 0 {
      parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: fadeTime))
      parameters.setVolumeRamp(
        fromStartVolume: volume,
        toEndVolume: 0,
        timeRange: CMTimeRange(start: CMTimeSubtract(Self.time(total), fadeTime), duration: fadeTime)
      )
    }

    /// トラックに入れる音ひとつぶん。
    struct Piece {
      let sourceURL: URL
      let track: AVAssetTrack
      let sourceRange: CMTimeRange
      let timelineStart: CMTime
    }
    var pieces: [Piece] = []

    for (index, cut) in plan.cuts.enumerated() {
      try Task.checkCancellation()
      let source = try await loadedAudio(for: cut.videoID)

      let start = Self.time(cut.timelineStart)
      let end = Self.time(cut.timelineEnd)
      let length = CMTimeSubtract(end, start)
      guard length > .zero else { continue }

      // 映像と同じ素材の位置を使う(素材の終わりを越えるときは、映像と同じだけ手前へずらす)。
      var sourceStart = Self.time(cut.sourceStart)
      if CMTimeAdd(sourceStart, length) > source.videoRange.end {
        sourceStart = max(source.videoRange.start, CMTimeSubtract(source.videoRange.end, length))
      }

      if let track = source.track {
        // 音声が映像より短い素材は、音のある範囲だけを入れる(残りは無音)。
        let audioStart = max(sourceStart, source.audioRange.start)
        let skipped = CMTimeSubtract(audioStart, sourceStart)
        let available = min(CMTimeSubtract(length, skipped), CMTimeSubtract(source.audioRange.end, audioStart))
        if available > .zero {
          pieces.append(Piece(
            sourceURL: source.asset.url, track: track,
            sourceRange: CMTimeRange(start: audioStart, duration: available),
            timelineStart: CMTimeAdd(start, skipped)
          ))
        }
      }

      // つなぎ目(カットの頭)の前後を一瞬だけ絞る。前後のカットが短すぎるときと、フェードの間は入れない。
      guard index > 0 else { continue }
      let previousLength = plan.cuts[index - 1].duration
      let seamSeconds = Self.sourceAudioSeam
      guard cut.duration > seamSeconds * 2, previousLength > seamSeconds * 2 else { continue }
      let seamStart = cut.timelineStart - seamSeconds
      let seamEnd = cut.timelineStart + seamSeconds
      guard fade == 0 || (seamStart >= fade && seamEnd <= total - fade) else { continue }
      parameters.setVolumeRamp(
        fromStartVolume: volume,
        toEndVolume: 0,
        timeRange: CMTimeRange(start: CMTimeSubtract(start, seam), duration: seam)
      )
      parameters.setVolumeRamp(
        fromStartVolume: 0,
        toEndVolume: volume,
        timeRange: CMTimeRange(start: start, duration: seam)
      )
    }

    // 一部の成分だけを残すときは、使う範囲ごとに、その成分だけの音を作り、それを入れる。
    guard parts.needsSeparation else {
      for piece in pieces {
        try audioTrack.insertTimeRange(piece.sourceRange, of: piece.track, at: piece.timelineStart)
      }
      return parameters
    }
    audioSeparator.trimCache()
    let processed = try await separateAudio(from: pieces.map { ($0.sourceURL, $0.sourceRange) }, parts: parts, using: audioSeparator)
    for (piece, url) in zip(pieces, processed) {
      // 分けられなかった範囲は、選んでいない成分が混ざらないよう、無音にする。
      guard let url else { continue }
      let asset = AVURLAsset(url: url)
      guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
      let available = min(piece.sourceRange.duration, try await asset.load(.duration))
      guard available > .zero else { continue }
      try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: available), of: track, at: piece.timelineStart)
    }
    return parameters
  }

  /// 同時に分ける範囲の数。多すぎると、音の解析でメモリと CPU を使い切る。
  private static let separationConcurrency = 4

  /// 各範囲から、選んだ成分だけを残したファイルを作る。失敗した範囲は nil（キャンセルのときは投げ直す）。順序は入力と同じ。
  private func separateAudio(
    from ranges: [(url: URL, range: CMTimeRange)],
    parts: SourceAudioParts,
    using separator: SourceAudioSeparator
  ) async throws -> [URL?] {
    var results = [URL?](repeating: nil, count: ranges.count)
    try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
      var next = 0
      func addNext() {
        guard next < ranges.count else { return }
        let index = next
        next += 1
        let item = ranges[index]
        group.addTask {
          do {
            let url = try await separator.audio(
              source: item.url, start: item.range.start.seconds, duration: item.range.duration.seconds, parts: parts
            )
            return (index, url)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return (index, nil)
          }
        }
      }
      for _ in 0..<Self.separationConcurrency { addNext() }
      while let (index, url) = try await group.next() {
        results[index] = url
        addNext()
      }
    }
    return results
  }

  /// 素材を画面に収める変換。向き（回転）も反映する。
  /// `.fill` は画面いっぱいに（はみ出す部分は切り落として）敷き詰め、`.fit` は全体が収まる大きさにして中央に置く。
  private static func transform(for source: SourceTrack, renderSize: CGSize, fit: MusicVideoFitMode) -> CGAffineTransform {
    let rotated = source.naturalSize.applying(source.preferredTransform)
    let displaySize = CGSize(width: abs(rotated.width), height: abs(rotated.height))
    guard displaySize.width > 0, displaySize.height > 0 else { return .identity }

    let widthScale = renderSize.width / displaySize.width
    let heightScale = renderSize.height / displaySize.height
    let scale = fit == .fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
    let scaledSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    let translation = CGAffineTransform(
      translationX: (renderSize.width - scaledSize.width) / 2,
      y: (renderSize.height - scaledSize.height) / 2
    )
    return source.preferredTransform
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      .concatenating(translation)
  }

  private static func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: timescale)
  }

  // MARK: - 書き出し

  /// 合成した映像を mp4(H.264 + AAC)に書き出す。`progress` には 0〜1 が渡される。
  /// 画面サイズは保ったまま、`quality` に応じた映像のビットレートで書き出す。
  func export(
    _ composed: MusicVideoComposition,
    to outputURL: URL,
    quality: MusicVideoExportQuality = .high,
    progress: @escaping @Sendable (Double) async -> Void = { _ in }
  ) async throws {
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let job = try ExportJob(composed: composed, outputURL: outputURL, quality: quality)
    do {
      try await withTaskCancellationHandler {
        try await job.run(progress: progress)
      } onCancel: {
        job.cancel()
      }
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      if let known = error as? MusicVideoComposerError { throw known }
      throw MusicVideoComposerError.exportFailed(error.localizedDescription)
    }
    await progress(1)

    try await validateOutput(at: outputURL, expectedDuration: composed.duration)
  }

  /// 読み出し(合成済みの映像と音声)と書き込み(H.264 + AAC)をつなぎ、順に流し込む。
  private final class ExportJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private let duration: Double
    /// 読み出しの開始(startReading)中に中止(cancelReading)を呼ぶと AVFoundation の内部で落ちるので、
    /// 開始中の取り消しは、開始が終わってから実行する。
    private enum Phase { case idle, starting, running }
    private let lock = NSLock()
    private var isCancelled = false
    private var phase: Phase = .idle

    init(composed: MusicVideoComposition, outputURL: URL, quality: MusicVideoExportQuality) throws {
      let render = composed.render
      duration = composed.duration
      reader = try AVAssetReader(asset: composed.composition)

      videoOutput = AVAssetReaderVideoCompositionOutput(
        videoTracks: composed.composition.tracks(withMediaType: .video),
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
      )
      videoOutput.videoComposition = composed.videoComposition
      videoOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(videoOutput) else { throw MusicVideoComposerError.cannotCreateExporter }
      reader.add(videoOutput)

      let audioTracks = composed.composition.tracks(withMediaType: .audio)
      if audioTracks.isEmpty {
        audioOutput = nil
      } else {
        let output = AVAssetReaderAudioMixOutput(
          audioTracks: audioTracks,
          audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: MusicVideoExportQuality.audioSampleRate,
            AVNumberOfChannelsKey: 2
          ]
        )
        output.audioMix = composed.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicVideoComposerError.cannotCreateExporter }
        reader.add(output)
        audioOutput = output
      }

      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
      videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: render.width,
          AVVideoHeightKey: render.height,
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
          ],
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: quality.videoBitRate(for: render),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: render.framesPerSecond * 2,
            AVVideoExpectedSourceFrameRateKey: render.framesPerSecond
          ]
        ]
      )
      videoInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(videoInput) else { throw MusicVideoComposerError.cannotCreateExporter }
      writer.add(videoInput)

      if audioOutput != nil {
        let input = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MusicVideoExportQuality.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: MusicVideoExportQuality.audioBitRate
          ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MusicVideoComposerError.cannotCreateExporter }
        writer.add(input)
        audioInput = input
      } else {
        audioInput = nil
      }
    }

    func cancel() {
      lock.lock()
      isCancelled = true
      let shouldCancelNow = phase == .running
      lock.unlock()
      // 読み出しを止めると、流し込みの側は終わりまで読んだものとして自然に閉じる。
      // まだ始まっていない/開始中なら、run() が開始後に止める。
      if shouldCancelNow { reader.cancelReading() }
    }

    private var wasCancelled: Bool {
      lock.lock(); defer { lock.unlock() }
      return isCancelled
    }

    func run(progress: @escaping @Sendable (Double) async -> Void) async throws {
      lock.lock()
      if isCancelled { lock.unlock(); throw CancellationError() }
      phase = .starting
      lock.unlock()

      let started = reader.startReading()

      lock.lock()
      phase = .running
      let cancelledWhileStarting = isCancelled
      lock.unlock()
      if cancelledWhileStarting {
        reader.cancelReading()
        throw CancellationError()
      }
      guard started else {
        throw MusicVideoComposerError.exportFailed(reader.error?.localizedDescription ?? "読み出しを開始できませんでした．")
      }
      guard writer.startWriting() else {
        reader.cancelReading()
        throw MusicVideoComposerError.exportFailed(writer.error?.localizedDescription ?? "書き込みを開始できませんでした．")
      }
      writer.startSession(atSourceTime: .zero)

      async let videoDone: Void = pump(videoInput, from: videoOutput, progress: progress)
      async let audioDone: Void = {
        if let audioInput, let audioOutput { await pump(audioInput, from: audioOutput, progress: nil) }
      }()
      _ = await (videoDone, audioDone)

      if wasCancelled {
        writer.cancelWriting()
        throw CancellationError()
      }
      if reader.status == .failed {
        writer.cancelWriting()
        throw MusicVideoComposerError.exportFailed(reader.error?.localizedDescription ?? "読み出しに失敗しました．")
      }
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw MusicVideoComposerError.exportFailed(writer.error?.localizedDescription ?? "書き込みに失敗しました．")
      }
    }

    /// 読み出し側から取り出したサンプルを、書き込み側が受け取れるたびに渡す。
    private func pump(
      _ input: AVAssetWriterInput,
      from output: AVAssetReaderOutput,
      progress: (@Sendable (Double) async -> Void)?
    ) async {
      let queue = DispatchQueue(label: "musicvideo.export.\(input.mediaType.rawValue)")
      let total = max(duration, 0.001)
      // 書き出し側は、閉じた後も「受け取れます」と呼び出し直してくることがある。
      // そのとき、解放済みの読み出し側に触らないよう、(1)終わったら何もしない (2)呼び出しが続く間は reader を保持する。
      let reader = self.reader
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var lastReported = -1.0
        var isFinished = false
        input.requestMediaDataWhenReady(on: queue) {
          withExtendedLifetime(reader) {
            guard !isFinished else { return }
            while input.isReadyForMoreMediaData {
              guard let buffer = output.copyNextSampleBuffer() else {
                isFinished = true
                input.markAsFinished()
                continuation.resume()
                return
              }
              if !input.append(buffer) {
                isFinished = true
                input.markAsFinished()
                continuation.resume()
                return
              }
              if let progress {
                let fraction = min(1, max(0, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / total))
                if fraction - lastReported >= 0.01 {
                  lastReported = fraction
                  Task { await progress(fraction) }
                }
              }
            }
          }
        }
      }
    }
  }

  /// 書き出したファイルに映像と音声があり、長さが想定と大きくずれていないことを確かめる。
  private func validateOutput(at url: URL, expectedDuration: Double) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
    let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
    guard hasVideo else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("映像がありません．")
    }
    guard hasAudio else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("音声がありません．")
    }
    guard abs(duration - expectedDuration) < 1.0 else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("長さが想定（\(Int(expectedDuration))秒）と合いません．")
    }
  }
}
