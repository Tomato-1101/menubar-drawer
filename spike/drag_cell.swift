// 技術スパイク4: 引き出しの中のセルを上へドラッグして、メニューバーに取り出せるかを検証する。
// 実行: swift spike/drag_cell.swift <セル名の一部>

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

let needle = CommandLine.arguments.dropFirst().first ?? "Spotlight"

guard let drawer = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.tomato.menubar-drawer"
}) else { print("menubar-drawer が起動していない"); exit(1) }

let axApp = AXUIElementCreateApplication(drawer.processIdentifier)
guard let extras = attr(axApp, "AXExtrasMenuBar"),
      let icon = children(extras as! AXUIElement).first(where: { frameOf($0).width < 100 })
else { print("引き出しアイコンが見つからない"); exit(1) }

// すでに開いているときにアイコンを押すと閉じてしまうので、閉じているときだけ開く
func panelWindows() -> [AXUIElement] {
    (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
}
if panelWindows().isEmpty {
    AXUIElementPerformAction(icon, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.6)
}

func findButton(_ el: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    if (attr(el, kAXRoleAttribute as String) as? String) == "AXButton" {
        // SwiftUI の accessibilityLabel は AXDescription 側に出る
        let title = attr(el, kAXTitleAttribute as String) as? String ?? ""
        let desc = attr(el, kAXDescriptionAttribute as String) as? String ?? ""
        if title.localizedCaseInsensitiveContains(needle) || desc.localizedCaseInsensitiveContains(needle) {
            return el
        }
    }
    for c in children(el) { if let hit = findButton(c, depth + 1) { return hit } }
    return nil
}

let windows = panelWindows()
guard let cell = windows.compactMap({ findButton($0) }).first else {
    print("セル '\(needle)' が見つからない"); exit(1)
}

let cellFrame = frameOf(cell)
let start = CGPoint(x: cellFrame.midX, y: cellFrame.midY)
print("セル '\(needle)' \(cellFrame) を上へドラッグ")

let source = CGEventSource(stateID: .combinedSessionState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

post(.mouseMoved, start)
Thread.sleep(forTimeInterval: 0.1)
post(.leftMouseDown, start)
for step in 1...10 {
    post(.leftMouseDragged, CGPoint(x: start.x, y: start.y - CGFloat(step) * 6))
    Thread.sleep(forTimeInterval: 0.02)
}
post(.leftMouseUp, CGPoint(x: start.x, y: start.y - 60))
Thread.sleep(forTimeInterval: 2.0)

let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-R", "0,0,1512,40", "-t", "png",
                  "\(NSHomeDirectory())/Project/menubar-drawer/shots/drag-\(needle).png"]
try? shot.run()
shot.waitUntilExit()
print("screenshot: shots/drag-\(needle).png")
