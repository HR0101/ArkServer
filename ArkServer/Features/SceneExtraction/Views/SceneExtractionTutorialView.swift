// ArkServer/Features/SceneExtraction/Views/SceneExtractionTutorialView.swift

import SwiftUI

nonisolated enum SceneExtractionTutorialSection: String, CaseIterable, Identifiable, Sendable {
  case workflow = "操作手順"
  case glossary = "用語集"

  var id: String { rawValue }
}

nonisolated enum SceneExtractionGlossaryCategory: String, CaseIterable, Identifiable, Sendable {
  case all = "すべて"
  case analysis = "解析"
  case detection = "候補判定"
  case export = "書き出し"
  case learning = "ラベル・学習"

  var id: String { rawValue }
}

nonisolated struct SceneExtractionTutorialStep: Identifiable, Sendable {
  let id: Int
  let title: String
  let systemImage: String
  let summary: String
  let details: [String]
  let tip: String
}

nonisolated struct SceneExtractionGlossaryTerm: Identifiable, Sendable {
  let term: String
  let category: SceneExtractionGlossaryCategory
  let shortDefinition: String
  let detail: String
  let relatedSetting: String?

  var id: String { term }
}

nonisolated enum SceneExtractionTutorialContent {
  static let currentVersion = 4

  static let steps: [SceneExtractionTutorialStep] = [
    SceneExtractionTutorialStep(
      id: 1,
      title: "画面の役割を知る",
      systemImage: "rectangle.split.3x1",
      summary: "左で動画を確認し，右で解析結果，下で候補を操作します．",
      details: [
        "左側は動画プレイヤーと候補マーカー付きタイムラインです．",
        "右上は音声A・映像B・遷移C・合成スコアのグラフです．",
        "右下は解析条件とクリップ書き出し条件です．",
        "画面下部は検出された候補区間の一覧です．"
      ],
      tip: "最初は右側の細かな設定を変えず，既定値で一度解析するのがおすすめです．"
    ),
    SceneExtractionTutorialStep(
      id: 2,
      title: "ライブラリで動画を選ぶ",
      systemImage: "film",
      summary: "アプリ内の動画を1本選び，「シーン抽出」を実行します．",
      details: [
        "アルバムや「すべての動画」で対象を1本クリックすると，ツールバーに「シーン抽出」が表示されます．",
        "動画を右クリックし，メニューの「シーン抽出」を選ぶこともできます．",
        "再生ボタンまたはSpaceキーで再生・停止できます．",
        "左右のフレームボタンは1コマずつ確認するときに使います．",
        "スライダーまたはタイムラインをクリックすると，その時刻へ移動します．"
      ],
      tip: "解析画面で別ファイルを選び直す必要はありません．「ライブラリへ戻る」で元の一覧へ戻れます．"
    ),
    SceneExtractionTutorialStep(
      id: 3,
      title: "解析条件を決める",
      systemImage: "slider.horizontal.3",
      summary: "候補の出やすさと，音声・映像・遷移の重視度を設定します．",
      details: [
        "候補しきい値を下げると候補が増え，上げると厳選されます．",
        "音声・映像・遷移の重みは，合成スコアへの影響度です．",
        "解析fpsは解析に使う1秒あたりの映像枚数です．",
        "freezeしきい値は，どの程度の小さな動きを静止とみなすかを決めます．"
      ],
      tip: "候補が0件なら候補しきい値を少し下げ，多すぎるなら少し上げてください．"
    ),
    SceneExtractionTutorialStep(
      id: 4,
      title: "候補を解析する",
      systemImage: "waveform.path.ecg",
      summary: "「候補を解析」を押すと，音声と映像を並行して調べます．",
      details: [
        "Aは音声帯域と音量変化，Bは映像の動き，Cは静止・遷移の特徴です．",
        "合成スコアはA・B・Cと前後関係をまとめた候補らしさです．",
        "解析中も画面は操作可能で，必要ならキャンセルできます．",
        "グラフの山と候補マーカーを見比べると，検出理由を把握できます．"
      ],
      tip: "A・B・Cの全部が高くなくても候補になります．単独特徴の強い場面もランキング対象です．"
    ),
    SceneExtractionTutorialStep(
      id: 5,
      title: "候補とGTを確認する",
      systemImage: "checkmark.seal",
      summary: "候補をプレビューし，採用・却下・保留を付けます．",
      details: [
        "候補行の「プレビュー」でstartからendまでをループ再生します．",
        "startとendは候補ごとに秒単位で微調整できます．",
        "大きなボタンまたは1・2・3キーで，採用・保留・却下をすばやく付けられます．",
        "判定後は次の未判定候補へ自動的に移動し，プレビューを開始します．",
        "GTモードでは，タイムラインをクリックした位置を手動の正解として追加できます．",
        "ラベルはJSON・CSVへ保存され，将来の分類器学習に利用できます．"
      ],
      tip: "迷う候補は却下せず「保留」にすると，後から見直しやすくなります．"
    ),
    SceneExtractionTutorialStep(
      id: 6,
      title: "クリップとデータを保存する",
      systemImage: "square.and.arrow.down",
      summary: "ComfyUIのinputフォルダを選び，候補を書き出します．",
      details: [
        "各候補の「書き出し」で動画クリップとsidecar JSONを作成します．",
        "書き出し中は隠し一時ファイルを使い，正常完了後にだけ最終MP4を表示します．",
        "既定値はH.264・24fps・241フレームです．",
        "「JSON・CSVを保存」は全特徴量とラベルを教師データとして保存します．",
        "HEVCは容量を抑えやすい一方，ワークフロー側の対応確認が必要です．"
      ],
      tip: "ComfyUIで読めない場合は，まずH.264・音声なしで書き出して確認してください．"
    )
  ]

  static let glossaryTerms: [SceneExtractionGlossaryTerm] = [
    term("候補区間", .detection, "特徴量から自動抽出された確認対象です．", "この時点では正解と断定していません．候補をプレビューし，人が採用・却下・保留を判断します．"),
    term("ピーク時刻", .detection, "候補らしさが局所的に最も高い時刻です．", "クリップの基準位置です．既定ではピークの4秒前から始まり，後ろ側を6秒含めます．", "ピークまで［秒］"),
    term("合成スコア", .detection, "A・B・Cと前後関係をまとめた0〜1の値です．", "1に近いほど現在のルールでは有力です．意味内容を直接理解したAIの確率ではありません．"),
    term("候補しきい値", .detection, "候補として残す最低スコアです．", "下げると見逃しが減る代わりに候補が増えます．上げると候補は減ります．", "候補しきい値"),
    term("候補間隔", .detection, "近接する候補を重複採用しないための秒数です．", "指定秒数より近いピークが複数ある場合，原則として高得点側を残します．", "候補間隔［秒］"),
    term("A・音声スコア", .analysis, "声帯域の強さ，上昇，減衰を表します．", "100〜1500Hzのエネルギー，RMS，直前との差などから作られます．"),
    term("B・映像スコア", .analysis, "フレーム間の動きや変化量を表します．", "輝度差，エッジ差，急増，急低下を組み合わせた値です．"),
    term("C・遷移スコア", .analysis, "静止や編集上の切り替わりらしさを表します．", "freeze，dissolve，fade，急変後の低変化を候補特徴としてまとめます．"),
    term("FFT", .analysis, "音を周波数ごとの強さへ分解する計算です．", "このアプリではAccelerateのvDSPを使い，100〜1500Hz帯域のパワーを求めます．"),
    term("100〜1500Hz帯域", .analysis, "解析対象としている主な声成分の周波数範囲です．", "声以外の音も含まれるため，帯域が強いだけで候補が確定するわけではありません．"),
    term("RMS", .analysis, "短い時間窓における音量の代表値です．", "瞬間的な波形の正負に左右されず，音のエネルギー量を比較できます．"),
    term("音声窓", .analysis, "音声を区切って解析する短い時間幅です．", "既定では約100ms単位です．短いほど細かな変化を拾いますが，値が不安定になりやすくなります．"),
    term("フレーム差分", .analysis, "連続する映像フレームの違いです．", "値が大きいほど動きやカット変化が大きく，ほぼ0が続くとfreeze候補になります．"),
    term("輝度差", .analysis, "映像の明るさが前フレームから変わった量です．", "色の違いよりも明暗変化を中心に捉え，fade検出にも利用します．"),
    term("エッジ差", .analysis, "輪郭の形や位置が変わった量です．", "単純な明るさ変化だけでは分かりにくい被写体の動きを補助的に捉えます．"),
    term("motion spike／drop", .analysis, "動き量の急増／急低下です．", "直前に大きく動き，直後に止まるような前後関係を候補判定へ使います．"),
    term("freeze", .analysis, "フレーム差分が非常に小さい状態の継続です．", "完全な静止画だけでなく，コマ止めやほぼ動かない区間も含む候補スコアです．", "freezeしきい値"),
    term("dissolve", .analysis, "2つの映像が徐々に混ざって切り替わる遷移です．", "差分が単発で跳ねず，中程度の変化が滑らかに続くパターンを簡易検出します．"),
    term("fade", .analysis, "画面全体が徐々に明るく，または暗くなる遷移です．", "平均輝度が一定方向へ連続して変化するパターンから候補化します．"),
    term("edit transition", .analysis, "編集による急な切り替わり候補です．", "大きな差分が出た直後に変化が小さくなるパターンをスコア化します．"),
    term("解析fps", .analysis, "解析に使う1秒あたりの映像枚数です．", "高くすると短い変化を拾いやすくなりますが，解析時間とCPU負荷が増えます．既定の8fpsが開始点です．", "解析fps"),
    term("重み", .detection, "各特徴を合成スコアへ反映する強さです．", "音声・映像・遷移の重みを相対的に調整します．迷う場合は既定値を使ってください．"),
    term("正規化", .analysis, "単位の異なる特徴を比較可能な範囲へそろえる処理です．", "移動平均とz-scoreを使い，最終的に0〜1へ変換してから合成します．"),
    term("GT", .learning, "Ground Truthの略で，人が付ける正解データです．", "自動候補にない正解位置を手動追加し，将来のモデル学習や検出評価に利用します．"),
    term("採用／却下／保留", .learning, "候補に付ける人間の判断ラベルです．", "採用は正例，却下は負例，保留は判断未確定としてCSVへ保存できます．"),
    term("CatBoost", .learning, "表形式の特徴量を扱いやすい機械学習手法です．", "このアプリが出力するCSVをPython側で学習し，将来ルールベース分類器と交換できます．"),
    term("Core ML", .learning, "Apple製品上で機械学習モデルを実行する仕組みです．", "学習済みモデルを変換し，`ClimaxClassifier`の実装として差し込む想定です．"),
    term("fps", .export, "1秒あたりの映像フレーム数です．", "出力fpsを24にすると，1秒を24枚の画像で構成します．", "出力fps"),
    term("出力フレーム数", .export, "クリップに含める映像フレームの総数です．", "ComfyUIワークフローが要求する値へ合わせます．実時間はフレーム数÷fpsです．", "出力フレーム数"),
    term("H.264", .export, "互換性が高い動画圧縮方式です．", "迷う場合はこちらを使います．多くのComfyUI環境や動画ツールで読み込めます．"),
    term("HEVC", .export, "H.264より高圧縮になりやすい動画圧縮方式です．", "容量を抑えられますが，利用するノードや環境が対応しているか確認してください．"),
    term("sidecar JSON", .export, "動画クリップと並べて保存する説明データです．", "元動画，開始・終了・ピーク，スコア，理由，fps，フレーム数などを記録します．"),
    term("CSV", .learning, "表計算ソフトやPythonで扱えるカンマ区切り形式です．", "時刻ごとのA・B・C・合成スコアと人間のラベルを学習用に保存します．")
  ]

  private static func term(
    _ term: String,
    _ category: SceneExtractionGlossaryCategory,
    _ shortDefinition: String,
    _ detail: String,
    _ relatedSetting: String? = nil
  ) -> SceneExtractionGlossaryTerm {
    SceneExtractionGlossaryTerm(
      term: term,
      category: category,
      shortDefinition: shortDefinition,
      detail: detail,
      relatedSetting: relatedSetting
    )
  }
}

struct SceneExtractionTutorialView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedSection: SceneExtractionTutorialSection = .workflow
  @State private var selectedStepIndex = 0
  @State private var selectedCategory: SceneExtractionGlossaryCategory = .all
  @State private var searchText = ""

  private let sheetWidth: CGFloat = 820
  private let sheetHeight: CGFloat = 640

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      switch selectedSection {
      case .workflow:
        workflowContent
      case .glossary:
        glossaryContent
      }
    }
    .frame(width: sheetWidth, height: sheetHeight)
    .appSheet()
  }

  private var header: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text("シーン抽出の使い方")
          .font(.appTitle)
        Text("操作手順と用語の意味をいつでも確認できます．")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
      }

      Spacer()

      FlatSegmentedControl(
        options: Array(SceneExtractionTutorialSection.allCases),
        title: { $0.rawValue },
        selection: $selectedSection,
        width: 240
      )
      .accessibilityLabel("表示内容")

      Button("閉じる") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
    }
    .padding(20)
  }

  private var workflowContent: some View {
    VStack(spacing: 0) {
      stepIndicator
        .padding(.horizontal, 24)
        .padding(.vertical, 16)

      Divider()

      let step = SceneExtractionTutorialContent.steps[selectedStepIndex]
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack(alignment: .top, spacing: 18) {
            Image(systemName: step.systemImage)
              .font(.system(size: 30, weight: .light))
              .foregroundStyle(NeomorphicTheme.ink)
              .frame(width: 58, height: 58)
              .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
              Text("STEP \(step.id)")
                .font(.appCaptionStrong)
                .foregroundStyle(NeomorphicTheme.muted)
              Text(step.title)
                .font(.appLargeTitle)
              Text(step.summary)
                .font(.appHeadline.weight(.regular))
                .foregroundStyle(NeomorphicTheme.muted)
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            ForEach(step.details, id: \.self) { detail in
              Label {
                Text(detail)
              } icon: {
                Image(systemName: "checkmark.circle")
                  .foregroundStyle(NeomorphicTheme.muted)
              }
            }
          }
          .font(.appBody)

          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
              .foregroundStyle(NeomorphicTheme.caution)
            VStack(alignment: .leading, spacing: 3) {
              Text("ヒント")
                .font(.appBodyStrong)
              Text(step.tip)
                .font(.appBody)
                .foregroundStyle(NeomorphicTheme.muted)
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(28)
      }

      Divider()
      workflowFooter
    }
  }

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      ForEach(Array(SceneExtractionTutorialContent.steps.enumerated()), id: \.element.id) { index, step in
        Button {
          selectedStepIndex = index
        } label: {
          VStack(spacing: 5) {
            Text("\(step.id)")
              .font(.appCaptionStrong)
              .frame(width: 28, height: 28)
              // いまの手順は白い丸に暗い数字（再生ボタンと同じ表し方）、ほかは薄い面。
              .background(
                index == selectedStepIndex ? NeomorphicTheme.ink : NeomorphicTheme.control,
                in: Circle()
              )
              .foregroundStyle(index == selectedStepIndex ? NeomorphicTheme.canvas : NeomorphicTheme.muted)
            Text(step.title)
              .font(.appMicro)
              .foregroundStyle(index == selectedStepIndex ? NeomorphicTheme.ink : NeomorphicTheme.muted)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)

        if index < SceneExtractionTutorialContent.steps.count - 1 {
          Rectangle()
            .fill(NeomorphicTheme.separator)
            .frame(width: 18, height: 1)
        }
      }
    }
  }

  private var workflowFooter: some View {
    HStack {
      Button("戻る") {
        selectedStepIndex = max(0, selectedStepIndex - 1)
      }
      .disabled(selectedStepIndex == 0)

      Spacer()

      Text("\(selectedStepIndex + 1) / \(SceneExtractionTutorialContent.steps.count)")
        .font(.appCaption.monospacedDigit())
        .foregroundStyle(NeomorphicTheme.muted)

      Spacer()

      if selectedStepIndex < SceneExtractionTutorialContent.steps.count - 1 {
        Button("次へ") {
          selectedStepIndex += 1
        }
        .keyboardShortcut(.defaultAction)
      } else {
        Button("用語集を見る") {
          selectedSection = .glossary
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
  }

  private var glossaryContent: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        TextField("用語を検索", text: $searchText)
          .textFieldStyle(.roundedBorder)

        Picker("カテゴリ", selection: $selectedCategory) {
          ForEach(SceneExtractionGlossaryCategory.allCases) { category in
            Text(category.rawValue).tag(category)
          }
        }
        .tint(NeomorphicTheme.ink)
        .frame(width: 160)
      }
      .padding(16)

      Divider()

      if filteredTerms.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(filteredTerms) { glossaryTerm in
              glossaryCard(glossaryTerm)
            }
          }
          .padding(18)
        }
      }
    }
  }

  private var filteredTerms: [SceneExtractionGlossaryTerm] {
    SceneExtractionTutorialContent.glossaryTerms.filter { glossaryTerm in
      let matchesCategory = selectedCategory == .all || glossaryTerm.category == selectedCategory
      let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      let matchesSearch = normalizedSearch.isEmpty
        || glossaryTerm.term.localizedCaseInsensitiveContains(normalizedSearch)
        || glossaryTerm.shortDefinition.localizedCaseInsensitiveContains(normalizedSearch)
        || glossaryTerm.detail.localizedCaseInsensitiveContains(normalizedSearch)
      return matchesCategory && matchesSearch
    }
  }

  private func glossaryCard(_ glossaryTerm: SceneExtractionGlossaryTerm) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(glossaryTerm.term)
          .font(.appBodyStrong)
        Text(glossaryTerm.category.rawValue)
          .font(.appMicroStrong)
          .foregroundStyle(NeomorphicTheme.muted)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(NeomorphicTheme.control, in: Capsule())
        Spacer()
        if let relatedSetting = glossaryTerm.relatedSetting {
          Label(relatedSetting, systemImage: "slider.horizontal.3")
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
        }
      }
      Text(glossaryTerm.shortDefinition)
        .font(.appBody.weight(.medium))
      Text(glossaryTerm.detail)
        .font(.appBody)
        .foregroundStyle(NeomorphicTheme.muted)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(NeomorphicTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
