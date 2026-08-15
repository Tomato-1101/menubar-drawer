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

        applyDefaultPositionsIfNeeded()

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

    /// 引き出しから選ばれたアイテムのメニューを、引き出しのその場に出す。
    ///
    /// アイテムをメニューバーへ戻したりカーソルを飛ばしたりはしない。AX はメニューを開かなくても
    /// 項目を読めるので、読んだ内容で自前のメニューを組んでマウス位置に表示し、選ばれた項目を
    /// AX で実行する。AXMenu を持たないアプリ（ポップオーバー型）だけ従来のやり方に落とす。
    private func activate(_ item: MenuBarItem) {
        let entries = MenuReader.read(item)
        log.notice("activate \(item.displayName, privacy: .public) entries=\(entries.count)")

        guard !entries.isEmpty else {
            revealAndClick(item)
            return
        }

        panel.dismiss()
        showMenu(buildMenu(entries))
    }

    /// メニューは常に引き出しアイコンの真下に出す。
    /// マウス位置に出すと、押したセルの場所によって出てくる位置が毎回変わって落ち着かない。
    private func showMenu(_ menu: NSMenu) {
        guard let button = statusItem.button, let window = button.window else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), in: nil)
    }

    private func buildMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: entry.title, action: #selector(runEntry(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = entry
            menuItem.isEnabled = entry.isEnabled
            menuItem.state = entry.isChecked ? .on : .off
            if !entry.submenu.isEmpty {
                menuItem.submenu = buildMenu(entry.submenu)
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func runEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuEntry else { return }
        MenuReader.perform(entry)
    }

    /// AXMenu を読めないアプリ用のフォールバック。
    /// 押し出しを畳んでアイテムを画面へ戻し、実クリックを合成して本物のメニューを開かせる。
    private func revealAndClick(_ item: MenuBarItem) {
        panel.dismiss()
        let shift = pusher.reveal(itemAt: item.frame.origin.x, targetX: revealTargetX)
        pendingShift += shift
        log.notice("fallback reveal \(item.displayName, privacy: .public) shift=\(shift)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.press(item)
        }
    }

    /// 引き出しアイコンと押し出し帯の初期位置を、メニューバーのできるだけ右（Wi-Fi の左隣）に置く。
    ///
    /// 帯より左が隠れる仕組みなので、帯が右にあるほど多くを隠せるうえ、
    /// フォールバックでアイテムを一時的に戻すときの表示スペースも広くなる。
    /// 値は小さいほど右（実測: Wi-Fi=365, 再生中=223, コントロールセンター=135）。
    /// 一度書いたら以後は上書きしない — ユーザーが ⌘ドラッグで動かした位置を尊重する。
    private func applyDefaultPositionsIfNeeded() {
        let defaults = UserDefaults.standard
        let iconKey = "NSStatusItem Preferred Position menubar-drawer-icon"
        let separatorKey = "NSStatusItem Preferred Position menubar-drawer-separator"
        if defaults.object(forKey: iconKey) == nil { defaults.set(380, forKey: iconKey) }
        if defaults.object(forKey: separatorKey) == nil { defaults.set(390, forKey: separatorKey) }
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
