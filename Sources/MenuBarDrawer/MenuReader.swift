import AppKit
import ApplicationServices

/// ステータスアイテムのメニュー項目1個ぶん
final class MenuEntry {
    let element: AXUIElement
    let title: String
    let isEnabled: Bool
    let isChecked: Bool
    let isSeparator: Bool
    let submenu: [MenuEntry]

    init(element: AXUIElement, title: String, isEnabled: Bool, isChecked: Bool, isSeparator: Bool, submenu: [MenuEntry]) {
        self.element = element
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
        self.submenu = submenu
    }
}

/// 他アプリのステータスアイテムのメニューを、AX 経由で「開かずに」読む。
///
/// これが成立するのがこのアプリの肝。メニューを開かなくても AX ツリーには AXMenu と
/// その AXMenuItem が生えており、押し出されて画面外にいるアイテムでも中身が読める（実測）。
/// おかげで「アイコンをメニューバーに戻す → カーソルを飛ばしてクリック」が一切不要になり、
/// 引き出しの中に自前のメニューをそのまま出せる。
enum MenuReader {

    /// 読み取れる項目を返す。空なら AXMenu を持たないアプリ（NSPopover 型など）
    static func read(_ item: MenuBarItem) -> [MenuEntry] {
        guard let menu = children(item.element).first(where: { role(of: $0) == "AXMenu" }) else { return [] }
        return entries(of: menu, depth: 0)
    }

    /// 項目を実行する。メニューを開いていなくても効く（実測: Tailscale の Open Tailscale で確認）。
    /// AX の呼び出しは相手アプリの応答待ちでブロックすることがあるので、必ず別スレッドから。
    static func perform(_ entry: MenuEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
            log.notice("menu perform '\(entry.title, privacy: .public)' ax=\(result.rawValue)")
        }
    }

    // MARK: - AX ヘルパ

    private static func entries(of menu: AXUIElement, depth: Int) -> [MenuEntry] {
        guard depth <= 3 else { return [] }

        return children(menu).compactMap { child -> MenuEntry? in
            guard role(of: child) == "AXMenuItem" else { return nil }

            let title = (attribute(child, kAXTitleAttribute as String) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = attribute(child, kAXEnabledAttribute as String) as? Bool ?? true
            let mark = attribute(child, kAXMenuItemMarkCharAttribute as String) as? String ?? ""

            // タイトルが空で押せない項目は区切り線
            if title.isEmpty, !enabled {
                return MenuEntry(element: child, title: "", isEnabled: false, isChecked: false,
                                 isSeparator: true, submenu: [])
            }

            let sub = children(child)
                .first(where: { role(of: $0) == "AXMenu" })
                .map { entries(of: $0, depth: depth + 1) } ?? []

            // 複数行のタイトル（Tailscale のアカウント欄など）は1行目だけ見せる
            let firstLine = title.components(separatedBy: .newlines).first ?? title

            return MenuEntry(
                element: child,
                title: firstLine.isEmpty ? " " : firstLine,
                isEnabled: enabled,
                isChecked: !mark.isEmpty,
                isSeparator: false,
                submenu: sub
            )
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func role(of element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute as String) as? String ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
}
