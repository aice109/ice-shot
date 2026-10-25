#!/usr/bin/env bash
#
# gate.sh —— 质量门禁：构建 + 单测 + 警告统计，一条命令给出可复现的结论。
#
# 用法（任意目录执行均可）：
#   Scripts/gate.sh [Debug|Release]
#
# 为什么需要它：
# - `xcodebuild test` 在默认 DerivedData 上会被上一次构建残留的未签名
#   `IceShotTests.xctest` 挡住（CodeSign 报 "code object is not signed at all"），
#   于是「测试全绿」变成看运气。门禁用独立 DerivedData，把这件事变成确定行为。
# - 「无新增警告」是人眼验收不了的，这里按 `文件:行:列: warning:` 逐条数出来。
# - Release 关闭 testability（`@testable import` 编不过），所以测试只在 Debug 跑；
#   Release 门禁只保证「编得过、无警告」。
#
# 约定：
# - 日志落在 `build/logs/gate-<动作>-<配置>.log`（`build/` 已忽略，不入库）。
# - 退出码：0 通过；非 0 表示构建 / 测试失败或有代码警告。
# - 失败原因只走 stderr，正常结果走 stdout，便于 `Scripts/gate.sh > /dev/null`。

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

project="IceShot.xcodeproj"
scheme="IceShot"
destination="platform=macOS"
configuration="${1:-Debug}"

# 卡死取证开关：默认关闭。设成 1 时给 Swift 编译器加 `-DICESHOT_HANG_TRACE`，
# 打开 `HangTrace` 的落盘与 watchdog，用于排查偶发卡死。
# 只影响编译条件，**不改变**本脚本的判据（构建 / 测试 / 零警告）。
swift_flags=()
if [ "${ICESHOT_HANG_TRACE:-0}" = "1" ]; then
  swift_flags+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ICESHOT_HANG_TRACE")
fi


case "$configuration" in
  Debug | Release) ;;
  *)
    echo "用法: Scripts/gate.sh [Debug|Release]" >&2
    exit 2
    ;;
esac

# 独立 DerivedData：不与 Xcode 图形界面、package.sh 共用，避免残留产物干扰结论。
derived_data="${ICESHOT_GATE_DERIVED_DATA:-$repo_root/build/GateDerivedData}"
log_dir="$repo_root/build/logs"
build_log="$log_dir/gate-build-$configuration.log"
test_log="$log_dir/gate-test-$configuration.log"
ran_tests=0

fail() {
  echo "✗ $*" >&2
  exit 1
}

if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
  [ -d /Applications/Xcode.app/Contents/Developer ] \
    || fail "找不到可用的 Xcode，请先安装 Xcode 27+ 或设置 DEVELOPER_DIR。"
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$log_dir"

# 1. 构建（文档里的门禁命令就是这一条）。
echo "▸ 构建 ${configuration}（独立 DerivedData：${derived_data#"$repo_root"/}）"
xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
  -destination "$destination" -derivedDataPath "$derived_data" \
  ${swift_flags[@]+"${swift_flags[@]}"} \
  build >"$build_log" 2>&1
build_status=$?

if [ "$build_status" -ne 0 ] || ! grep -q "BUILD SUCCEEDED" "$build_log"; then
  tail -30 "$build_log" >&2
  fail "构建失败，完整日志：${build_log#"$repo_root"/}"
fi

# 2. 测试：Swift Testing（纯逻辑）+ XCTest（UI 冒烟）一起跑。
if [ "$configuration" = "Debug" ]; then
  echo "▸ 测试"
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$derived_data" \
    ${swift_flags[@]+"${swift_flags[@]}"} \
    test >"$test_log" 2>&1
  test_status=$?
  ran_tests=1

  if [ "$test_status" -ne 0 ] || ! grep -q "TEST SUCCEEDED" "$test_log"; then
    grep -E "error:|Test case|✘" "$test_log" | head -20 >&2
    tail -20 "$test_log" >&2
    if grep -q "code object is not signed at all" "$test_log"; then
      echo "提示：测试包残留未签名产物，执行 rm -rf \"$derived_data\" 后重跑本脚本。" >&2
    fi
    fail "测试失败，完整日志：${test_log#"$repo_root"/}"
  fi
else
  echo "▸ 跳过测试（Release 无 testability，测试由 Debug 门禁覆盖）"
fi

# 3. 警告清零。只认 `文件:行:列: warning:` 这一种形态，
#    自动排除 AppIntents 元数据之类的无源码位置提示。
logs=("$build_log")
[ "$ran_tests" -eq 1 ] && logs+=("$test_log")
warnings=$(grep -hE '\.(swift|m|mm|c|h):[0-9]+:[0-9]+: warning: ' "${logs[@]}" 2>/dev/null | sort -u)
warning_count=0
if [ -n "$warnings" ]; then
  warning_count=$(printf '%s\n' "$warnings" | wc -l | tr -d ' ')
fi

if [ "$warning_count" -ne 0 ]; then
  printf '%s\n' "$warnings" | sed "s|$repo_root/||" >&2
  echo "✗ 有 ${warning_count} 条代码警告，门禁要求 0 条。" >&2
  exit 1
fi

# 4. 摘要：单测数量取 Swift Testing 的总结行，UI 用例取 XCTest 的最大值。
echo
echo "✓ 门禁通过（${configuration}）"
echo "  构建：BUILD SUCCEEDED"
if [ "$ran_tests" -eq 1 ]; then
  unit_summary=$(grep -oE "Test run with [0-9]+ tests in [0-9]+ suites passed" "$test_log" | tail -1)
  ui_count=$(grep -oE "Executed [0-9]+ test" "$test_log" | grep -oE "[0-9]+" | sort -n | tail -1)
  echo "  单测：${unit_summary:-未取到 Swift Testing 总结}"
  echo "  UI  ：${ui_count:-0} 个用例通过"
  echo "  日志：${build_log#"$repo_root"/} / ${test_log#"$repo_root"/}"
else
  echo "  日志：${build_log#"$repo_root"/}"
fi
echo "  警告：0"
