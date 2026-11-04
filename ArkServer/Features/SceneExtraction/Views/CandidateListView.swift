// ArkServer/Features/SceneExtraction/Views/CandidateListView.swift

import SwiftUI

struct CandidateListView: View {
  let candidates: [CandidateSegment]
  let selectedCandidateID: UUID?
  let canExport: Bool
  let onSelect: (CandidateSegment) -> Void
  let onPreview: (CandidateSegment) -> Void
  let onReview: (CandidateLabel, UUID) -> Void
  let onUpdateStart: (Double, UUID) -> Void
  let onUpdateEnd: (Double, UUID) -> Void
  let onExport: (CandidateSegment) -> Void
  @FocusState private var isReviewFocused: Bool

  private var sortedCandidates: [CandidateSegment] {
    candidates.sorted { $0.score > $1.score }
  }

  private var selectedCandidate: CandidateSegment? {
    guard let selectedCandidateID else { return sortedCandidates.first }
    return sortedCandidates.first { $0.id == selectedCandidateID }
  }

  private var selectedIndex: Int? {
    guard let selectedCandidate else { return nil }
    return sortedCandidates.firstIndex { $0.id == selectedCandidate.id }
  }

  private var reviewedCount: Int {
    candidates.filter { $0.userLabel != nil }.count
  }

  var body: some View {
    SectionCard(title: "候補区間") {
      if candidates.isEmpty {
        ContentUnavailableView(
          "候補がありません",
          systemImage: "scope",
          description: Text("解析後の候補または手動GTがここに表示されます．")
        )
      } else {
        VStack(spacing: 10) {
          quickReviewBar
          Divider()
          candidateScrollView
        }
      }
    }
    .focusable()
    .focusEffectDisabled()
    .focused($isReviewFocused)
    .onKeyPress(phases: .down, action: handleReviewKey)
    .onAppear {
      isReviewFocused = true
    }
  }

  private var quickReviewBar: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(positionText)
          .font(.appHeadline.monospacedDigit())
        Text("判定済み \(reviewedCount)／\(candidates.count)")
          .font(.appCaption)
          .foregroundStyle(.secondary)
      }
      .frame(minWidth: 105, alignment: .leading)

      Button {
        moveSelection(by: -1)
        isReviewFocused = true
      } label: {
        Label("前へ", systemImage: "chevron.left")
      }
      .disabled(!canMove(by: -1))

      Button {
        if let selectedCandidate {
          onPreview(selectedCandidate)
        }
        isReviewFocused = true
      } label: {
        Label("プレビュー", systemImage: "play.fill")
      }

      Spacer(minLength: 8)

      if let selectedCandidate {
        quickLabelButton(.accepted, candidate: selectedCandidate, shortcut: "1")
        quickLabelButton(.uncertain, candidate: selectedCandidate, shortcut: "2")
        quickLabelButton(.rejected, candidate: selectedCandidate, shortcut: "3")
      }

      Spacer(minLength: 8)

      Button {
        moveSelection(by: 1)
        isReviewFocused = true
      } label: {
        Label("次へ", systemImage: "chevron.right")
      }
      .disabled(!canMove(by: 1))
    }
  }

  private var candidateScrollView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(sortedCandidates) { candidate in
            candidateRow(candidate)
              .id(candidate.id)
          }
        }
      }
      .onChange(of: selectedCandidateID) { _, newID in
        guard let newID else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(newID, anchor: .center)
        }
      }
    }
  }

  private func candidateRow(_ candidate: CandidateSegment) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text("ピーク \(timeText(candidate.peakTime))")
            .font(.appBodyStrong)
          Text(String(format: "score %.3f", candidate.score))
            .font(.appMonoCaption)
            .foregroundStyle(.secondary)
          labelBadge(candidate.userLabel)
        }

        HStack(spacing: 5) {
          Text("start")
          TextField(
            "start",
            value: Binding(
              get: { candidate.startTime },
              set: { onUpdateStart($0, candidate.id) }
            ),
            format: .number.precision(.fractionLength(2))
          )
          Text("end")
          TextField(
            "end",
            value: Binding(
              get: { candidate.endTime },
              set: { onUpdateEnd($0, candidate.id) }
            ),
            format: .number.precision(.fractionLength(2))
          )
        }
        .font(.appMonoCaption)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 245)

        Text(candidate.reason.joined(separator: "，"))
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .lineLimit(1)
      }

      Spacer()

      Text(String(format: "A %.2f  B %.2f  C %.2f", candidate.audioScore, candidate.visualScore, candidate.transitionScore))
        .font(.appMonoMicro)
        .foregroundStyle(NeomorphicTheme.muted)

      HStack(spacing: 5) {
        ForEach(CandidateLabel.allCases, id: \.self) { label in
          rowLabelButton(label, candidate: candidate)
        }
      }

      Button("プレビュー") {
        onPreview(candidate)
      }

      Button("書き出し") {
        onExport(candidate)
      }
      .disabled(!canExport)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(candidate.id == selectedCandidateID ? NeomorphicTheme.selection : NeomorphicTheme.control)
    )
    .overlay(
      // 選んでいる行は、面の明るさに加えて細い青の縁で示す（選択の目印）。
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(candidate.id == selectedCandidateID ? NeomorphicTheme.accent.opacity(0.8) : Color.clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect(candidate)
      isReviewFocused = true
    }
  }

  private func quickLabelButton(
    _ label: CandidateLabel,
    candidate: CandidateSegment,
    shortcut: String
  ) -> some View {
    Button {
      onReview(label, candidate.id)
      isReviewFocused = true
    } label: {
      VStack(spacing: 2) {
        Label(label.displayName, systemImage: labelIcon(label))
          .font(.appHeadline)
        Text("キー \(shortcut)")
          .font(.appMicro.monospaced())
          .opacity(0.85)
      }
      .frame(minWidth: 86)
      .padding(.vertical, 5)
    }
    // 塗りつぶさず、色は文字と薄い面だけにする（3色の塗りが並ぶと、判定ボタンが画面で一番目立ってしまう）。
    .buttonStyle(AppActionButtonStyle())
    .tint(labelColor(label))
  }

  private func rowLabelButton(
    _ label: CandidateLabel,
    candidate: CandidateSegment
  ) -> some View {
    let isActive = candidate.userLabel == label
    return Button {
      onReview(label, candidate.id)
      isReviewFocused = true
    } label: {
      Image(systemName: labelIcon(label))
        .font(.system(size: 13, weight: .bold))
        .frame(width: 28, height: 24)
        .foregroundStyle(isActive ? Color.white : labelColor(label))
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isActive ? labelColor(label) : labelColor(label).opacity(0.12))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(labelColor(label).opacity(0.65), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help("\(label.displayName)にして次の未判定候補へ移動")
    .accessibilityLabel("\(label.displayName)にする")
  }

  private func labelBadge(_ label: CandidateLabel?) -> some View {
    Text(label?.displayName ?? "未判定")
      .font(.appMicroStrong)
      .foregroundStyle(label.map(labelColor) ?? NeomorphicTheme.muted)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(
        Capsule()
          .fill((label.map(labelColor) ?? NeomorphicTheme.muted).opacity(0.14))
      )
  }

  private var positionText: String {
    guard let selectedIndex else { return "候補 －／\(candidates.count)" }
    return "候補 \(selectedIndex + 1)／\(candidates.count)"
  }

  private func canMove(by offset: Int) -> Bool {
    guard let selectedIndex else { return false }
    return sortedCandidates.indices.contains(selectedIndex + offset)
  }

  private func moveSelection(by offset: Int) {
    guard let selectedIndex else { return }
    let targetIndex = selectedIndex + offset
    guard sortedCandidates.indices.contains(targetIndex) else { return }
    onPreview(sortedCandidates[targetIndex])
  }

  /// 数値欄の編集中は候補一覧からフォーカスが外れるため，1・2・3を通常入力できます．
  private func handleReviewKey(_ press: KeyPress) -> KeyPress.Result {
    guard let selectedCandidate else { return .ignored }

    switch press.key {
    case "1":
      onReview(.accepted, selectedCandidate.id)
    case "2":
      onReview(.uncertain, selectedCandidate.id)
    case "3":
      onReview(.rejected, selectedCandidate.id)
    default:
      return .ignored
    }
    return .handled
  }

  private func labelColor(_ label: CandidateLabel) -> Color {
    switch label {
    case .accepted:
      return NeomorphicTheme.online
    case .rejected:
      return NeomorphicTheme.negative
    case .uncertain:
      return NeomorphicTheme.caution
    }
  }

  private func labelIcon(_ label: CandidateLabel) -> String {
    switch label {
    case .accepted:
      return "checkmark"
    case .rejected:
      return "xmark"
    case .uncertain:
      return "questionmark"
    }
  }

  private func timeText(_ seconds: Double) -> String {
    let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
    let hours = Int(safeSeconds) / 3_600
    let minutes = Int(safeSeconds) % 3_600 / 60
    let remainingSeconds = Int(safeSeconds) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
  }
}
