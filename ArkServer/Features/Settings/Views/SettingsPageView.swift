// ArkServer/Features/Settings/Views/SettingsPageView.swift

import AppKit
import SwiftUI

/// 詳細設定のページ。中央の1列に、項目ごとの「セクション名 + 行をまとめた面」を並べる。
/// 値の実体は LibraryViewModel / ServerViewModel / AppSettings / UserDefaults（シートだった頃と同じ）。
struct SettingsPageView: View {
  let pane: SettingsPane
  @ObservedObject var dataManager: LibraryViewModel
  @ObservedObject var webServerManager: ServerViewModel
  @ObservedObject var appSettings: AppSettings

  @AppStorage("thumbnailMemoryCacheLimit") private var thumbnailMemoryCacheLimit = 600

  private static let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        Text(pane.title)
          .font(.appLargeTitle)
          .foregroundStyle(NeomorphicTheme.ink)
          .padding(.top, 8)
          .accessibilityAddTraits(.isHeader)

        content
      }
      .frame(maxWidth: settingsColumnWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.top, 28)
      .padding(.bottom, 40)
    }
    .background(CommandDeckBackground())
    // 設定のスイッチなど「入」の色は青にする（内容側の既定は文字色の中立色）。
    .tint(NeomorphicTheme.accent)
    .foregroundStyle(NeomorphicTheme.ink)
    // ページを開くと AppKit が先頭の入力欄（ポート番号）を自動で選択し，うっかり打鍵しただけで
    // 値が書き換わる。SwiftUI の FocusState では止められないので，開いた直後に選択を外す。
    .background(InitialFirstResponderClearer())
    .id(pane)
  }

  @ViewBuilder
  private var content: some View {
    switch pane {
    case .connection: connection
    case .appearance: appearance
    case .data: dataSafety
    case .protection: protection
    case .performance: performance
    case .export: export
    case .updates: UpdateSettingsSection()
    case .shortcuts: MediaShortcutSettingsSection()
    }
  }

  // MARK: - 接続・認証

  private var connection: some View {
    // ポート・PIN・自動停止はホームのカードでも変えられるが，設定を探すときにここだけ見れば全部そろっているようにする
    // （値の実体は同じ ServerViewModel）。
    VStack(alignment: .leading, spacing: 28) {
      SettingsSection(
        title: "サーバー",
        footer: webServerManager.isRunning ? "ポート番号と自動停止は，サーバーを停止すると変更できます．" : nil
      ) {
        SettingsGroup {
          SettingsRow(title: "ポート番号", detail: "iPhoneやブラウザから接続するときのポートです．既定は8080です．") {
            HStack(spacing: 6) {
              TextField("ポート番号", value: $webServerManager.targetPort, format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .multilineTextAlignment(.center)
              Button {
                webServerManager.targetPort = 8080
              } label: {
                Image(systemName: "arrow.counterclockwise")
              }
              .buttonStyle(.quiet)
              .help("既定(8080)に戻す")
              .accessibilityLabel("ポート番号を既定に戻す")
            }
            .disabled(webServerManager.isRunning)
          }
          SettingsRow(title: "自動停止タイマー", detail: "サーバーを開始してから決めた時間がたつと，自動で停止します．") {
            SettingsSwitch(title: "自動停止タイマー", isOn: $webServerManager.autoStopEnabled)
              .disabled(webServerManager.isRunning)
          }
          if webServerManager.autoStopEnabled {
            SettingsRow(title: "サーバー開始から終了まで") {
              HStack(spacing: 6) {
                TextField("分", value: $webServerManager.autoStopIntervalMinutes, format: .number)
                  .labelsHidden()
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 60)
                  .multilineTextAlignment(.trailing)
                Text("分").foregroundStyle(NeomorphicTheme.muted)
              }
              .disabled(webServerManager.isRunning)
            }
          }
        }
      }

      SettingsSection(title: "認証") {
        SettingsGroup {
          SettingsRow(
            title: "PIN認証を必須にする",
            detail: webServerManager.authEnabled
              ? "接続する端末で6桁のPINの入力が必要になります．"
              : "認証が無効です．同じWi-Fi内の誰でもアクセスできます．"
          ) {
            SettingsSwitch(title: "PIN認証を必須にする", isOn: $webServerManager.authEnabled)
          }
          if webServerManager.authEnabled {
            SettingsRow(title: "接続PIN") {
              HStack(spacing: 8) {
                Text(webServerManager.authPIN)
                  .font(.system(.body, design: .monospaced).weight(.semibold))
                  .textSelection(.enabled)
                Button {
                  webServerManager.regeneratePIN()
                } label: {
                  Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.quiet)
                .help("PINを再生成する")
                .accessibilityLabel("PINを再生成する")
              }
            }
          }
        }
      }
    }
  }

  // MARK: - 外観

  private var appearance: some View {
    SettingsSection(title: "表示") {
      SettingsGroup {
        SettingsRow(title: "ダークな外観にする", detail: "暗い外観と明るい外観を切り替えます．") {
          SettingsSwitch(title: "ダークな外観にする", isOn: $appSettings.neomorphicDarkBase)
        }
        SettingsRow(
          title: "サイドバーのアルバムに表紙と詳細を表示",
          detail: "オフにすると，名前と件数だけの行に戻ります．アルバムが非常に多いときに行を詰めたい場合に使います．"
        ) {
          SettingsSwitch(title: "サイドバーのアルバムに表紙と詳細を表示", isOn: $appSettings.sidebarShowsAlbumDetails)
        }
      }
    }
  }

  // MARK: - データの安全

  private var dataSafety: some View {
    SettingsSection(title: "メディアの扱い") {
      SettingsGroup {
        SettingsRow(
          title: "インポート時にファイルをアプリ内へコピー",
          detail: "オンにすると，元のフォルダを消してもサーバー内に実体が残ります（ディスク容量を消費）．オフ（既定）は元の場所を参照するだけで，元ファイルを消すと再生できなくなります．"
        ) {
          SettingsSwitch(title: "インポート時にファイルをアプリ内へコピー", isOn: $dataManager.importCopiesFiles)
        }
        SettingsRow(title: "ゴミ箱の自動削除", detail: "ゴミ箱に入れてから指定日数が経過した項目を，起動時に完全削除します．") {
          Picker("ゴミ箱の自動削除", selection: $dataManager.trashAutoDeleteDays) {
            Text("しない").tag(0)
            Text("30日後").tag(30)
            Text("90日後").tag(90)
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(
          title: "起動時にリンク切れメディアを自動整理",
          detail: "元ファイルが見つからない項目を起動時に自動削除します．外付けドライブのメディアを参照している場合はオフのままにしてください（未接続時に誤って消えます）．"
        ) {
          SettingsSwitch(title: "起動時にリンク切れメディアを自動整理", isOn: $dataManager.autoCleanupMissingFilesEnabled)
        }
      }
    }
  }

  // MARK: - サーバー保護

  private var protection: some View {
    SettingsSection(title: "サーバーの保護") {
      SettingsGroup {
        SettingsRow(
          title: "認証オフでも削除操作にはPINを要求",
          detail: "PIN認証をオフにしていても，完全削除・アルバム削除・サーバー停止のAPIにはPINを要求します．"
        ) {
          SettingsSwitch(title: "認証オフでも削除操作にはPINを要求", isOn: $webServerManager.requirePINForDeletion)
        }
        SettingsRow(
          title: "サーバー表示名",
          detail: "iOSアプリやブラウザに表示される名前です．空欄ならコンピュータ名を使います．変更はサーバーの再起動後に反映されます．"
        ) {
          TextField("コンピュータ名", text: $webServerManager.serverDisplayName)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
        }
        SettingsRow(
          title: "アップロード上限",
          detail: "受信中のファイルは丸ごとメモリに読み込まれるため，搭載メモリ（\(Self.physicalMemoryGB) GB）の半分までしか選べません．"
        ) {
          Picker("アップロード上限", selection: $webServerManager.maxUploadGB) {
            ForEach(ServerViewModel.uploadLimitOptionsGB, id: \.self) { gb in
              Text("\(gb) GB").tag(gb)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
    }
  }

  // MARK: - パフォーマンス

  private var performance: some View {
    SettingsSection(title: "処理の負荷") {
      SettingsGroup {
        SettingsRow(title: "自動重複チェックの間隔") {
          Picker("自動重複チェックの間隔", selection: $dataManager.duplicateCheckIntervalSeconds) {
            Text("30秒").tag(30)
            Text("1分").tag(60)
            Text("5分").tag(300)
            Text("15分").tag(900)
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "インポートの並列数") {
          Picker("インポートの並列数", selection: $dataManager.importConcurrency) {
            Text("2（省電力）").tag(2)
            Text("4（標準）").tag(4)
            Text("8（高速）").tag(8)
          }
          .labelsHidden()
          .fixedSize()
        }
        SettingsRow(title: "サムネイルのメモリキャッシュ上限") {
          Picker("サムネイルのメモリキャッシュ上限", selection: $thumbnailMemoryCacheLimit) {
            Text("200枚（省メモリ）").tag(200)
            Text("600枚（標準）").tag(600)
            Text("1200枚（大量表示向け）").tag(1200)
          }
          .labelsHidden()
          .fixedSize()
          .onChange(of: thumbnailMemoryCacheLimit) { _, newValue in
            MacVideoThumbnailView.updateMemoryCacheLimit(newValue)
          }
        }
      }
    }
  }

  // MARK: - エクスポート

  private var export: some View {
    SettingsSection(title: "書き出し") {
      SettingsGroup {
        SettingsRow(
          title: "アルバムの階層構造を再現して書き出す",
          detail: "オフにすると，すべてのファイルを選んだフォルダ直下にフラットに書き出します．"
        ) {
          SettingsSwitch(title: "アルバムの階層構造を再現して書き出す", isOn: $dataManager.exportPreservesAlbumStructure)
        }
      }
    }
  }
}
