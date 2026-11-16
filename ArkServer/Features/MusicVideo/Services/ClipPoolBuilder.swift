// ArkServer/Features/MusicVideo/Services/ClipPoolBuilder.swift

import Foundation

/// 解析対象の素材動画1本。
nonisolated struct ClipPoolSource: Sendable {
  let videoID: UUID
  let url: URL
  /// ライブラリに記録されている動画の長さ（秒）。
  let duration: Double
}

nonisolated enum ClipPoolError: LocalizedError {
  case noUsableVideos

  var errorDescription: String? {
    switch self {
    case .noUsableVideos:
      return "素材動画を解析できませんでした．動画ファイルが存在するか確認してください．"
    }
  }
}

/// 解析前の（正規化していない）動きの時系列。キャッシュにはこの形で保存する。
/// 「急に動いた瞬間」(衝撃)は、この動きの列から作れるので、保存しない。
nonisolated struct RawMotionWindow: Codable, Equatable, Sendable {
  let offset: Double
  let duration: Double
  let hop: Double
  let values: [Double]
}

/// 素材動画から、カット割りで使う「動きの時系列」を作る。
///
/// 長い動画は全体を解析すると時間がかかるので、動画の中の離れた複数の区間（窓）だけを調べる。
/// 解析結果は動画ごとにディスクへキャッシュし、同じ動画は再解析しない。
nonisolated struct ClipPoolBuilder: Sendable {
  /// 1つの窓の長さ（秒）。
  var windowDuration = 15.0
  /// 1本の動画から調べる窓の最大数。
  var maxWindowsPerVideo = 6
  /// 動きを調べるときの1秒あたりの標本数。
  /// 拍の間隔(120BPMで0.5秒)より十分細かくしないと、拍と動きの山を合わせられない。
  /// 動画の読み込み(復号)は、標本数に関わらず全フレームぶん行うので、細かくしても重さはあまり増えない。
  var analysisFramesPerSecond = 12.0
  /// 同時に解析する動画の数。
  var maxConcurrentAnalyses = 3
  /// 解析する動画の最大本数。これを超えたらシードで無作為に選ぶ。
  var maxVideos = 40
  /// キャッシュの保存先。nil ならキャッシュしない。
  var cacheDirectory: URL?

  private static let cacheVersion = 2

  func build(
    sources: [ClipPoolSource],
    seed: UInt64,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void = { _, _ in }
  ) async throws -> [SourceMotionProfile] {
    let selected = select(sources, seed: seed)
    guard !selected.isEmpty else { throw ClipPoolError.noUsableVideos }

    var analyzed: [(source: ClipPoolSource, windows: [RawMotionWindow])] = []
    var completed = 0
    await progress(0, selected.count)

    try await withThrowingTaskGroup(of: (Int, [RawMotionWindow]?).self) { group in
      var nextIndex = 0
      func addNext() {
        guard nextIndex < selected.count else { return }
        let index = nextIndex
        let source = selected[index]
        nextIndex += 1
        group.addTask {
          (index, try? await self.motionWindows(for: source))
        }
      }
      for _ in 0..<max(1, maxConcurrentAnalyses) { addNext() }

      var results: [Int: [RawMotionWindow]] = [:]
      while let (index, windows) = try await group.next() {
        try Task.checkCancellation()
        completed += 1
        if let windows, !windows.isEmpty { results[index] = windows }
        await progress(completed, selected.count)
        addNext()
      }
      // 選んだ順に並べ直す(完了順に依存させず、結果を再現可能にする)。
      for index in selected.indices {
        if let windows = results[index] { analyzed.append((selected[index], windows)) }
      }
    }

    guard !analyzed.isEmpty else { throw ClipPoolError.noUsableVideos }
    return Self.normalizedProfiles(from: analyzed)
  }

  // MARK: - 素材の絞り込み

  /// 動画が多すぎるときは、シードで決まる順に `maxVideos` 本へ絞る。
  func select(_ sources: [ClipPoolSource], seed: UInt64) -> [ClipPoolSource] {
    guard sources.count > maxVideos else { return sources }
    var generator = SeededGenerator(seed: seed)
    return Array(sources.shuffled(using: &generator).prefix(maxVideos))
  }

  // MARK: - 窓の配置

  /// 動画の長さから、解析する窓の (開始位置, 長さ) を決める。
  /// 冒頭と末尾の5%は(タイトルやエンドロールが多いので)避け、残りに均等に並べる。
  func windowRanges(forDuration duration: Double) -> [(offset: Double, length: Double)] {
    guard duration > 0 else { return [] }
    if duration <= windowDuration { return [(0, duration)] }

    let margin = duration * 0.05
    let usable = max(windowDuration, duration - 2 * margin)
    let count = max(1, min(maxWindowsPerVideo, Int(usable / windowDuration)))
    if count == 1 {
      return [(max(0, (duration - windowDuration) / 2), windowDuration)]
    }
    let span = usable - windowDuration
    return (0..<count).map { index in
      let offset = margin + span * Double(index) / Double(count - 1)
      return (min(offset, duration - windowDuration), windowDuration)
    }
  }

  // MARK: - 解析とキャッシュ

  private struct CacheFile: Codable {
    var version: Int
    var fileSize: Int64
    var modificationTime: Double
    var windowDuration: Double
    var maxWindowsPerVideo: Int
    var framesPerSecond: Double
    var duration: Double
    var windows: [RawMotionWindow]
  }

  private func motionWindows(for source: ClipPoolSource) async throws -> [RawMotionWindow] {
    let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    let modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

    if let cached = loadCache(for: source.videoID),
       cached.version == Self.cacheVersion,
       cached.fileSize == fileSize,
       abs(cached.modificationTime - modificationTime) < 0.001,
       cached.windowDuration == windowDuration,
       cached.maxWindowsPerVideo == maxWindowsPerVideo,
       cached.framesPerSecond == analysisFramesPerSecond,
       abs(cached.duration - source.duration) < 0.001 {
      return cached.windows
    }

    let analyzer = VisualAnalyzer()
    var settings = AnalysisSettings()
    settings.analysisFramesPerSecond = analysisFramesPerSecond
    let hop = 1 / analysisFramesPerSecond

    var windows: [RawMotionWindow] = []
    for range in windowRanges(forDuration: source.duration) {
      try Task.checkCancellation()
      let points = try await analyzer.analyze(
        url: source.url,
        settings: settings,
        timeRange: range.offset...(range.offset + range.length)
      )
      let values = Self.resample(points: points, offset: range.offset, length: range.length, hop: hop)
      if !values.isEmpty {
        windows.append(RawMotionWindow(offset: range.offset, duration: range.length, hop: hop, values: values))
      }
    }

    if !windows.isEmpty {
      saveCache(
        CacheFile(
          version: Self.cacheVersion,
          fileSize: fileSize,
          modificationTime: modificationTime,
          windowDuration: windowDuration,
          maxWindowsPerVideo: maxWindowsPerVideo,
          framesPerSecond: analysisFramesPerSecond,
          duration: source.duration,
          windows: windows
        ),
        for: source.videoID
      )
    }
    return windows
  }

  /// 解析点を、窓の先頭から `hop` 秒ごとの等間隔の列に直す。
  /// 先頭の点は直前のフレームが無く差が0になるので使わない。欠けた所は直前の値で埋める。
  static func resample(points: [VisualFeaturePoint], offset: Double, length: Double, hop: Double) -> [Double] {
    let usable = Array(points.dropFirst())
    guard !usable.isEmpty, hop > 0 else { return [] }
    let bucketCount = max(1, Int((length / hop).rounded(.up)))
    var sums = [Double](repeating: 0, count: bucketCount)
    var counts = [Int](repeating: 0, count: bucketCount)
    for point in usable {
      let index = min(bucketCount - 1, max(0, Int((point.time - offset) / hop)))
      sums[index] += point.frameDiff
      counts[index] += 1
    }
    var values = [Double](repeating: 0, count: bucketCount)
    var last = usable[0].frameDiff
    for index in 0..<bucketCount {
      if counts[index] > 0 { last = sums[index] / Double(counts[index]) }
      values[index] = last
    }
    return values
  }

  private func cacheURL(for videoID: UUID) -> URL? {
    cacheDirectory?.appendingPathComponent("\(videoID.uuidString).json")
  }

  private func loadCache(for videoID: UUID) -> CacheFile? {
    guard let url = cacheURL(for: videoID), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CacheFile.self, from: data)
  }

  private func saveCache(_ cache: CacheFile, for videoID: UUID) {
    guard let directory = cacheDirectory, let url = cacheURL(for: videoID) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(cache) {
      try? data.write(to: url, options: .atomic)
    }
  }

  // MARK: - 正規化

  /// 全素材をまとめて、下位5%を0・上位5%を1として規格化する。
  /// 動画ごとに規格化すると、静かな動画にも「激しい部分」ができてしまうので、素材全体で揃える。
  static func normalizedProfiles(
    from analyzed: [(source: ClipPoolSource, windows: [RawMotionWindow])]
  ) -> [SourceMotionProfile] {
    let allValues = analyzed.flatMap { $0.windows.flatMap(\.values) }.sorted()
    guard !allValues.isEmpty else { return [] }
    let low = allValues[Int(Double(allValues.count - 1) * 0.05)]
    let high = allValues[Int(Double(allValues.count - 1) * 0.95)]
    let range = high - low

    // 「急に動いた瞬間」も、素材全体で揃えて規格化する(上位1%を1とする)。
    let rawImpactsByWindow = analyzed.map { entry in entry.windows.map { Self.rawImpacts(from: $0.values) } }
    let allImpacts = rawImpactsByWindow.flatMap { $0.flatMap { $0 } }.sorted()
    let impactScale = allImpacts.isEmpty ? 0 : allImpacts[Int(Double(allImpacts.count - 1) * 0.99)]

    var profiles: [SourceMotionProfile] = []
    for (sourceIndex, entry) in analyzed.enumerated() {
      for (windowIndex, window) in entry.windows.enumerated() {
        let values: [Double] = window.values.map { value in
          guard range > 1e-9 else { return 0.5 }
          return min(1, max(0, (value - low) / range))
        }
        let impacts: [Double] = rawImpactsByWindow[sourceIndex][windowIndex].map { value in
          impactScale > 1e-9 ? min(1, value / impactScale) : 0
        }
        profiles.append(
          SourceMotionProfile(
            videoID: entry.source.videoID,
            offset: window.offset,
            duration: window.duration,
            hop: window.hop,
            values: values,
            impacts: impacts
          )
        )
      }
    }
    return profiles
  }

  /// 動きの列から、「急に動いた瞬間」の強さ(規格化前)を求める。
  /// その位置の動きが、直前の3つの平均より増えた分(増えなければ 0)。増えた位置が分かるよう、
  /// 前後に少しにじませる(隣の標本に半分ずつ)。
  static func rawImpacts(from values: [Double]) -> [Double] {
    guard !values.isEmpty else { return [] }
    var rises = [Double](repeating: 0, count: values.count)
    for index in 1..<max(1, values.count) {
      let lower = max(0, index - 3)
      let baseline = values[lower..<index].reduce(0, +) / Double(index - lower)
      rises[index] = max(0, values[index] - baseline)
    }
    return rises.indices.map { index in
      let previous = index > 0 ? rises[index - 1] : 0
      let next = index + 1 < rises.count ? rises[index + 1] : 0
      return 0.5 * rises[index] + 0.25 * (previous + next)
    }
  }
}
