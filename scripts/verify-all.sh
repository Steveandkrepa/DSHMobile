#!/usr/bin/env bash
#
# DSHMobile — 本机可跑的**全部**验证，一次执行完。
#
# 开发机上若没有 iOS SDK，xcodebuild 编译这一环无法本地覆盖；
# 本脚本把**不需要 iOS SDK 就能做**的验证全部跑一遍，作为提交前的门槛：
#
#   1. 语法检查        —— 全部 .swift 走 swiftc -parse
#   2. 配置文件合法性  —— YAML / Info.plist / asset catalog / shell 脚本
#   3. 图标合规性      —— 尺寸 1024×1024
#   4. 真实编译        —— 有 Xcode 时跑一次完整 xcodebuild（最关键的一项）
#
# 用法：
#   ./scripts/verify-all.sh
#
# 退出码：0 = 全部通过；非 0 = 有检查项失败。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAILED=()
step() { printf '\n%s── %s%s\n' "$BOLD" "$*" "$RESET"; }
pass() { printf '%s   ✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
fail() { printf '%s   ✗ %s%s\n' "$RED" "$*" "$RESET"; FAILED+=("$*"); }

printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$BOLD" "$RESET"
printf '%s║  DSHMobile — 本机验证套件（不需要 iOS SDK）              ║%s\n' "$BOLD" "$RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$BOLD" "$RESET"
printf '%s  第 4 步需要完整 Xcode；没有时会自动跳过而不是报错。%s\n' "$DIM" "$RESET"

# ───────────────────────────────────────────── 1. 语法检查
step "1/4  Swift 语法检查（swiftc -parse）"
SWIFT_FILES=$(find DSHMobile DSHMobileWidgets -name '*.swift' | sort)
COUNT=$(printf '%s\n' "$SWIFT_FILES" | wc -l | tr -d ' ')
if [ -z "$SWIFT_FILES" ]; then
    fail "没找到任何 .swift 文件"
elif ! command -v swiftc >/dev/null 2>&1; then
    printf '%s   – 跳过：没有 swiftc（本机非 macOS / 未装 Swift 工具链）。%s\n' "$DIM" "$RESET"
    printf '%s    CI 的 macOS runner 上会自动启用此步。%s\n' "$DIM" "$RESET"
elif swiftc -parse $SWIFT_FILES 2>/tmp/dshmobile-parse.log; then
    pass "$COUNT 个文件语法全部通过"
else
    fail "语法检查失败"; sed 's/^/      /' /tmp/dshmobile-parse.log | head -40
fi

# ───────────────────────────────────────────── 2. 配置文件
step "2/4  配置文件合法性"

if command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e 'YAML.load_file("project.yml"); YAML.load_file(".github/workflows/build-ipa.yml")' 2>/dev/null; then
        pass "project.yml 与 workflow 的 YAML 合法"
    else
        fail "YAML 解析失败"
    fi
else
    printf '%s   – 跳过 YAML 校验（没有 ruby）%s\n' "$DIM" "$RESET"
fi

# Info.plist：plutil 只有 macOS 有；Linux 用 python3 plistlib 校验。
# 注意：Swift Linux 工具链自带一个 plutil，但其参数风格与 macOS 的
# `plutil -lint file` 不兼容（会报 "No files specified"），因此这里
# plutil 失败时回退到 plistlib，任一成功即通过。
PLIST_BAD=0
for p in Resources/Info.plist DSHMobileWidgets/Info.plist; do
    OK=0
    if command -v plutil >/dev/null 2>&1 && plutil -lint "$p" >/dev/null 2>&1; then
        pass "$p 合法（plutil）"; OK=1
    elif python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$p" 2>/dev/null; then
        pass "$p 合法（plistlib）"; OK=1
    fi
    if [ "$OK" -eq 0 ]; then
        fail "$p 不合法（plutil 与 plistlib 均失败）"; PLIST_BAD=1
    fi
done
[ "$PLIST_BAD" -eq 0 ] && true

ASSET_BAD=0
for j in $(find Resources -name 'Contents.json'); do
    python3 -c "import json,sys; json.load(open('$j'))" 2>/dev/null || { fail "JSON 非法：$j"; ASSET_BAD=1; }
done
[ "$ASSET_BAD" -eq 0 ] && pass "asset catalog 的 Contents.json 全部合法"

SH_BAD=0
for s in scripts/*.sh; do
    bash -n "$s" 2>/dev/null || { fail "shell 语法错误：$s"; SH_BAD=1; }
done
[ "$SH_BAD" -eq 0 ] && pass "scripts/*.sh 语法全部合法"

# ───────────────────────────────────────────── 3. 图标
step "3/4  App 图标合规性"
ICON="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
if [ -f "$ICON" ]; then
    # sips 只有 macOS 有；Linux 用 python3 PIL 校验尺寸与通道。
    if command -v sips >/dev/null 2>&1; then
        W=$(sips -g pixelWidth "$ICON" 2>/dev/null | awk '/pixelWidth/{print $2}')
        H=$(sips -g pixelHeight "$ICON" 2>/dev/null | awk '/pixelHeight/{print $2}')
        A=$(sips -g hasAlpha "$ICON" 2>/dev/null | awk '/hasAlpha/{print $2}')
        [ "$W" = "1024" ] && [ "$H" = "1024" ] && pass "尺寸 1024×1024" || fail "尺寸不对：${W}×${H}"
        [ "$A" = "no" ] && pass "不含 alpha 通道" || fail "带 alpha 通道"
    else
        if python3 -c "
from PIL import Image
im = Image.open('$ICON')
assert im.size == (1024, 1024), im.size
assert im.mode not in ('RGBA', 'LA'), 'alpha channel present: ' + im.mode
" 2>/dev/null; then
            pass "尺寸 1024×1024 且不含 alpha 通道（PIL）"
        else
            fail "图标尺寸/通道不合规（需要 1024×1024 且无 alpha）"
        fi
    fi
else
    fail "找不到 $ICON"
fi

# ───────────────────────────────────────────── 4. 真实编译（可选）
step "4/4  真实 xcodebuild 编译（需要 Xcode）"

DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo '')}"
if ! printf '%s' "$DEVELOPER_PATH" | grep -q 'Xcode[^/]*\.app/Contents/Developer'; then
    printf '%s   – 跳过：没有可用的完整 Xcode。%s\n' "$DIM" "$RESET"
    printf '%s    设 DEVELOPER_DIR 或跑 sudo xcode-select -s 后即可自动启用此步。%s\n' "$DIM" "$RESET"
elif ! command -v xcodegen >/dev/null 2>&1; then
    printf '%s   – 跳过：找不到 xcodegen（生成 .xcodeproj 需要它）。%s\n' "$DIM" "$RESET"
else
    if xcodegen generate --spec project.yml >/dev/null 2>&1; then
        pass "xcodegen 生成 DSHMobile.xcodeproj"
    else
        fail "xcodegen 生成工程失败"
    fi

    BUILD_LOG=$(mktemp)
    if xcodebuild -project DSHMobile.xcodeproj -scheme DSHMobile \
         -configuration Release -destination 'generic/platform=iOS' \
         -derivedDataPath build/DerivedData \
         CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
         CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
         build > "$BUILD_LOG" 2>&1; then
        ERRS=$(grep -cE 'error:' "$BUILD_LOG")
        WARNS=$(grep -cE 'warning:' "$BUILD_LOG")
        pass "xcodebuild 构建成功（error ${ERRS} / warning ${WARNS}）"
    else
        fail "xcodebuild 构建失败（详见 ${BUILD_LOG}）"
        grep -oE '[^ ]+\.swift:[0-9]+:[0-9]+: error: .*' "$BUILD_LOG" | sed 's|.*/DSHMobile/||' | sort -u | head -15 | sed 's/^/      /'
    fi
fi

# ───────────────────────────────────────────── 结果
printf '\n%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
if [ ${#FAILED[@]} -eq 0 ]; then
    printf '%s  ✅ 全部通过%s\n' "$GREEN$BOLD" "$RESET"
    exit 0
else
    printf '%s  ❌ %d 项失败%s\n' "$RED$BOLD" "${#FAILED[@]}" "$RESET"
    for f in "${FAILED[@]}"; do printf '     · %s\n' "$f"; done
    exit 1
fi
