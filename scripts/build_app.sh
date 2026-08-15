#!/bin/bash
# menubar-drawer.app をビルドする（SPM リリースビルド → .app 手組み → Apple Development 証明書で署名）
#
# 使い方: ./scripts/build_app.sh
# 出力:   dist/menubar-drawer.app
#
# 署名に自己署名/ad-hoc を使わないのは、ビルドごとに cdhash が変わって
# アクセシビリティ権限（このアプリの生命線）が毎回リセットされるため。
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build (release)"
swift build -c release

APP="dist/menubar-drawer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/MenuBarDrawer "$APP/Contents/MacOS/MenuBarDrawer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${MENUBAR_DRAWER_SIGN_IDENTITY:-$(
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9]*) [A-F0-9]* "\(Apple Development:.*\)"$/\1/p' \
        | head -n 1
)}"

if [[ -z "$IDENTITY" ]]; then
    echo "エラー: Apple Development 証明書が見つかりません（Xcode でサインインしてください）" >&2
    exit 1
fi

echo "==> codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier com.tomato.menubar-drawer "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -2

echo "==> 完了: $APP"
