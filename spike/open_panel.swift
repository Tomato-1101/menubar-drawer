// 引き出しを開いた状態をスクショするだけのヘルパ（見た目の確認用）。
// 実行: swift spike/open_panel.swift [出力名]

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

let name = CommandLine.arguments.dropFirst().first ?? "panel"

guard let drawer = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.tomato.menubar-drawer"
}) else {
    print("menubar-drawer が起動していない")
    exit(1)
}

let axApp = AXUIElementCreateApplication(drawer.processIdentifier)
guard let extras = attr(axApp, "AXExtrasMenuBar"),
      let icon = children(extras as! AXUIElement).first(where: {
          var size = CGSize.zero
          if let v = attr($0, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
          return size.width < 100
      })
else {
    print("引き出しアイコンが見つからない")
    exit(1)
}

var iconFrame = CGRect.zero
if let v = attr(icon, kAXPositionAttribute as String) {
    var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); iconFrame.origin = p
}
if let v = attr(icon, kAXSizeAttribute as String) {
    var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); iconFrame.size = s
}
print("引き出しアイコン: \(iconFrame)")

AXUIElementPerformAction(icon, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.6)

let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-R", "0,0,1512,340", "-t", "png",
                  "\(NSHomeDirectory())/Project/menubar-drawer/shots/\(name).png"]
try? shot.run()
shot.waitUntilExit()
print("screenshot: shots/\(name).png")
