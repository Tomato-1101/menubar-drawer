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

    /// 画面外に開いてしまったポップオーバーを、AX で画面内へ引き戻す。
    ///
    /// Passwords のようにアイテムの x へ厳密にアンカーするポップオーバーは、
    /// 押し出し中だとそのまま画面外に出て見えない。位置は書き換え可能（実測 positionSettable=true）。
    /// AX がブロックすることがあるので**メインスレッドから呼ばない**。
    /// - Returns: 1つでも画面内に移せたか
    static func pullOnScreen(_ windows: [Window], centerX: CGFloat) -> Bool {
        var moved = false

        for pid in Set(windows.map(\.pid)) {
            let axApp = AXUIElementCreateApplication(pid)
            guard let axWindows = copyAttribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                let frame = frameOf(axWindow)
                guard frame.width > 0, !isOnScreen(frame) else { continue }

                var origin = CGPoint(x: onScreenX(width: frame.width, centerX: centerX), y: frame.origin.y)
                guard let value = AXValueCreate(.cgPoint, &origin),
                      AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) == .success
                else { continue }

                // 設定できた＝動いた とは限らないので、位置を読み直して確かめる
                if isOnScreen(frameOf(axWindow)) { moved = true }
            }
        }
        return moved
    }

    // MARK: - 内部

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
