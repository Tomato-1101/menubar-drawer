// 技術スパイク2: AXPress で他アプリのステータスアイテムのメニューを実際に開けるか。
// 画面内のアイテムと、Hidden Bar に画面外(負座標)へ押し出されたアイテムの両方で試す。
// 実行: swift spike/press.swift <アプリ名の一部>

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return e == .success ? v : nil
}

func position(_ el: AXUIElement) -> CGPoint {
    var p = CGPoint.zero
    if let v = attr(el, kAXPositionAttribute as String) {
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
    }
    return p
}

let needle = CommandLine.arguments.dropFirst().first ?? "Kanary"

var target: (app: NSRunningApplication, el: AXUIElement)?
for app in NSWorkspace.shared.runningApplications {
    guard (app.localizedName ?? "").localizedCaseInsensitiveContains(needle) else { continue }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar"),
          CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let kids = attr(extras as! AXUIElement, kAXChildrenAttribute as String) as? [AXUIElement],
          let first = kids.first else { continue }
    target = (app, first)
    break
}

guard let t = target else {
    print("NOT FOUND: \(needle)")
    exit(1)
}

let before = position(t.el)
print("target: \(t.app.localizedName ?? "?") at (\(Int(before.x)),\(Int(before.y)))  offscreen=\(before.x < 0)")

let err = AXUIElementPerformAction(t.el, kAXPressAction as CFString)
print("AXPress result: \(err.rawValue) (0=success)")

Thread.sleep(forTimeInterval: 0.8)

// 開いたメニュー(またはポップオーバー)が画面のどこにあるか、スクショで確認する
let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
let out = "\(NSHomeDirectory())/Project/menubar-drawer/shots/press-\(needle).png"
shot.arguments = ["-x", "-R", "0,0,1512,420", "-t", "png", out]
try? shot.run()
shot.waitUntilExit()
print("screenshot: \(out)")

// AX でメニューが開いたかを確認（アイテム直下に AXMenu が生えるか）
if let kids = attr(t.el, kAXChildrenAttribute as String) as? [AXUIElement] {
    for k in kids {
        let role = attr(k, kAXRoleAttribute as String) as? String ?? "?"
        let n = (attr(k, kAXChildrenAttribute as String) as? [AXUIElement])?.count ?? 0
        print("  child role=\(role) children=\(n)")
        if role == "AXMenu", let items = attr(k, kAXChildrenAttribute as String) as? [AXUIElement] {
            for it in items.prefix(8) {
                print("    item: '\(attr(it, kAXTitleAttribute as String) as? String ?? "")'")
            }
        }
    }
} else {
    print("  (no children — メニューは AX 経由では見えない)")
}

// 後始末: 開いたメニューを閉じる
AXUIElementPerformAction(t.el, kAXCancelAction as CFString)
Thread.sleep(forTimeInterval: 0.3)
let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
esc?.post(tap: .cghidEventTap)
let escUp = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
escUp?.post(tap: .cghidEventTap)
print("closed.")
