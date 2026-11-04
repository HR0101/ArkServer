// ArkServerTests/MusicVideoSyncTests.swift

import Foundation
import Testing
@testable import ArkServer

/// 曲と映像の動きの合わせ込み。同じ素材・同じ曲で、合わせ込みを切った場合と入れた場合を比べて、数値で確かめる。
@Suite(.serialized)
struct MusicVideoSyncTests {
  private static let videoHop = 1.0 / 12

  // MARK: 合成データ

  /// 120BPM(0.5秒ごとの拍)の曲。拍の強さは「強・中・強め・中」のように変わり、小節の頭(強)は添字 0, 4, 8 …。
  /// 音の立ち上がり(onset)は、各拍に、その拍の強さの山。
  private func syntheticAnalysis(
    duration: Double = 40,
    intensity: MusicIntensity = .medium,
    energy: Double = 0.5
  ) -> MusicAnalysis {
    let beats = stride(from: 0.5, to: duration - 0.1, by: 0.5).map { $0 }
    var analysis = MusicAnalysis(
      duration: duration, tempo: 120, beats: beats,
      energy: [Double](repeating: energy, count: Int(duration * 10)),
      intensity: [MusicIntensity](repeating: intensity, count: Int(duration * 10)),
      energyHop: 0.1
    )
    analysis.beatAccents = beats.indices.map { $0 % 4 == 0 ? 1.0 : ($0 % 2 == 0 ? 0.65 : 0.3) }
    analysis.downbeatPhase = 0
    var envelope = [Double](repeating: 0, count: Int(duration / 0.05) + 2)
    for (index, time) in beats.enumerated() {
      envelope[Int((time / 0.05).rounded())] = analysis.beatAccents[index]
    }
    analysis.onsetEnvelope = envelope
    analysis.onsetHop = 0.05
    return analysis
  }

  /// 動きの強さは一定(0.5)で、0.5秒ごとに「衝撃」が起きる素材。衝撃の位相(最初の衝撃の時刻)だけが違う。
  /// 動きの強さでは区別できないので、選び方の差は、衝撃を拍に重ねたかどうかだけで決まる。
  private func periodicImpactProfile(
    _ id: UUID = UUID(),
    phase: Double,
    period: Double = 0.5,
    duration: Double = 60,
    motion: Double = 0.5,
    spread: Bool = true
  ) -> SourceMotionProfile {
    let hop = Self.videoHop
    let count = Int(duration / hop)
    var impacts = [Double](repeating: 0, count: count)
    var time = phase
    while time < duration - hop {
      let index = Int((time / hop).rounded())
      if index < count { impacts[index] = 1 }
      if spread {
        if index > 0 { impacts[index - 1] = max(impacts[index - 1], 0.5) }
        if index + 1 < count { impacts[index + 1] = max(impacts[index + 1], 0.5) }
      }
      time += period
    }
    return SourceMotionProfile(
      videoID: id, duration: duration, hop: hop,
      values: [Double](repeating: motion, count: count), impacts: impacts
    )
  }

  /// 位相を 1/12 秒ずつずらした6本。
  private func phasedPool() -> [SourceMotionProfile] {
    (0..<6).map { periodicImpactProfile(phase: Double($0) * Self.videoHop) }
  }

  /// 衝撃が1秒に1回・1標本だけの、まばらな素材。位相を 1/6 秒ずつずらした6本。
  /// 衝撃の間が空いているので、位置が偶然に決まると、強い拍に衝撃が重なる確率は2割ほどしかない(合わせ込みの差が出やすい)。
  private func sparsePhasedPool() -> [SourceMotionProfile] {
    (0..<6).map { periodicImpactProfile(phase: Double($0) * 2 * Self.videoHop, period: 1.0, spread: false) }
  }

  private func planner(hitSync: HitSync, motion: MotionMatching = .standard, style: MusicVideoCutStyle = .standard) -> CutPlanner {
    var tuning = MusicVideoCutTuning()
    tuning.hitSync = hitSync
    tuning.motionMatching = motion
    return CutPlanner(style: style, tuning: tuning)
  }

  private func averageHitAlignment(
    _ planner: CutPlanner,
    analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    seeds: ClosedRange<UInt64> = 1...4
  ) throws -> Double {
    var total = 0.0
    for seed in seeds {
      let plan = try planner.plan(analysis: analysis, pool: pool, seed: seed)
      let metrics = MusicVideoSyncMetrics(plan: plan, analysis: analysis, pool: pool)
      total += try #require(metrics.hitAlignment, "seed \(seed)")
    }
    return total / Double(seeds.count)
  }

  // MARK: 拍と衝撃の一致

  @Test
  func hitSyncPutsTheVideoImpactsOnTheStrongBeats() throws {
    let analysis = syntheticAnalysis()
    let pool = sparsePhasedPool()

    let off = try averageHitAlignment(planner(hitSync: .off), analysis: analysis, pool: pool)
    let standard = try averageHitAlignment(planner(hitSync: .standard), analysis: analysis, pool: pool)
    let strong = try averageHitAlignment(planner(hitSync: .strong), analysis: analysis, pool: pool)
    print("INFO hitAlignment off=\(off) standard=\(standard) strong=\(strong)")

    // 合わせない場合は、衝撃の位置が偶然に決まる(強い拍に重なるのは2割ほど)。
    #expect(off < 0.5, "合わせない \(off)")
    // 合わせると、ほぼすべての強い拍に、衝撃が重なる。
    #expect(standard >= 0.9, "標準 \(standard)")
    #expect(strong >= 0.9, "強い \(strong)")
    #expect(strong > off + 0.4, "強い \(strong) 合わせない \(off)")
  }

  @Test
  func theImpactsLandOnTheCutStartsToo() throws {
    // カットは拍の上で切り替わる。その瞬間(頭)に、映像の衝撃が来ているか。
    let analysis = syntheticAnalysis()
    let pool = phasedPool()
    let plan = try planner(hitSync: .strong).plan(analysis: analysis, pool: pool, seed: 3)

    var aligned = 0
    var counted = 0
    for cut in plan.cuts.dropFirst() where cut.timelineStart > 1 {
      guard let profile = pool.first(where: { $0.videoID == cut.videoID }) else { continue }
      let index = Int((cut.sourceStart / profile.hop).rounded())
      let nearStart = (max(0, index - 1)...min(profile.impacts.count - 1, index + 1)).map { profile.impacts[$0] }.max() ?? 0
      counted += 1
      if nearStart >= 0.99 { aligned += 1 }
    }
    #expect(counted >= 20)
    #expect(Double(aligned) / Double(counted) >= 0.9, "頭に衝撃が来たカット \(aligned)/\(counted)")
  }

  @Test
  func hitSyncDoesNotOverrideAClearMotionLevelMismatch() throws {
    // 動きの強さが大きく違う素材(0.05)に、拍の合った衝撃があっても、盛り上がり(0.9)の曲には、動きの大きな素材(0.9)を選ぶ。
    let analysis = syntheticAnalysis(intensity: .intense, energy: 0.9)
    let quietAligned = (0..<3).map { _ in periodicImpactProfile(phase: 0, motion: 0.05) }
    let busyOffbeat = (0..<3).map { _ in periodicImpactProfile(phase: 0.25, motion: 0.9) }
    let pool = quietAligned + busyOffbeat
    let busyIDs = Set(busyOffbeat.map(\.videoID))

    let plan = try planner(hitSync: .standard, motion: .strong).plan(analysis: analysis, pool: pool, seed: 1)
    let busyCuts = plan.cuts.filter { busyIDs.contains($0.videoID) }.count
    #expect(Double(busyCuts) / Double(plan.cuts.count) >= 0.9, "動きの大きい素材のカット \(busyCuts)/\(plan.cuts.count)")
  }

  @Test
  func withoutOnsetInformationThePlannerFallsBackToTheMotionLevel() throws {
    // 簡易な解析(onset の細かい情報なし)では、拍と衝撃の一致は使わず、動きの強さだけで選ぶ(以前と同じ動作)。
    var analysis = syntheticAnalysis(intensity: .intense, energy: 0.9)
    analysis.onsetEnvelope = []
    let calm = (0..<3).map { _ in periodicImpactProfile(phase: 0, motion: 0.1) }
    let busy = (0..<3).map { _ in periodicImpactProfile(phase: 0.25, motion: 0.9) }
    let busyIDs = Set(busy.map(\.videoID))

    let plan = try planner(hitSync: .strong, motion: .strong).plan(analysis: analysis, pool: calm + busy, seed: 2)
    let busyCuts = plan.cuts.filter { busyIDs.contains($0.videoID) }.count
    #expect(Double(busyCuts) / Double(plan.cuts.count) >= 0.95)
  }

  @Test
  func hitSyncKeepsThePlanDeterministicPerSeedButVariedAcrossSeeds() throws {
    let analysis = syntheticAnalysis()
    let pool = phasedPool()
    let strong = planner(hitSync: .strong)
    let first = try strong.plan(analysis: analysis, pool: pool, seed: 7)
    let again = try strong.plan(analysis: analysis, pool: pool, seed: 7)
    let other = try strong.plan(analysis: analysis, pool: pool, seed: 8)
    #expect(first == again)
    #expect(first != other)   // 同点の候補が多いので、種が違えば、別のカット割りになる
  }

  @Test
  func replacingACutKeepsTheImpactAlignment() throws {
    let analysis = syntheticAnalysis()
    let pool = phasedPool()
    let strong = planner(hitSync: .strong)
    let plan = try strong.plan(analysis: analysis, pool: pool, seed: 5)

    var current = plan
    for index in [3, 7, 11, 15] {
      current = try strong.replaceCut(at: index, in: current, analysis: analysis, pool: pool, seed: 21)
    }
    let metrics = MusicVideoSyncMetrics(plan: current, analysis: analysis, pool: pool)
    #expect((metrics.hitAlignment ?? 0) >= 0.9)
    // 差し替えても、カットの枠は同じ。
    #expect(current.cuts.map(\.timelineStart) == plan.cuts.map(\.timelineStart))
  }

  // MARK: 動きの強さの相関

  @Test
  func motionLevelMatchingFollowsTheMusicEnergy() throws {
    // 前半は静か(0.1)、後半は盛り上がり(0.9)の曲。素材は動きの少ないものと大きいものが半々。
    var analysis = syntheticAnalysis(duration: 40)
    analysis.energy = (0..<400).map { $0 < 200 ? 0.1 : 0.9 }
    analysis.intensity = (0..<400).map { $0 < 200 ? .calm : .intense }
    let calmVideos = (0..<4).map { _ in periodicImpactProfile(phase: 0, motion: 0.1) }
    let busyVideos = (0..<4).map { _ in periodicImpactProfile(phase: 0, motion: 0.9) }
    let pool = calmVideos + busyVideos

    func correlation(_ planner: CutPlanner) throws -> Double {
      var total = 0.0
      for seed in 1...3 as ClosedRange<UInt64> {
        let plan = try planner.plan(analysis: analysis, pool: pool, seed: seed)
        total += try #require(MusicVideoSyncMetrics(plan: plan, analysis: analysis, pool: pool).energyCorrelation)
      }
      return total / 3
    }
    let strong = try correlation(planner(hitSync: .off, motion: .strong))
    let off = try correlation(planner(hitSync: .off, motion: .off))
    #expect(strong >= 0.9, "動きを強く合わせる \(strong)")
    #expect(strong > off + 0.3, "強く合わせる \(strong) 合わせない \(off)")
  }

  // MARK: 曲の構造・小節の頭に合わせたカットの位置

  @Test
  func cutsBreakAtTheSectionBoundariesOfTheSong() throws {
    // 控えめ(静かな所は8拍=4秒)のとき、4秒の格子に載らない 11 秒と 22 秒に、曲の構造の境目がある。
    var withSections = syntheticAnalysis(duration: 40, intensity: .calm, energy: 0.1)
    withSections.sectionBoundaries = [11, 22]
    var without = withSections
    without.sectionBoundaries = []
    let pool = phasedPool()
    let relaxed = planner(hitSync: .off, style: .relaxed)

    func starts(_ analysis: MusicAnalysis) throws -> [Double] {
      try relaxed.plan(analysis: analysis, pool: pool, seed: 1).cuts.map(\.timelineStart)
    }
    let withStarts = try starts(withSections)
    let withoutStarts = try starts(without)
    #expect(withStarts.contains { abs($0 - 11) < 1e-9 }, "境目 11 秒でカットが替わる \(withStarts.prefix(8))")
    #expect(withStarts.contains { abs($0 - 22) < 1e-9 }, "境目 22 秒でカットが替わる")
    #expect(!withoutStarts.contains { abs($0 - 11) < 1e-9 }, "境目が無ければ、11 秒は格子の外")
  }

  @Test
  func barAlignedCutsFollowTheDetectedBarStart() throws {
    // 静かな所は4拍(=1小節)ごと。小節の頭が拍の添字 0 のとき、2 のときで、カットの位置が変わる。
    func startsOnBeat(phase: Int) throws -> [Int] {
      var analysis = syntheticAnalysis(duration: 40, intensity: .calm, energy: 0.1)
      analysis.downbeatPhase = phase
      let plan = try planner(hitSync: .off).plan(analysis: analysis, pool: phasedPool(), seed: 1)
      // 最初の導入部のカットを除き、各カットの頭の拍の添字(拍は 0.5 秒ごと、添字 0 が 0.5 秒)。
      return plan.cuts.dropFirst().map { Int(($0.timelineStart / 0.5).rounded()) - 1 }
    }
    let zero = try startsOnBeat(phase: 0)
    let two = try startsOnBeat(phase: 2)

    #expect(zero.dropFirst().allSatisfy { $0 % 4 == 0 }, "小節の頭が 0: \(zero.prefix(6))")
    #expect(two.dropFirst().allSatisfy { $0 % 4 == 2 }, "小節の頭が 2: \(two.prefix(6))")
    #expect(zero != two)
  }

  // MARK: 部品

  @Test
  func correlationMatchesANaiveCalculation() {
    var generator = SeededGenerator(seed: 4)
    let signal = (0..<120).map { _ in Double.random(in: 0..<1, using: &generator) }
    let kernel = (0..<9).map { _ in Double.random(in: 0..<1, using: &generator) }
    let positions = signal.count - kernel.count + 1

    let fast = CutPlanner.correlate(signal, kernel: kernel, positions: positions)
    #expect(fast.count == positions)
    for index in 0..<positions {
      var expected = 0.0
      for offset in 0..<kernel.count { expected += signal[index + offset] * kernel[offset] }
      #expect(abs(fast[index] - expected) < 1e-9, "位置 \(index)")
    }
    // 信号が短すぎるときは、落ちずに 0 を返す。
    #expect(CutPlanner.correlate([1, 2], kernel: kernel, positions: 3) == [0, 0, 0])
  }

  @Test
  func impactsMarkWhereTheMotionJumpsUp() throws {
    // 動きが一定 → 4つ目で急に増える → また一定。
    let values = [0.1, 0.1, 0.1, 0.1, 0.9, 0.9, 0.9, 0.9, 0.9]
    let impacts = ClipPoolBuilder.rawImpacts(from: values)
    #expect(impacts.count == values.count)
    let peak = try #require(impacts.indices.max { impacts[$0] < impacts[$1] })
    #expect((4...5).contains(peak))                      // 増えた位置(にじませた隣を含む)が、いちばん高い
    #expect(impacts[0] == 0 && impacts[1] == 0)          // 一定の間は 0
    #expect(impacts[8] == 0)                             // 増えたあとの一定は、衝撃ではない
    #expect(ClipPoolBuilder.rawImpacts(from: []).isEmpty)
    // 減るだけの動きは、衝撃ではない。
    #expect(ClipPoolBuilder.rawImpacts(from: [0.9, 0.9, 0.1, 0.1]).allSatisfy { $0 < 1e-12 })
  }

  @Test
  func impactsAreNormalizedAcrossTheWholePool() {
    let calm = RawMotionWindow(offset: 0, duration: 5, hop: 0.5, values: [Double](repeating: 0.2, count: 10))
    var jumpy = [Double](repeating: 0.2, count: 10)
    jumpy[5] = 2.0
    let busy = RawMotionWindow(offset: 0, duration: 5, hop: 0.5, values: jumpy)
    let a = ClipPoolSource(videoID: UUID(), url: URL(fileURLWithPath: "/dev/null"), duration: 5)
    let b = ClipPoolSource(videoID: UUID(), url: URL(fileURLWithPath: "/dev/null"), duration: 5)

    let profiles = ClipPoolBuilder.normalizedProfiles(from: [(a, [calm]), (b, [busy])])
    let calmProfile = profiles[0], busyProfile = profiles[1]
    #expect(calmProfile.impacts.count == calmProfile.values.count)
    #expect(calmProfile.impacts.allSatisfy { $0 == 0 })                 // 一定の素材には衝撃が無い
    #expect(busyProfile.impacts.contains { $0 > 0.4 })                  // 急に動く素材には、はっきり出る
    #expect(busyProfile.impacts.allSatisfy { $0 >= 0 && $0 <= 1 })
  }

  @Test
  func profilesWithoutImpactsStillDecodeAndMismatchedImpactsAreIgnored() throws {
    let id = UUID()
    let legacy = #"{"videoID":"\#(id.uuidString)","offset":3,"duration":10,"hop":0.25,"values":[0.1,0.2,0.3]}"#
    let decoded = try JSONDecoder().decode(SourceMotionProfile.self, from: Data(legacy.utf8))
    #expect(decoded.values == [0.1, 0.2, 0.3])
    #expect(decoded.impacts.isEmpty)

    // 長さが合わない衝撃は、位置がずれるので使わない。
    let mismatched = SourceMotionProfile(videoID: id, duration: 1, hop: 0.25, values: [0, 0, 0, 0], impacts: [1, 0])
    #expect(mismatched.impacts.isEmpty)

    // 保存→読み込みで、衝撃も残る。
    let original = SourceMotionProfile(videoID: id, duration: 1, hop: 0.25, values: [0, 0.5, 0, 0], impacts: [0, 1, 0, 0])
    let restored = try JSONDecoder().decode(SourceMotionProfile.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
  }

  @Test
  func syncMetricsFollowTheFootageOntoTheTimeline() {
    // 素材 A の 10 秒目に、衝撃が1つ。カットは、曲の 2 秒から 4 秒に、素材の 9 秒から 11 秒を置く。
    // 曲の 3 秒(強い拍)に映る素材の時刻は 10 秒で、衝撃と一致する。曲の 2 秒(強い拍)に映るのは 9 秒で、衝撃は無い。
    let id = UUID()
    let hop = 0.25
    var impacts = [Double](repeating: 0, count: 80)
    impacts[40] = 1                                  // 10 秒
    let profile = SourceMotionProfile(videoID: id, duration: 20, hop: hop, values: [Double](repeating: 0.5, count: 80), impacts: impacts)
    let plan = CutPlan(
      cuts: [PlannedCut(videoID: id, sourceStart: 9, duration: 2, timelineStart: 2, intensity: .medium)],
      duration: 4
    )
    var analysis = MusicAnalysis(
      duration: 4, tempo: 60, beats: [2.0, 3.0], energy: [0.5], intensity: [.medium], energyHop: 4
    )
    analysis.beatAccents = [1.0, 1.0]

    let metrics = MusicVideoSyncMetrics(plan: plan, analysis: analysis, pool: [profile])
    #expect(metrics.strongBeatCount == 2)
    #expect(metrics.hitAlignment == 0.5)             // 2つの強い拍のうち、1つだけ衝撃が重なる

    // 弱い拍は数えない。
    analysis.beatAccents = [0.2, 1.0]
    let weakFirst = MusicVideoSyncMetrics(plan: plan, analysis: analysis, pool: [profile])
    #expect(weakFirst.strongBeatCount == 1)
    #expect(weakFirst.hitAlignment == 1.0)

    // 衝撃の情報が無い素材では、調べられない(nil)。
    let blind = SourceMotionProfile(videoID: id, duration: 20, hop: hop, values: [Double](repeating: 0.5, count: 80))
    #expect(MusicVideoSyncMetrics(plan: plan, analysis: analysis, pool: [blind]).hitAlignment == nil)
  }

  @Test
  func pearsonCorrelationHandlesTheEdgeCases() {
    let x = (0..<20).map(Double.init)
    #expect(abs((MusicVideoSyncMetrics.pearson(x, x) ?? 0) - 1) < 1e-9)
    #expect(abs((MusicVideoSyncMetrics.pearson(x, x.map { -$0 }) ?? 0) + 1) < 1e-9)
    #expect(MusicVideoSyncMetrics.pearson(x, [Double](repeating: 1, count: 20)) == nil)   // 一定
    #expect(MusicVideoSyncMetrics.pearson([1, 2, 3], [1, 2, 3]) == nil)                   // 標本が少ない
  }

  @Test
  func oldCutTuningWithoutHitSyncDecodesWithTheDefault() throws {
    let legacy = #"{"minimumCutDuration":1,"motionMatching":"strong","variety":"wide","alignment":"free"}"#
    let decoded = try JSONDecoder().decode(MusicVideoCutTuning.self, from: Data(legacy.utf8))
    #expect(decoded.minimumCutDuration == 1)
    #expect(decoded.motionMatching == .strong)
    #expect(decoded.variety == .wide)
    #expect(decoded.alignment == .free)
    #expect(decoded.hitSync == .strong)               // 無い項目は既定値(いちばん強く合わせる)
    #expect(decoded.maximumCutDuration == nil)
  }

  // MARK: 速さ

  @Test
  func planningAFullSongFromAHugePoolStaysFast() throws {
    // 4分13秒・129BPM、素材は 66 本 × 6 窓(15 秒、1秒に12回)。拍ごとに素材のすべての位置を採点しても、数秒で終わる。
    let duration = 253.0
    let interval = 60.0 / 129
    let beats = stride(from: interval, to: duration - 0.1, by: interval).map { $0 }
    var analysis = MusicAnalysis(
      duration: duration, tempo: 129, beats: beats,
      energy: (0..<2530).map { 0.5 + 0.4 * sin(Double($0) / 80) },
      intensity: [MusicIntensity](repeating: .medium, count: 2530), energyHop: 0.1
    )
    analysis.beatAccents = beats.indices.map { $0 % 4 == 0 ? 1.0 : 0.4 }
    var envelope = [Double](repeating: 0, count: Int(duration / 0.05) + 2)
    for (index, time) in beats.enumerated() { envelope[Int((time / 0.05).rounded())] = analysis.beatAccents[index] }
    analysis.onsetEnvelope = envelope

    var generator = SeededGenerator(seed: 11)
    let hop = Self.videoHop
    let pool: [SourceMotionProfile] = (0..<(66 * 6)).map { index in
      let count = Int(15 / hop)
      let values = (0..<count).map { _ in Double.random(in: 0...1, using: &generator) }
      let impacts = (0..<count).map { _ in Double.random(in: 0...1, using: &generator) > 0.9 ? 1.0 : 0.0 }
      return SourceMotionProfile(videoID: UUID(), offset: Double(index % 6) * 20, duration: 15, hop: hop, values: values, impacts: impacts)
    }

    let started = Date()
    let plan = try planner(hitSync: .strong, motion: .strong, style: .energetic).plan(analysis: analysis, pool: pool, seed: 1)
    let elapsed = Date().timeIntervalSince(started)

    #expect(plan.cuts.count > 100)
    #expect(elapsed < 30, "かかった時間 \(elapsed) 秒(カット \(plan.cuts.count))")
    print("INFO planning time \(String(format: "%.2f", elapsed)) s for \(plan.cuts.count) cuts from \(pool.count) windows")
  }
}
