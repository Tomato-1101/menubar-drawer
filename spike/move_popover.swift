// 技術スパイク7（検証A）:
// 「画面外に開いてしまうポップオーバー（Passwords 型）を、AX で画面内へ動かせるか」を確かめる。
//
// 押し出し状態のアイテムに AXPress を送ると、Passwords のポップオーバーは
// アイテムの x に厳密アンカーして画面外 (-3241,35) に開く（スパイク6で実測）。
// これを AXUIElementSetAttributeValue(kAXPositionAttribute) で引き戻せれば、
// ポップオーバー型もメニューバーへ展開せずに使える。
//
// 実行: swift spike/move_popover.swift <アプリ名の一部> [移動先x]

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

/// 相手アプリがトラッキング中は AX が返らないので、必ずタイムアウト付きで投げる
func withTimeout<T>(_ seconds: Double, _ body: @escaping () -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    var result: T?
    DispatchQueue.global(qos: .userInitiated).async {
        result = body()
        sem.signal()
    }
    return sem.wait(timeout: .now() + seconds) == .success ? result : nil
}

func rectString(_ r: CGRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
}

// MARK: - ウィンドウ観測

struct WinInfo {
    let number: Int
    let layer: Int
    let bounds: CGRect
    let name: String
    let owner: String
    let pid: pid_t
}

func cgWindows() -> [WinInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { info in
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
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

let screenSize = (NSScreen.main?.frame.size) ?? CGSize(width: 1512, height: 982)

func isOnScreen(_ r: CGRect) -> Bool {
    guard r.width > 0, r.height > 0 else { return false }
    return r.maxX > 0 && r.minX < screenSize.width && r.maxY > 0 && r.minY < screenSize.height
}

// MARK: - 対象の特定

let needle = CommandLine.arguments.dropFirst().first ?? "Passwords"
let destX = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 1100)

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
print("対象: \(appName) pid=\(t.app.processIdentifier)")
print("  ステータスアイテム frame=\(rectString(frameOf(t.el)))")
print("  移動先の x: \(Int(destX))")

let before = cgWindows()
let beforeNumbers = Set(before.map(\.number))

// MARK: - AXPress（fire-and-forget）

DispatchQueue.global(qos: .userInitiated).async {
    _ = AXUIElementPerformAction(t.el, kAXPressAction as CFString)
}
Thread.sleep(forTimeInterval: 0.8)

let newWindows = cgWindows().filter { !beforeNumbers.contains($0.number) }
print("--- AXPress 後 ---")
for w in newWindows {
    print("  新規 #\(w.number) [\(w.owner)] pid=\(w.pid) L\(w.layer) \(rectString(w.bounds)) '\(w.name)'"
          + " → \(isOnScreen(w.bounds) ? "画面内" : "画面外")")
}

// MARK: - 検証A-1: そのウィンドウが AX の kAXWindows に出るか

// ポップオーバーを出すのが別プロセスのことがあるので、新規ウィンドウの pid ぶん全部見る
var pidsToCheck = Set(newWindows.map(\.pid))
pidsToCheck.insert(t.app.processIdentifier)

var movable: [(pid: pid_t, el: AXUIElement, before: CGRect)] = []

for pid in pidsToCheck.sorted() {
    let ax = AXUIElementCreateApplication(pid)
    let wins = withTimeout(1.0) { (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] } ?? []
    print("  pid=\(pid) の AXWindow \(wins.count)件:")
    for w in wins {
        let sub = attr(w, kAXSubroleAttribute as String) as? String ?? ""
        let title = attr(w, kAXTitleAttribute as String) as? String ?? ""
        let f = frameOf(w)
        // 位置を書き換えられる属性かどうかも見る
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &settable)
        print("    \(sub) '\(title)' \(rectString(f)) positionSettable=\(settable.boolValue)")
        if !isOnScreen(f), f.width > 0 {
            movable.append((pid, w, f))
        }
    }
}

// MARK: - 検証A-2: 画面外のウィンドウを画面内へ動かす

if movable.isEmpty {
    print("  → 陰性: 画面外ウィンドウが AXWindows に出ない（AX から掴めない）")
} else {
    for m in movable {
        var dest = CGPoint(x: destX, y: m.before.origin.y)
        guard let value = AXValueCreate(.cgPoint, &dest) else { continue }
        let r = AXUIElementSetAttributeValue(m.el, kAXPositionAttribute as CFString, value)
        Thread.sleep(forTimeInterval: 0.3)
        let after = frameOf(m.el)
        print("  移動 pid=\(m.pid): \(rectString(m.before)) → set=\(r.rawValue) 結果 \(rectString(after))"
              + " → \(isOnScreen(after) ? "画面内" : "画面外のまま")")
    }
    // CGWindowList 側でも本当に動いたか（AX の申告だけを信じない）
    Thread.sleep(forTimeInterval: 0.3)
    let recheck = cgWindows().filter { !beforeNumbers.contains($0.number) }
    print("  CGWindow 再確認:")
    for w in recheck {
        print("    #\(w.number) [\(w.owner)] \(rectString(w.bounds)) → \(isOnScreen(w.bounds) ? "画面内" : "画面外")")
    }
}

// MARK: - スクショ

let safeName = appName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
let shotPath = "\(NSHomeDirectory())/Project/menubar-drawer/shots/move-\(safeName).png"
let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-t", "png", shotPath]
try? shot.run()
shot.waitUntilExit()
print("  screenshot: \(shotPath)")

// MARK: - 後始末

CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.6)

var left = cgWindows().filter { !beforeNumbers.contains($0.number) && isOnScreen($0.bounds) }
print("  Esc 後に残っている新規ウィンドウ: \(left.count)件")
if !left.isEmpty {
    _ = withTimeout(1.5) { AXUIElementPerformAction(t.el, kAXPressAction as CFString) }
    Thread.sleep(forTimeInterval: 0.6)
    left = cgWindows().filter { !beforeNumbers.contains($0.number) && isOnScreen($0.bounds) }
    print("  再送後に残っている新規ウィンドウ: \(left.count)件")
}
print("終了")
