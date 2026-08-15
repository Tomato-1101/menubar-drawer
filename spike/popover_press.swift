// 技術スパイク6（ポップオーバー型の決定打）:
// 「画面外に押し出したままのステータスアイテムに AXPress を送ると、
//   ポップオーバー/ウィンドウは macOS 側で画面内にクランプされて出るのか」を確かめる。
//
// 成立するなら、ポップオーバー型（AXMenu を持たない 6 個）でも
// メニューバーへ展開し直す必要がなくなり、ノッチの下問題も消える。
//
// 実行: swift spike/popover_press.swift <アプリ名の一部> [showmenu]
//   第2引数 "showmenu" で AXPress の代わりに AXShowMenu を送る。

import AppKit
import ApplicationServices

// MARK: - AX ヘルパ

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func frameOf(_ el: AXUIElement) -> CGRect {
    var o = CGPoint.zero, s = CGSize.zero
    if let v = attr(el, kAXPositionAttribute as String) { AXValueGetValue(v as! AXValue, .cgPoint, &o) }
    if let v = attr(el, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: o, size: s)
}

/// 相手アプリがメニュー/ポップオーバーのトラッキング中は AX が応答を返さないので、
/// どの問い合わせも別スレッド＋タイムアウト付きで投げる（スクリプト自体が固まるのを防ぐ）
func withTimeout<T>(_ seconds: Double, _ body: @escaping () -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    var result: T?
    DispatchQueue.global(qos: .userInitiated).async {
        result = body()
        sem.signal()
    }
    return sem.wait(timeout: .now() + seconds) == .success ? result : nil
}

// MARK: - ウィンドウ観測（CGWindowList: AX と違って相手アプリの応答を待たない）

struct WinInfo {
    let number: Int
    let layer: Int
    let bounds: CGRect
    let name: String
    let owner: String
    let pid: pid_t
}

/// pid=nil なら全プロセスぶん。ポップオーバーを別プロセスが出す場合があるので既定は全件見る
func cgWindows(pid: pid_t? = nil) -> [WinInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { info in
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              pid == nil || owner == pid,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let num = info[kCGWindowNumber as String] as? Int
        else { return nil }
        return WinInfo(
            number: num,
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
            name: info[kCGWindowName as String] as? String ?? "",
            owner: info[kCGWindowOwnerName as String] as? String ?? "",
            pid: owner
        )
    }
}

/// AX 側のウィンドウ一覧も一応見る（ポップオーバーが AXWindow として現れるアプリもある）
func axWindowFrames(_ axApp: AXUIElement) -> [String] {
    let wins = withTimeout(1.0) { (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] } ?? []
    return wins.map { w in
        let title = attr(w, kAXTitleAttribute as String) as? String ?? ""
        let sub = attr(w, kAXSubroleAttribute as String) as? String ?? ""
        return "\(sub) '\(title)' \(rectString(frameOf(w)))"
    }
}

func rectString(_ r: CGRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
}

let screenSize = (NSScreen.main?.frame.size) ?? CGSize(width: 1512, height: 982)

/// 画面内に見えているか（メニューバー帯そのもの＝高さ 24 以下の細長いものは除く）
func isOnScreen(_ r: CGRect) -> Bool {
    guard r.width > 0, r.height > 0 else { return false }
    return r.maxX > 0 && r.minX < screenSize.width && r.maxY > 0 && r.minY < screenSize.height
}

// MARK: - 対象の特定

let needle = CommandLine.arguments.dropFirst().first ?? "Spotlight"
let useShowMenu = CommandLine.arguments.dropFirst(2).first == "showmenu"
let action = useShowMenu ? "AXShowMenu" : (kAXPressAction as String)

var target: (app: NSRunningApplication, axApp: AXUIElement, el: AXUIElement)?
for app in NSWorkspace.shared.runningApplications {
    let name = app.localizedName ?? ""
    guard name.localizedCaseInsensitiveContains(needle) else { continue }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar"),
          CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let first = children(extras as! AXUIElement).first(where: { frameOf($0).width > 0 })
    else { continue }
    target = (app, axApp, first)
    break
}

guard let t = target else { print("NOT FOUND: \(needle)"); exit(1) }

let appName = t.app.localizedName ?? "?"
let itemFrame = frameOf(t.el)
print("対象: \(appName) pid=\(t.app.processIdentifier)")
print("  ステータスアイテム frame=\(rectString(itemFrame)) offscreen=\(itemFrame.origin.x < 0)")
print("  送るアクション: \(action)")

// MARK: - 押す前の状態

let before = cgWindows()
let beforeNumbers = Set(before.map(\.number))
let beforeOwn = before.filter { $0.pid == t.app.processIdentifier }
print("--- 押す前 ---")
print("  全 CGWindow \(before.count)件 / 対象アプリぶん \(beforeOwn.count)件: "
      + beforeOwn.map { "#\($0.number) L\($0.layer) \(rectString($0.bounds))" }.joined(separator: " "))
print("  AXWindow: \(axWindowFrames(t.axApp))")

// MARK: - アクション送信（fire-and-forget）

// 押した相手がトラッキングに入ると PerformAction は返ってこないことがあるので、
// 別スレッドへ投げて結果は「返ってきたら記録する」だけにする
let started = Date()
let lock = NSLock()
var pressResult: String = "（1.2秒以内に返らず＝トラッキング中の可能性）"
var pressElapsed: Double = -1

DispatchQueue.global(qos: .userInitiated).async {
    let r = AXUIElementPerformAction(t.el, action as CFString)
    let elapsed = -started.timeIntervalSinceNow
    lock.lock()
    pressResult = "\(r.rawValue)"
    pressElapsed = elapsed
    lock.unlock()
}

Thread.sleep(forTimeInterval: 1.2)

lock.lock()
let resultText = pressResult
let elapsedText = pressElapsed < 0 ? ">1.2" : String(format: "%.2f", pressElapsed)
lock.unlock()
print("--- \(action) 送信後 ---")
print("  結果=\(resultText) (0=success, -25204=cannotComplete)  所要 \(elapsedText)s")

// MARK: - 押した後の状態

let after = cgWindows()
let newWindows = after.filter { !beforeNumbers.contains($0.number) }
print("  新規ウィンドウ \(newWindows.count)件（全プロセス対象）")
for w in newWindows {
    let verdict = isOnScreen(w.bounds) ? "画面内" : "画面外"
    print("    新規 #\(w.number) [\(w.owner)] L\(w.layer) \(rectString(w.bounds)) '\(w.name)' → \(verdict)")
}
let onScreenNew = newWindows.filter { isOnScreen($0.bounds) }
print("  判定: 画面内に出た新規ウィンドウ = \(onScreenNew.count)件")
print("  AXWindow: \(axWindowFrames(t.axApp))")

// ステータスアイテム直下に AXMenu が生えたか（メニュー型なら生える）
let kidRoles = withTimeout(1.0) {
    children(t.el).map { attr($0, kAXRoleAttribute as String) as? String ?? "?" }
} ?? ["(AX 応答なし＝トラッキング中)"]
print("  アイテムの子: \(kidRoles)")

// MARK: - スクショ（全画面。実際に何が見えているかの唯一の証拠）

let safeName = appName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
let shotPath = "\(NSHomeDirectory())/Project/menubar-drawer/shots/popover-\(safeName)\(useShowMenu ? "-showmenu" : "").png"
let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-t", "png", shotPath]
try? shot.run()
shot.waitUntilExit()
print("  screenshot: \(shotPath)")

// MARK: - 後始末（開いたものを必ず閉じる。カーソルは動かさない）

CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.6)

let closed = cgWindows().filter { !beforeNumbers.contains($0.number) && isOnScreen($0.bounds) }
print("  Esc 後に残っている新規ウィンドウ: \(closed.count)件")
if !closed.isEmpty {
    // Esc で閉じないポップオーバーは、もう一度アクションを送ってトグルで閉じる
    _ = withTimeout(1.0) { AXUIElementPerformAction(t.el, action as CFString) }
    Thread.sleep(forTimeInterval: 0.6)
    let again = cgWindows().filter { !beforeNumbers.contains($0.number) && isOnScreen($0.bounds) }
    print("  再送後に残っている新規ウィンドウ: \(again.count)件")
}
print("終了")
