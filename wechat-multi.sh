#!/usr/bin/env bash
# ============================================================
# 微信多开 for macOS (WeChat Multi-Instance Launcher)
#
# 原理：微信 4.x 的单实例检测 keyed on Bundle ID + 代码签名，
#       且是延迟校验——实测仅改路径的克隆副本会在启动约 10 秒后
#       被单例守护终止（新路径首次启动能活 ~10s，同一路径第二次
#       启动直接秒死）。因此本脚本把 WeChat.app 克隆成副本后
#       **修改副本的 CFBundleIdentifier 并做 ad-hoc 重签名**，
#       副本即可与本体长期共存。
#
#       副本 Bundle ID 按序号编号（com.tencent.xinWeChat2/3/…），
#       各副本拥有独立的 sandbox 数据容器，聊天记录互不干扰。
#
#       克隆用 APFS clonefile（秒级、实际净增占用接近 0）。
#       全程不注入、不修改微信本体，所有改动都只发生在副本上。
#
# 用法：
#   ./wechat-multi.sh          # 多开 1 个微信
#   ./wechat-multi.sh 3        # 再多开 3 个微信
#   ./wechat-multi.sh -s       # 查看当前正在运行的微信实例数
#   ./wechat-multi.sh -c       # 清理克隆出来的副本应用
#   ./wechat-multi.sh -h       # 帮助
# ============================================================
set -euo pipefail

BUNDLE_ID="com.tencent.xinWeChat"
# 克隆副本的存放目录（clonefile 几乎不占磁盘，但 Finder 会显示原始大小）
CLONE_DIR="$HOME/Library/Application Support/wechat-multi"
# 存活校验窗口（秒）：单实例守护是延迟击杀（实测约 10 秒后），
# 校验窗口必须盖过它，否则会把"即将被杀"误判为启动成功
STABLE_WAIT=15

# ------------------------------------------------------------
# 定位微信本体：先查常见安装路径，找不到再用 Spotlight 按
# bundle id 全盘搜索（微信装在自定义目录时也能找到）
# ------------------------------------------------------------
find_wechat_app() {
    local candidates=(
        "/Applications/WeChat.app"
        "$HOME/Applications/WeChat.app"
    )
    local path
    for path in "${candidates[@]}"; do
        if [[ -d "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    local found
    found="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" && -d "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# 统计当前微信主进程数（所有实例的进程名都是 WeChat）
# ------------------------------------------------------------
running_count() {
    pgrep -x WeChat 2>/dev/null | wc -l | tr -d ' '
}

# ------------------------------------------------------------
# 判断某个副本应用（或整个副本目录）是否有实例正在运行：
# 在进程命令行里匹配路径子串——传具体 app 时命中其主进程，
# 传目录时命中该目录下任意副本的实例
# ------------------------------------------------------------
clone_in_use() {
    # grep 自身进程的命令行也包含匹配串，必须排除，否则会误判为"在运行"
    ps -axo command= 2>/dev/null | grep -F "$1" | grep -qv grep
}

# ------------------------------------------------------------
# 读取 app 的 bundle id / 版本号，用于检测副本是否需要重建
# ------------------------------------------------------------
app_bundle_id() {
    defaults read "$1/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown"
}
app_version() {
    defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown"
}

# ------------------------------------------------------------
# 准备第 n 号副本应用：
#   克隆（APFS clonefile）→ 改 Bundle ID 为 com.tencent.xinWeChat<n>
#   → ad-hoc 重签名。
# 已存在的副本若 Bundle ID 与版本号都对得上则直接复用；
# 版本落后（微信升级过）时删掉重建；有实例在跑则警告并复用旧版。
# ------------------------------------------------------------
prepare_clone() {
    local src="$1" n="$2"
    local dst="$CLONE_DIR/WeChat${n}.app"
    local want_bid="${BUNDLE_ID}${n}"

    if [[ -d "$dst" ]]; then
        if [[ "$(app_bundle_id "$dst")" == "$want_bid" && "$(app_version "$dst")" == "$(app_version "$src")" ]]; then
            printf '%s' "$dst"
            return 0
        fi
        # 副本 Bundle ID 不对或版本落后：微信升级过，副本需要重建
        if clone_in_use "$dst"; then
            printf '警告：%s 版本过期且有实例在运行，本次复用旧版；建议退出全部微信后重新执行。\n' "$dst" >&2
            printf '%s' "$dst"
            return 0
        fi
        rm -rf "$dst"
    fi

    printf '正在准备副本 %s（克隆 + 重签名，约需几十秒）...\n' "$(basename "$dst")" >&2
    mkdir -p "$CLONE_DIR"
    if ! cp -cR "$src" "$dst" 2>/dev/null; then
        # 非 APFS 卷（如部分外置盘）不支持 clonefile，退回普通复制（较慢、占空间）
        cp -R "$src" "$dst"
    fi

    # 关键一步：改写副本 Bundle ID，让单实例检测不再把它认成本体
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $want_bid" "$dst/Contents/Info.plist" 2>/dev/null; then
        printf '错误：修改副本 Bundle ID 失败（%s）。\n' "$dst" >&2
        rm -rf "$dst"
        return 1
    fi

    # 改 Info.plist 会破坏原签名，必须 ad-hoc 重签，否则被系统拒绝启动
    if ! codesign --force --deep --sign - "$dst" >/dev/null 2>&1; then
        printf '错误：副本重签名失败，请确认已安装 Xcode 命令行工具（xcode-select --install）。\n' >&2
        rm -rf "$dst"
        return 1
    fi

    printf '%s' "$dst"
}

# ------------------------------------------------------------
# 启动一个实例：第 1 号直接用本体，其余用改过 Bundle ID 的副本。
# 启动后等待 STABLE_WAIT 秒确认进程数 +1 且稳定存活
# ------------------------------------------------------------
launch_one() {
    local src="$1" n="$2"
    local before after app
    before="$(running_count)"

    if (( n == 1 )); then
        app="$src"
    else
        app="$(prepare_clone "$src" "$n")" || return 1
    fi

    # -n 强制新实例；LaunchServices 偶发拒绝时退回普通 open
    open -n "$app" 2>/dev/null || open "$app"

    sleep "$STABLE_WAIT"
    after="$(running_count)"
    if (( after > before )); then
        return 0
    fi
    printf '启动 %s 后 %s 秒内进程数未增加，实例可能被微信单例守护终止。\n' "$app" "$STABLE_WAIT" >&2
    return 1
}

# ------------------------------------------------------------
# 多开 N 个实例：按当前实例数递增分配副本序号，
# 每开一个都独立校验存活，失败的不影响后续
# ------------------------------------------------------------
launch_instances() {
    local src="$1" want="$2"
    local cur launched=0 n
    cur="$(running_count)"
    printf '当前微信实例数：%s\n' "$cur"

    for ((n = cur + 1; n <= cur + want; n++)); do
        if launch_one "$src" "$n"; then
            launched=$((launched + 1))
        fi
    done

    printf '完成：本次成功新开 %s/%s 个，当前共 %s 个实例在运行。\n' \
        "$launched" "$want" "$(running_count)"
    if (( launched < want )); then
        return 1
    fi
}

# ------------------------------------------------------------
# 清理克隆副本：有实例在跑时拒绝，避免删除运行中的应用
# ------------------------------------------------------------
clean_clones() {
    if [[ ! -d "$CLONE_DIR" ]]; then
        printf '没有需要清理的副本（%s 不存在）。\n' "$CLONE_DIR"
        return 0
    fi
    if clone_in_use "$CLONE_DIR"; then
        printf '有克隆副本的微信实例正在运行，请先退出后再清理。\n' >&2
        return 1
    fi
    rm -rf "$CLONE_DIR"
    printf '已清理克隆副本目录：%s\n' "$CLONE_DIR"
}

usage() {
    cat <<'EOF'
微信多开 for macOS

用法:
  ./wechat-multi.sh [N]    再多开 N 个微信实例（默认 1）
  ./wechat-multi.sh -s     查看当前正在运行的微信实例数
  ./wechat-multi.sh -c     清理克隆出来的副本应用（释放显示空间）
  ./wechat-multi.sh -h     显示本帮助

示例:
  ./wechat-multi.sh        # 新开 1 个微信，扫码登录第二个账号
  ./wechat-multi.sh 2      # 新开 2 个微信
EOF
}

main() {
    # -s / -c / -h 不依赖微信本体，先处理；涉及启动的先确认找得到微信
    case "${1:-}" in
        -h|--help)
            usage
            return 0
            ;;
        -s|--status)
            printf '当前正在运行的微信实例：%s 个\n' "$(running_count)"
            return 0
            ;;
        -c|--clean)
            clean_clones
            return
            ;;
    esac

    local app_path
    if ! app_path="$(find_wechat_app)"; then
        printf '错误：未找到微信（WeChat.app）。请确认已安装微信。\n' >&2
        return 1
    fi

    case "${1:-}" in
        "")
            launch_instances "$app_path" 1
            ;;
        *)
            # 校验参数为正整数，防止误传 "abc" 之类
            if [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
                printf '错误：参数必须是正整数，收到 "%s"\n\n' "$1" >&2
                usage >&2
                return 1
            fi
            launch_instances "$app_path" "$1"
            ;;
    esac
}

main "$@"
