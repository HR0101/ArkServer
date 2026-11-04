import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 共有グリッド設定バー（ソート/サムネ位置/タイトル/列数）
struct MediaGridControlBar: View {
    @EnvironmentObject private var appSettings: AppSettings
    /// 「サイズ」「最後に開いた日」等を選んだときにファイル属性キャッシュを最新化するためだけに参照する。
    /// 表示更新は監視しないので @ObservedObject ではなく素の参照にしている。
    let dataManager: LibraryViewModel
    /// 並べ替えの操作を出すか。「再生履歴」は再生した順そのものが中身なので、
    /// 効かない操作を出しておかないよう false で呼ぶ。
    var showsSortControls: Bool = true

    private static let secondsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 0
        f.maximum = 3600
        return f
    }()

    private static let minimumColumnCount = 2.0
    private static let maximumColumnCount = 12.0
    private static let columnSliderWidth: CGFloat = 110

    var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
          sortingControls
          thumbnailControls
          Spacer(minLength: 12)
          displayControls
          columnControls
        }
        VStack(spacing: 10) {
          HStack(spacing: 12) {
            sortingControls
            Spacer(minLength: 8)
            thumbnailControls
          }
          HStack(spacing: 12) {
            displayControls
            Spacer(minLength: 8)
            columnControls
          }
        }
      }
      .font(.appCaption)
      .tint(NeomorphicTheme.ink)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      // 下地と同じ不透明色にして、区切りは細い線だけにする（帯が浮くと画面が散らかって見える）。
      .background(NeomorphicTheme.canvas)
      .overlay(alignment: .top) {
        Rectangle().fill(NeomorphicTheme.separator).frame(height: 0.5)
      }
      // メニューのグレーの枠は付けず、文字とアイコンだけの軽い見た目にする。

    }

    @ViewBuilder
    private var sortingControls: some View {
      if showsSortControls {
        // 「短い順」の横に ↓ / ↑ だけのボタンを並べると，矢印が何を指すのか分からない．
        // 逆順はメニューの中のチェック項目にし，効いているときはラベルに「（逆順）」と出す．
        AppChoiceMenu {
          ForEach(SortOrder.allCases) { order in
            Toggle(order.rawValue, isOn: Binding(
              get: { appSettings.sortOrder == order },
              set: { isOn in
                guard isOn else { return }
                // ファイル属性を使う並べ替えは，最新の属性を読み直します．
                if order.needsFileMetadata { dataManager.refreshFileMetadataCache() }
                appSettings.sortOrder = order
              }
            ))
          }
          Divider()
          Toggle("逆順にする", isOn: $appSettings.sortReversed)
        } label: {
          Label(
            "並び順：\(appSettings.sortOrder.rawValue)\(appSettings.sortReversed ? "（逆順）" : "")",
            systemImage: "arrow.up.arrow.down"
          )
        }
        .fixedSize()
        .help("並び順と，逆順にするかを選びます．")
      }
    }

    private var thumbnailControls: some View {
      HStack(spacing: 6) {
        AppChoiceMenu {
          ForEach(ThumbnailOption.allCases) { option in
            Button(option.rawValue) { appSettings.thumbnailOption = option }
          }
        } label: {
          Label("サムネ：\(appSettings.thumbnailOption.rawValue)", systemImage: "photo.on.rectangle.angled")
        }
        .fixedSize()
        if appSettings.thumbnailOption == .custom {
          HStack(spacing: 4) {
            AppNumberStepper(value: $appSettings.customThumbnailTime, in: 0...3600, step: 1) { EmptyView() }
              .labelsHidden()
            TextField("秒", value: $appSettings.customThumbnailTime, formatter: Self.secondsFormatter)
              .frame(width: 46)
              .multilineTextAlignment(.trailing)
              .accessibilityLabel("サムネイルの秒数")
            Text("秒")
          }
        }
      }
    }

    private var displayControls: some View {
      AppChoiceMenu {
        Toggle("タイトルを表示", isOn: $appSettings.showTitles)
        Toggle("インポート日を表示", isOn: $appSettings.showImportDates)
      } label: {
        Label("表示項目", systemImage: "text.below.photo")
      }
      .fixedSize()
      .help("サムネイルの下に表示するタイトル・日付を変更します．")
    }

    private var columnControls: some View {
      HStack(spacing: 8) {
        Text("\(Int(appSettings.columnCount))列")
          .monospacedDigit()
          .fixedSize()
        Slider(value: $appSettings.columnCount,
          in: Self.minimumColumnCount...Self.maximumColumnCount, step: 1)
          .frame(width: Self.columnSliderWidth)
          .accessibilityLabel("表示列数")
          .accessibilityValue("\(Int(appSettings.columnCount))列")
      }
      .help("列を減らすとサムネイルが大きくなります．")
    }
}
