// 技術スパイク5（方針を決める決定打）:
// 「押し出したまま AX でメニューを開き、項目を読み取れるか」を確かめる。
// 読み取れるなら、引き出しの中に自前メニューを描けるので、
// アイコンをメニューバーへ戻す必要も、カーソルを飛ばす必要も無くなる。
//
// 実行: swift spike/read_menu.swift <アプリ名の一部>

import AppKit
import ApplicationServices

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

let needle = CommandLine.arguments.dropFirst().first ?? "Tailscale"

var target: (String, AXUIElement)?
for app in NSWorkspace.shared.runningApplications {
    guard (app.localizedName ?? "").localizedCaseInsensitiveContains(needle) else { continue }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar"),
          CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let first = children(extras as! AXUIElement).first
    else { continue }
    target = (app.localizedName ?? "?", first)
    break
}

guard let (name, element) = target else { print("NOT FOUND: \(needle)"); exit(1) }

print("対象: \(name) frame=\(frameOf(element))")

// 1) 開く前に子が生えているか（開かずに項目を読めるなら理想）
print("--- 開く前 ---")
func dumpBefore(_ el: AXUIElement, _ depth: Int = 0) {
    for child in children(el) {
        let role = attr(child, kAXRoleAttribute as String) as? String ?? "?"
        let title = attr(child, kAXTitleAttribute as String) as? String ?? ""
        print("\(String(repeating: "  ", count: depth))\(role) '\(title)'")
        if depth < 2 { dumpBefore(child, depth + 1) }
    }
}
dumpBefore(element)
print("--- ここから AXPress ---")

// 2) AXPress でメニューを開く
let started = Date()
let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
print("AXPress = \(result.rawValue) (0=success) 所要 \(String(format: "%.2f", -started.timeIntervalSinceNow))s")

Thread.sleep(forTimeInterval: 0.5)

// 3) 開いた状態で項目を読む
func dumpMenu(_ el: AXUIElement, _ depth: Int = 0) {
    for child in children(el) {
        let role = attr(child, kAXRoleAttribute as String) as? String ?? "?"
        let title = attr(child, kAXTitleAttribute as String) as? String ?? ""
        let enabled = attr(child, kAXEnabledAttribute as String) as? Bool ?? true
        let mark = attr(child, kAXMenuItemMarkCharAttribute as String) as? String ?? ""
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)\(role) '\(title.replacingOccurrences(of: "\n", with: " / "))' enabled=\(enabled) mark='\(mark)'")
        if depth < 2 { dumpMenu(child, depth + 1) }
    }
}
dumpMenu(element)

// 4) 第2引数があれば、その項目を AXPress して「引き出しから直接実行できるか」を確かめる
if let wanted = CommandLine.arguments.dropFirst(2).first {
    func find(_ el: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
        for child in children(el) {
            let title = attr(child, kAXTitleAttribute as String) as? String ?? ""
            if title.localizedCaseInsensitiveContains(wanted) { return child }
            if depth < 2, let hit = find(child, depth + 1) { return hit }
        }
        return nil
    }
    if let menuItem = find(element) {
        let r = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        print(">>> '\(wanted)' を AXPress = \(r.rawValue) (0=success)")
    } else {
        print(">>> '\(wanted)' が見つからない")
    }
    Thread.sleep(forTimeInterval: 1.0)
}

// 5) 後始末
AXUIElementPerformAction(element, kAXCancelAction as CFString)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
print("閉じた")
