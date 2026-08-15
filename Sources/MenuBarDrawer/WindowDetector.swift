import AppKit
import ApplicationServices

/// ステータスアイテムを押した結果、何がどこに開いたのかを見るための道具。
///
/// 「開いたか」の判定は CGWindowList の全プロセス差分で行う。AX の kAXWindows に
/// ポップオーバーを載せないアプリがあり（Blip で実測）、ウィンドウを1つも持たないアプリもある（Spotlight）ため。
/// 逆に「開いたものを動かす」のは AX でしかできないので、動かすときだけ AX を使う。
enum WindowDetector {

    struct Window {
        let number: Int
        let pid: pid_t
        let owner: String
        let bounds: CGRect
    }

    /// 押す直前のウィンドウ番号。差分を取るためだけに使う
    static func snapshot() -> Set<Int> {
        Set(all().map(\.number))
    }

    /// snapshot 以降に増えたウィンドウ
    static func newWindows(since snapshot: Set<Int>) -> [Window] {
        all().filter { !snapshot.contains($0.number) }
    }

    /// 画面に掛かっていて実際に見えるか。押し出し中のアイテムに張り付いたポップオーバーは
    /// x が大きな負の値になるのでここで落ちる
    static func isOnScreen(_ rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        return rect.maxX > 0 && rect.minX < size.width && rect.maxY > 0 && rect.minY < size.height
    }

    /// 開いたポップオーバーを、AX で指定した中心 x（引き出しアイコンの真下）へ寄せる。
    ///
    /// 押し出し中は開く場所がアプリ任せでばらつく。Passwords のようにアイテムの x へ厳密に
    /// アンカーするものは画面外に出て見えず、Blip のように画面左端へ寄るものもある。
    /// どちらも同じ経路でここへ揃える。位置は書き換え可能（実測 positionSettable=true）。
    /// y は触らない — どのポップオーバーも既にメニューバー直下の高さで開いているため。
    /// AX がブロックすることがあるので**メインスレッドから呼ばない**。
    /// - Returns: 1つでも動かせたか
    static func align(_ windows: [Window], toCenterX centerX: CGFloat) -> Bool {
        var moved = false

        for window in windows {
            guard let axWindow = axElement(of: window) else { continue }
            let frame = frameOf(axWindow)
            guard frame.width > 0 else { continue }

            let destinationX = onScreenX(width: frame.width, centerX: centerX)
            var origin = CGPoint(x: destinationX, y: frame.origin.y)
            guard let value = AXValueCreate(.cgPoint, &origin),
                  AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) == .success
            else { continue }

            // 設定できた＝動いた とは限らないので、位置を読み直して確かめる
            if abs(frameOf(axWindow).origin.x - destinationX) < 2 { moved = true }
        }
        return moved
    }

    // MARK: - 内部

    /// CGWindowList で見つけたウィンドウに対応する AX 要素を返す。
    ///
    /// kAXWindows に素直に載るもの（Passwords / What Watt? の AXSystemDialog）と、
    /// そこに一切載らないもの（Blip の AXPopover。kAXWindows は 0 件＝実測）がある。
    /// 後者はウィンドウの中の座標からヒットテストで掴んで、親をたどって入れ物まで戻る。
    /// ヒットテストの起点は必ず対象アプリの要素にする（システム全体を起点にすると
    /// 他アプリのウィンドウを掴んで動かしてしまう＝調査中に実際に起きた）。
    private static func axElement(of window: Window) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(window.pid)

        if let axWindows = copyAttribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement],
           let match = axWindows.first(where: { sameSize(frameOf($0).size, window.bounds.size) }) {
            return match
        }
        return hitTest(axApp, at: CGPoint(x: window.bounds.midX, y: window.bounds.midY))
    }

    private static func hitTest(_ axApp: AXUIElement, at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit
        else { return nil }

        // 当たるのは中身の部品なので、位置を持つ入れ物まで親をさかのぼる
        for _ in 0..<8 {
            switch copyAttribute(element, kAXRoleAttribute as String) as? String {
            case "AXPopover", "AXWindow", "AXSheet":
                return element
            default:
                guard let parent = copyAttribute(element, kAXParentAttribute as String) else { return nil }
                element = parent as! AXUIElement
            }
        }
        return nil
    }

    private static func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private static func all() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            return Window(
                number: number,
                pid: pid,
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                bounds: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            )
        }
    }

    /// centerX を中心に置きつつ、画面からはみ出さない x
    private static func onScreenX(width: CGFloat, centerX: CGFloat) -> CGFloat {
        let screenWidth = NSScreen.main?.frame.width ?? 1512
        let margin: CGFloat = 8
        return min(max(centerX - width / 2, margin), max(margin, screenWidth - width - margin))
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        if let value = copyAttribute(element, kAXPositionAttribute as String) {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        var size = CGSize.zero
        if let value = copyAttribute(element, kAXSizeAttribute as String) {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
