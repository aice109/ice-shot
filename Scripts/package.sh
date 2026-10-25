#!/usr/bin/env bash
#
# package.sh —— 本机打包发布版：Release 构建 → 团队证书签名 → 根目录 DMG。
#
# 用法（任意目录执行均可）：
#   Scripts/package.sh [版本号] [构建号]
#
# 省略参数时从工程的 IceShot target 读取 MARKETING_VERSION / CURRENT_PROJECT_VERSION，例如：
#   IceShot-0.1.0.dmg
#   IceShot-0.1.0.dmg.sha256
#
# 预览版打包时传通道名，文件名会带上后缀，避免和正式包搞混：
#   ICESHOT_CHANNEL=beta Scripts/package.sh
#   → IceShot-0.2.2-beta.dmg
# 通道不改版本号：`CFBundleShortVersionString` 始终是纯数字。
#
# 约定：
# - 产物只写在仓库根目录，文件名 `IceShot-<版本号>.dmg`，已被 .gitignore 忽略。
# - 生产 / 测试使用同一张团队证书（工程里写死 DEVELOPMENT_TEAM），不做公证；
#   首次打开仍需用户手动放行（见 README）。
# - 发布包不注入 `get-task-allow`，避免分发包可被调试。
# - 打包前先跑 `Scripts/gate.sh Release`（构建 + 单测 + 警告清零），没过的代码打不出包。
# - 脚本不会改动工程文件，也不会提交任何东西。

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

project="IceShot.xcodeproj"
scheme="IceShot"
configuration="Release"
entitlements="IceShot.entitlements"

fail() {
  echo "✗ $*" >&2
  exit 1
}

# Release 只用一张团队证书，不需要 CI / 无证书回退；
# 若 xcode-select 指向 Command Line Tools，自动切到完整 Xcode。
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
  [ -d /Applications/Xcode.app/Contents/Developer ] \
    || fail "找不到可用的 Xcode，请先安装 Xcode 27+ 或设置 DEVELOPER_DIR。"
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 版本号 / 构建号 / Team 都从 IceShot target 的构建设置读取，
# 不解析 pbxproj（Xcode 会重写工程文件，测试 target 也有自己的版本号）。
settings_file=$(mktemp)
trap 'rm -f "$settings_file"' EXIT

xcodebuild -project "$project" -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -showBuildSettings > "$settings_file" 2>/dev/null \
  || fail "读取构建设置失败，请先在 Xcode 里确认工程可以打开。"

read_setting() {
  awk -v key="$1" '$1==key { print $3; exit }' "$settings_file"
}

version="${1:-$(read_setting MARKETING_VERSION)}"
build_number="${2:-$(read_setting CURRENT_PROJECT_VERSION)}"
team_id="$(read_setting DEVELOPMENT_TEAM)"
channel="${ICESHOT_CHANNEL:-}"

[ -n "$version" ] || fail "读取不到 MARKETING_VERSION，请显式传入版本号。"
[ -n "$build_number" ] || fail "读取不到 CURRENT_PROJECT_VERSION，请显式传入构建号。"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "版本号格式应为 1.2 或 1.2.3：$version"
[ -n "$team_id" ] || fail "工程里没有 DEVELOPMENT_TEAM，请先在 Xcode 的 Signing & Capabilities 选择团队。"
if [ -n "$channel" ] && ! [[ "$channel" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  fail "通道名只能用小写字母、数字与连字符：$channel"
fi
suffix=""
[ -n "$channel" ] && suffix="-$channel"
icon_name="AppIcon"

dmg_name="IceShot-${version}${suffix}.dmg"
dmg_path="$repo_root/$dmg_name"
app_path="build/DerivedData/Build/Products/${configuration}/IceShot.app"

echo "▸ 版本 ${version} (${build_number})${channel:+ · $channel}，Team ${team_id:-未设置（用 Xcode 自动签名）}，图标 ${icon_name}"

mkdir -p build

# 门禁先行：与打包共用 build/DerivedData，后续构建是增量的，不白跑一遍编译。
echo "▸ 门禁（Release 构建 + 单测 + 警告清零）"
ICESHOT_GATE_DERIVED_DATA="$repo_root/build/DerivedData" Scripts/gate.sh Release \
  || fail "门禁未通过，已中止打包。"

echo "▸ 构建 ${configuration}（团队证书自动签名）"
xcodebuild -project "$project" -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  ASSETCATALOG_COMPILER_APPICON_NAME="$icon_name" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | tee build/package.log

[ -d "$app_path" ] || fail "构建结束但找不到 $app_path"
grep -q "BUILD SUCCEEDED" build/package.log || fail "构建失败，日志见 build/package.log"

# 图标名不写进 pbxproj，而是打包时用构建设置覆盖，所以要回头确认真的生效了
actual_icon=$(plutil -extract CFBundleIconName raw "$app_path/Contents/Info.plist" 2>/dev/null || true)
[ "$actual_icon" = "$icon_name" ] \
  || fail "图标未生效：期望 $icon_name，实际 ${actual_icon:-无}。请在 Xcode 中确认 AppIcon 已在 Assets 里。"

echo "▸ 校验签名"
codesign --verify --strict --verbose=2 "$app_path"

signature_info=$(codesign -d --verbose=4 "$app_path" 2>&1)
if printf '%s' "$signature_info" | grep -q "Signature=adhoc"; then
  fail "产物仍是 ad-hoc 签名，检查签名证书与 Team。"
fi
actual_team=$(printf '%s' "$signature_info" | sed -n 's/^TeamIdentifier=//p' | head -1)
[ "$actual_team" = "$team_id" ] || fail "Team 不匹配：期望 ${team_id}，实际 ${actual_team:-无}"
printf '%s\n' "$signature_info" | grep -E "Identifier|TeamIdentifier|Timestamp" || true

echo "▸ 校验 entitlements（沙盒 + 用户选择文件；无联网、无 get-task-allow）"
[ -f "$entitlements" ] || fail "缺少 $entitlements"
app_entitlements=$(codesign -d --entitlements - "$app_path" 2>/dev/null) || fail "读取 entitlements 失败"
if printf '%s' "$app_entitlements" | grep -q "get-task-allow"; then
  fail "Release 产物仍包含 get-task-allow，检查签名注入设置。"
fi
# App 不联网：除屏幕录制外不申请任何额外能力，网络权限一旦混入就是隐私承诺的倒退。
if printf '%s' "$app_entitlements" | grep -q "com.apple.security.network"; then
  fail "Release 产物包含联网权限，IceShot 不联网。"
fi
printf '%s\n' "$app_entitlements"

echo "▸ 打包 DMG"
Scripts/create-dmg.sh "$app_path" "$dmg_path"

echo
echo "✓ 完成：$dmg_name"
echo "  大小：$(du -h "$dmg_path" | cut -f1)"
echo "  校验：$(cat "${dmg_path}.sha256")"
echo "  未公证：首次打开需「系统设置 → 隐私与安全性 → 仍要打开」。"
