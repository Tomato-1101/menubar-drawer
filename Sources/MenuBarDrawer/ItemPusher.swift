import AppKit

/// サードパーティのステータスアイテムをメニューバーの外へ押し出して、見た目を空にする。
///
/// macOS には他アプリのステータスアイテムを隠す API が無いため、Hidden Bar / Ice / Bartender と
/// 同じ手法を使う: 幅の非常に広いダミーのステータスアイテムを1つ置き、その左側にあるアイテムを
/// 画面の外へ追いやる。実測では Hidden Bar も同じことをしていた（幅 5002pt のアイテム1個）。
final class ItemPusher {

    /// 押し出し帯の幅。
    /// macOS は NSStatusItem の実効幅を約 5002pt で頭打ちにする（Hidden Bar の帯も実測 5002pt だった）。
    /// 上限を超える値を入れると、縮めても実効幅が変わらず押し出しが緩まないので、必ず上限より小さくする。
    private static let fullWidth: CGFloat = 4000

    private let separator: NSStatusItem
    private(set) var isPushing = false

    init() {
        separator = NSStatusBar.system.statusItem(withLength: 0)
        separator.autosaveName = "menubar-drawer-separator"
        separator.button?.image = nil
        separator.button?.title = ""
        // 押し出し帯そのものはクリックしても何も起きないようにする
        separator.button?.isEnabled = false
    }

    func push() {
        separator.length = Self.fullWidth
        isPushing = true
    }

    func release() {
        separator.length = 0
        isPushing = false
    }
}
