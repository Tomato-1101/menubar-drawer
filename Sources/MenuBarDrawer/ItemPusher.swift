import AppKit

/// サードパーティのステータスアイテムをメニューバーの外へ押し出して、見た目を空にする。
///
/// macOS には他アプリのステータスアイテムを隠す API が無いため、Hidden Bar / Ice / Bartender と
/// 同じ手法を使う: 幅の非常に広いダミーのステータスアイテムを1つ置き、その左側にあるアイテムを
/// 画面の外へ追いやる。実測では Hidden Bar も同じことをしていた（幅 5002pt のアイテム1個）。
final class ItemPusher {

    /// 押し出し帯の幅。
    /// macOS は NSStatusItem の実効幅を約 5002pt で頭打ちにする（Hidden Bar の帯も実測 5002pt だった）。
    /// 上限を超える値を入れると reveal で減らしても実効幅が変わらず、押し出しが緩まないので
    /// 必ず上限より小さくしておく。画面幅 + アイテム総幅には十分足りる。
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

    /// 対象アイテムだけを、押せる位置（targetX 付近）へ引き戻す。
    ///
    /// 帯を丸ごと畳む方式は使わない。全アイテムが本来の並びに戻るため、数が多い環境では
    /// 目当てのものがノッチの下に入って掴めなくなる（実測: Spotlight が x=812 = ノッチ内に戻り
    /// ⌘ドラッグが空振りした）。必要なぶんだけ縮めれば、動くのは対象とその左だけで済む。
    ///
    /// targetX は必ずノッチより右にする。左端まで戻すとメニューバー左のアプリメニュー領域に
    /// 重なり、クリックがそちらに吸われる（実測: x=40 に戻したら Warp のメニューが開いた）。
    /// - Returns: 元に戻すために必要な幅（0 なら元から押せる位置にいた）
    @discardableResult
    func reveal(itemAt x: CGFloat, targetX: CGFloat) -> CGFloat {
        guard x < targetX else { return 0 }
        let shift = min(separator.length, targetX - x)
        separator.length = max(0, separator.length - shift)
        return shift
    }

    /// reveal で畳んだぶんを押し出し直す
    func restore(shift: CGFloat) {
        guard isPushing else { return }
        separator.length = min(Self.fullWidth, separator.length + shift)
    }
}
