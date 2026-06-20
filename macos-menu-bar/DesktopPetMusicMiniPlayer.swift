import AppKit
import SwiftUI

private enum DesktopPetMusicMiniPlayerChrome {
    static let cornerRadius: CGFloat = 24

    static func borderColor(for appearance: NSAppearance?) -> CGColor {
        let match = appearance?.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor
        }
        return NSColor(calibratedWhite: 0.0, alpha: 0.08).cgColor
    }
}

final class DesktopPetMusicMiniPlayerController {
    private static let collapsedSize = NSSize(width: 304, height: 166)
    private static let expandedSize = NSSize(width: 304, height: 414)

    private var panel: DesktopPetMusicMiniPlayerPanel?
    private weak var anchorWindow: NSWindow?

    deinit {
        panel?.orderOut(nil)
    }

    func show(anchorWindow: NSWindow?, musicFeature: DesktopPetMusicFeature) {
        self.anchorWindow = anchorWindow

        if let panel, panel.isVisible {
            panel.setFrame(Self.frame(for: panel.frame.size, anchorWindow: anchorWindow), display: true, animate: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let size = Self.collapsedSize
        let panel = DesktopPetMusicMiniPlayerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        CompanionModalPanelStyle.applyPopupWindowChrome(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        panel.title = "XiaoHuaEr Music"
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.panel = nil
        }

        let view = DesktopPetMusicMiniPlayerView(
            musicFeature: musicFeature,
            closeAction: { [weak panel] in panel?.close() },
            resizeAction: { [weak panel] isExpanded in
                guard let panel else { return }
                let targetSize = isExpanded ? Self.expandedSize : Self.collapsedSize
                panel.setFrame(Self.frame(for: targetSize, preservingPositionOf: panel), display: true, animate: true)
            }
        )
        let contentView = DesktopPetMusicPanelContentView(frame: NSRect(origin: .zero, size: size))
        let hostingView = DesktopPetMusicHostingView(rootView: view)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        panel.contentView = contentView
        panel.setFrame(Self.frame(for: size, anchorWindow: anchorWindow), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()

        self.panel = panel
    }

    private static func frame(for size: NSSize, anchorWindow: NSWindow?) -> NSRect {
        let visibleFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        guard let anchorWindow, anchorWindow.isVisible else {
            return NSRect(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.minY + 96,
                width: size.width,
                height: size.height
            )
        }

        let anchor = anchorWindow.frame
        let gap: CGFloat = 12
        let proposedX: CGFloat
        if anchor.maxX + gap + size.width <= visibleFrame.maxX - 8 {
            proposedX = anchor.maxX + gap
        } else {
            proposedX = anchor.minX - gap - size.width
        }

        let proposedY = anchor.midY - size.height * 0.48
        let x = min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = min(max(proposedY, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func frame(for size: NSSize, preservingPositionOf panel: NSPanel) -> NSRect {
        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let current = panel.frame
        let proposed = NSRect(
            x: current.minX,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        return NSRect(
            x: min(max(proposed.minX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
            y: min(max(proposed.minY, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8),
            width: size.width,
            height: size.height
        )
    }
}

private final class DesktopPetMusicMiniPlayerPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        orderOut(nil)
        onClose?()
        onClose = nil
    }
}

private final class DesktopPetMusicPanelContentView: NSView {
    override var isOpaque: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = DesktopPetMusicMiniPlayerChrome.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = DesktopPetMusicMiniPlayerChrome.borderColor(for: effectiveAppearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = DesktopPetMusicMiniPlayerChrome.cornerRadius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = DesktopPetMusicMiniPlayerChrome.borderColor(for: effectiveAppearance)
    }
}

private final class DesktopPetMusicHostingView<Content: View>: CompanionInteractiveHostingView<Content> {
    override var isOpaque: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }
}

private struct DesktopPetMusicMiniPlayerView: View {
    @ObservedObject var musicFeature: DesktopPetMusicFeature
    let closeAction: () -> Void
    let resizeAction: (Bool) -> Void

    @State private var isExpanded = false

    private var snapshot: DesktopPetMusicPlayerSnapshot {
        musicFeature.snapshot
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            nowPlaying
            controls
            if isExpanded {
                playlist
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesktopPetMusicPlayerSurface())
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.tint)
                    .frame(width: 28, height: 28)
                    .background(XiaoHuaErTheme.tint.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("小花儿音乐")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(snapshot.status.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(DesktopPetMusicWindowDragRegion())

            statusChip

            Button(action: closeAction) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DesktopPetMusicIconButtonStyle(size: 24, symbolSize: 10))
            .help("关闭")
        }
        .contentShape(Rectangle())
    }

    private var statusChip: some View {
        let title = snapshot.playableCount > 0 ? "已验证" : (snapshot.status.isBusy ? "加载中" : "待验证")
        return Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(snapshot.playableCount > 0 ? XiaoHuaErTheme.tint : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                (snapshot.playableCount > 0 ? XiaoHuaErTheme.tint : Color.secondary)
                    .opacity(0.12),
                in: Capsule(style: .continuous)
            )
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(XiaoHuaErTheme.tint.opacity(snapshot.status.isPlaying ? 0.18 : 0.13))
                Image(systemName: snapshot.status.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(XiaoHuaErTheme.tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.currentTrack?.displayTitle ?? "准备播放")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detailLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(DesktopPetMusicPlayerSurface.cardFill, in: RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                .stroke(DesktopPetMusicPlayerSurface.cardStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .overlay(DesktopPetMusicWindowDragRegion())
    }

    private var detailLine: String {
        if let currentTrack = snapshot.currentTrack {
            return currentTrack.displayArtist
        }
        if case .failed(let message) = snapshot.status {
            return message
        }
        return snapshot.playableCount > 0 ? "随机播放已就绪" : "点击播放开始加载歌池"
    }

    private var controls: some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)

                Button(action: toggleList) {
                    Image(systemName: isExpanded ? "list.bullet.rectangle.fill" : "list.bullet")
                }
                .buttonStyle(DesktopPetMusicIconButtonStyle(size: 30, symbolSize: 11))
                .help("播放列表")
            }

            playbackControls
        }
        .frame(height: 38)
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button(action: { musicFeature.playPreviousTrack() }) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(DesktopPetMusicIconButtonStyle(size: 30, symbolSize: 11))
            .disabled(!snapshot.canPlayPrevious || snapshot.status.isBusy)
            .help("上一首")

            Button(action: togglePlayback) {
                Image(systemName: snapshot.status.isPlaying || snapshot.status.isBusy ? "stop.fill" : "play.fill")
            }
            .buttonStyle(DesktopPetMusicIconButtonStyle(tone: .primary, size: 36, symbolSize: 13))
            .help(snapshot.status.isPlaying || snapshot.status.isBusy ? "停止" : "播放")

            Button(action: { musicFeature.playNextTrack() }) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(DesktopPetMusicIconButtonStyle(size: 30, symbolSize: 11))
            .disabled(snapshot.status.isBusy)
            .help("下一首")
        }
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            if snapshot.catalog.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: snapshot.status.isBusy ? "hourglass" : "music.note.list")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(snapshot.status.isBusy ? "正在准备可播放曲目" : "播放后会显示可播放列表")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(snapshot.catalog) { track in
                            DesktopPetMusicTrackRow(
                                track: track,
                                isCurrent: snapshot.currentTrack?.id == track.id && snapshot.status.isPlaying
                            ) {
                                musicFeature.playTrack(track)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 270)
            }
        }
    }

    private func togglePlayback() {
        if snapshot.status.isPlaying || snapshot.status.isBusy {
            musicFeature.stop()
        } else {
            musicFeature.startRandomPlayback()
        }
    }

    private func toggleList() {
        isExpanded.toggle()
        resizeAction(isExpanded)
    }
}

private struct DesktopPetMusicTrackRow: View {
    let track: DesktopPetMusicTrack
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "waveform" : "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? XiaoHuaErTheme.tint : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                (isCurrent ? XiaoHuaErTheme.tint.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: XiaoHuaErTheme.smallRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DesktopPetMusicIconButtonStyle: ButtonStyle {
    var tone: CompanionGlassButtonTone = .neutral
    var size: CGFloat = 30
    var symbolSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(tone.fill)
                    .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.32), radius: 8, x: 0, y: 4)
            )
            .overlay(Circle().stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct DesktopPetMusicWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DesktopPetMusicDragView {
        DesktopPetMusicDragView()
    }

    func updateNSView(_ nsView: DesktopPetMusicDragView, context: Context) {}
}

private final class DesktopPetMusicDragView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct DesktopPetMusicPlayerSurface: View {
    static let panelFill = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 0.12, alpha: 0.96)
            : NSColor(calibratedWhite: 0.985, alpha: 0.98)
    })
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 0.94)
            : NSColor(calibratedWhite: 1.00, alpha: 0.96)
    })
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 1.00, alpha: 0.10)
            : NSColor(calibratedWhite: 0.00, alpha: 0.07)
    })

    var body: some View {
        RoundedRectangle(cornerRadius: DesktopPetMusicMiniPlayerChrome.cornerRadius, style: .continuous)
            .fill(Self.panelFill)
            .overlay(
                RoundedRectangle(cornerRadius: DesktopPetMusicMiniPlayerChrome.cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.42), radius: 18, x: 0, y: 10)
    }
}
