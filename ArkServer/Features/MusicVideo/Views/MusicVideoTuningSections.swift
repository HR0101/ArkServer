// ArkServer/Features/MusicVideo/Views/MusicVideoTuningSections.swift

import SwiftUI

/// 表示する操作のまとまり。映像を作るための設定値は持たない。
enum MusicVideoInspectorPane: String, CaseIterable, Identifiable {
  case inputs = "曲と素材"
  case rhythm = "リズム"
  case finish = "仕上げ"

  var id: String { rawValue }
}

/// 「カット割り」「見た目と音」「書き出し」の調整項目。
///
/// 映像ができているときは、項目を変えると、すぐにプレビューとタイムラインが変わる(乱数の種は変えないので、
/// 変えた項目だけの違いが出る)。各項目の説明には、いまの曲での秒数や、いまのカット割りの結果を数値で添える。
struct MusicVideoTuningSections: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  let pane: MusicVideoInspectorPane

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      switch pane {
      case .inputs:
        EmptyView()
      case .rhythm:
        cutSection
      case .finish:
        lookSection
        exportSection
      }
    }
    .disabled(viewModel.isWorking)
  }

  // MARK: - カット割り

  private var cutSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      MusicVideoParameterBar(
        title: "カットの細かさ", options: MusicVideoCutStyle.allCases,
        valueLabel: \.displayName, selection: $viewModel.cutStyle, detail: cutStyleDetail
      )
      MusicVideoParameterBar(
        title: "動きの合わせ方", options: MotionMatching.allCases,
        valueLabel: \.displayName, selection: $viewModel.cutTuning.motionMatching, detail: motionDetail
      )
      MusicVideoParameterBar(
        title: "拍への合わせ込み", options: HitSync.allCases,
        valueLabel: \.displayName, selection: $viewModel.cutTuning.hitSync, detail: hitSyncDetail
      )
      MusicVideoParameterBar(
        title: "動画のばらけ具合", options: Array(VideoVariety.allCases.reversed()),
        valueLabel: \.displayName, selection: $viewModel.cutTuning.variety, detail: varietyDetail
      )

      MusicVideoFoldout(title: "カットの長さとタイミング", summary: cutLengthSummary) {
        MusicVideoParameterBar(
          title: "最短のカット", options: MusicVideoCutTuning.minimumChoices,
          valueLabel: Self.seconds, selection: minimumBinding, detail: minimumDetail
        )
        MusicVideoParameterBar(
          title: "最長のカット", options: MusicVideoCutTuning.maximumChoices.map { Double?.some($0) } + [Double?.none],
          valueLabel: { $0.map(Self.seconds) ?? "制限なし" },
          selection: maximumBinding, detail: maximumDetail
        )
        MusicVideoField(title: "切り替えのタイミング", detail: viewModel.cutTuning.alignment.summary) {
          MusicVideoChoices(options: CutAlignment.allCases, title: \.displayName, selection: $viewModel.cutTuning.alignment, minimumWidth: 120)
        }
      }

      Text(viewModel.plan == nil ? "映像を作ったあとも，ここで調整できます" : "変更はプレビューへ反映されます．カットの編集から元に戻せます")
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
    }
  }

  private var cutLengthSummary: String {
    "\(Self.seconds(viewModel.cutTuning.minimumCutDuration))〜\(viewModel.cutTuning.maximumCutDuration.map(Self.seconds) ?? "上限なし")"
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
    VStack(alignment: .leading, spacing: 24) {
      MusicVideoField(title: "画面サイズ", detail: renderDetail) {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(MusicVideoRenderPreset.allCases, id: \.self) { preset in
            MusicVideoChoiceButton(
              title: preset.displayName,
              isSelected: viewModel.renderPreset == preset,
              frameAspect: preset.isPortrait ? 9.0 / 16 : 16.0 / 9
            ) { viewModel.renderPreset = preset }
          }
        }
      }
      MusicVideoField(title: "画面の合わせ方", detail: viewModel.lookTuning.fitMode.summary) {
        MusicVideoChoices(options: MusicVideoFitMode.allCases, title: \.displayName, selection: $viewModel.lookTuning.fitMode, minimumWidth: 120)
      }
      MusicVideoField(title: "切り替え効果", detail: viewModel.lookTuning.transition.summary) {
        MusicVideoChoices(options: MusicVideoTransition.allCases, title: \.displayName, selection: $viewModel.lookTuning.transition, minimumWidth: 100)
      }
      MusicVideoFoldout(title: "映像と音のフェード", summary: viewModel.lookTuning.fadeSeconds == 0 ? "なし" : Self.seconds(viewModel.lookTuning.fadeSeconds)) {
        MusicVideoParameterBar(
          title: "最初と最後のフェード", options: MusicVideoLookTuning.fadeChoices,
          valueLabel: { $0 == 0 ? "なし" : Self.seconds($0) }, selection: $viewModel.lookTuning.fadeSeconds, detail: fadeDetail
        )
      }
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
    MusicVideoParameterBar(
      title: "書き出しの画質", options: Array(MusicVideoExportQuality.allCases.reversed()),
      valueLabel: \.displayName, selection: $viewModel.exportQuality, detail: exportSizeText
    )
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

// MARK: - ミュージックビデオ画面の操作部品

/// 既存の選択肢を順に並べた段階式のバー。中間の値は作らない。
struct MusicVideoParameterBar<Option: Hashable>: View {
  let title: String
  let options: [Option]
  let valueLabel: (Option) -> String
  @Binding var selection: Option
  var detail: String? = nil

  private var indexBinding: Binding<Double> {
    Binding(
      get: { Double(options.firstIndex(of: selection) ?? 0) },
      set: { value in
        guard value.isFinite, !options.isEmpty else { return }
        let index = min(max(Int(value.rounded()), 0), options.count - 1)
        if selection != options[index] { selection = options[index] }
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
          .font(.appBodyStrong)
          .foregroundStyle(NeomorphicTheme.ink)
        Spacer(minLength: 0)
        Text(valueLabel(selection))
          .font(.appMonoCaption)
          .foregroundStyle(NeomorphicTheme.ink)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 4))
          .accessibilityHidden(true)
      }

      MusicVideoParameterTrack(
        title: title,
        valueText: valueLabel(selection),
        value: indexBinding,
        bounds: 0...Double(max(1, options.count - 1)),
        snapStep: 1,
        tickCount: options.count
      )
      .disabled(options.count < 2)

      HStack(spacing: 12) {
        Text(options.first.map(valueLabel) ?? "")
        Spacer(minLength: 0)
        Text(options.last.map(valueLabel) ?? "")
      }
      .font(.appMicro)
      .foregroundStyle(NeomorphicTheme.muted)
      .accessibilityHidden(true)

      if let detail {
        Text(detail)
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 細いトラック・目盛り・縦長のつまみで描く，画面専用のパラメーターバー。
/// ドラッグ，矢印キー，VoiceOverの値調整を同じ更新処理へ渡す。
struct MusicVideoParameterTrack: View {
  let title: String
  let valueText: String
  @Binding var value: Double
  let bounds: ClosedRange<Double>
  var snapStep: Double? = nil
  var tickCount = 0
  var keyboardStep: Double = 1

  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool

  private static var thumbWidth: CGFloat { 8 }
  private static var thumbHeight: CGFloat { 20 }
  private static var thumbInset: CGFloat { 8 }
  private static var trackHeight: CGFloat { 4 }
  private static var controlHeight: CGFloat { 32 }

  private var fraction: Double {
    let span = bounds.upperBound - bounds.lowerBound
    guard span > 0, value.isFinite else { return 0 }
    return min(1, max(0, (value - bounds.lowerBound) / span))
  }

  var body: some View {
    GeometryReader { geometry in
      let usableWidth = max(0, geometry.size.width - Self.thumbInset * 2)
      let thumbX = Self.thumbInset + usableWidth * fraction
      ZStack(alignment: .leading) {
        Capsule()
          .fill(NeomorphicTheme.controlSelected)
          .frame(height: Self.trackHeight)
          .padding(.horizontal, Self.thumbInset)
        Capsule()
          .fill(NeomorphicTheme.accent)
          .frame(width: usableWidth * fraction, height: Self.trackHeight)
          .offset(x: Self.thumbInset)

        if tickCount > 1 {
          ForEach(0..<tickCount, id: \.self) { index in
            Rectangle()
              .fill(NeomorphicTheme.muted.opacity(0.6))
              .frame(width: 1, height: 8)
              .position(
                x: Self.thumbInset + usableWidth * Double(index) / Double(tickCount - 1),
                y: geometry.size.height / 2
              )
          }
        }

        RoundedRectangle(cornerRadius: 2)
          .fill(NeomorphicTheme.ink)
          .frame(width: Self.thumbWidth, height: Self.thumbHeight)
          .overlay {
            RoundedRectangle(cornerRadius: 2)
              .strokeBorder(NeomorphicTheme.canvas.opacity(0.4), lineWidth: 1)
          }
          .position(x: thumbX, y: geometry.size.height / 2)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            guard usableWidth > 0 else { return }
            let progress = min(1, max(0, (gesture.location.x - Self.thumbInset) / usableWidth))
            setValue(bounds.lowerBound + progress * (bounds.upperBound - bounds.lowerBound))
          }
      )
    }
    .frame(height: Self.controlHeight)
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(isFocused ? NeomorphicTheme.accent : .clear, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .opacity(isEnabled ? 1 : 0.4)
    .focusable(isEnabled)
    .focused($isFocused)
    .onKeyPress(.leftArrow) { adjust(by: -keyboardStep) }
    .onKeyPress(.rightArrow) { adjust(by: keyboardStep) }
    .onKeyPress(.downArrow) { adjust(by: -keyboardStep) }
    .onKeyPress(.upArrow) { adjust(by: keyboardStep) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(valueText)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: setValue(value + keyboardStep)
      case .decrement: setValue(value - keyboardStep)
      @unknown default: break
      }
    }
  }

  private func adjust(by amount: Double) -> KeyPress.Result {
    guard isEnabled else { return .ignored }
    setValue(value + amount)
    return .handled
  }

  private func setValue(_ proposedValue: Double) {
    guard isEnabled, proposedValue.isFinite else { return }
    var newValue = min(max(proposedValue, bounds.lowerBound), bounds.upperBound)
    if let snapStep, snapStep > 0 {
      newValue = bounds.lowerBound + ((newValue - bounds.lowerBound) / snapStep).rounded() * snapStep
    }
    newValue = min(max(newValue, bounds.lowerBound), bounds.upperBound)
    if value != newValue { value = newValue }
  }
}

/// 項目名・選択肢・説明の順に並べ，狭いパネルでも操作の幅を確保する。
struct MusicVideoField<Content: View>: View {
  let title: String
  var detail: String? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.appBodyStrong)
        .foregroundStyle(NeomorphicTheme.ink)
      content
      if let detail {
        Text(detail)
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// 選択肢は幅が足りないときに折り返す。値の変更は既存のBindingへそのまま渡す。
struct MusicVideoChoices<Option: Hashable>: View {
  let options: [Option]
  let title: (Option) -> String
  @Binding var selection: Option
  var minimumWidth: CGFloat = 64

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        ForEach(options, id: \.self) { option in
          optionButton(option)
            .frame(minWidth: minimumWidth)
        }
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 8)], spacing: 8) {
        ForEach(options, id: \.self) { option in
          optionButton(option)
        }
      }
    }
  }

  private func optionButton(_ option: Option) -> some View {
    MusicVideoChoiceButton(title: title(option), isSelected: selection == option) {
      selection = option
    }
  }
}

/// 明るさの差と短い青線で選択中を示す。図は設定の意味を表す場合だけ付ける。
struct MusicVideoChoiceButton: View {
  let title: String
  let isSelected: Bool
  var frameAspect: CGFloat? = nil
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false
  @FocusState private var isFocused: Bool

  private let cornerRadius: CGFloat = 8

  var body: some View {
    Button(action: action) {
      VStack(spacing: 12) {
        if let frameAspect {
          RoundedRectangle(cornerRadius: 2)
            .strokeBorder(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted, lineWidth: 1)
            .aspectRatio(frameAspect, contentMode: .fit)
            .frame(width: 48, height: 32)
            .accessibilityHidden(true)
        }
        Text(title)
          .font(.appCaptionStrong)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
      .padding(.horizontal, 8)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: 40)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(isSelected ? NeomorphicTheme.controlSelected : (isHovering ? NeomorphicTheme.hover : NeomorphicTheme.control))
      )
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(isFocused ? NeomorphicTheme.accent : NeomorphicTheme.cardBorder, lineWidth: isFocused ? 2 : 1)
      }
      .overlay(alignment: .bottom) {
        if isSelected {
          RoundedRectangle(cornerRadius: 1)
            .fill(NeomorphicTheme.accent)
            .frame(width: 20, height: 2)
            .padding(.bottom, 4)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
      .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .onHover { isHovering = $0 }
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityValue(isSelected ? "選択中" : "未選択")
  }
}

/// 使用中の値は閉じていても確認できる。開閉状態は画面内だけで持つ。
struct MusicVideoFoldout<Content: View>: View {
  let title: String
  var summary: String = ""
  var selectedCutIndex: Int? = nil
  @ViewBuilder var content: Content
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 12)
          Text(title)
            .font(.appCaptionStrong)
          Spacer(minLength: 4)
          Text(summary)
            .font(.appMicro.monospacedDigit())
            .foregroundStyle(NeomorphicTheme.muted)
            .lineLimit(1)
        }
        .foregroundStyle(NeomorphicTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 24)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue(isExpanded ? "展開中" : "折りたたみ中")
      .accessibilityHint("押すと詳細設定を開閉します")

      if isExpanded { content }
    }
    .padding(16)
    .background(GlassCardSurface())
    .onAppear {
      if selectedCutIndex != nil { isExpanded = true }
    }
    .onChange(of: selectedCutIndex) { _, selected in
      if selected != nil { isExpanded = true }
    }
  }
}

/// チェック操作を画面のタイルと同じ線・面で描く。
struct MusicVideoCheckStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 8) {
        ZStack {
          RoundedRectangle(cornerRadius: 4)
            .fill(configuration.isOn ? NeomorphicTheme.ink : NeomorphicTheme.control)
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
          if configuration.isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(NeomorphicTheme.canvas)
          }
        }
        .frame(width: 20, height: 20)
        configuration.label
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.ink)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "オン" : "オフ")
  }
}

/// 作成ボタンを最も明るくし，保存などの操作は控えめな面にする。
struct MusicVideoActionStyle: ButtonStyle {
  var isPrimary = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.appCaptionStrong)
      .foregroundStyle(isPrimary ? NeomorphicTheme.canvas : NeomorphicTheme.ink)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(isPrimary ? NeomorphicTheme.ink : NeomorphicTheme.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
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
      MusicVideoField(title: "使う範囲", detail: detail(start: start, end: end, duration: duration, isPartial: range != nil)) {
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
      MusicVideoParameterTrack(
        title: label,
        valueText: Self.clock(value),
        value: Binding(get: { value }, set: onChange),
        bounds: bounds
      )
        .frame(minWidth: 100, maxWidth: .infinity)
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
