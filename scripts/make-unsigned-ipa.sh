#!/usr/bin/env bash
#
# ============================================================================
#  DSHMobile — 未签名 IPA 构建脚本
#  ---------------------------------------------------------------------------
#  产出：一个 **完全没有签名** 的 .ipa（内部没有 _CodeSignature/、没有
#        embedded.mobileprovision），可以直接丢给 SideStore 用免费 Apple ID 重签。
#
#  用法：
#      scripts/make-unsigned-ipa.sh [scheme] [configuration] [output.ipa]
#
#  参数（全部可选）：
#      scheme         默认 DSHMobile
#      configuration  默认 Release
#      output.ipa     默认 build/DSHMobile-<configuration>-<时间戳>.ipa
#
#  前置条件：
#      · 已安装完整 Xcode（不是只有 Command Line Tools）
#      · 已安装 XcodeGen：brew install xcodegen
#
#  ⚠️ 关于签名：本脚本**故意**把签名全部关掉。产物未签名是设计目标，
#     不是配置错误。
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- 输出美化
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_BLUE=$'\033[34m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_RED=$'\033[31m'

step()  { printf '%s==> %s%s\n' "$C_BLUE$C_BOLD" "$*" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# ---------------------------------------------------------------- 参数解析
usage() {
    cat <<'EOF'
DSHMobile — 未签名 IPA 构建脚本

用法：
    scripts/make-unsigned-ipa.sh [scheme] [configuration] [output.ipa]

参数（全部可选）：
    scheme         默认 DSHMobile
    configuration  默认 Release
    output.ipa     默认 build/DSHMobile-<configuration>-<时间戳>.ipa
EOF
    exit 0
}

case "${1:-}" in
    -h|--help|help) usage ;;
esac

SCHEME="${1:-DSHMobile}"
CONFIGURATION="${2:-Release}"

# ---------------------------------------------------------------- 路径解析
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT_FILE="$PROJECT_ROOT/DSHMobile.xcodeproj"
SPEC_FILE="$PROJECT_ROOT/project.yml"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/build/DerivedData}"
STAGING_DIR="$PROJECT_ROOT/build/ipa-staging"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUTPUT_ARG="${3:-build/DSHMobile-${CONFIGURATION}-${TIMESTAMP}.ipa}"

case "$OUTPUT_ARG" in
    /*) OUTPUT_IPA="$OUTPUT_ARG" ;;
    *)  OUTPUT_IPA="$(pwd)/$OUTPUT_ARG" ;;
esac

printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_RESET"
printf '%s║  DSHMobile — 构建未签名 IPA                               ║%s\n' "$C_BOLD" "$C_RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n\n' "$C_BOLD" "$C_RESET"
info "仓库根目录 : $PROJECT_ROOT"
info "scheme     : $SCHEME"
info "配置       : $CONFIGURATION"
info "输出       : $OUTPUT_IPA"
printf '\n'

# ============================================================ 1. 依赖检查
step "[1/6] 检查构建依赖"

if ! command -v xcodebuild >/dev/null 2>&1; then
    die "找不到 xcodebuild。请安装完整 Xcode（Command Line Tools 不够，没有 iOS SDK）。"
fi

DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo '')}"
if ! printf '%s' "$DEVELOPER_PATH" | grep -q 'Xcode[^/]*\.app/Contents/Developer'; then
    die "当前命令行工具指向的不是完整 Xcode，因此没有 iOS SDK，无法构建 iOS App。

       xcode-select -p  →  ${DEVELOPER_PATH:-<取不到>}

       处理方式：
         1) 本机装 Xcode：App Store 搜索 Xcode，装完 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
         2) 不 sudo 就设 DEVELOPER_DIR 覆盖：
              export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
         3) 用 GitHub Actions 云端构建（推仓库即可，.github/workflows/build-ipa.yml 自动出包）"
fi
info "developer dir: $DEVELOPER_PATH"

if ! XCODEBUILD_VERSION="$(xcodebuild -version 2>&1)"; then
    die "xcodebuild 执行失败：\n$(printf '%s\n' "$XCODEBUILD_VERSION" | sed 's/^/       /')"
fi
printf '%s\n' "$XCODEBUILD_VERSION" | sed 's/^/    /'

IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '')"
if [ -z "$IOS_SDK_VERSION" ]; then
    warn "取不到 iphoneos SDK 版本（xcrun --sdk iphoneos --show-sdk-version 失败），继续尝试构建。"
else
    info "iphoneos SDK: $IOS_SDK_VERSION"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    die "找不到 xcodegen。请先安装：brew install xcodegen"
fi
info "xcodegen   : $(xcodegen --version 2>&1)"

[ -f "$SPEC_FILE" ] || die "找不到工程描述文件：$SPEC_FILE"
ok "依赖检查通过"

# ============================================================ 2. 生成工程
step "[2/6] 用 XcodeGen 生成 DSHMobile.xcodeproj"
info "spec: $SPEC_FILE"
( cd "$PROJECT_ROOT" && xcodegen generate --spec project.yml )
[ -d "$PROJECT_FILE" ] || die "xcodegen 执行完了但没生成 $PROJECT_FILE"
ok "工程已生成：$PROJECT_FILE"

# ============================================================ 3. 构建
step "[3/6] xcodebuild 构建（签名全部关闭）"

BUILD_ARGS=(
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    CODE_SIGN_ENTITLEMENTS=""
)

info "sdk        : 由 destination 分派（iOS target → iphoneos）"
info "derivedData: $DERIVED_DATA"
info "签名       : CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO / CODE_SIGN_IDENTITY=\"\""
printf '\n'

mkdir -p "$DERIVED_DATA"
xcodebuild "${BUILD_ARGS[@]}" build

# ============================================================ 4. 定位产物
step "[4/6] 从 -showBuildSettings 读取真实的产物路径"

# scheme 含多个 target（主 App + Widget 扩展）时，`-scheme ... -showBuildSettings`
# 会依次打印每个 target 的设置。主 App 与扩展共享同一个 BUILT_PRODUCTS_DIR，
# 但 FULL_PRODUCT_NAME / EXECUTABLE_NAME 各自不同（DSHMobile.app / DSHMobile
# 对 DSHMobileWidgets.appex / DSHMobileWidgets），因此这里：
#   · BUILT_PRODUCTS_DIR 直接用（所有 target 相同）；
#   · FULL_PRODUCT_NAME 取以 `.app` 结尾的那个，排除扩展的 `.appex`；
#   · EXECUTABLE_NAME 由主 App 产物名去掉扩展名得到。
BUILD_SETTINGS="$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null)"

read_setting() {
    printf '%s\n' "$BUILD_SETTINGS" \
        | awk -v key="$1" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
                sub(/^[[:space:]]*[^=]*=[[:space:]]*/, "", $0)
                print
            }' \
        | tail -n 1
}

BUILT_PRODUCTS_DIR="$(read_setting BUILT_PRODUCTS_DIR)"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" \
    | awk '/FULL_PRODUCT_NAME/{v=$0; sub(/^[[:space:]]*[^=]*=[[:space:]]*/, "", v); if (v ~ /\.app$/) print v}' \
    | tail -n 1)"
EXECUTABLE_NAME="${FULL_PRODUCT_NAME%.app}"

[ -n "$BUILT_PRODUCTS_DIR" ] || die "-showBuildSettings 里没拿到 BUILT_PRODUCTS_DIR"
[ -n "$FULL_PRODUCT_NAME" ]  || die "-showBuildSettings 里没拿到 FULL_PRODUCT_NAME（没有以 .app 结尾的产物？）"
[ -n "$EXECUTABLE_NAME" ]    || die "-showBuildSettings 里没拿到 EXECUTABLE_NAME"

APP_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
info "BUILT_PRODUCTS_DIR : $BUILT_PRODUCTS_DIR"
info "FULL_PRODUCT_NAME  : $FULL_PRODUCT_NAME"

[ -d "$APP_PATH" ] || die "构建报告成功，但找不到 .app：$APP_PATH"
[ -f "$APP_PATH/$EXECUTABLE_NAME" ] || die ".app 里没有可执行文件：$APP_PATH/$EXECUTABLE_NAME"
[ -f "$APP_PATH/Info.plist" ] || die ".app 里没有 Info.plist：$APP_PATH/Info.plist"
ok "已定位到 .app：$APP_PATH"

# ============================================================ 5. 签名校验
step "[5/6] 校验产物确实「未签名」"

SIGN_FAILED=0
if [ -d "$APP_PATH/_CodeSignature" ]; then
    warn "$APP_PATH/_CodeSignature 存在 —— 产物被签过名了！"
    SIGN_FAILED=1
else
    ok "没有 _CodeSignature 目录（符合预期）"
fi

if [ -f "$APP_PATH/embedded.mobileprovision" ]; then
    warn "$APP_PATH/embedded.mobileprovision 存在 —— 包里带了描述文件，不是纯净的未签名包。"
    SIGN_FAILED=1
else
    ok "没有 embedded.mobileprovision（符合预期）"
fi

if [ "$SIGN_FAILED" -ne 0 ]; then
    die "产物不是未签名包，已中止。请检查 project.yml / 命令行里的签名设置。"
fi

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
SDK_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
info "Bundle ID        : $BUNDLE_ID"
info "显示名           : $DISPLAY_NAME"
info "MinimumOSVersion : $MIN_OS"
info "构建用 SDK       : $SDK_NAME"

APP_SIZE="$(du -sh "$APP_PATH" | awk '{print $1}')"
info "未压缩体积       : $APP_SIZE"

# ============================================================ 6. 组装 IPA
step "[6/6] 组装 Payload 并打包成 .ipa"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/$FULL_PRODUCT_NAME"
info "Payload/$FULL_PRODUCT_NAME"

mkdir -p "$(dirname -- "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
( cd "$STAGING_DIR" && zip -qry -X "$OUTPUT_IPA" Payload )

[ -f "$OUTPUT_IPA" ] || die "打包失败，没有生成 $OUTPUT_IPA"
ok "IPA 已生成"

# ============================================================ 7. 结果汇报
step "[7/7] 完成"

IPA_BYTES="$(stat -f%z "$OUTPUT_IPA" 2>/dev/null || echo 0)"
IPA_HUMAN="$(du -h "$OUTPUT_IPA" | awk '{print $1}')"

printf '\n%s┌──────────────────────────────────────────────────────────┐%s\n' "$C_GREEN" "$C_RESET"
printf '%s│  ✅ 未签名 IPA 构建成功                                   │%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '%s└──────────────────────────────────────────────────────────┘%s\n\n' "$C_GREEN" "$C_RESET"
info "绝对路径 : $OUTPUT_IPA"
info "文件大小 : $IPA_HUMAN  ($IPA_BYTES 字节)"
info "配置     : $CONFIGURATION"
printf '\n'
printf '%s  下一步：把 ipa 传到 iPhone/iPad，用 SideStore 打开安装。%s\n' "$C_BOLD" "$C_RESET"
printf '\n'
info "· 传输方式：AirDrop / 文件 App / iCloud 云盘 / 自建 HTTP 都行。"
info "· 安装方式：在「文件」里点 .ipa → 选 SideStore 打开 → 签名安装。"
info "· 免费 Apple ID 限制：证书 7 天过期需回 SideStore 续签；最多同时装 3 个自签 App。"
printf '\n'

info "IPA 内顶层结构："
unzip -Z1 "$OUTPUT_IPA" 2>/dev/null | awk -F/ 'NF<=3' | sed 's/^/    /' | head -20 || true
printf '\n'
