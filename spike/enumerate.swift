// 技術スパイク: Accessibility API で他アプリのステータスアイテム(メニューバーエクストラ)を
// 列挙できるか / クリックできるか / 位置とアイコンが取れるかを実測する。
// 実行: swift spike/enumerate.swift

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return e == .success ? v : nil
}

func actionNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(el, &names)
    return (names as? [String]) ?? []
}

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
print("screen frame: \(NSScreen.main?.frame ?? .zero)")
print(String(repeating: "-", count: 72))

var total = 0
for app in NSWorkspace.shared.runningApplications {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar") else { continue }
    guard CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }
    let extrasEl = extras as! AXUIElement
    guard let kids = attr(extrasEl, kAXChildrenAttribute as String) as? [AXUIElement] else { continue }

    for kid in kids {
        let title = attr(kid, kAXTitleAttribute as String) as? String ?? ""
        let desc = attr(kid, kAXDescriptionAttribute as String) as? String ?? ""
        let help = attr(kid, kAXHelpAttribute as String) as? String ?? ""

        var pos = CGPoint.zero
        if let p = attr(kid, kAXPositionAttribute as String) {
            AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        }
        var size = CGSize.zero
        if let s = attr(kid, kAXSizeAttribute as String) {
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        }

        total += 1
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid\(app.processIdentifier)"
        print("[\(name)] title='\(title)' desc='\(desc)' help='\(help)'")
        print("    pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height))) actions=\(actionNames(kid))")
    }
}
print(String(repeating: "-", count: 72))
print("total status items found: \(total)")
