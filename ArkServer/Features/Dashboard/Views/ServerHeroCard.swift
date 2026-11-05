import AppKit
import SwiftUI

// MARK: - サーバーの状態と接続案内
/// ホームの先頭に置く、開始/停止と接続のしかたをまとめたカード。
/// 停止中は「どう接続するか」の手順を、稼働中は「いまの接続先」をそのまま使える形で見せる。
struct ServerHeroCard: View {
  @ObservedObject var webServerManager: ServerViewModel

  var body: some View {
    NeomorphicTile(padding: DS.cardPadding) {
      VStack(alignment: .leading, spacing: 16) {
        CardHeader(icon: "network", tint: NeomorphicTheme.accent, title: "サーバーの状態")
        statusRow

        Text(webServerManager.isRunning
          ? "同じWi-Fi内の端末から，動画・画像を閲覧できます．"
          : "「開始」を押すと，iPhoneやブラウザから接続できます．")
          .font(.appBody)
          .foregroundStyle(NeomorphicTheme.muted)
          .fixedSize(horizontal: false, vertical: true)

        if !webServerManager.statusMessage.isEmpty,
           webServerManager.statusMessage.contains("❌") || webServerManager.statusMessage.contains("⚠️") {
          Label(webServerManager.statusMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.appBody)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        Rectangle().fill(NeomorphicTheme.separator).frame(height: 0.5)

        if webServerManager.isRunning {
          runningDetails
        } else {
          connectionSteps
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  // MARK: 状態と開始/停止

  private var statusRow: some View {
    HStack(spacing: 12) {
      StatusDot(active: webServerManager.isRunning)
      Text(webServerManager.isRunning ? "配信中" : "停止中")
        .font(.appStatus)
      if webServerManager.isRunning {
        // 稼働時間は補足なので、状態の文字より小さく控えめに添える。
        Text("稼働 \(webServerManager.uptimeString)")
          .font(.appBody.monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
          .padding(.top, 8)
      }
      Spacer()
      if webServerManager.isRunning {
        // 停止は主役の操作ではない（誤って押したくもない）ので、塗りつぶさない。
        Button(action: toggleServer) {
          Label("停止", systemImage: "stop.fill")
            .font(.appBodyStrong)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
        .accessibilityLabel("サーバーを停止")
      } else {
        Button(action: toggleServer) {
          Label("開始", systemImage: "power")
            .font(.appBodyStrong)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(AppActionButtonStyle(isPrimary: true))
        .accessibilityLabel("サーバーを開始")
      }
    }
  }

  // MARK: 稼働中：いまの接続先

  private var runningDetails: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("ブラウザの接続先")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)

        if let url = webServerManager.serverURL {
          HStack(spacing: 12) {
            // 読み取り・入力しやすいよう大きめの等幅にして、クリックでコピーできるようにする。
            CopyableText(
              text: url,
              font: .system(size: 17, weight: .medium, design: .monospaced),
              tint: NeomorphicTheme.ink
            )
            Spacer(minLength: 8)
            Button {
              if let target = URL(string: url) { NSWorkspace.shared.open(target) }
            } label: {
              Label("開く", systemImage: "arrow.up.forward.app")
                .font(.appBodyStrong)
            }
            .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
            .help("このMacのブラウザで接続先を開く")
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
          Text("接続先を取得しています…")
            .font(.appBody)
            .foregroundStyle(NeomorphicTheme.muted)
        }
      }

      // スマホのカメラで読み取るための QR コード。URL を打ち込まずに接続できる。
      // QR に入れるのは接続先の URL だけで、PIN は含めない（画面を見られても PIN が漏れないようにする）。
      if let url = webServerManager.serverURL {
        HStack(alignment: .center, spacing: 16) {
          QRCodeView(text: url, size: 96)
          VStack(alignment: .leading, spacing: 6) {
            Text("スマホで読み取る")
              .font(.appBodyStrong)
            Text(webServerManager.authEnabled
              ? "カメラで読み取ると，ブラウザで接続先が開きます．開いたら「PIN認証」の6桁のPINを入力します．"
              : "カメラで読み取ると，ブラウザで接続先が開きます．（PIN認証は無効です）")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
              .fixedSize(horizontal: false, vertical: true)
            Text("iPhoneアプリは，このMacを自動で見つけます．")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  // MARK: 停止中：接続の手順

  private var connectionSteps: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("接続方法")
        .font(.appBodyStrong)
      step(1, "端末をMacと同じWi-Fiに接続します．")
      step(2, "iPhoneアプリでこのMacを選ぶか，ブラウザで接続先を開きます．")
      step(3, webServerManager.authEnabled
        ? "「PIN認証」に表示される6桁のPINを入力します．"
        : "PIN認証は無効です．同じWi-Fi内の端末はPINなしで接続できます．")
      Text("接続先のURLは，サーバー開始後にここへ表示されます．")
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
        .padding(.top, 2)
    }
  }

  /// 番号を小さな丸に入れた手順1行分。
  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(number)")
        .font(.appMicroStrong.monospacedDigit())
        .foregroundStyle(NeomorphicTheme.muted)
        .frame(width: 20, height: 20)
        .background(Circle().fill(NeomorphicTheme.control))
      Text(text)
        .font(.appBody)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func toggleServer() {
    if webServerManager.isRunning {
      webServerManager.stopServer()
    } else {
      webServerManager.startServer()
    }
  }
}
