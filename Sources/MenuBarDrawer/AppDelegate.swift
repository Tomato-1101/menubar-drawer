import AppKit
import ApplicationServices
import OSLog

/// 状態遷移は .notice で書く。.info/.debug は永続化されず `log show` で追えないため
let log = Logger(subsystem: "com.tomato.menubar-drawer", category: "drawer")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pusher: ItemPusher!
    private var panel: DrawerPanel!

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

        panel = DrawerPanel { [weak self] item in
            self?.activate(item)
        }
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

        // 引き出しに載せるのは「押し出されて隠れているもの」だけ。
        // メニューバーに出ているアイテムまで並べると同じものが二か所に見えてしまう
        let hidden = StatusItemScanner.scan().filter { $0.isOffscreen }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(items: hidden, below: anchor, on: screen)
    }

    // MARK: - 引き出しからメニューを開く

    /// 選ばれたアイテムのメニューを、引き出しアイコンの真下に出す。
    ///
    /// アイテムは画面外に押し出したまま動かさない。カーソルも動かさない。
    /// AX はメニューを開かなくても項目を読めるので、読んだ内容で自前のメニューを組んで表示し、
    /// 選ばれた項目を AX で実行する。
    private func activate(_ item: MenuBarItem) {
        let entries = MenuReader.read(item)
        log.notice("activate \(item.displayName, privacy: .public) entries=\(entries.count)")

        panel.dismiss()
        showMenu(entries.isEmpty ? unsupportedMenu(for: item) : buildMenu(entries))
    }

    /// メニューは常に引き出しアイコンの真下に出す。
    /// マウス位置に出すと、押したセルの場所によって出てくる位置が毎回変わって落ち着かない。
    private func showMenu(_ menu: NSMenu) {
        guard let button = statusItem.button, let window = button.window else { return }
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

    /// ポップオーバー型（クリックするとパネルが出るタイプ）は AX にメニューが無く、中身を読めない。
    ///
    /// 代わりにアイテムをメニューバーへ戻して合成クリックする、という手も動きはするが、
    /// カーソルが勝手に飛ぶ挙動になるので入れない（Tomato 指示: 無理なら無理と言う・
    /// 無理やりマウスを動かす動作は絶対に入れない）。できないことはそう表示して、
    /// 折りたたみを一時解除する導線だけ出す。
    private func unsupportedMenu(for item: MenuBarItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for line in [
            "\(item.displayName) は引き出しから開けません",
            "クリックでパネルを出すタイプのため、メニューの中身を読み取れません"
        ] {
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }

        menu.addItem(.separator())

        let release = NSMenuItem(title: "折りたたみを一時解除してメニューバーに戻す",
                                 action: #selector(togglePush), keyEquivalent: "")
        release.target = self
        menu.addItem(release)

        let hint = NSMenuItem(title: "常に出しておくには ⌘ を押しながら引き出しアイコンより右へドラッグ",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        return menu
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
        if pusher.isPushing {
            pusher.release()
        } else {
            pusher.push()
        }
        log.notice("togglePush isPushing=\(self.pusher.isPushing)")
    }

    // MARK: - 配置と権限

    /// 引き出しアイコンと押し出し帯の初期位置を、メニューバーのできるだけ右（Wi-Fi の左隣）に置く。
    ///
    /// 帯より左が隠れる仕組みなので、帯が右にあるほど多くを隠せる。
    /// 値は小さいほど右（実測: Wi-Fi=365, 再生中=223, コントロールセンター=135）。
    /// 一度書いたら以後は上書きしない — ユーザーが ⌘ドラッグで動かした位置を尊重する。
    private func applyDefaultPositionsIfNeeded() {
        let defaults = UserDefaults.standard
        let iconKey = "NSStatusItem Preferred Position menubar-drawer-icon"
        let separatorKey = "NSStatusItem Preferred Position menubar-drawer-separator"
        if defaults.object(forKey: iconKey) == nil { defaults.set(380, forKey: iconKey) }
        if defaults.object(forKey: separatorKey) == nil { defaults.set(390, forKey: separatorKey) }
    }

    private func requestAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
