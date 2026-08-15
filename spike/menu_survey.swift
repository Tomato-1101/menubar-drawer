// いま出ている全ステータスアイテムについて、AX でメニューを読めるか（自前メニューを出せるか）を一覧する。
// 読めないものはポップオーバー型で、フォールバック（アイテムを戻して実クリック）行きになる。
// 実行: swift spike/menu_survey.swift

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func role(_ el: AXUIElement) -> String {
    attr(el, kAXRoleAttribute as String) as? String ?? ""
}

var readable = 0, unreadable = 0

for app in NSWorkspace.shared.runningApplications {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar"),
          CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }

    for item in children(extras as! AXUIElement) {
        var size = CGSize.zero
        if let v = attr(item, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        guard size.width > 0 else { continue }

        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        guard let menu = children(item).first(where: { role($0) == "AXMenu" }) else {
            print("✗ \(name): AXMenu なし（ポップオーバー型 → フォールバック）")
            unreadable += 1
            continue
        }
        let items = children(menu).filter { role($0) == "AXMenuItem" }
        let titles = items.compactMap { attr($0, kAXTitleAttribute as String) as? String }
            .map { $0.components(separatedBy: .newlines).first ?? "" }
            .filter { !$0.isEmpty }
        print("✓ \(name): \(items.count) 項目  \(titles.prefix(4).joined(separator: " / "))")
        readable += 1
    }
}

print("\n読める: \(readable) / 読めない: \(unreadable)")
