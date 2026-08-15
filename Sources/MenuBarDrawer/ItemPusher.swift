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

    /// 対象アイテムが画面内に出るところまで帯を縮める（＝メニューバーに展開する）。
    ///
    /// 帯より左の並び順は macOS 側で固定されていて動かせないので、対象より右にいるアイテムも
    /// 一緒に出てくる。対象が押し出し群の右端に近いほど、出てくる数は少なくなる。
    /// 「対象1個だけ」を出すには並べ替え（⌘ドラッグ合成）が要るため、それはしない。
    /// - Returns: 元に戻すために必要な幅（0 なら元から見えていた）
    @discardableResult
    func reveal(itemAt x: CGFloat, targetX: CGFloat) -> CGFloat {
        guard x < targetX else { return 0 }
        let shift = min(separator.length, targetX - x)
        separator.length = max(0, separator.length - shift)
        return shift
    }

    /// reveal で縮めたぶんを押し出し直す
    func restore(shift: CGFloat) {
        guard isPushing else { return }
        separator.length = min(Self.fullWidth, separator.length + shift)
    }
}
