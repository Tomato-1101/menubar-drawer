// 技術スパイク3: 引き出しを開き、パネル内のセルを AX で押して、
// 画面外に押し出されたアイテムのメニューが「画面内に」開くかを検証する。
// 実行: swift spike/click_cell.swift <セル名の一部>

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

let needle = CommandLine.arguments.dropFirst().first ?? "Tailscale"

guard let drawer = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.tomato.menubar-drawer"
}) else {
    print("menubar-drawer が起動していない")
    exit(1)
}

let axApp = AXUIElementCreateApplication(drawer.processIdentifier)

// 1. メニューバーのアイコンを押して引き出しを開く
guard let extras = attr(axApp, "AXExtrasMenuBar"),
      let icon = children(extras as! AXUIElement).first(where: {
          var size = CGSize.zero
          if let v = attr($0, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
          return size.width < 100  // 押し出し帯(5002pt)ではなくアイコンの方
      })
else {
    print("引き出しアイコンが見つからない")
    exit(1)
}
AXUIElementPerformAction(icon, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.5)

// 2. パネル内のセル(AXButton)を再帰的に探す
func findButton(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    let role = attr(el, kAXRoleAttribute as String) as? String ?? ""
    if role == "AXButton" {
        let title = attr(el, kAXTitleAttribute as String) as? String ?? ""
        let desc = attr(el, kAXDescriptionAttribute as String) as? String ?? ""
        if title.localizedCaseInsensitiveContains(needle) || desc.localizedCaseInsensitiveContains(needle) {
            return el
        }
    }
    for child in children(el) {
        if let hit = findButton(child, depth: depth + 1) { return hit }
    }
    return nil
}

let windows = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
print("panel windows: \(windows.count)")

guard let cell = windows.compactMap({ findButton($0) }).first else {
    print("セル '\(needle)' が見つからない")
    // デバッグ: パネル内の全ボタン名を出す
    for w in windows {
        func dump(_ el: AXUIElement, _ d: Int) {
            let role = attr(el, kAXRoleAttribute as String) as? String ?? "?"
            let title = attr(el, kAXTitleAttribute as String) as? String ?? ""
            let desc = attr(el, kAXDescriptionAttribute as String) as? String ?? ""
            let value = attr(el, kAXValueAttribute as String) as? String ?? ""
            let pad = String(repeating: "  ", count: d)
            print("\(pad)\(role) title='\(title)' desc='\(desc)' value='\(value)'")
            if d < 12 { for c in children(el) { dump(c, d + 1) } }
        }
        dump(w, 0)
    }
    exit(1)
}

// SwiftUI の Button は AXPress では action が発火しないことがあるため、
// セルの実座標へ本物のマウスクリックを送る
var cellOrigin = CGPoint.zero
if let v = attr(cell, kAXPositionAttribute as String) { AXValueGetValue(v as! AXValue, .cgPoint, &cellOrigin) }
var cellSize = CGSize.zero
if let v = attr(cell, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &cellSize) }
let center = CGPoint(x: cellOrigin.x + cellSize.width / 2, y: cellOrigin.y + cellSize.height / 2)
print("セル '\(needle)' を \(center) でクリック")

CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 1.2)

let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-R", "0,0,1512,500", "-t", "png",
                  "\(NSHomeDirectory())/Project/menubar-drawer/shots/cell-\(needle).png"]
try? shot.run()
shot.waitUntilExit()
print("screenshot: shots/cell-\(needle).png")
