import AppKit
import SwiftUI

/// メニューバー直下に降りてくる引き出し。
/// 背後にあるのは他アプリとデスクトップなので、ガラスは NSVisualEffectView(.behindWindow) で作る
/// （SwiftUI の Material / glassEffect は同一ウィンドウ内しかサンプルできず灰色の塊になる）。
final class DrawerPanel: NSPanel {

    private let hostingView: NSHostingView<DrawerView>
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(onSelect: @escaping (MenuBarItem) -> Void) {
        hostingView = NSHostingView(rootView: DrawerView(items: [], onSelect: onSelect))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let glass = GlassBackgroundView(frame: .zero)
        glass.autoresizingMask = [.width, .height]
        hostingView.autoresizingMask = [.width, .height]
        glass.addSubview(hostingView)
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    /// 指定した画面座標（メニューバー上のボタン位置）の真下に、右端を揃えて開く。
    func show(items: [MenuBarItem], below anchor: NSRect, on screen: NSScreen) {
        hostingView.rootView = DrawerView(items: items, onSelect: hostingView.rootView.onSelect)
        let size = hostingView.fittingSize
        setContentSize(size)

        // 押したアイコンの真下から降りてくるよう、アイコンの中心に引き出しの中心を合わせる
        let margin: CGFloat = 8
        var x = anchor.midX - size.width / 2
        x = min(x, screen.frame.maxX - size.width - margin)
        x = max(x, screen.frame.minX + margin)
        let y = anchor.minY - size.height - 4

        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        startDismissMonitors()
    }

    func dismiss() {
        stopDismissMonitors()
        orderOut(nil)
    }

    var isShown: Bool { isVisible }

    // MARK: - 引き出しの外を触ったら閉じる

    private func startDismissMonitors() {
        stopDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    private func stopDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

/// 背後の他アプリをライブでぼかすガラス。角丸は maskImage で与える。
private final class GlassBackgroundView: NSVisualEffectView {
    private var maskSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        alphaValue = 0.92  // 引き出しは中身を読む面なので、HUD ピルより濃いめにする
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func layout() {
        super.layout()
        if abs(bounds.width - maskSize.width) > 0.5 || abs(bounds.height - maskSize.height) > 0.5 {
            maskSize = bounds.size
            maskImage = Self.roundedMask(radius: 14)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - 引き出しの中身

struct DrawerView: View {
    let items: [MenuBarItem]
    let onSelect: (MenuBarItem) -> Void

    private let cellWidth: CGFloat = 78
    private let cellHeight: CGFloat = 70

    /// 6列を上限に、アイテム数に合わせて詰める（少ないときに横長の空白が出ないように）
    private var columnCount: Int { max(1, min(6, items.count)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: 6), count: columnCount),
                    spacing: 6
                ) {
                    ForEach(items) { item in
                        DrawerCell(item: item, width: cellWidth, height: cellHeight) { onSelect(item) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: items.isEmpty
               ? 320
               : CGFloat(columnCount) * cellWidth + 6 * CGFloat(columnCount - 1) + 28)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.primary.opacity(0.4))
            Text("メニューバーのアイテムが見つかりません")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.7))
            Text("システム設定 → プライバシーとセキュリティ → アクセシビリティ で\nmenubar-drawer を許可してください")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct DrawerCell: View {
    let item: MenuBarItem
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                Text(item.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary.opacity(0.78))
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .onHover { isHovered = $0 }
        .help(item.help.isEmpty ? item.displayName : item.help)
    }

    private var icon: some View {
        Group {
            if let image = item.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 26))
                    .foregroundStyle(.primary.opacity(0.5))
            }
        }
        .frame(width: 32, height: 32)
    }
}
