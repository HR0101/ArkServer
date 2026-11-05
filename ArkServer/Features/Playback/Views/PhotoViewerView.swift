import SwiftUI
import AppKit
import ImageIO

enum PhotoImageLoader {
    nonisolated static func loadDisplayImage(from url: URL, maxPixelSize: CGFloat = 2400) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

// 画像をウィンドウ全体に表示するフルスクリーンビューア。
// 動画の全画面再生（PlaybackCoordinator）と同じ仕組みで、再生中はライブラリ画面ごと差し替わる。
// クリックの左右ゾーン・矢印キーで前後の画像へ移動でき、漫画モードでは送り方向が反転する。
struct PhotoViewerView: View {
    private enum EdgePreviewSide {
        case previous
        case next
    }

    @State var current: VideoItem
    let dataManager: LibraryViewModel

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @AppStorage("isMangaMode") private var isMangaMode = false
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    @FocusState private var isFocused: Bool

    @State private var image: NSImage?
    @State private var fileMissing = false
    @State private var controlsVisible = true
    @State private var edgePreviewSide: EdgePreviewSide?
    @State private var imageCache: [UUID: NSImage] = [:]
    @State private var previewImageCache: [UUID: NSImage] = [:]
    @State private var thumbnailCache: [UUID: NSImage] = [:]
    @State private var loadingTask: Task<Void, Never>?
    @State private var preloadTask: Task<Void, Never>?
    @State private var previewPreloadTask: Task<Void, Never>?
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hideFilmstripTask: Task<Void, Never>?
    @State private var filmstripVisible = false
    @State private var filmstripPreloadCenterID: UUID?
    @State private var visiblePhotos: [VideoItem]
    @State private var showDeleteConfirmation = false

    // マウスドラッグで範囲選択してその領域へズームする状態。
    @State private var zoom = MarqueeZoomState()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?

    private let preloadRadius = 8
    private let imageCacheRadius = 12
    private let previewPreloadRadius = 18
    private let previewCacheRadius = 24
    private let previewPixelSize: CGFloat = 1200
    private let controlsAutoHideDelay: UInt64 = 2_000_000_000
    private let filmstripThumbnailPixelSize: CGFloat = 220
    private let filmstripAutoHideDelay: UInt64 = 2_000_000_000
    private let filmstripPreviewWidth: CGFloat = 420
    private let filmstripPreviewHeight: CGFloat = 270
    private let filmstripThumbSize: CGFloat = 138
    private let filmstripBarHeight: CGFloat = 198
    private let topControlsHoverHeight: CGFloat = 96
    private let filmstripPreloadRadius = 12

    init(photos: [VideoItem], current: VideoItem, dataManager: LibraryViewModel) {
        self.dataManager = dataManager
        _current = State(initialValue: current)
        _visiblePhotos = State(initialValue: photos)
    }

    private var currentIndex: Int? {
        visiblePhotos.firstIndex(where: { $0.id == current.id })
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            imageLayer

            if controlsVisible {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

        }
        .overlay(alignment: .bottom) {
            if filmstripVisible {
                bottomFilmstrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            load()
            hideControls()
        }
        .onChange(of: current.id) { _, _ in
            coordinator.updateLibraryReturnSelection(mediaID: current.id)
            zoom.reset()
            load()
        }
        .onDisappear {
            loadingTask?.cancel()
            preloadTask?.cancel()
            previewPreloadTask?.cancel()
            thumbnailTask?.cancel()
            hideControlsTask?.cancel()
            hideFilmstripTask?.cancel()
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
        .appConfirmationPanel(
            "削除方法を選んでください",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("アプリ内のゴミ箱へ") {
                deleteCurrentPhoto {
                    dataManager.moveToTrash(videoIDs: $0)
                    return true
                }
            }
            Button("完全に削除", role: .destructive) {
                deleteCurrentPhoto {
                    dataManager.deleteVideos(videoIDs: $0)
                    return true
                }
            }
            Button("実ファイルをMacのゴミ箱へ移動", role: .destructive) {
                deleteCurrentPhoto { ids in
                    let result = dataManager.moveMediaFilesToSystemTrash(
                        videoIDs: ids
                    )
                    return result.movedVideoIDs.contains(current.id)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("アプリ内のゴミ箱は復元できます．Macのゴミ箱へ移動すると，リンク元を含む実ファイルも移動します．")
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if fileMissing {
            ContentUnavailableView(
                "ファイルが見つかりません",
                systemImage: "questionmark.app.dashed",
                description: Text("メディアファイルが移動または削除された可能性があります")
            )
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let image {
            GeometryReader { geo in
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(x: zoom.scaleX, y: zoom.scaleY, anchor: .topLeading)
                        .offset(zoom.offset)

                    interactionLayer(in: geo.size)

                    if let s = marqueeStart, let c = marqueeCurrent {
                        MarqueeRectangleShape(start: s, current: c)
                    }
                    edgePreviewOverlay
                }
                .clipped()
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func interactionLayer(in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                marqueeZoomGesture(start: $marqueeStart, current: $marqueeCurrent, containerSize: size) { rect in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoom.zoom(into: rect, containerSize: size)
                    }
                }
            )
            .onTapGesture { location in
                // ズーム中のクリックはフィット表示へ戻す。等倍のときだけ左右送りにする。
                if zoom.isZoomed {
                    withAnimation(.easeInOut(duration: 0.2)) { zoom.reset() }
                    return
                }
                let width = size.width
                if location.x < width * 0.3 {
                    changeItem(offset: isMangaMode ? 1 : -1)
                } else if location.x > width * 0.7 {
                    changeItem(offset: isMangaMode ? -1 : 1)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHoverAffordances(for: location, in: size)
                case .ended:
                    edgePreviewSide = nil
                    hideControlsAfterDelay()
                    hideFilmstripAfterDelay()
                }
            }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(current.originalFilename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if visiblePhotos.count > 1, let idx = currentIndex {
                Text("\(idx + 1) / \(visiblePhotos.count)")
                    .font(.appCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            if visiblePhotos.count > 1 {
                Button { isMangaMode.toggle() } label: {
                    Text(isMangaMode ? "漫画モード" : "通常モード")
                        .font(.appCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        // 入っているモードは面を一段明るくして示す（色は付けない）。
                        .background(isMangaMode ? PlayerChrome.chip : PlayerChrome.hover)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("削除方法を選ぶ")

            Button {
                if let url = dataManager.fileURL(for: current) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("外部アプリで開く")

            Button { coordinator.close() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("閉じる")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var edgePreviewOverlay: some View {
        if let side = edgePreviewSide, visiblePhotos.count > 1 {
            HStack {
                if side == .previous {
                    edgePreviewPanel(side: .previous)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    edgePreviewPanel(side: .next)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(.easeInOut(duration: 0.12), value: edgePreviewSide)
        }
    }

    @ViewBuilder
    private var bottomFilmstrip: some View {
        if visiblePhotos.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(visiblePhotos) { photo in
                            Button {
                                current = photo
                            } label: {
                                filmstripCell(for: photo)
                            }
                            .buttonStyle(.plain)
                            .id(photo.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .frame(height: filmstripBarHeight)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.86), .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        showFilmstrip()
                    case .ended:
                        hideFilmstripAfterDelay()
                    }
                }
                .task(id: current.id) {
                    await Task.yield()
                    scrollFilmstripToCurrent(proxy)
                    preloadFilmstripThumbnails(around: currentIndex)
                }
                .onAppear {
                    scrollFilmstripToCurrent(proxy)
                    preloadFilmstripThumbnails()
                }
            }
        }
    }

    private func edgePreviewPanel(side: EdgePreviewSide) -> some View {
        let targetIndex = side == .previous
            ? currentIndex.map { $0 + (isMangaMode ? 1 : -1) }
            : currentIndex.map { $0 + (isMangaMode ? -1 : 1) }
        let targetItem = targetIndex.flatMap { visiblePhotos.indices.contains($0) ? visiblePhotos[$0] : nil }

        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.24))

                if let targetItem, let thumbnail = thumbnailCache[targetItem.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                } else if targetItem != nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: side == .previous ? "chevron.left" : "chevron.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .frame(width: filmstripPreviewWidth, height: filmstripPreviewHeight)
        }
        .frame(width: filmstripPreviewWidth, height: filmstripPreviewHeight)
        .task(id: targetItem?.id) {
            guard let targetItem else { return }
            await loadThumbnailIfNeeded(for: targetItem)
        }
    }

    private func filmstripCell(for photo: VideoItem) -> some View {
        let isCurrent = photo.id == current.id

        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))

                if let thumbnail = thumbnailCache[photo.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.8))
                }
            }
            .frame(width: filmstripThumbSize, height: filmstripThumbSize)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent ? Color.white.opacity(0.9) : .white.opacity(0.15), lineWidth: isCurrent ? 2 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Text("現在")
                        .font(.appMicro.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.9), in: Capsule())
                        .padding(6)
                }
            }

            Text(photo.originalFilename)
                .font(.appMicro)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 108)
        }
        .padding(.vertical, 2)
    }

    private func deleteCurrentPhoto(
        performDeletion: ([UUID]) -> Bool
    ) {
        let idToDelete = current.id
        guard let currentIdx = currentIndex else { return }
        guard performDeletion([idToDelete]) else { return }
        let remainingPhotos = visiblePhotos.filter { $0.id != idToDelete }

        imageCache[idToDelete] = nil
        previewImageCache[idToDelete] = nil
        thumbnailCache[idToDelete] = nil
        edgePreviewSide = nil

        if remainingPhotos.isEmpty {
            coordinator.close()
        } else {
            let nextIndex = min(currentIdx, remainingPhotos.count - 1)
            visiblePhotos = remainingPhotos
            current = remainingPhotos[nextIndex]
        }

    }

    private func changeItem(offset: Int) {
        guard let idx = currentIndex else { return }
        let nextIdx = idx + offset
        if nextIdx >= 0 && nextIdx < visiblePhotos.count {
            current = visiblePhotos[nextIdx]
        }
    }

    private func updateEdgePreview(for location: CGPoint, width: CGFloat) {
        guard visiblePhotos.count > 1, width > 0 else {
            edgePreviewSide = nil
            return
        }

        let edgeActivationWidth = max(120, min(220, width * 0.16))
        let leftThreshold = edgeActivationWidth
        let rightThreshold = width - edgeActivationWidth

        if location.x <= leftThreshold {
            edgePreviewSide = .previous
        } else if location.x >= rightThreshold {
            edgePreviewSide = .next
        } else {
            edgePreviewSide = nil
        }
    }

    private func updateHoverAffordances(for location: CGPoint, in size: CGSize) {
        guard visiblePhotos.count > 1, size.width > 0, size.height > 0 else {
            edgePreviewSide = nil
            return
        }

        if location.y <= topControlsHoverHeight {
            showControls()
        } else if controlsVisible {
            hideControlsAfterDelay()
        }

        let bottomThreshold = max(92, min(140, size.height * 0.16))
        if location.y >= size.height - bottomThreshold {
            edgePreviewSide = nil
            showFilmstrip()
            return
        }

        let previousSide = edgePreviewSide
        updateEdgePreview(for: location, width: size.width)
        if previousSide != nil || filmstripVisible {
            hideFilmstrip()
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        _ = shortcutSettingsVersion

        if MediaShortcutSettings.matches(.photoPrevious, press: press) {
            changeItem(offset: isMangaMode ? 1 : -1)
            return .handled
        } else if MediaShortcutSettings.matches(.photoNext, press: press) {
            changeItem(offset: isMangaMode ? -1 : 1)
            return .handled
        } else if MediaShortcutSettings.matches(.photoToggleMangaMode, press: press) {
            isMangaMode.toggle()
            return .handled
        } else if MediaShortcutSettings.matches(.photoDelete, press: press) {
            showDeleteConfirmation = true
            return .handled
        } else if MediaShortcutSettings.matches(.photoClose, press: press) {
            coordinator.close()
            return .handled
        }

        switch press.key {
        case .escape:
            coordinator.close()
            return .handled
        default:
            return .ignored
        }
    }

    private func load() {
        loadingTask?.cancel()
        fileMissing = false

        if let cached = imageCache[current.id] {
            image = cached
            preloadNearbyImages()
            return
        }

        let cachedPreview = previewImageCache[current.id] ?? thumbnailCache[current.id]
        if let preview = cachedPreview {
            image = preview
        } else {
            image = nil
        }
        guard let url = dataManager.fileURL(for: current) else {
            fileMissing = true
            return
        }
        let targetID = current.id
        let needsPreview = cachedPreview == nil
        preloadPreviewImages()
        loadingTask = Task.detached(priority: .userInitiated) {
            if needsPreview,
               let preview = PhotoImageLoader.loadDisplayImage(from: url, maxPixelSize: previewPixelSize) {
                await MainActor.run {
                    guard current.id == targetID, imageCache[targetID] == nil else { return }
                    previewImageCache[targetID] = preview
                    image = preview
                    trimPreviewImageCache()
                }
            }

            guard !Task.isCancelled else { return }
            let loaded = PhotoImageLoader.loadDisplayImage(from: url)
            await MainActor.run {
                // 読み込み中に別の画像へ移動していた場合は破棄する
                guard current.id == targetID else { return }
                if let loaded {
                    imageCache[targetID] = loaded
                    image = loaded
                    trimImageCache()
                    preloadPreviewImages()
                    preloadNearbyImages()
                } else {
                    fileMissing = true
                }
            }
        }
    }

    private func showControls() {
        hideControlsTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible = true
        }
    }

    private func hideControls() {
        hideControlsTask?.cancel()
        controlsVisible = false
    }

    private func hideControlsAfterDelay() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: controlsAutoHideDelay)
            guard !Task.isCancelled else { return }
            hideControls()
        }
    }

    private func showFilmstrip() {
        hideFilmstripTask?.cancel()
        let shouldPreload = filmstripPreloadCenterID != current.id
        withAnimation(.easeInOut(duration: 0.2)) {
            filmstripVisible = true
        }
        if shouldPreload {
            preloadFilmstripThumbnails(around: currentIndex)
        }
    }

    private func hideFilmstrip() {
        hideFilmstripTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            filmstripVisible = false
        }
    }

    private func hideFilmstripAfterDelay() {
        hideFilmstripTask?.cancel()
        hideFilmstripTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: filmstripAutoHideDelay)
            guard !Task.isCancelled else { return }
            hideFilmstrip()
        }
    }

    private func scrollFilmstripToCurrent(_ proxy: ScrollViewProxy) {
        guard visiblePhotos.contains(where: { $0.id == current.id }) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(current.id, anchor: .center)
        }
    }

    private func preloadFilmstripThumbnails() {
        preloadFilmstripThumbnails(around: currentIndex)
    }

    private func preloadFilmstripThumbnails(around index: Int?) {
        guard filmstripPreloadCenterID != current.id || thumbnailTask == nil else { return }
        thumbnailTask?.cancel()
        thumbnailTask = nil

        guard let index else { return }
        filmstripPreloadCenterID = current.id
        let lower = max(0, index - filmstripPreloadRadius)
        let upper = min(visiblePhotos.count - 1, index + filmstripPreloadRadius)
        guard lower <= upper else { return }

        let priorityIDs = Set(nearbyPhotos(around: index).map(\.id) + [current.id])
        let windowPhotos = Array(visiblePhotos[lower...upper])
            .sorted { lhs, rhs in
                if priorityIDs.contains(lhs.id) != priorityIDs.contains(rhs.id) {
                    return priorityIDs.contains(lhs.id)
                }
                return abs((visiblePhotos.firstIndex(where: { $0.id == lhs.id }) ?? index) - index)
                    < abs((visiblePhotos.firstIndex(where: { $0.id == rhs.id }) ?? index) - index)
            }

        guard thumbnailTask == nil else { return }
        let targets = windowPhotos
            .filter { thumbnailCache[$0.id] == nil }
            .compactMap { item -> (UUID, URL)? in
                guard let url = dataManager.fileURL(for: item) else { return nil }
                return (item.id, url)
            }

        guard !targets.isEmpty else { return }

        thumbnailTask = Task.detached(priority: .utility) {
            await ThumbnailDecodeLimiter.shared.acquire()
            defer { Task { await ThumbnailDecodeLimiter.shared.release() } }

            defer {
                Task { @MainActor in
                    thumbnailTask = nil
                }
            }

            for (id, url) in targets {
                guard !Task.isCancelled else { return }
                guard let loaded = PhotoImageLoader.loadDisplayImage(from: url, maxPixelSize: filmstripThumbnailPixelSize) else { continue }
                await MainActor.run {
                    guard thumbnailCache[id] == nil else { return }
                    thumbnailCache[id] = loaded
                }
            }
        }
    }

    private func loadThumbnailIfNeeded(for item: VideoItem) async {
        guard thumbnailCache[item.id] == nil,
              let url = dataManager.fileURL(for: item) else { return }

        let loaded = await Task.detached(priority: .utility) {
            await ThumbnailDecodeLimiter.shared.acquire()
            defer { Task { await ThumbnailDecodeLimiter.shared.release() } }
            return PhotoImageLoader.loadDisplayImage(from: url, maxPixelSize: filmstripThumbnailPixelSize)
        }.value

        guard thumbnailCache[item.id] == nil, let loaded else { return }
        thumbnailCache[item.id] = loaded
    }

    private func preloadNearbyImages() {
        guard let index = currentIndex else { return }
        preloadTask?.cancel()
        let targets = nearbyPhotos(around: index, radius: preloadRadius)
            .filter { imageCache[$0.id] == nil }
            .compactMap { item -> (UUID, URL)? in
                guard let url = dataManager.fileURL(for: item) else { return nil }
                return (item.id, url)
            }

        preloadPreviewImages()

        guard !targets.isEmpty else {
            trimImageCache()
            trimPreviewImageCache()
            return
        }

        preloadTask = Task.detached(priority: .utility) {
            for (id, url) in targets {
                guard !Task.isCancelled else { return }
                await ThumbnailDecodeLimiter.shared.acquire()
                let loaded = PhotoImageLoader.loadDisplayImage(from: url)
                await ThumbnailDecodeLimiter.shared.release()
                guard !Task.isCancelled, let loaded else { continue }
                await MainActor.run {
                    guard imageCache[id] == nil else { return }
                    imageCache[id] = loaded
                    trimImageCache()
                }
            }
        }
    }

    private func preloadPreviewImages() {
        guard let index = currentIndex else { return }
        previewPreloadTask?.cancel()
        let targets = nearbyPhotos(around: index, radius: previewPreloadRadius)
            .filter { previewImageCache[$0.id] == nil && imageCache[$0.id] == nil }
            .compactMap { item -> (UUID, URL)? in
                guard let url = dataManager.fileURL(for: item) else { return nil }
                return (item.id, url)
            }

        guard !targets.isEmpty else {
            trimPreviewImageCache()
            return
        }

        previewPreloadTask = Task.detached(priority: .utility) {
            for (id, url) in targets {
                guard !Task.isCancelled else { return }
                await ThumbnailDecodeLimiter.shared.acquire()
                let loaded = PhotoImageLoader.loadDisplayImage(from: url, maxPixelSize: previewPixelSize)
                await ThumbnailDecodeLimiter.shared.release()
                guard !Task.isCancelled, let loaded else { continue }
                await MainActor.run {
                    guard previewImageCache[id] == nil, imageCache[id] == nil else { return }
                    previewImageCache[id] = loaded
                    trimPreviewImageCache()
                }
            }
        }
    }

    private func nearbyPhotos(around index: Int, radius: Int) -> [VideoItem] {
        let lower = max(0, index - radius)
        let upper = min(visiblePhotos.count - 1, index + radius)
        guard lower <= upper else { return [] }
        return (lower...upper)
            .filter { $0 != index }
            .sorted { abs($0 - index) < abs($1 - index) }
            .map { visiblePhotos[$0] }
    }

    private func nearbyPhotos(around index: Int) -> [VideoItem] {
        nearbyPhotos(around: index, radius: preloadRadius)
    }

    private func trimImageCache() {
        guard let index = currentIndex else { return }
        let keepIDs = Set((max(0, index - imageCacheRadius)...min(visiblePhotos.count - 1, index + imageCacheRadius)).map { visiblePhotos[$0].id })
        imageCache = imageCache.filter { keepIDs.contains($0.key) }
    }

    private func trimPreviewImageCache() {
        guard let index = currentIndex else { return }
        let keepIDs = Set((max(0, index - previewCacheRadius)...min(visiblePhotos.count - 1, index + previewCacheRadius)).map { visiblePhotos[$0].id })
        previewImageCache = previewImageCache.filter { keepIDs.contains($0.key) }
    }
}
