import AppKit
import ApplicationServices
import OSLog

/// 状態遷移は .notice で書く。.info/.debug は永続化されず `log show` で追えないため
let log = Logger(subsystem: "com.tomato.menubar-drawer", category: "drawer")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pusher: ItemPusher!
    private var panel: DrawerPanel!

    /// メニューバーに展開中のアイテムを戻すために必要な幅。展開できるのは常に1件だけ
    private var revealedShift: CGFloat = 0
    private var revealedItem: MenuBarItem?
    private var restoreTimer: Timer?

    /// 展開したあと自動でクリックするか。既定 OFF（ON のときだけカーソルが動く）
    private var autoClickEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoClickAfterReveal") }
        set { UserDefaults.standard.set(newValue, forKey: "autoClickAfterReveal") }
    }

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
        restoreTimer?.invalidate()
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

        // 前回の展開が残っていれば畳んでから開く（展開は常に1件だけ）
        restoreReveal()

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

        guard !entries.isEmpty else {
            openWithoutMenu(item)
            return
        }
        showMenu(buildMenu(entries))
    }

    // MARK: - AX にメニューが無いアイテム（ポップオーバー型）

    /// メニューを読めないアイテムを開く。
    ///
    /// 開き方はアプリごとに違い、事前には見分けられないので、押してから何が起きたかで振り分ける。
    /// メニューバーへの展開（revealToMenuBar）は、どれも当たらなかったときの最後の手段。
    private func openWithoutMenu(_ item: MenuBarItem) {
        // Spotlight は押下そのものを無視する（AXPress が success を返すのに何も開かない＝実測）。
        // 画面内にいても開かないので、展開しても無駄。開く手段はショートカットだけ
        if item.bundleID == "com.apple.Spotlight" {
            guard let hotkey = SpotlightHotkey.current() else {
                log.notice("popover \(item.displayName, privacy: .public) route=spotlight-hotkey-disabled")
                revealToMenuBar(item)
                return
            }
            hotkey.post()
            log.notice("popover \(item.displayName, privacy: .public) route=spotlight-hotkey key=\(hotkey.keyCode)")
            return
        }

        // 押す前のウィンドウを控えておく。何が開いたかはこの差分でしか分からない
        // （AX の kAXWindows に載らないポップオーバーがある＝Blip で実測）
        let before = WindowDetector.snapshot()

        // AXPress は相手がメニュートラッキングに入ると返ってこない（moomoo で実測 >1.2s）。
        // 戻り値は当てにならないので投げ捨て、結果は開いたものを見て判断する
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        }

        // 判定も別スレッドで。上の AXPress とは別のブロックなので、詰まっていても巻き込まれない
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) { [weak self] in
            let entries = MenuReader.read(item, timeout: 1.0)
            let opened = WindowDetector.newWindows(since: before)
            DispatchQueue.main.async {
                self?.routePopover(item, entries: entries, opened: opened)
            }
        }
    }

    /// 押した結果を見て、後始末と表示を決める
    private func routePopover(_ item: MenuBarItem, entries: [MenuEntry], opened: [WindowDetector.Window]) {
        let name = item.displayName

        // a. 押したことでメニューが遅れて生えるアプリ（moomoo_OpenD）。
        //    そのメニューは画面外で開いているので Esc で捨て、読めた中身で自前のメニューを出し直す
        if !entries.isEmpty {
            sendEscape()
            log.notice("popover \(name, privacy: .public) route=lazy-menu entries=\(entries.count)")
            // Esc の直後に出すと自前のメニューまで一緒に閉じられる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.showMenu(self.buildMenu(entries))
            }
            return
        }

        // b. 画面内に開いた（Nani / Blip / 帯より右にいる What Watt?）。もう使える状態なので何もしない
        if let visible = opened.first(where: { WindowDetector.isOnScreen($0.bounds) }) {
            log.notice("popover \(name, privacy: .public) route=window-onscreen x=\(Int(visible.bounds.origin.x))")
            return
        }

        // c. アイテムの x に張り付いて画面外に開いた（Passwords 型）→ AX で画面内へ引き戻す
        let offscreen = opened.filter { !WindowDetector.isOnScreen($0.bounds) }
        if !offscreen.isEmpty {
            let centerX = popoverCenterX
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let moved = WindowDetector.pullOnScreen(offscreen, centerX: centerX)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard moved else {
                        log.notice("popover \(name, privacy: .public) route=window-offscreen-stuck → reveal")
                        self.sendEscape()
                        self.revealToMenuBar(item)
                        return
                    }
                    log.notice("popover \(name, privacy: .public) route=window-pulled x=\(Int(centerX))")
                }
            }
            return
        }

        // d. 何も起きなかった → 従来どおりメニューバーへ展開して、利用者自身に押してもらう
        log.notice("popover \(name, privacy: .public) route=reveal")
        revealToMenuBar(item)
    }

    /// 引き戻したポップオーバーを置く位置。引き出しアイコンの真下に合わせる
    private var popoverCenterX: CGFloat {
        guard let button = statusItem.button, let window = button.window else {
            return (NSScreen.main?.frame.width ?? 1512) / 2
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).midX
    }

    /// 開いてしまったメニュー / ポップオーバーを閉じる。キーだけ送る（カーソルは動かさない）
    private func sendEscape() {
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: isDown)?.post(tap: .cghidEventTap)
        }
    }

    /// ポップオーバー型（AX にメニューが無いアプリ）は引き出しの中では開けないので、
    /// そのアイテムをメニューバーに展開して、利用者自身に押してもらう。
    ///
    /// 帯より左の並び順は macOS 側で固定で動かせないため、対象より右にいるアイテムも
    /// 一緒に出てくる（対象1個だけを出すには ⌘ドラッグ合成での並べ替えが要る＝やらない）。
    /// 展開は常に1件だけで、新しく展開すると前の展開は畳む。
    private func revealToMenuBar(_ item: MenuBarItem) {
        restoreReveal()

        let shift = pusher.reveal(itemAt: item.frame.origin.x, targetX: revealTargetX)
        revealedShift = shift
        revealedItem = item
        log.notice("reveal \(item.displayName, privacy: .public) shift=\(shift) autoClick=\(self.autoClickEnabled)")

        // 展開しっぱなしにしない。触らなければ自分で畳む
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.restoreReveal()
        }

        // 展開しても本当に見えているかは別問題。アイテムが多いとノッチの下に入って見えない。
        // 押し出しを緩めた直後の AX は移動途中の座標を返すので、止まるまで待ってから判定する
        waitUntilLayoutSettles(item) { [weak self] frame in
            guard let self, let target = self.revealedItem, target.id == item.id else { return }

            guard isVisibleOnMenuBar(frame) else {
                log.notice("reveal \(item.displayName, privacy: .public) 失敗: x=\(frame.origin.x) は見えない位置")
                self.restoreReveal()
                self.showMenu(self.cannotRevealMenu(for: item))
                return
            }

            guard self.autoClickEnabled else { return }
            // ここだけカーソルが動く。設定で明示的に ON にしたときのみ
            let ok = StatusItemScanner.click(item)
            log.notice("auto click \(item.displayName, privacy: .public) x=\(frame.origin.x) ok=\(ok)")
        }
    }

    /// メニューバーの再レイアウトが終わる（座標が2回続けて同じになる）まで待つ。
    /// 押し出しを緩めた直後に測ると移動途中の座標が返り、見えているのに「見えない」と誤判定する。
    private func waitUntilLayoutSettles(
        _ item: MenuBarItem,
        attemptsLeft: Int = 30,
        lastX: CGFloat = .infinity,
        completion: @escaping (CGRect) -> Void
    ) {
        let frame = StatusItemScanner.liveFrame(of: item)
        // 画面内に入り、かつ座標が前回と同じ＝移動が終わった。
        // x>=0 を条件に入れないと「まだ動き出していない画面外の座標」を2回読んで
        // 安定と誤判定する（実測: -3205 のまま見えない判定になった）
        if frame.width > 0, frame.origin.x >= 0, frame.origin.x == lastX {
            completion(frame)
            return
        }
        guard attemptsLeft > 0 else {
            completion(frame)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.waitUntilLayoutSettles(item, attemptsLeft: attemptsLeft - 1,
                                         lastX: frame.origin.x, completion: completion)
        }
    }

    /// メニューバー上で実際に見えている位置か。ノッチの下と画面外は見えない
    private func isVisibleOnMenuBar(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.origin.x >= 0 else { return false }
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return true }
        if let rightArea = screen.auxiliaryTopRightArea {
            return frame.minX >= rightArea.minX
        }
        return true
    }

    /// 展開しても見えなかったときに、理由と手が残っていることを伝える
    private func cannotRevealMenu(for item: MenuBarItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for line in [
            "\(item.displayName) はメニューバーに出せませんでした",
            "隠しているアイテムが多く、ノッチの下に入ってしまいます"
        ] {
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "⌘ を押しながら引き出しアイコンより右へドラッグすると常に出せます",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let release = NSMenuItem(title: "折りたたみを一時解除する", action: #selector(togglePush), keyEquivalent: "")
        release.target = self
        menu.addItem(release)

        return menu
    }

    /// 展開していたぶんを畳んで元に戻す
    private func restoreReveal() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        guard revealedShift > 0 else {
            revealedItem = nil
            return
        }
        pusher.restore(shift: revealedShift)
        log.notice("restore \(self.revealedItem?.displayName ?? "-", privacy: .public)")
        revealedShift = 0
        revealedItem = nil
    }

    /// アイテムを展開する先。ノッチの下は表示されないので、その右側を狙う
    private var revealTargetX: CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        if let notchRight = screen?.auxiliaryTopRightArea?.minX {
            return notchRight + 40
        }
        return (screen?.frame.width ?? 1440) * 0.6
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

    // MARK: - 右クリックメニュー

    private func showContextMenu() {
        let menu = NSMenu()

        if let revealed = revealedItem {
            let back = NSMenuItem(title: "\(revealed.displayName) の展開を戻す",
                                  action: #selector(restoreRevealFromMenu), keyEquivalent: "")
            back.target = self
            menu.addItem(back)
            menu.addItem(.separator())
        }

        let autoClick = NSMenuItem(
            title: "展開したら自動でクリックする",
            action: #selector(toggleAutoClick),
            keyEquivalent: ""
        )
        autoClick.target = self
        autoClick.state = autoClickEnabled ? .on : .off
        menu.addItem(autoClick)

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
        restoreReveal()
        if pusher.isPushing {
            pusher.release()
        } else {
            pusher.push()
        }
        log.notice("togglePush isPushing=\(self.pusher.isPushing)")
    }

    @objc private func toggleAutoClick() {
        autoClickEnabled.toggle()
        log.notice("autoClick=\(self.autoClickEnabled)")
    }

    @objc private func restoreRevealFromMenu() {
        restoreReveal()
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
