// 検証用ダミーのステータスアイテム。本物のアプリを再起動せずに、
// 引き出しの分岐（AppDelegate.routePopover）を通すために使う。
//
// 実行: swift spike/dummy_item.swift [lazy|silent]   （Ctrl-C か kill で終了）
//   lazy   (既定) 押されるまで NSMenu を持たない＝moomoo_OpenD 型。route=lazy-menu を通す。
//                 moomoo は一度 AXPress すると AXMenu が残り続けるので、本物で初回押下を
//                 試すには取引ゲートウェイの再起動が要る。その代わりのダミー。
//   silent        押しても何も起きない＝どの経路にも当たらないアプリ。route=reveal を通す。

import AppKit

let isSilent = CommandLine.arguments.dropFirst().first == "silent"

final class Delegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 引き出しのセル名になるので、探しやすい名前を AX の title として出す
        statusItem.button?.title = isSilent ? "SilentTest" : "LazyTest"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(pressed)
        print("\(isSilent ? "SilentTest" : "LazyTest") 起動")
    }

    /// lazy: 初回だけここに来る。メニューを作って開く＝AXMenu が遅れて生える。
    /// 以後は statusItem.menu があるので押下は macOS 側が処理し、この関数は呼ばれない。
    /// silent: 何もしない（ウィンドウもメニューも出さない）
    @objc private func pressed() {
        guard !isSilent, statusItem.menu == nil else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "遅延メニュー項目1", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "遅延メニュー項目2", action: nil, keyEquivalent: ""))
        statusItem.menu = menu
        print("メニューを生成した")
        statusItem.button?.performClick(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
