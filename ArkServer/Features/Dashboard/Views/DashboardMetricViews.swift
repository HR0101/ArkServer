import AppKit
import Charts
import SwiftUI

// MARK: - 重複チェック件数バッジ
struct DuplicateCheckCountBadge: View {
    let title: String
    let count: Int

    var body: some View {
        // 緑・橙の強い色の面はやめ、中立の面に濃い文字で数字だけを見せる。
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.appCaption)
                .foregroundStyle(NeomorphicTheme.muted)
            Text(count.formatted())
                .font(.appMetric)
                .monospacedDigit()
                .foregroundStyle(NeomorphicTheme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NeomorphicTheme.control)
        )
    }
}

// MARK: - リソースゲージ
struct ResourceGauge: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: min(max(value, 0), 100), in: 0...100) {
                Text(label)
            } currentValueLabel: {
                Text("\(Int(value))％")
                    .font(.appMicroStrong)
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(0.85)
            .frame(width: 52, height: 52)

            Text(label)
                .font(.appMicroStrong)
                .foregroundStyle(.secondary)
        }
    }
}
