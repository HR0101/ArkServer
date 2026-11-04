// ArkServer/Features/MusicVideo/Views/MusicVideoTuningSections.swift

import SwiftUI

/// 「カット割り」「見た目と音」「書き出し」の調整項目。
///
/// 映像ができているときは、項目を変えると、すぐにプレビューとタイムラインが変わる(乱数の種は変えないので、
/// 変えた項目だけの違いが出る)。各項目の説明には、いまの曲での秒数や、いまのカット割りの結果を数値で添える。
struct MusicVideoTuningSections: View {
  @ObservedObject var viewModel: MusicVideoViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      cutSection
      lookSection
      exportSection
    }
  }

  // MARK: - カット割り

  private var cutSection: some View {
    SettingsSection(
      title: "カット割り",
      footer: viewModel.plan == nil
        ? "映像を作ると、ここを変えるたびにプレビューが変わります．"
        : "変えるとすぐに映像へ反映されます．気に入らなければ「元に戻す」で戻せます．"
    ) {
      SettingsGroup {
        SettingsRow(title: "カットの細かさ", detail: cutStyleDetail) {
          FlatSegmentedControl(
            options: MusicVideoCutStyle.allCases,
            title: \.displayName,
            selection: $viewModel.cutStyle,
            width: 210
          )
        }
        SettingsRow(title: "最短のカット", detail: minimumDetail) {
          Picker("最短のカット", selection: minimumBinding) {
            ForEach(MusicVideoCutTuning.minimumChoices, id: \.self) { value in
              Text(Self.seconds(value)).tag(value)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "最長のカット", detail: maximumDetail) {
          Picker("最長のカット", selection: maximumBinding) {
            Text("制限なし").tag(Double?.none)
            ForEach(MusicVideoCutTuning.maximumChoices, id: \.self) { value in
              Text(Self.seconds(value)).tag(Double?.some(value))
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "動きの合わせ方", detail: motionDetail) {
          FlatSegmentedControl(
            options: MotionMatching.allCases,
            title: \.displayName,
            selection: $viewModel.cutTuning.motionMatching,
            width: 300
          )
        }
        SettingsRow(title: "拍への合わせ込み", detail: hitSyncDetail) {
          FlatSegmentedControl(
            options: HitSync.allCases,
            title: \.displayName,
            selection: $viewModel.cutTuning.hitSync,
            width: 240
          )
        }
        SettingsRow(title: "動画のばらけ具合", detail: varietyDetail) {
          Picker("動画のばらけ具合", selection: $viewModel.cutTuning.variety) {
            ForEach(VideoVariety.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "切り替えのタイミング", detail: viewModel.cutTuning.alignment.summary) {
          Picker("切り替えのタイミング", selection: $viewModel.cutTuning.alignment) {
            ForEach(CutAlignment.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      .disabled(viewModel.isWorking)
    }
  }

  private var minimumBinding: Binding<Double> {
    Binding(
      get: { viewModel.cutTuning.minimumCutDuration },
      set: { viewModel.cutTuning.setMinimum($0) }
    )
  }

  private var maximumBinding: Binding<Double?> {
    Binding(
      get: { viewModel.cutTuning.maximumCutDuration },
      set: { viewModel.cutTuning.setMaximum($0) }
    )
  }

  /// この曲のテンポでの、盛り上がりの段階ごとのカットの長さ。最短・最長・細かさを変えると、数値も変わる。
  private var cutStyleDetail: String {
    let base = "静かな所は長く，盛り上がる所は細かく切り替えます．"
    guard let tempo = viewModel.fullAnalysis?.tempo, tempo > 0 else { return base }
    let interval = 60 / tempo
    let planner = CutPlanner(style: viewModel.cutStyle, tuning: viewModel.cutTuning)
    func seconds(_ intensity: MusicIntensity) -> String {
      Self.seconds(Double(planner.effectiveBeats(for: intensity, beatInterval: interval)) * interval)
    }
    return base + "\nこの曲（\(Int(tempo.rounded())) BPM）では、静かな所は約\(seconds(.calm))、中は約\(seconds(.medium))、盛り上がる所は約\(seconds(.intense))ごとです．"
  }

  private var minimumDetail: String {
    var text = "これより短いカットは作りません．速い曲で切り替えが忙しすぎるときに上げます．"
    if let stats = viewModel.planStats { text += "\nいまの最短: \(Self.seconds(stats.shortestCutDuration))" }
    return text
  }

  private var maximumDetail: String {
    var text = "これより長いカットは作りません．静かな所で1カットが長すぎるときに下げます．"
    if let stats = viewModel.planStats { text += "\nいまの最長: \(Self.seconds(stats.longestCutDuration))" }
    return text
  }

  private var motionDetail: String {
    var text = viewModel.cutTuning.motionMatching.summary
    if let match = viewModel.planStats?.motionMatch { text += "\nいまの動きの一致度: \(MusicVideoChangeSummary.percent(match))" }
    return text
  }

  private var hitSyncDetail: String {
    var text = viewModel.cutTuning.hitSync.summary
    if let stats = viewModel.planStats {
      if let hit = stats.hitAlignment { text += "\nいま: 強い拍のうち\(MusicVideoChangeSummary.percent(hit))で、映像の大きな動きが重なっています" }
      if let correlation = stats.energyCorrelation { text += "\n盛り上がりと映像の動きの相関: \(String(format: "%.2f", correlation))" }
    }
    return text
  }

  private var varietyDetail: String {
    var text = viewModel.cutTuning.variety.summary
    if let stats = viewModel.planStats {
      text += "\nいま: 素材\(stats.poolVideoCount)本のうち\(stats.usedVideoCount)本を使用"
    }
    return text
  }

  // MARK: - 見た目と音

  private var lookSection: some View {
    SettingsSection(title: "見た目と音") {
      SettingsGroup {
        SettingsRow(title: "画面サイズ", detail: renderDetail) {
          Picker("画面サイズ", selection: $viewModel.renderPreset) {
            ForEach(MusicVideoRenderPreset.allCases, id: \.self) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "画面の合わせ方", detail: viewModel.lookTuning.fitMode.summary) {
          FlatSegmentedControl(
            options: MusicVideoFitMode.allCases,
            title: \.displayName,
            selection: $viewModel.lookTuning.fitMode,
            width: 230
          )
        }
        SettingsRow(title: "切り替え効果", detail: viewModel.lookTuning.transition.summary) {
          FlatSegmentedControl(
            options: MusicVideoTransition.allCases,
            title: \.displayName,
            selection: $viewModel.lookTuning.transition,
            width: 300
          )
        }
        SettingsRow(title: "最初と最後のフェード", detail: fadeDetail) {
          Picker("最初と最後のフェード", selection: $viewModel.lookTuning.fadeSeconds) {
            ForEach(MusicVideoLookTuning.fadeChoices, id: \.self) { value in
              Text(value == 0 ? "なし" : Self.seconds(value)).tag(value)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      .disabled(viewModel.isWorking)
    }
  }

  private var renderDetail: String {
    let size = viewModel.renderPreset.settings
    var text = "完成映像の大きさです．いま \(size.width)×\(size.height)．"
    if viewModel.renderPreset.isPortrait {
      text += "\n縦向きは一時的な選択です．アプリを開き直すと、横に戻ります．"
    }
    return text
  }

  private var fadeDetail: String {
    let seconds = viewModel.lookTuning.fadeSeconds
    if seconds == 0 { return "フェードしません．最初から最後まで、そのままの明るさと音量です．" }
    return "映像は黒から、音は無音から\(Self.seconds(seconds))かけて出て、最後も同じように消えます．この間、切り替え効果は付きません．"
  }

  // MARK: - 書き出し

  private var exportSection: some View {
    SettingsSection(title: "書き出し") {
      SettingsGroup {
        SettingsRow(title: "書き出しの画質", detail: exportSizeText) {
          Picker("書き出しの画質", selection: $viewModel.exportQuality) {
            ForEach(MusicVideoExportQuality.allCases, id: \.self) { quality in
              Text(quality.displayName).tag(quality)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      .disabled(viewModel.isWorking)
    }
  }

  /// 選んだ画質での、ファイルサイズの目安。映像にする長さが分かっていれば、全体の大きさも出す。
  private var exportSizeText: String {
    let render = viewModel.renderPreset.settings
    let perMinute = viewModel.exportQuality.estimatedMegabytesPerMinute(for: render)
    var text = "1分あたり約\(Int(perMinute.rounded()))MB"
    if let duration = viewModel.targetDuration {
      text += "・この映像で約\(Int((perMinute * duration / 60).rounded()))MB"
    }
    return text
  }

  static func seconds(_ value: Double) -> String {
    MusicVideoChangeSummary.seconds(value)
  }
}

// MARK: - いまの結果

/// プレビューの下に出す、いまのカット割りの結果。調整項目を変えるたびに数値が変わる。
struct MusicVideoResultSummary: View {
  @ObservedObject var viewModel: MusicVideoViewModel

  var body: some View {
    if let stats = viewModel.planStats {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(line(for: stats))
            .font(.appCaptionStrong)
            .foregroundStyle(NeomorphicTheme.ink)
            .lineLimit(2)
          if viewModel.isApplyingEdit { ProgressView().controlSize(.small) }
        }
        if let note = viewModel.lastChangeNote {
          Text(note)
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    }
  }

  private func line(for stats: MusicVideoPlanStats) -> String {
    var parts = [
      "\(stats.cutCount)カット",
      "平均\(MusicVideoChangeSummary.seconds(stats.averageCutDuration))（\(MusicVideoChangeSummary.seconds(stats.shortestCutDuration))〜\(MusicVideoChangeSummary.seconds(stats.longestCutDuration))）",
      "動画\(stats.usedVideoCount)/\(stats.poolVideoCount)本を使用"
    ]
    if let match = stats.motionMatch { parts.append("動きの一致\(MusicVideoChangeSummary.percent(match))") }
    if let hit = stats.hitAlignment { parts.append("拍の一致\(MusicVideoChangeSummary.percent(hit))") }
    return parts.joined(separator: "・")
  }
}

// MARK: - 曲の範囲

/// 曲のうち、映像にする範囲の開始と終了を選ぶ。開始は曲の拍にそろう。
struct MusicRangeControl: View {
  @ObservedObject var viewModel: MusicVideoViewModel

  var body: some View {
    if let duration = viewModel.fullAnalysis?.duration, duration > MusicRange.minimumLength {
      let range = viewModel.musicRange
      let start = range?.start ?? 0
      let end = range?.end ?? duration
      SettingsRow(title: "使う範囲", detail: detail(start: start, end: end, duration: duration, isPartial: range != nil)) {
        VStack(alignment: .trailing, spacing: 6) {
          sliderRow(label: "開始", value: start, bounds: 0...(duration - MusicRange.minimumLength)) {
            viewModel.setMusicRange(start: $0, end: max(end, $0 + MusicRange.minimumLength))
          }
          sliderRow(label: "終了", value: end, bounds: MusicRange.minimumLength...duration) {
            viewModel.setMusicRange(start: min(start, $0 - MusicRange.minimumLength), end: $0)
          }
          if range != nil {
            Button("全体に戻す") { viewModel.setMusicRange(start: 0, end: duration) }
              .buttonStyle(.quiet)
          }
        }
        .disabled(viewModel.isWorking)
      }
    }
  }

  private func sliderRow(
    label: String,
    value: Double,
    bounds: ClosedRange<Double>,
    onChange: @escaping (Double) -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.appMicro)
        .foregroundStyle(NeomorphicTheme.muted)
      Slider(value: Binding(get: { value }, set: onChange), in: bounds)
        .frame(width: 170)
      Text(Self.clock(value))
        .font(.appCaption.monospacedDigit())
        .foregroundStyle(NeomorphicTheme.muted)
        .frame(width: 40, alignment: .trailing)
    }
  }

  private func detail(start: Double, end: Double, duration: Double, isPartial: Bool) -> String {
    guard isPartial else { return "曲の全体（\(Self.clock(duration))）を使います．サビだけの短い映像にしたいときは、範囲を狭めます．" }
    return "曲の\(Self.clock(start))から\(Self.clock(end))までの\(Int((end - start).rounded()))秒を映像にします．開始は拍にそろえます．"
  }

  static func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
