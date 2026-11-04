import AppKit
import SwiftUI

// MARK: - 文字サイズの階層

/// アプリ全体の文字サイズの段階。システム標準の `.caption`（macOS では 10pt）は小さすぎて読みにくいので使わず、
/// 画面ごとにばらついていた指定を、次の 6 段階にそろえる。強弱は太さ（.weight）で足す。
///
/// | 名前          | pt | 用途                                   |
/// |---------------|----|----------------------------------------|
/// | appMicro      | 11 | バッジ・単位・時刻などの補足           |
/// | appCaption    | 12 | 説明文・2 行目・ラベル                 |
/// | appBody       | 13 | 本文・行・ボタン                       |
/// | appHeadline   | 15 | カードの見出し                         |
/// | appTitle      | 17 | シート・パネルの見出し                 |
/// | appLargeTitle | 26 | ページの見出し（LibraryPageHeader）    |
///
/// 見出しの太さは .medium までにする（太字にしない）。太字は、数値の強調や警告のように意味のある所だけで使う。
/// 同じ大きさで少し強めたい文字（行の題名・件数・状態）は、`.weight` を足さず `…Strong` を使う。
/// 時刻・IP・キー名のような等幅の文字は `appMono…`、画面の主役になる数値は `appMetric` を使う。
extension Font {
    static let appMicro = Font.system(size: 11)
    static let appCaption = Font.system(size: 12)
    static let appBody = Font.system(size: 13)
    static let appMicroStrong = Font.system(size: 11, weight: .medium)
    static let appCaptionStrong = Font.system(size: 12, weight: .medium)
    static let appBodyStrong = Font.system(size: 13, weight: .medium)
    static let appMonoMicro = Font.system(size: 11, design: .monospaced)
    static let appMonoCaption = Font.system(size: 12, design: .monospaced)
    static let appMonoBody = Font.system(size: 13, design: .monospaced)
    /// 件数のように、一目で読ませたい数値。数値だけは少し太くしてよい。
    static let appMetric = Font.system(size: 22, weight: .semibold)
    static let appHeadline = Font.system(size: 15, weight: .medium)
    static let appTitle = Font.system(size: 17, weight: .medium)
    static let appLargeTitle = Font.system(size: 26, weight: .medium)
    /// サーバーの「停止中／配信中」のような、画面の主役になる状態の文字。
    static let appStatus = Font.system(size: 28, weight: .medium)
}

// MARK: - デザイントークン

enum DS {
    static let cardCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 20
    static let cardSpacing: CGFloat = 20
}

/// ガラス風テーマの色です．既存の外観設定キーを引き継ぎます．
/// 静的な色参照とAppKitのウィンドウ外観を同じ設定に揃えます．
enum NeomorphicTheme {
    static let darkBaseDefaultsKey = "appearance.neomorphicDarkBase"

    // 黒基調の面の関係は、参考にした設定画面を、このアプリと同じ方法（スクリーンショットの画素値）で測って合わせた。
    //   窓の枠（タイトルバー・左のレール） ＞ サイドバー ＞ 内容の下地 の順に暗くなる。
    //   設定の行をまとめる面は、サイドバーとほぼ同じ明るさ。線と選択の面は、白の約8％。
    // つまり、内容は枠の内側にはめ込まれた一番暗いパネルに見える。
    /// 未設定のときは黒基調。動画・画像が主役のアプリなので、作品の色が映える暗い下地を既定にする。
    static var isDarkBase: Bool {
        UserDefaults.standard.object(forKey: darkBaseDefaultsKey) as? Bool ?? true
    }

    // 配色の考え方：色味のない中立のグレーだけで面を作り、強弱は面の明るさと文字の濃淡でつける。
    // 色（アクセント）は、主要ボタン・スイッチ・選択中の枠のような「操作の目印」にだけ使う。

    /// 内容側の下地。
    static var canvas: Color {
        isDarkBase ? Color(white: 0.093) : Color(white: 0.965)
    }
    /// サイドバー・カードの面。下地よりわずかに明るい（黒基調）／白（明るい側）。
    static var sidebar: Color {
        isDarkBase ? Color(white: 0.133) : Color(white: 0.925)
    }
    /// 窓の枠の色。左のレールとタイトルバーに使い、内側のサイドバーと内容を一段くぼませて見せる。
    static var rail: Color {
        isDarkBase ? Color(white: 0.204) : Color(white: 0.895)
    }
    static var card: Color {
        isDarkBase ? Color(white: 0.139) : Color.white
    }
    /// 入力欄・検索欄・セグメントのような、面の上に置く操作部品の地。
    static var control: Color {
        isDarkBase ? Color.white.opacity(0.085) : Color.black.opacity(0.055)
    }
    /// セグメントの選ばれている側。地（control）より一段はっきりさせる。
    static var controlSelected: Color {
        isDarkBase ? Color.white.opacity(0.17) : Color.white
    }
    static var cardBorder: Color {
        isDarkBase ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
    static var background: Color { canvas }
    static var surface: Color {
        isDarkBase ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    static var ink: Color {
        isDarkBase ? Color(white: 0.93) : Color(white: 0.10)
    }
    static var muted: Color {
        isDarkBase ? Color(white: 0.62) : Color(white: 0.42)
    }
    static var accent: Color {
        isDarkBase ? Color(red: 0.33, green: 0.60, blue: 1.0) : Color(red: 0.0, green: 0.40, blue: 0.92)
    }
    static var separator: Color {
        isDarkBase ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    /// 選択中の行・セグメント。色を付けず、面を一段明るく（暗く）するだけにする。
    static var selection: Color {
        isDarkBase ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }
    static var hover: Color {
        isDarkBase ? Color.white.opacity(0.05) : Color.black.opacity(0.045)
    }
    static var shadow: Color {
        Color.black.opacity(isDarkBase ? 0.5 : 0.12)
    }
    /// 稼働中・許可の目印（状態ドットと同じ落ち着いた緑）
    static let online = Color(red: 0.30, green: 0.78, blue: 0.45)
    /// 拒否・削除・エラーの目印（ハートや破壊的な操作と同じ赤）
    static let negative = Color(red: 1.0, green: 0.27, blue: 0.23)
    /// 「どちらとも言えない」「注意」の目印（強い黄・橙ではなく、落ち着いた琥珀）
    static let caution = Color(red: 0.96, green: 0.68, blue: 0.22)
}

// MARK: - 見出しつきのカード

/// 標準の GroupBox の代わりに使う、平らなカード。見出しは控えめな文字だけで、枠や色は付けない。
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.appBody.weight(.medium))
                .foregroundStyle(NeomorphicTheme.muted)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassCardSurface())
    }
}

// MARK: - シート共通

extension View {
    /// シートの下地を、アプリ本体と同じ中立の単色にそろえる。
    /// 何も指定しないと OS 標準の半透明になり、デスクトップの色で青や緑に濁る。
    func appSheet() -> some View {
        self
            .foregroundStyle(NeomorphicTheme.ink)
            .background(NeomorphicTheme.canvas)
            .tint(NeomorphicTheme.accent)
    }
}

/// シート上部の見出し。色付きのタイルは使わず、細い無彩色のアイコンと文字だけにする。
struct SheetHeader: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(NeomorphicTheme.muted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - コマンドデッキ背景

/// ホームとライブラリに共通で使う背景です。
/// 背景を常時動かすと内容より演出が目立つため，ここは静的に保ちます。
/// 動きはカードへのホバーやサーバーの稼働状態など，意味のある箇所だけで見せます。
struct CommandDeckBackground: View {
  var body: some View {
    NeomorphicTheme.canvas
      .ignoresSafeArea()
      .allowsHitTesting(false)
  }
}

/// ホーム・管理画面で共通の、平らなカードの面です。
struct GlassCardSurface: View {
  var isHovering = false

  var body: some View {
    // 影は付けず、面の明るさの差だけで下地から浮かせる（平らで静かな見た目にする）。
    RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
      .fill(NeomorphicTheme.card)
      .overlay {
        RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
          .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
      }
  }
}

/// どの一覧でも同じ位置と文字組みで，現在地と件数を示します．
struct LibraryPageHeader: View {
  let title: String
  let subtitle: String
  var count: Int? = nil

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.appLargeTitle)
          .foregroundStyle(NeomorphicTheme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(title)
        Text(subtitle)
          .font(.appBody)
          .foregroundStyle(NeomorphicTheme.muted)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      if let count {
        Text("\(count.formatted())件")
          .font(.appBody.weight(.medium).monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - 平らなセグメント（絞り込み用）

/// 標準のセグメントは選択中が青い塊になって目立ちすぎるので、色を付けない薄い選択表示にした版。
/// 幅は呼び出し側が指定する（サイドバーでは「広がるだけ広がる」指定が使えないため、固定幅で組む）。
struct FlatSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    let width: CGFloat

    var body: some View {
        let inner = width - 4
        let segment = inner / CGFloat(max(options.count, 1))
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
                        .frame(width: segment, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? NeomorphicTheme.controlSelected : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NeomorphicTheme.control))
    }
}

// MARK: - カード

struct CardBackground: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(DS.cardPadding)
            .background(GlassCardSurface(isHovering: isHovering))
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(CardBackground())
    }
}

// MARK: - カードヘッダー（システム設定風のアイコンタイル付き）

struct CardHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            // 角丸のタイルで囲まず、アイコンだけを置く（カードごとに青いタイルが並ぶとテンプレート然として見えるため）。
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(NeomorphicTheme.muted)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(NeomorphicTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct IconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.opacity(0.10))
            .frame(width: size, height: size)
            .overlay(
                safeSystemImage(named: icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.12), lineWidth: 1)
            )
    }

    private func safeSystemImage(named name: String) -> Image {
        if let nsImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return Image(nsImage: nsImage)
        }
        if let nsImage = NSImage(named: NSImage.Name(name)) {
            return Image(nsImage: nsImage)
        }
        return Image(nsImage: NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage())
    }
}

// MARK: - ステータスインジケーター（稼働中はパルスする）

struct StatusDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.45).opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.6 : 0.8)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(active ? Color(red: 0.30, green: 0.78, blue: 0.45) : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear { pulse = active }
        .onChange(of: active) { _, newValue in pulse = newValue }
    }
}

// MARK: - 設定行（ラベル + コントロール）

struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            content
        }
    }
}

/// ラベルを左、スイッチを右端に置く設定行（macOS のシステム設定と同じ並び）。
/// スイッチをラベルのすぐ隣に置くと、行ごとに位置がばらついて見える。
struct SettingToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - コピー可能なテキスト（クリックでコピー、フィードバック付き）

struct CopyableText: View {
    let text: String
    var font: Font = .system(.body, design: .monospaced)
    var tint: Color = .accentColor
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(text)
                    .font(font)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .help("クリックでコピー")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - 統計表示（アイコン + 値 + ラベル）

struct StatPill: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(NeomorphicTheme.accent.opacity(0.1))
        )
    }
}

// MARK: - 入力欄の自動選択を外す

/// 置かれたウィンドウの最初の入力欄の自動選択を，表示直後に一度だけ外す。
struct InitialFirstResponderClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearerView { ClearerView() }
    func updateNSView(_ nsView: ClearerView, context: Context) {}

    final class ClearerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // AppKit が初期の first responder を決めるのはウィンドウが key になった後なので，次のループで外す。
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}
