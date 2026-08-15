import AppKit
import ApplicationServices
import OSLog

/// 状態遷移は .notice で書く。.info/.debug は永続化されず `log show` で追えないため
/// （field で消える不具合を後から追えなくなる）
let log = Logger(subsystem: "com.tomato.menubar-drawer", category: "drawer")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pusher: ItemPusher!
    private var panel: DrawerPanel!

    /// reveal で一時的に緩めた押し出し量。メニューを閉じたら戻す
    private var pendingShift: CGFloat = 0
    private var restoreMonitor: Any?
    private var restoreTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionIfNeeded()
        log.notice("launched trusted=\(AXIsProcessTrusted())")

        // 引き出しのアイコン。先に作ることで、後から作る押し出し帯より右（＝時計寄り）に置く
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "menubar-drawer-icon"
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "メニューバーの引き出しを開く"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        pusher = ItemPusher()
        pusher.push()

        panel = DrawerPanel(
            onSelect: { [weak self] item in self?.activate(item) },
            onExtract: { [weak self] item in self?.extract(item) }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 終了時に押し出しを解除しないと、アイテムが画面外に取り残されて見えなくなる
        pusher?.release()
    }

    // MARK: - 引き出しの開閉

    @objc private func handleClick() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isShown {
            panel.dismiss()
        } else {
            openDrawer()
        }
    }

    private func openDrawer() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return }

        // 前回 reveal したぶんが残っていれば、開くタイミングで押し出しを揃え直す
        restorePush()

        // 引き出しに載せるのは「押し出されて隠れているもの」だけ。
        // メニューバーに出ているアイテムまで並べると同じものが二か所に見えてしまう
        let hidden = StatusItemScanner.scan().filter { $0.isOffscreen }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(items: hidden, below: anchor, on: screen)
    }

    /// 引き出しから選ばれたアイテムを押す。
    /// メニューはステータスアイテム自身の位置に開くので、押す前に必要なぶんだけ押し出しを緩めて
    /// 対象を画面内へ引き戻しておく（緩めないと、メニューが画面外に開いて見えない）。
    private func activate(_ item: MenuBarItem) {
        panel.dismiss()

        let shift = pusher.reveal(itemAt: item.frame.origin.x, targetX: revealTargetX)
        pendingShift += shift
        log.notice("activate \(item.displayName, privacy: .public) x=\(item.frame.origin.x) shift=\(shift)")

        // 押し出しを緩めた直後はメニューバーが再レイアウト中で、AX も移動途中の座標を返す
        // （実測: ノッチの下 x=825 を返し、そこを押したら boringNotch が開いた）。落ち着かせてから押す。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.press(item)
        }
    }

    /// アイテムを引き戻す先。ノッチの右側でなければ掴めない
    private var revealTargetX: CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        if let notchRight = screen?.auxiliaryTopRightArea?.minX {
            return notchRight + 40
        }
        return (screen?.frame.width ?? 1440) * 0.6
    }

    /// 引き出しから上へ引っ張り出されたアイテムを、メニューバーに常駐させる。
    /// 引き出しアイコンの右隣へ ⌘ドラッグすれば押し出し帯の外側になり、以後は常に見える。
    private func extract(_ item: MenuBarItem) {
        panel.dismiss()
        let shift = pusher.reveal(itemAt: item.frame.origin.x, targetX: revealTargetX)
        log.notice("extract \(item.displayName, privacy: .public) 開始 shift=\(shift)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  let button = self.statusItem.button,
                  let window = button.window
            else { return }

            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            ItemMover.move(item, toX: anchor.maxX + 14) { moved in
                log.notice("extract \(item.displayName, privacy: .public) moved=\(moved)")
                self.pusher.restore(shift: shift)
            }
        }
    }

    private func press(_ item: MenuBarItem) {
        let frame = StatusItemScanner.liveFrame(of: item)
        let ok = StatusItemScanner.click(item)
        log.notice("click \(item.displayName, privacy: .public) x=\(frame.origin.x) ok=\(ok)")
        if pendingShift > 0 { scheduleRestore() }
    }

    /// 開いたメニューが閉じたら押し出しを元に戻す。
    /// メニューを閉じる操作（どこかのクリック / Esc）を拾い、取りこぼした場合の保険に時間切れも置く。
    private func scheduleRestore() {
        cancelRestoreWatchers()
        restoreMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyUp]) {
            [weak self] _ in
            self?.restorePush()
        }
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.restorePush()
        }
    }

    private func restorePush() {
        cancelRestoreWatchers()
        guard pendingShift > 0 else { return }
        pusher.restore(shift: pendingShift)
        pendingShift = 0
    }

    private func cancelRestoreWatchers() {
        if let restoreMonitor { NSEvent.removeMonitor(restoreMonitor) }
        restoreMonitor = nil
        restoreTimer?.invalidate()
        restoreTimer = nil
    }

    // MARK: - 右クリックメニュー

    private func showContextMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: pusher.isPushing ? "メニューバーへ戻す（折りたたみ解除）" : "メニューバーを折りたたむ",
            action: #selector(togglePush),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(
            title: "アクセシビリティ設定を開く",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(withTitle: "menubar-drawer を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePush() {
        pendingShift = 0
        if pusher.isPushing {
            pusher.release()
        } else {
            pusher.push()
        }
    }

    // MARK: - 権限

    private func requestAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
