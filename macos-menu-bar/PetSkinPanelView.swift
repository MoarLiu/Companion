import AppKit
import SwiftUI

struct PetSkinPanelView: View {
    @ObservedObject var viewModel: PetSkinPanelViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(viewModel.skins) { skin in
                        PetSkinCardView(
                            skin: skin,
                            isSelected: skin.id == viewModel.selectedSkinID,
                            frames: viewModel.previewProvider.idleFrames(for: skin),
                            selectAction: {
                                viewModel.select(skin)
                            }
                        )
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintpalette")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(XiaoHuaErTheme.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("桌面宠物皮肤")
                    .font(.system(size: 20, weight: .semibold))
                Text("\(viewModel.skins.count) 个皮肤")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(XiaoHuaErTheme.coral)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.openUserSkinFolder()
            } label: {
                Label("打开皮肤文件夹", systemImage: "folder")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 132))
            .help("打开皮肤文件夹")

            Button {
                viewModel.reloadSkins()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 84))
            .help("刷新皮肤")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct PetSkinCardView: View {
    let skin: PetSkinSummary
    let isSelected: Bool
    let frames: [NSImage]
    let selectAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PetSkinAnimatedPreviewView(
                frames: frames,
                fps: skin.manifest.states.first(where: { $0.id == "idle" })?.fps ?? 8
            )
            .frame(height: 150)

            VStack(alignment: .leading, spacing: 5) {
                Text(skin.manifest.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                statusLabel
                Spacer()
                Button {
                    selectAction()
                } label: {
                    Label(isSelected ? "当前使用中" : "切换皮肤", systemImage: isSelected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(CompanionGlassButtonStyle(tone: isSelected ? .neutral : .primary, minWidth: 112))
                .disabled(isSelected || frames.isEmpty)
                .help(isSelected ? "当前使用中" : "切换皮肤")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                .stroke(isSelected ? XiaoHuaErTheme.tint.opacity(0.55) : XiaoHuaErTheme.subtleBorder, lineWidth: 1)
        )
    }

    private var subtitle: String {
        var parts = [skin.origin.label]
        if let author = skin.manifest.author, !author.isEmpty {
            parts.append(author)
        }
        if let version = skin.manifest.version, !version.isEmpty {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLabel: some View {
        if frames.isEmpty {
            Label("不可用", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(XiaoHuaErTheme.coral)
        } else if isSelected {
            Label("已启用", systemImage: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(XiaoHuaErTheme.tint)
        } else {
            Text("可用")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PetSkinAnimatedPreviewView: View {
    let frames: [NSImage]
    let fps: Double
    @State private var frameIndex = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.64))

            if let frame = currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                .stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 1)
        )
        .onReceive(Timer.publish(every: timerInterval, on: .main, in: .common).autoconnect()) { _ in
            guard frames.count > 1 else { return }
            frameIndex = (frameIndex + 1) % frames.count
        }
    }

    private var currentFrame: NSImage? {
        guard !frames.isEmpty else { return nil }
        return frames[frameIndex % frames.count]
    }

    private var timerInterval: TimeInterval {
        1.0 / max(fps, 1)
    }
}
