#!/bin/bash
# shellcheck disable=SC2016
#═══════════════════════════════════════════════════════════════════════════════
#  singbox-click 管理脚本
#
#  功能:
#    1. 内核管理  - 通过 SagerNet 官方 apt 源 下载 / 更新 / 删除 sing-box 内核
#    2. 协议管理  - 安装 / 查看 / 删除代理协议 (AnyTLS / Shadowsocks, 需先安装内核)
#    3. 链式代理  - 保存 SS 与 SS2022 节点, 加入代理出口并管理解析策略
#    4. 流量规则  - 禁止回国流量 / 广告拦截 / 默认出口
#    5. 服务管理  - 启动 / 停止 / 重启 / 查看 systemd 服务
#    6. 依赖自检  - 自动检测并安装缺失的基础依赖
#
#  项目: https://github.com/mikuuu3981/singbox-click.git
#  参考: https://sing-box.sagernet.org/zh/installation/package-manager/
#
#  ⚠  仅限在 Linux 服务器上运行, 会主动拒绝在 macOS 本地执行
#═══════════════════════════════════════════════════════════════════════════════

set -o pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly APP_NAME="singbox-click"
readonly GITHUB_REPO="mikuuu3981/singbox-click"
readonly GITHUB_API_REPO="https://api.github.com/repos/${GITHUB_REPO}"
readonly GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}"
readonly CONFIG_DIR="/etc/singbox-click"
readonly CONFIG_FILE="${CONFIG_DIR}/${APP_NAME}.json"
readonly LEGACY_CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly CERT_DIR="${CONFIG_DIR}/certs"
readonly NODES_FILE="${CONFIG_DIR}/nodes.json"
readonly CHAIN_DOMAIN_STRATEGY_FILE="${CONFIG_DIR}/chain-domain-strategy"
readonly CHAIN_DOMAIN_RESOLVER_TAG="${APP_NAME}-local"
readonly SINGBOX_DIR="/etc/sing-box"
readonly SINGBOX_CONFIG_FILE="${SINGBOX_DIR}/config.json"
readonly SERVICE="sing-box"

# 运行态文件:
#   /etc/singbox-click/singbox-click.json      singbox-click 管理的运行配置
#   /etc/sing-box/config.json                   指向上述配置的兼容链接, 供官方服务读取
#   nodes.json               链式代理节点列表, 与运行配置解耦
#   chain-domain-strategy    chain-* 出站访问域名时的解析策略

# 脚本自安装 / 快捷命令
readonly SELF_INSTALL_DIR="/usr/local/bin"
readonly SELF_INSTALL_PATH="${SELF_INSTALL_DIR}/${APP_NAME}"
readonly DEFAULT_SHORTCUT="${APP_NAME}"
# 解析当前脚本的绝对路径 (兼容通过快捷命令软链接调用)
SCRIPT_SRC="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"

# SagerNet apt 源
readonly SAGERNET_KEYRING="/etc/apt/keyrings/sagernet.asc"
readonly SAGERNET_GPG_URL="https://sing-box.app/gpg.key"
readonly SAGERNET_SOURCE="/etc/apt/sources.list.d/sagernet.sources"

#───────────────────────────────────────────────────────────────────────────────
#  颜色与输出助手
#───────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'
    W=$'\e[97m'; D=$'\e[2m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
    R=''; G=''; Y=''; C=''; W=''; D=''; BOLD=''; NC=''
fi

_line()  { echo -e "  ${D}────────────────────────────────────────────────────────${NC}"; }
_info()  { echo -e "  ${C}▸${NC} $1"; }
_ok()    { echo -e "  ${G}✓${NC} $1"; }
_err()   { echo -e "  ${R}✗${NC} $1" >&2; }
_warn()  { echo -e "  ${Y}!${NC} $1"; }
_dim()   { echo -e "  ${D}$1${NC}"; }

_pause() {
    echo ""
    read -rp "  ${D}按 Enter 返回...${NC}" _
}

# 计算字符串显示宽度 (非 ASCII 字符如中文按 2 列计)
# 兼容 bash 3.2 (printf 返回有符号首字节) 与 bash 5 (返回 Unicode 码点)
_strwidth() {
    local s="$1" w=0 i c cp
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        printf -v cp '%d' "'$c" 2>/dev/null || cp=0
        if (( cp < 0 || cp > 127 )); then
            (( w += 2 ))   # 非 ASCII (中文等双宽字符)
        else
            (( w += 1 ))
        fi
    done
    echo "$w"
}

_header() {
    clear
    local title="$1"
    local inner=54                       # 边框内部宽度 (列)
    local bar; printf -v bar '═%.0s' $(seq 1 "$inner")
    local tw; tw="$(_strwidth "$title")"
    local pad=$(( inner - 2 - tw ))       # 2 = 标题前导两空格
    (( pad < 0 )) && pad=0
    local spaces; printf -v spaces '%*s' "$pad" ''
    echo ""
    echo -e "  ${C}${BOLD}╔${bar}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}${title}${NC}${spaces}${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${bar}╝${NC}"
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
#  运行环境守卫
#───────────────────────────────────────────────────────────────────────────────
guard_environment() {
    # 1) 禁止在 macOS 本地运行
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo ""
        _err "检测到 macOS (Darwin) 环境。"
        _err "本脚本只能在 Linux 服务器上运行, 不会在本地 Mac 上安装任何内核。"
        _err "请把脚本上传到服务器后再执行。"
        echo ""
        exit 1
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        _err "不支持的操作系统: $(uname -s), 仅支持 Linux。"
        exit 1
    fi

    # 2) 需要 root
    if [[ "$EUID" -ne 0 ]]; then
        _err "请使用 root 运行 (sudo bash $0)。"
        exit 1
    fi

    # 3) 需要 systemd (sing-box 包依赖 systemd 服务)
    if ! command -v systemctl >/dev/null 2>&1; then
        _err "未检测到 systemd (systemctl), 本脚本依赖 systemd 管理服务。"
        exit 1
    fi
}

#───────────────────────────────────────────────────────────────────────────────
#  发行版检测
#───────────────────────────────────────────────────────────────────────────────
PKG_MGR=""       # apt / dnf / yum
DISTRO_ID=""     # debian / ubuntu / ...

detect_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        DISTRO_ID="$(. /etc/os-release && echo "${ID:-}")"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
#  依赖自检与自动安装
#───────────────────────────────────────────────────────────────────────────────
# 用法: pkg_install <包名...>
pkg_install() {
    case "$PKG_MGR" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y "$@" >/dev/null 2>&1
            ;;
        yum)
            yum install -y "$@" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_update_index() {
    case "$PKG_MGR" in
        apt) apt-get update >/dev/null 2>&1 ;;
        dnf) dnf makecache >/dev/null 2>&1 ;;
        yum) yum makecache >/dev/null 2>&1 ;;
    esac
}

# 命令 -> 包名 映射 (不同发行版差异)
_pkg_name_for() {
    local cmd="$1"
    case "$cmd" in
        openssl) echo "openssl" ;;
        curl)    echo "curl" ;;
        jq)      echo "jq" ;;
        *)       echo "$cmd" ;;
    esac
}

# 确保基础依赖存在, 缺失则自动安装
ensure_dependencies() {
    local required=(curl jq openssl)
    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    _warn "检测到缺失依赖: ${missing[*]}"

    if [[ -z "$PKG_MGR" ]]; then
        _err "未识别到受支持的包管理器 (apt/dnf/yum), 请手动安装: ${missing[*]}"
        return 1
    fi

    _info "正在更新软件包索引..."
    pkg_update_index

    local pkgs=()
    for cmd in "${missing[@]}"; do
        pkgs+=("$(_pkg_name_for "$cmd")")
    done

    _info "正在安装: ${pkgs[*]} ..."
    pkg_install "${pkgs[@]}"

    # 复检
    local still=()
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || still+=("$cmd")
    done

    if [[ ${#still[@]} -ne 0 ]]; then
        _err "以下依赖安装失败, 请手动安装后重试: ${still[*]}"
        return 1
    fi

    _ok "依赖安装完成"
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
#  通用 TUI 选择菜单 (方向键 ↑↓ + Enter, 兼容数字输入)
#  用法: menu_select "标题" 选项1 选项2 ...
#  结果: 全局变量 MENU_CHOICE = 选中的序号 (从 1 开始), 取消返回 0
#───────────────────────────────────────────────────────────────────────────────
MENU_CHOICE=0
menu_select() {
    local title="$1"; shift
    local options=("$@")
    local count=${#options[@]}
    local sel=0
    local key

    # 非交互终端: 退化为数字输入
    if [[ ! -t 0 || ! -t 1 ]]; then
        local i
        echo -e "  ${W}${BOLD}${title}${NC}"
        for i in "${!options[@]}"; do
            printf "   %2d) %s\n" "$((i+1))" "${options[$i]}"
        done
        read -rp "  请输入序号: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= count )); then
            MENU_CHOICE=$sel
        else
            MENU_CHOICE=0
        fi
        return
    fi

    tput civis 2>/dev/null   # 隐藏光标

    # 每行以 \e[K 清到行尾, 避免上一帧较宽的高亮残留 (CJK 双宽字符尤甚)
    _render_menu() {
        local i CLR=$'\e[K'
        printf '  %s%s%s%s\n' "$W$BOLD" "$title" "$NC" "$CLR"
        for i in "${!options[@]}"; do
            if [[ $i -eq $sel ]]; then
                printf '  %s❯ %d. %s%s%s\n' "$G$BOLD" "$((i+1))" "${options[$i]}" "$NC" "$CLR"
            else
                printf '    %s%d.%s %s%s\n' "$D" "$((i+1))" "$NC" "${options[$i]}" "$CLR"
            fi
        done
    }

    _render_menu
    local lines=$((count + 1))
    local esc rest

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\e')  # 方向键: ESC [ A/B —— 一次多读, 超时放宽以适配 SSH
                rest=''
                read -rsn2 -t 0.2 rest
                esc="${key}${rest}"
                case "$esc" in
                    $'\e[A') if (( sel > 0 )); then ((sel--)); else sel=$((count-1)); fi ;;
                    $'\e[B') if (( sel < count-1 )); then ((sel++)); else sel=0; fi ;;
                    $'\e')  MENU_CHOICE=0; break ;;   # 单独 ESC = 返回
                    *) : ;;                            # 其它序列忽略
                esac
                ;;
            ''|$'\n'|$'\r') MENU_CHOICE=$((sel+1)); break ;;   # Enter
            q|Q)            MENU_CHOICE=0; break ;;
            k|K) if (( sel > 0 )); then ((sel--)); else sel=$((count-1)); fi ;;   # vim 上
            j|J) if (( sel < count-1 )); then ((sel++)); else sel=0; fi ;;       # vim 下
            [0-9])
                if (( key >= 1 && key <= count )); then
                    MENU_CHOICE=$key; break
                fi
                ;;
        esac
        # 重绘: 光标上移到菜单起点后逐行覆盖清行
        tput cuu "$lines" 2>/dev/null
        _render_menu
    done

    tput cnorm 2>/dev/null   # 恢复光标
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
#  内核管理
#───────────────────────────────────────────────────────────────────────────────
core_installed() {
    command -v sing-box >/dev/null 2>&1
}

core_version() {
    core_installed || return 1
    sing-box version 2>/dev/null | head -1
}

core_semver() {
    core_version | sed -nE 's/.*([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3/p' | head -1
}

version_ge() {
    local cur="$1" min="$2" i
    local -a cur_parts min_parts
    IFS='.' read -r -a cur_parts <<< "$cur"
    IFS='.' read -r -a min_parts <<< "$min"
    for i in 0 1 2; do
        local c="${cur_parts[$i]:-0}"
        local m="${min_parts[$i]:-0}"
        c="${c//[^0-9]/}"
        m="${m//[^0-9]/}"
        c="${c:-0}"
        m="${m:-0}"
        (( 10#$c > 10#$m )) && return 0
        (( 10#$c < 10#$m )) && return 1
    done
    return 0
}

require_core_for_protocol_install() {
    if core_installed; then
        return 0
    fi
    _err "尚未安装 sing-box 内核, 不能安装协议。"
    _dim "请先进入「内核管理」安装内核, 再回来安装协议。"
    _pause
    return 1
}

require_core_version() {
    local min="$1" feature="$2" cur
    cur="$(core_semver)"
    if [[ -z "$cur" ]]; then
        _warn "无法识别当前 sing-box 版本, 将继续尝试安装 ${feature}。"
        return 0
    fi
    if version_ge "$cur" "$min"; then
        return 0
    fi
    _err "${feature} 需要 sing-box ${min} 或更高版本, 当前版本为 ${cur}。"
    _dim "请先进入「内核管理」更新内核。"
    _pause
    return 1
}

# 配置 SagerNet apt 源 (幂等)
setup_sagernet_repo() {
    _info "配置 SagerNet apt 软件源..."
    mkdir -p /etc/apt/keyrings || return 1

    if ! curl -fsSL "$SAGERNET_GPG_URL" -o "$SAGERNET_KEYRING"; then
        _err "下载 GPG 公钥失败: $SAGERNET_GPG_URL"
        return 1
    fi
    chmod a+r "$SAGERNET_KEYRING"

    cat > "$SAGERNET_SOURCE" <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    _info "更新 apt 索引..."
    if ! apt-get update >/dev/null 2>&1; then
        _err "apt-get update 失败, 请检查网络。"
        return 1
    fi
    _ok "SagerNet 源已配置"
    return 0
}

core_install() {
    _header "内核安装 / 更新"

    if [[ "$PKG_MGR" != "apt" ]]; then
        _err "官方包管理器安装仅支持 Debian/Ubuntu (apt)。"
        _dim "当前系统包管理器: ${PKG_MGR:-未知}"
        _dim "其它系统请参考: https://sing-box.sagernet.org/zh/installation/"
        _pause
        return 1
    fi

    if core_installed; then
        _info "当前已安装: ${G}$(core_version)${NC}"
        echo ""
    fi

    # 稳定版 / 测试版
    menu_select "选择要安装的版本" \
        "稳定版 sing-box (推荐)" \
        "测试版 sing-box-beta"
    local pkg
    case "$MENU_CHOICE" in
        1) pkg="sing-box" ;;
        2) pkg="sing-box-beta" ;;
        *) _warn "已取消"; _pause; return 1 ;;
    esac

    setup_sagernet_repo || { _pause; return 1; }

    _info "正在安装 ${pkg} ..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 | tail -3; then
        if core_installed; then
            ensure_config
            _ok "安装完成: ${G}$(core_version)${NC}"
        else
            _err "安装命令执行完毕但未检测到 sing-box 命令。"
            _pause; return 1
        fi
    else
        _err "安装失败。"
        _pause; return 1
    fi

    _pause
    return 0
}

core_update() {
    _header "内核更新"

    if ! core_installed; then
        _warn "尚未安装 sing-box, 请先执行内核安装。"
        _pause
        return 1
    fi

    if [[ "$PKG_MGR" != "apt" ]]; then
        _err "官方包管理器更新仅支持 Debian/Ubuntu (apt)。"
        _pause; return 1
    fi

    _info "当前版本: $(core_version)"
    setup_sagernet_repo || { _pause; return 1; }

    # 判断安装的是稳定版还是 beta
    local pkg="sing-box"
    if dpkg -s sing-box-beta >/dev/null 2>&1; then
        pkg="sing-box-beta"
    fi

    _info "正在升级 ${pkg} ..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$pkg" 2>&1 | tail -3; then
        _ok "更新完成: ${G}$(core_version)${NC}"
        if systemctl is-active --quiet "$SERVICE"; then
            ensure_config
            _info "重启服务以应用新内核..."
            systemctl restart "$SERVICE" && _ok "服务已重启"
        fi
    else
        _err "更新失败。"
    fi

    _pause
    return 0
}

_singbox_core_present() {
    core_installed || dpkg -s sing-box >/dev/null 2>&1 || dpkg -s sing-box-beta >/dev/null 2>&1
}

_remove_click_config_dir() {
    if [[ -L "$SINGBOX_CONFIG_FILE" ]]; then
        local target
        target="$(readlink -f "$SINGBOX_CONFIG_FILE" 2>/dev/null || true)"
        if [[ "$target" == "$CONFIG_FILE" || "$target" == "$LEGACY_CONFIG_FILE" || "$target" == "$CONFIG_DIR"/* ]]; then
            rm -f "$SINGBOX_CONFIG_FILE"
            _ok "已删除兼容链接 ${SINGBOX_CONFIG_FILE}"
        fi
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        _ok "已删除配置目录 ${CONFIG_DIR}"
    else
        _dim "配置目录不存在: ${CONFIG_DIR}"
    fi
}

_remove_singbox_core() {
    local delete_config="${1:-no}"
    local had_core=0
    _singbox_core_present && had_core=1

    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true

    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get remove -y sing-box sing-box-beta >/dev/null 2>&1 || true
        apt-get purge -y sing-box sing-box-beta >/dev/null 2>&1 || true
    fi

    # 兜底: apt 卸载后若命令仍存在, 说明是手动安装的二进制 (非 apt 包管理)
    # 自动清理 /usr/local /usr/bin 等目录下的二进制及手动创建的 systemd 单元
    if core_installed; then
        local bin_path
        bin_path="$(command -v sing-box 2>/dev/null)"
        if [[ -n "$bin_path" ]] && ! dpkg -S "$bin_path" >/dev/null 2>&1; then
            _warn "检测到手动安装的 sing-box: ${bin_path}"
            rm -f "$bin_path" && _ok "已删除二进制 ${bin_path}"
            local unit removed_unit=0
            for unit in /etc/systemd/system/sing-box.service \
                        /etc/systemd/system/sing-box@.service \
                        /lib/systemd/system/sing-box.service; do
                if [[ -f "$unit" ]] && ! dpkg -S "$unit" >/dev/null 2>&1; then
                    rm -f "$unit" && removed_unit=1
                fi
            done
            if [[ "$removed_unit" == "1" ]]; then
                systemctl daemon-reload 2>/dev/null || true
                _ok "已删除手动创建的 systemd 服务单元"
            fi
        fi
    fi

    if [[ "$delete_config" =~ ^[Yy]$ ]]; then
        _remove_click_config_dir
    fi

    if core_installed; then
        _err "卸载后仍检测到 sing-box 命令: $(command -v sing-box)"
        _warn "该副本可能位于非常规目录, 请手动删除。"
        return 1
    fi

    if [[ "$had_core" == "1" ]]; then
        _ok "sing-box 内核已卸载"
    else
        _dim "sing-box 内核未安装, 已跳过"
    fi
    return 0
}

core_remove() {
    _header "内核删除"

    if ! _singbox_core_present; then
        _warn "未检测到已安装的 sing-box。"
        _pause
        return 1
    fi

    _warn "这将卸载 sing-box 内核。"
    read -rp "  是否同时删除配置文件 ${CONFIG_DIR} ? [y/N]: " del_cfg
    echo ""
    read -rp "  确认卸载内核? 输入 ${R}yes${NC} 继续: " confirm
    if [[ "$confirm" != "yes" ]]; then
        _warn "已取消"
        _pause
        return 1
    fi

    _remove_singbox_core "$del_cfg"

    _pause
    return 0
}

core_menu() {
    while true; do
        _header "内核管理"
        local has_core=0
        if core_installed; then
            has_core=1
            echo -e "  状态: ${G}已安装${NC}  版本: ${W}$(core_version)${NC}"
        else
            echo -e "  状态: ${Y}未安装${NC}"
        fi
        echo ""

        local opts=() actions=()
        if [[ "$has_core" == "1" ]]; then
            opts+=("更新内核")
            actions+=("update")
            opts+=("删除内核")
            actions+=("remove")
        else
            opts+=("安装内核")
            actions+=("install")
        fi
        opts+=("返回主菜单")
        actions+=("back")

        menu_select "请选择操作" "${opts[@]}"
        local action=""
        if (( MENU_CHOICE >= 1 && MENU_CHOICE <= ${#actions[@]} )); then
            action="${actions[$((MENU_CHOICE-1))]}"
        fi
        case "$action" in
            install) core_install ;;
            update) core_update ;;
            remove) core_remove ;;
            *) return ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  配置文件工具
#───────────────────────────────────────────────────────────────────────────────
_singbox_service_group() {
    if getent group sing-box >/dev/null 2>&1; then
        echo "sing-box"
        return 0
    fi
    if id -gn sing-box >/dev/null 2>&1; then
        id -gn sing-box
        return 0
    fi
    echo "root"
}

secure_config_permissions() {
    local service_group dir_mode config_mode key_mode
    service_group="$(_singbox_service_group)"
    if [[ "$service_group" == "root" ]]; then
        dir_mode=700
        config_mode=600
        key_mode=600
    else
        dir_mode=750
        config_mode=640
        key_mode=640
    fi

    [[ -d "$CONFIG_DIR" ]] && chown "root:${service_group}" "$CONFIG_DIR" 2>/dev/null && chmod "$dir_mode" "$CONFIG_DIR" 2>/dev/null
    [[ -d "$CERT_DIR" ]] && chown "root:${service_group}" "$CERT_DIR" 2>/dev/null && chmod "$dir_mode" "$CERT_DIR" 2>/dev/null
    [[ -d "$SINGBOX_DIR" ]] && chown "root:${service_group}" "$SINGBOX_DIR" 2>/dev/null && chmod "$dir_mode" "$SINGBOX_DIR" 2>/dev/null

    local f
    if [[ -f "$CONFIG_FILE" ]]; then
        chown "root:${service_group}" "$CONFIG_FILE" 2>/dev/null || true
        chmod "$config_mode" "$CONFIG_FILE" 2>/dev/null || true
    fi
    for f in "$NODES_FILE" "$CHAIN_DOMAIN_STRATEGY_FILE"; do
        [[ -f "$f" ]] || continue
        chown root:root "$f" 2>/dev/null || true
        chmod 600 "$f" 2>/dev/null || true
    done

    if [[ -d "$CERT_DIR" ]]; then
        find "$CERT_DIR" -type f -name '*.key' -exec chown "root:${service_group}" {} \; -exec chmod "$key_mode" {} \; 2>/dev/null || true
        find "$CERT_DIR" -type f \( -name '*.crt' -o -name '*.pem' \) -exec chown "root:${service_group}" {} \; -exec chmod 644 {} \; 2>/dev/null || true
    fi
}

migrate_legacy_config_dir() {
    [[ "$CONFIG_DIR" == "$SINGBOX_DIR" ]] && return 0
    mkdir -p "$CONFIG_DIR" "$CERT_DIR"

    local name legacy target
    if [[ "$LEGACY_CONFIG_FILE" != "$CONFIG_FILE" && ! -L "$LEGACY_CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            mv "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
        else
            rm -f "$LEGACY_CONFIG_FILE"
        fi
    elif [[ "$LEGACY_CONFIG_FILE" != "$CONFIG_FILE" && -L "$LEGACY_CONFIG_FILE" ]]; then
        local current
        current="$(readlink -f "$LEGACY_CONFIG_FILE" 2>/dev/null || true)"
        if [[ "$current" == "$CONFIG_FILE" ]]; then
            rm -f "$LEGACY_CONFIG_FILE"
        else
            if [[ -n "$current" && -f "$current" && ! -f "$CONFIG_FILE" ]]; then
                cp -p "$current" "$CONFIG_FILE" 2>/dev/null || cp "$current" "$CONFIG_FILE" 2>/dev/null || true
            fi
            rm -f "$LEGACY_CONFIG_FILE"
        fi
    fi

    [[ -d "$SINGBOX_DIR" ]] || return 0

    for name in nodes.json chain-domain-strategy; do
        legacy="${SINGBOX_DIR}/${name}"
        target="${CONFIG_DIR}/${name}"
        if [[ -L "$legacy" ]]; then
            continue
        fi
        if [[ -f "$legacy" && ! -f "$target" ]]; then
            mv "$legacy" "$target"
        elif [[ -f "$legacy" && -f "$target" && "$legacy" != "$SINGBOX_CONFIG_FILE" ]]; then
            rm -f "$legacy"
        fi
    done

    legacy="$SINGBOX_CONFIG_FILE"
    target="$CONFIG_FILE"
    if [[ ! -L "$legacy" && -f "$legacy" && ! -f "$target" ]]; then
        if _legacy_singbox_config_has_user_state "$legacy"; then
            mv "$legacy" "$target"
        fi
    fi

    if [[ -d "${SINGBOX_DIR}/certs" ]]; then
        local cert
        while IFS= read -r cert; do
            [[ -f "$cert" ]] || continue
            target="${CERT_DIR}/$(basename "$cert")"
            if [[ ! -e "$target" ]]; then
                mv "$cert" "$target"
            fi
        done < <(find "${SINGBOX_DIR}/certs" -maxdepth 1 -type f 2>/dev/null)
    fi
}

_legacy_singbox_config_has_user_state() {
    local file="$1"
    jq -e '
        ((.inbounds // []) | length > 0) or
        ([.outbounds[]? | select(((.tag // "") | startswith("chain-")) or ((.type // "") != "direct" and (.type // "") != "block"))] | length > 0) or
        ((.route.rule_set // []) | length > 0)
    ' "$file" >/dev/null 2>&1
}

_write_base_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
}

ensure_singbox_config_link() {
    [[ -f "$CONFIG_FILE" ]] || _write_base_config
    mkdir -p "$SINGBOX_DIR"
    if [[ -L "$SINGBOX_CONFIG_FILE" ]]; then
        local current
        current="$(readlink -f "$SINGBOX_CONFIG_FILE" 2>/dev/null || true)"
        [[ "$current" == "$CONFIG_FILE" ]] && return 0
        rm -f "$SINGBOX_CONFIG_FILE"
    elif [[ -e "$SINGBOX_CONFIG_FILE" ]]; then
        rm -f "$SINGBOX_CONFIG_FILE" || return 1
        _dim "已移除原 ${SINGBOX_CONFIG_FILE}"
    fi
    ln -s "$CONFIG_FILE" "$SINGBOX_CONFIG_FILE"
}

_chain_domain_resolver_supported() {
    local cur
    cur="$(core_semver)"
    [[ -z "$cur" ]] && return 0
    version_ge "$cur" "1.12.0"
}

_chain_managed_tags_json() {
    if [[ -f "$NODES_FILE" ]]; then
        jq -c '[.nodes[]?.active_tag | select(type == "string" and length > 0)] | unique' "$NODES_FILE" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

_migrate_legacy_chain_domain_strategy_options() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local legacy_count use_resolver managed_tags tmp check_out
    managed_tags="$(_chain_managed_tags_json)"
    legacy_count="$(jq -r --argjson managed_tags "$managed_tags" '
        [.outbounds[]? |
            (.tag // "") as $tag |
            select(
                ((($managed_tags | index($tag)) != null) or ($tag | startswith("chain-"))) and
                (has("domain_strategy") or has("domain_resolver"))
            )
        ] | length
    ' "$CONFIG_FILE" 2>/dev/null)" || return 0
    [[ "$legacy_count" =~ ^[0-9]+$ && "$legacy_count" -gt 0 ]] || return 0
    use_resolver=0
    _chain_domain_resolver_supported && use_resolver=1

    tmp="$(mktemp "${CONFIG_DIR}/.singbox-click.json.XXXXXX")" || return 1
    if jq --arg resolver "$CHAIN_DOMAIN_RESOLVER_TAG" \
        --arg use_resolver "$use_resolver" \
        --argjson managed_tags "$managed_tags" '
        def valid_strategy:
            . == "prefer_ipv4" or . == "prefer_ipv6" or . == "ipv4_only" or . == "ipv6_only";
        def managed_chain:
            (.tag // "") as $tag |
            (($managed_tags | index($tag)) != null) or
            (($tag | startswith("chain-")) and has("domain_strategy"));

        .outbounds = ((.outbounds // []) | map(
            if managed_chain then
                if $use_resolver == "1" then
                    if ((.domain_strategy // "") | valid_strategy) then
                        .domain_resolver = {server:$resolver, strategy:.domain_strategy} |
                        del(.domain_strategy)
                    else
                        del(.domain_strategy)
                    end
                else
                    if ((((.domain_resolver // {}) | .strategy) // "") | valid_strategy) then
                        .domain_strategy = .domain_resolver.strategy |
                        del(.domain_resolver)
                    else
                        del(.domain_resolver)
                    end
                end
            else
                .
            end
        )) |
        if $use_resolver == "1" and
           ([.outbounds[]? | select(((((.domain_resolver // {}) | .server) // "") == $resolver))] | length) > 0
        then
            .dns //= {} |
            .dns.servers //= [] |
            if ([.dns.servers[]? | select((.tag // "") == $resolver and (.type // "") != "local")] | length) > 0 then
                error("DNS 解析器 tag 冲突: " + $resolver)
            elif ([.dns.servers[]?.tag] | index($resolver)) then .
            else .dns.servers += [{type:"local", tag:$resolver}]
            end
        else .
        end
    ' "$CONFIG_FILE" >"$tmp" 2>/dev/null; then
        if check_out="$(config_check_file "$tmp")"; then
            mv "$tmp" "$CONFIG_FILE"
            secure_config_permissions
            return 0
        fi
    fi

    rm -f "$tmp"
    return 1
}

_migrate_packaged_default_fragments() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local need_cleanup tmp
    need_cleanup="$(jq -r '
        def packaged_hijack_dns:
            (type == "object") and
            ((.action // "") == "hijack-dns") and
            ((.port // null) == 53) and
            ((keys_unsorted - ["port","action"]) | length == 0);

        (([.outbounds[]? | select((.type // "") == "direct" and ((.tag // "") == ""))] | length) +
         ([.route.rules[]? | select(packaged_hijack_dns)] | length)) > 0
    ' "$CONFIG_FILE" 2>/dev/null)" || return 0
    [[ "$need_cleanup" == "true" ]] || return 0

    tmp="$(mktemp "${CONFIG_DIR}/.singbox-click.json.XXXXXX")" || return 1
    if jq '
        def packaged_hijack_dns:
            (type == "object") and
            ((.action // "") == "hijack-dns") and
            ((.port // null) == 53) and
            ((keys_unsorted - ["port","action"]) | length == 0);
        def untagged_direct:
            (type == "object") and
            ((.type // "") == "direct") and
            ((.tag // "") == "");

        .outbounds = ((.outbounds // []) | map(select(untagged_direct | not))) |
        (if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds = ([{"type":"direct","tag":"direct"}] + (.outbounds // [])) end) |
        (if ((.route.rules? // null) | type) == "array" then
            .route.rules = ((.route.rules // []) | map(select(packaged_hijack_dns | not)))
        else
            .
        end)
    ' "$CONFIG_FILE" >"$tmp" 2>/dev/null; then
        if config_check_file "$tmp" >/dev/null; then
            mv "$tmp" "$CONFIG_FILE"
            secure_config_permissions
            return 0
        fi
    fi

    rm -f "$tmp"
    return 1
}

ensure_config() {
    migrate_legacy_config_dir
    mkdir -p "$CONFIG_DIR" "$CERT_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        _write_base_config
    fi
    _migrate_packaged_default_fragments || _warn "官方默认配置片段清理失败, 请手动检查 ${CONFIG_FILE}"
    _migrate_legacy_chain_domain_strategy_options || _warn "旧版链式代理解析配置迁移失败, 请手动检查 ${CONFIG_FILE}"
    if core_installed; then
        ensure_singbox_config_link || _warn "创建 ${SINGBOX_CONFIG_FILE} 兼容链接失败"
    fi
    secure_config_permissions
}

CONFIG_TRANSITION_ERROR=""

# checked transition: 先在临时文件生成目标状态并校验, 通过后才替换正式配置。
config_check_file() {
    local file="${1:-$CONFIG_FILE}"
    if core_installed; then
        sing-box check -c "$file" 2>&1
        return $?
    fi
    jq empty "$file" 2>&1
}

config_apply_checked() {
    ensure_config
    CONFIG_TRANSITION_ERROR=""

    local tmp errf check_out
    tmp="$(mktemp "${CONFIG_DIR}/.singbox-click.json.XXXXXX")" || return 1
    errf="$(mktemp)" || { rm -f "$tmp"; return 1; }

    if ! jq "$@" "$CONFIG_FILE" >"$tmp" 2>"$errf"; then
        CONFIG_TRANSITION_ERROR="$(cat "$errf")"
        rm -f "$tmp" "$errf"
        return 1
    fi
    rm -f "$errf"

    if ! check_out="$(config_check_file "$tmp")"; then
        CONFIG_TRANSITION_ERROR="$check_out"
        rm -f "$tmp"
        return 1
    fi

    if mv "$tmp" "$CONFIG_FILE"; then
        secure_config_permissions
        return 0
    fi

    rm -f "$tmp"
    CONFIG_TRANSITION_ERROR="无法替换 ${CONFIG_FILE}"
    return 1
}

_print_config_transition_error() {
    local line
    [[ -n "$CONFIG_TRANSITION_ERROR" ]] || return 0
    while IFS= read -r line; do
        echo "    $line"
    done <<< "$CONFIG_TRANSITION_ERROR"
}

# 校验配置 (需内核已安装)
config_check() {
    config_check_file "$CONFIG_FILE"
}

# tag 是否已存在
inbound_tag_exists() {
    ensure_config
    local tag="$1"
    local found
    found="$(jq -r --arg t "$tag" '[.inbounds[]?|select(.tag==$t)]|length' "$CONFIG_FILE" 2>/dev/null)"
    [[ "$found" =~ ^[0-9]+$ && "$found" -gt 0 ]]
}

# 端口是否已被占用 (配置内)
inbound_port_used() {
    ensure_config
    local port="$1"
    local found
    found="$(jq -r --argjson p "$port" '[.inbounds[]?|select(.listen_port==$p)]|length' "$CONFIG_FILE" 2>/dev/null)"
    [[ "$found" =~ ^[0-9]+$ && "$found" -gt 0 ]]
}

#───────────────────────────────────────────────────────────────────────────────
#  证书管理
#───────────────────────────────────────────────────────────────────────────────
# 生成自签证书: gen_self_cert <cn/sni> <crt> <key>
gen_self_cert() {
    local cn="$1" crt="$2" key="$3"
    mkdir -p "$(dirname "$crt")"
    _info "为 SNI '${cn}' 生成 ECC 自签证书..."
    if openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$key" -out "$crt" \
        -subj "/CN=${cn}" -days 36500 \
        -addext "subjectAltName=DNS:${cn}" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
        chmod 600 "$key"
        chmod 644 "$crt"
        _ok "自签证书已生成"
        return 0
    fi
    _err "自签证书生成失败。"
    return 1
}

# 交互式获取证书, 结果写入全局: CERT_PATH / KEY_PATH / CERT_INSECURE(1/0)
CERT_PATH=""; KEY_PATH=""; CERT_INSECURE=1
prompt_certificate() {
    local sni="$1" name="$2"

    menu_select "选择证书方式" \
        "自签证书 (自动生成, 客户端需允许不安全)" \
        "使用已有证书 (提供 .crt / .key 路径)"

    case "$MENU_CHOICE" in
        1)
            CERT_PATH="${CERT_DIR}/${name}.crt"
            KEY_PATH="${CERT_DIR}/${name}.key"
            gen_self_cert "$sni" "$CERT_PATH" "$KEY_PATH" || return 1
            CERT_INSECURE=1
            ;;
        2)
            local c k
            read -rp "  证书文件路径 (.crt / fullchain): " c
            read -rp "  私钥文件路径 (.key): " k
            if [[ ! -f "$c" || ! -f "$k" ]]; then
                _err "证书或私钥文件不存在。"
                return 1
            fi
            if ! openssl x509 -in "$c" -noout >/dev/null 2>&1; then
                _err "证书文件无法解析, 请检查。"
                return 1
            fi
            CERT_PATH="$c"
            KEY_PATH="$k"
            CERT_INSECURE=0
            _ok "已使用真实证书 (客户端无需 insecure)"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
#  工具: 随机密码 / 获取公网 IP
#───────────────────────────────────────────────────────────────────────────────
gen_password() {
    openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-24
}

_ss_method_key_length() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo "16" ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo "32" ;;
        *) echo "0" ;;
    esac
}

gen_ss_password() {
    local method="$1" key_len
    key_len="$(_ss_method_key_length "$method")"
    if [[ "$key_len" != "0" ]]; then
        sing-box generate rand --base64 "$key_len" 2>/dev/null || openssl rand -base64 "$key_len"
    else
        gen_password
    fi
}

_ss_password_valid() {
    local method="$1" password="$2" key_len bytes
    [[ -n "$password" ]] || return 1
    key_len="$(_ss_method_key_length "$method")"
    [[ "$key_len" == "0" ]] && return 0
    if ! bytes="$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')"; then
        return 1
    fi
    [[ "$bytes" == "$key_len" ]]
}

_b64u_no_pad() {
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

_ss_share_link() {
    local method="$1" password="$2" server="$3" port="$4" name="$5"
    local userinfo
    userinfo="$(_b64u_no_pad "${method}:${password}")"
    echo "ss://${userinfo}@${server}:${port}#${name}"
}

get_public_ip() {
    local ip
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null)"
    [[ -z "$ip" ]] && ip="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null)"
    [[ -z "$ip" ]] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
    echo "$ip"
}

SS_METHOD=""
select_ss_method() {
    SS_METHOD=""
    menu_select "选择 Shadowsocks 加密方式" \
        "2022-blake3-aes-128-gcm (SS2022, 推荐)" \
        "2022-blake3-aes-256-gcm (SS2022)" \
        "2022-blake3-chacha20-poly1305 (SS2022)" \
        "aes-128-gcm" \
        "aes-192-gcm" \
        "aes-256-gcm" \
        "chacha20-ietf-poly1305" \
        "xchacha20-ietf-poly1305"
    case "$MENU_CHOICE" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        4) SS_METHOD="aes-128-gcm" ;;
        5) SS_METHOD="aes-192-gcm" ;;
        6) SS_METHOD="aes-256-gcm" ;;
        7) SS_METHOD="chacha20-ietf-poly1305" ;;
        8) SS_METHOD="xchacha20-ietf-poly1305" ;;
        *) return 1 ;;
    esac
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
#  协议: AnyTLS 安装
#───────────────────────────────────────────────────────────────────────────────
install_anytls() {
    _header "安装协议: AnyTLS"

    require_core_for_protocol_install || return 1
    require_core_version "1.12.0" "AnyTLS" || return 1

    ensure_config

    # --- 端口 ---
    local port
    while true; do
        read -rp "  监听端口 [默认 8443]: " port
        port="${port:-8443}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            _warn "端口无效, 请输入 1-65535。"
            continue
        fi
        if inbound_port_used "$port"; then
            _warn "端口 $port 已被现有配置占用, 请换一个。"
            continue
        fi
        break
    done

    # --- 密码 ---
    local password def_pw
    def_pw="$(gen_password)"
    read -rp "  连接密码 [默认随机: ${def_pw}]: " password
    password="${password:-$def_pw}"

    # --- SNI ---
    local sni
    read -rp "  TLS SNI / 伪装域名 [默认 www.apple.com]: " sni
    sni="${sni:-www.apple.com}"

    # --- 用户名 (统计用, 可选) ---
    local uname
    read -rp "  用户名 (仅本地标识) [默认 anytls-default]: " uname
    uname="${uname:-anytls-default}"

    # --- 证书 ---
    echo ""
    prompt_certificate "$sni" "anytls-${port}" || { _err "证书配置失败, 已中止。"; _pause; return 1; }

    # --- tag (端口隔离, 支持多实例) ---
    local tag="anytls-in-${port}"

    # --- 构建并写入 inbound ---
    local inbound
    inbound="$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg uname "$uname" \
        --arg pw "$password" \
        --arg sni "$sni" \
        --arg cert "$CERT_PATH" \
        --arg key "$KEY_PATH" \
        '{
            type: "anytls",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            tcp_fast_open: true,
            users: [ { name: $uname, password: $pw } ],
            tls: {
                enabled: true,
                server_name: $sni,
                certificate_path: $cert,
                key_path: $key
            }
        }')"

    echo ""
    _info "校验配置..."
    if config_apply_checked --argjson ib "$inbound" '.inbounds += [$ib]'; then
        _ok "配置已写入并校验通过"
    else
        _err "配置校验失败 (未写入):"
        _print_config_transition_error
        _pause
        return 1
    fi

    # --- 启动/重启服务 ---
    if core_installed; then
        _info "启用并重启 sing-box 服务..."
        systemctl enable "$SERVICE" >/dev/null 2>&1
        if systemctl restart "$SERVICE" 2>/dev/null; then
            sleep 1
            if systemctl is-active --quiet "$SERVICE"; then
                _ok "服务运行中"
            else
                _err "服务启动失败, 查看日志: journalctl -u ${SERVICE} -e"
            fi
        fi
    fi

    # --- 输出分享信息 ---
    local ip
    ip="$(get_public_ip)"
    [[ -z "$ip" ]] && ip="<服务器IP>"
    local nodename="AnyTLS-${port}"
    local insecure_flag=""
    [[ "$CERT_INSECURE" == "1" ]] && insecure_flag="&allowInsecure=1"
    local link="anytls://${password}@${ip}:${port}?sni=${sni}${insecure_flag}#${nodename}"

    echo ""
    _line
    echo -e "  ${G}${BOLD}AnyTLS 安装完成${NC}"
    _line
    echo -e "  地址   : ${W}${ip}${NC}"
    echo -e "  端口   : ${W}${port}${NC}"
    echo -e "  密码   : ${W}${password}${NC}"
    echo -e "  SNI    : ${W}${sni}${NC}"
    echo -e "  证书   : ${W}$([[ "$CERT_INSECURE" == "1" ]] && echo "自签 (需 insecure)" || echo "真实证书")${NC}"
    echo ""
    echo -e "  ${C}分享链接:${NC}"
    echo -e "  ${Y}${link}${NC}"
    _line

    _pause
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
#  协议: Shadowsocks 安装
#───────────────────────────────────────────────────────────────────────────────
install_shadowsocks() {
    _header "安装协议: Shadowsocks"

    require_core_for_protocol_install || return 1
    ensure_config

    select_ss_method || { _warn "已取消"; _pause; return 1; }
    local method="$SS_METHOD"

    # --- 端口 ---
    local port
    while true; do
        read -rp "  监听端口 [默认 8388]: " port
        port="${port:-8388}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            _warn "端口无效, 请输入 1-65535。"
            continue
        fi
        if inbound_port_used "$port"; then
            _warn "端口 $port 已被现有配置占用, 请换一个。"
            continue
        fi
        if inbound_tag_exists "ss-in-${port}"; then
            _warn "标签 ss-in-${port} 已存在, 请换一个端口。"
            continue
        fi
        break
    done

    # --- 密码 / 密钥 ---
    local password def_pw key_len
    key_len="$(_ss_method_key_length "$method")"
    def_pw="$(gen_ss_password "$method")"
    while true; do
        if [[ "$key_len" != "0" ]]; then
            read -rp "  连接密钥 [默认随机 ${key_len} 字节 base64: ${def_pw}]: " password
        else
            read -rp "  连接密码 [默认随机: ${def_pw}]: " password
        fi
        password="${password:-$def_pw}"
        if _ss_password_valid "$method" "$password"; then
            break
        fi
        _warn "该加密方式需要 ${key_len} 字节随机密钥的 base64 值。"
        _dim "可直接使用默认值, 或执行: sing-box generate rand --base64 ${key_len}"
    done

    # --- 写入 inbound ---
    local tag="ss-in-${port}"
    local inbound
    inbound="$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            type: "shadowsocks",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            tcp_fast_open: true,
            method: $method,
            password: $password
        }')"

    echo ""
    _info "校验配置..."
    if config_apply_checked --argjson ib "$inbound" '.inbounds += [$ib]'; then
        _ok "配置已写入并校验通过"
    else
        _err "配置校验失败 (未写入):"
        _print_config_transition_error
        _pause
        return 1
    fi

    # --- 启动/重启服务 ---
    _info "启用并重启 sing-box 服务..."
    systemctl enable "$SERVICE" >/dev/null 2>&1
    if systemctl restart "$SERVICE" 2>/dev/null; then
        sleep 1
        if systemctl is-active --quiet "$SERVICE"; then
            _ok "服务运行中"
        else
            _err "服务启动失败, 查看日志: journalctl -u ${SERVICE} -e"
        fi
    fi

    # --- 输出分享信息 ---
    local ip nodename link
    ip="$(get_public_ip)"
    [[ -z "$ip" ]] && ip="<服务器IP>"
    if [[ "$method" == 2022-* ]]; then
        nodename="SS2022-${port}"
    else
        nodename="SS-${port}"
    fi
    link="$(_ss_share_link "$method" "$password" "$ip" "$port" "$nodename")"

    echo ""
    _line
    echo -e "  ${G}${BOLD}Shadowsocks 安装完成${NC}"
    _line
    echo -e "  地址   : ${W}${ip}${NC}"
    echo -e "  端口   : ${W}${port}${NC}"
    echo -e "  加密   : ${W}${method}${NC}"
    echo -e "  密码   : ${W}${password}${NC}"
    echo ""
    echo -e "  ${C}分享链接:${NC}"
    echo -e "  ${Y}${link}${NC}"
    _line

    _pause
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
#  协议: 单个详情 (含密码 / 证书 / 分享链接)
#  参数: $1 = inbound 下标 (从 0 开始)
#───────────────────────────────────────────────────────────────────────────────
show_protocol_detail() {
    local idx="$1"
    ensure_config

    local type port tag sni cert key method password
    type="$(jq -r --argjson i "$idx" '.inbounds[$i].type // "-"' "$CONFIG_FILE")"
    port="$(jq -r --argjson i "$idx" '.inbounds[$i].listen_port // "-"' "$CONFIG_FILE")"
    tag="$(jq -r --argjson i "$idx" '.inbounds[$i].tag // "-"' "$CONFIG_FILE")"
    sni="$(jq -r --argjson i "$idx" '.inbounds[$i].tls.server_name // "-"' "$CONFIG_FILE")"
    cert="$(jq -r --argjson i "$idx" '.inbounds[$i].tls.certificate_path // empty' "$CONFIG_FILE")"
    key="$(jq -r --argjson i "$idx" '.inbounds[$i].tls.key_path // empty' "$CONFIG_FILE")"
    method="$(jq -r --argjson i "$idx" '.inbounds[$i].method // "-"' "$CONFIG_FILE")"
    password="$(jq -r --argjson i "$idx" '.inbounds[$i].password // "-"' "$CONFIG_FILE")"

    # 证书类型判断: 本脚本自签证书都放在 CERT_DIR
    local insecure=0 cert_desc="真实证书"
    if [[ -n "$cert" && "$cert" == "${CERT_DIR}/"* ]]; then
        insecure=1
        cert_desc="自签证书 (需 allowInsecure)"
    fi

    local ip
    ip="$(get_public_ip)"
    [[ -z "$ip" ]] && ip="<服务器IP>"

    echo ""
    _line
    echo -e "  ${G}${BOLD}${type} · ${tag}${NC}"
    _line
    echo -e "  地址   : ${W}${ip}${NC}"
    echo -e "  端口   : ${W}${port}${NC}"
    if [[ "$type" == "anytls" ]]; then
        echo -e "  SNI    : ${W}${sni}${NC}"
        echo -e "  证书   : ${W}${cert_desc}${NC}"
        [[ -n "$cert" ]] && echo -e "  证书路径: ${D}${cert}${NC}"
    elif [[ "$type" == "shadowsocks" ]]; then
        echo -e "  加密   : ${W}${method}${NC}"
    fi

    if [[ "$type" == "anytls" ]]; then
        # 为每个用户输出密码与分享链接
        local insecure_flag=""
        [[ "$insecure" == "1" ]] && insecure_flag="&allowInsecure=1"
        local ucount
        ucount="$(jq -r --argjson i "$idx" '.inbounds[$i].users|length' "$CONFIG_FILE" 2>/dev/null)"
        echo ""
        local u
        for (( u=0; u<ucount; u++ )); do
            local uname pw link nodename
            uname="$(jq -r --argjson i "$idx" --argjson u "$u" '.inbounds[$i].users[$u].name // "-"' "$CONFIG_FILE")"
            pw="$(jq -r --argjson i "$idx" --argjson u "$u" '.inbounds[$i].users[$u].password // "-"' "$CONFIG_FILE")"
            nodename="AnyTLS-${port}"
            [[ "$ucount" -gt 1 ]] && nodename="AnyTLS-${port}-${uname}"
            link="anytls://${pw}@${ip}:${port}?sni=${sni}${insecure_flag}#${nodename}"
            echo -e "  ${C}用户${NC} ${W}${uname}${NC}"
            echo -e "    密码: ${W}${pw}${NC}"
            echo -e "    链接: ${Y}${link}${NC}"
        done
    elif [[ "$type" == "shadowsocks" ]]; then
        local nodename link
        if [[ "$method" == 2022-* ]]; then
            nodename="SS2022-${port}"
        else
            nodename="SS-${port}"
        fi
        link="$(_ss_share_link "$method" "$password" "$ip" "$port" "$nodename")"
        echo ""
        echo -e "  ${C}用户${NC} ${W}default${NC}"
        echo -e "    密码: ${W}${password}${NC}"
        echo -e "    链接: ${Y}${link}${NC}"
    else
        echo -e "  ${D}(该协议类型暂不支持自动生成分享链接, 请查看配置文件)${NC}"
    fi
    _line
}

#───────────────────────────────────────────────────────────────────────────────
#  协议: 查看清单
#───────────────────────────────────────────────────────────────────────────────
list_protocols() {
    while true; do
        _header "配置清单"
        ensure_config

        local n
        n="$(jq -r '.inbounds|length' "$CONFIG_FILE" 2>/dev/null)"
        if [[ ! "$n" =~ ^[0-9]+$ || "$n" -eq 0 ]]; then
            _warn "当前没有已安装的协议。"
            _pause
            return
        fi

        echo -e "  ${D}配置文件: ${CONFIG_FILE}${NC}"
        echo ""
        printf "  ${W}%-4s %-12s %-8s %-22s %s${NC}\n" "#" "类型" "端口" "标签(tag)" "SNI/加密"
        _line
        jq -r '
            .inbounds
            | to_entries[]
            | "\(.key+1)|\(.value.type // "-")|\(.value.listen_port // "-")|\(.value.tag // "-")|\(.value.tls.server_name // .value.method // "-")"
        ' "$CONFIG_FILE" 2>/dev/null | while IFS='|' read -r idx type port tag snival; do
            printf "  %-4s ${C}%-12s${NC} %-8s %-22s ${D}%s${NC}\n" "$idx" "$type" "$port" "$tag" "$snival"
        done
        _line

        # 服务状态
        echo ""
        if core_installed; then
            if systemctl is-active --quiet "$SERVICE"; then
                echo -e "  服务状态: ${G}运行中${NC}"
            else
                echo -e "  服务状态: ${Y}未运行${NC}"
            fi
        else
            echo -e "  内核状态: ${Y}未安装${NC}"
        fi
        echo ""

        # 选择查看某项的完整详情 (密码 / 分享链接)
        local opts=()
        while IFS='|' read -r type port tag; do
            opts+=("${type} · 端口 ${port} · ${tag}")
        done < <(jq -r '.inbounds[] | "\(.type)|\(.listen_port)|\(.tag)"' "$CONFIG_FILE")
        opts+=("返回")

        menu_select "选择协议查看密码 / 分享链接" "${opts[@]}"
        local choice="$MENU_CHOICE"
        if (( choice <= 0 || choice > n )); then
            return
        fi

        _header "协议详情"
        show_protocol_detail "$((choice-1))"
        _pause
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  协议: 删除
#───────────────────────────────────────────────────────────────────────────────
remove_protocol() {
    _header "删除协议"
    ensure_config

    local n
    n="$(jq -r '.inbounds|length' "$CONFIG_FILE" 2>/dev/null)"
    if [[ ! "$n" =~ ^[0-9]+$ || "$n" -eq 0 ]]; then
        _warn "当前没有可删除的协议。"
        _pause
        return
    fi

    # 构建选项
    local opts=()
    while IFS='|' read -r type port tag; do
        opts+=("${type} · 端口 ${port} · ${tag}")
    done < <(jq -r '.inbounds[] | "\(.type)|\(.listen_port)|\(.tag)"' "$CONFIG_FILE")
    opts+=("取消")

    menu_select "选择要删除的协议" "${opts[@]}"
    local choice="$MENU_CHOICE"
    if (( choice <= 0 || choice > n )); then
        _warn "已取消"
        _pause
        return
    fi

    local idx=$((choice-1))
    local tag cert key
    tag="$(jq -r --argjson i "$idx" '.inbounds[$i].tag' "$CONFIG_FILE")"
    cert="$(jq -r --argjson i "$idx" '.inbounds[$i].tls.certificate_path // empty' "$CONFIG_FILE")"
    key="$(jq -r --argjson i "$idx" '.inbounds[$i].tls.key_path // empty' "$CONFIG_FILE")"

    read -rp "  确认删除 '${tag}' ? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        _warn "已取消"
        _pause
        return
    fi

    if ! config_apply_checked --argjson i "$idx" 'del(.inbounds[$i])'; then
        _err "删除协议失败 (未写入):"
        _print_config_transition_error
        _pause
        return
    fi
    _ok "已从配置移除 ${tag}"

    # 仅删除本脚本自签目录内的证书, 避免误删用户真实证书
    if [[ -n "$cert" && "$cert" == "${CERT_DIR}/"* ]]; then
        read -rp "  同时删除自签证书文件? [y/N]: " del_cert
        if [[ "$del_cert" =~ ^[Yy]$ ]]; then
            rm -f "$cert" "$key"
            _ok "已删除证书文件"
        fi
    fi

    # 重启服务
    if core_installed && systemctl is-active --quiet "$SERVICE"; then
        systemctl restart "$SERVICE" 2>/dev/null && _ok "服务已重启"
    fi

    _pause
}

protocol_menu() {
    while true; do
        _header "协议管理"
        if core_installed; then
            echo -e "  内核: ${G}已安装${NC}  版本: ${W}$(core_version)${NC}"
        else
            echo -e "  内核: ${Y}未安装${NC}  ${D}安装协议前必须先安装内核${NC}"
        fi
        echo ""
        local anytls_label="安装 AnyTLS"
        local ss_label="安装 Shadowsocks (SS / SS2022)"
        if ! core_installed; then
            anytls_label="安装 AnyTLS (需先安装内核)"
            ss_label="安装 Shadowsocks (需先安装内核)"
        fi
        menu_select "请选择操作" \
            "$anytls_label" \
            "$ss_label" \
            "查看配置清单" \
            "删除协议" \
            "返回主菜单"
        case "$MENU_CHOICE" in
            1) install_anytls ;;
            2) install_shadowsocks ;;
            3) list_protocols ;;
            4) remove_protocol ;;
            *) return ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  服务管理
#───────────────────────────────────────────────────────────────────────────────
service_menu() {
    while true; do
        _header "服务管理"
        if core_installed; then
            if systemctl is-active --quiet "$SERVICE"; then
                echo -e "  状态: ${G}运行中${NC}"
            else
                echo -e "  状态: ${Y}已停止${NC}"
            fi
        else
            echo -e "  状态: ${Y}内核未安装${NC}"
        fi
        echo ""
        menu_select "请选择操作" \
            "启动服务" \
            "停止服务" \
            "重启服务" \
            "查看状态" \
            "查看实时日志" \
            "返回主菜单"
        case "$MENU_CHOICE" in
            1)
                ensure_config
                systemctl enable "$SERVICE" >/dev/null 2>&1
                if systemctl start "$SERVICE"; then
                    _ok "已启动"
                else
                    _err "启动失败"
                fi
                _pause
                ;;
            2)
                if systemctl stop "$SERVICE"; then
                    _ok "已停止"
                else
                    _err "停止失败"
                fi
                _pause
                ;;
            3)
                ensure_config
                if systemctl restart "$SERVICE"; then
                    _ok "已重启"
                else
                    _err "重启失败"
                fi
                _pause
                ;;
            4) echo ""; systemctl status "$SERVICE" --no-pager -l 2>&1 | head -20; _pause ;;
            5) echo ""; _dim "Ctrl+C 退出日志"; echo ""; journalctl -u "$SERVICE" -f --no-pager ;;
            *) return ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  出口 / 规则管理 (链式代理)
#───────────────────────────────────────────────────────────────────────────────
# 官方规则集仓库 (sing-box rule-set, format=binary)
readonly GEOSITE_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
readonly GEOIP_BASE="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

# --- URL 解析辅助 ---
# base64 解码 (兼容 url-safe 与缺省 padding)
_b64d() {
    local s="$1"
    s="${s//-/+}"; s="${s//_/\/}"
    case $(( ${#s} % 4 )) in
        2) s+="==" ;;
        3) s+="=" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

# url 解码 (%XX 与 +)
_urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# 从 query 串取某个键的值: _qget "a=1&b=2" b
_qget() {
    local q="$1" key="$2" kv parts
    IFS='&' read -ra parts <<< "$q"
    for kv in "${parts[@]}"; do
        if [[ "${kv%%=*}" == "$key" ]]; then
            _urldecode "${kv#*=}"
            return 0
        fi
    done
    return 1
}

# 拆分 host:port (兼容 IPv6 [::1]:443), 结果写入 HOST / PORT
HOST=""; PORT=""
_split_hostport() {
    local hp="$1"
    if [[ "$hp" == \[*\]* ]]; then
        HOST="${hp#[}"; HOST="${HOST%%]*}"
        PORT="${hp##*]:}"
    else
        HOST="${hp%:*}"; PORT="${hp##*:}"
    fi
}

# 生成一个在 outbounds 中唯一的 tag
_unique_out_tag() {
    local base="$1" t="$1" i=1 cnt
    while :; do
        cnt="$(jq -r --arg t "$t" '[.outbounds[]?|select(.tag==$t)]|length' "$CONFIG_FILE" 2>/dev/null)"
        [[ "$cnt" == "0" || -z "$cnt" ]] && break
        t="${base}-${i}"; ((i++))
    done
    echo "$t"
}

# 把节点名清洗成合法 tag 片段
_sanitize_tag() {
    local s="$1"
    s="${s//[^a-zA-Z0-9_-]/-}"
    while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
    s="${s#-}"; s="${s%-}"
    [[ -z "$s" ]] && s="node"
    echo "$s"
}

# 读取链式代理访问远端节点域名时的解析策略。
# as_is 表示不写 domain_resolver, 交给 sing-box 默认行为。
_chain_domain_strategy() {
    local ds=""
    [[ -f "$CHAIN_DOMAIN_STRATEGY_FILE" ]] && ds="$(tr -d '[:space:]' < "$CHAIN_DOMAIN_STRATEGY_FILE" 2>/dev/null)"
    case "$ds" in
        prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only|as_is) echo "$ds" ;;
        *) echo "prefer_ipv4" ;;
    esac
}

_chain_domain_strategy_label() {
    case "$(_chain_domain_strategy)" in
        prefer_ipv4) echo "优先 IPv4" ;;
        prefer_ipv6) echo "优先 IPv6" ;;
        ipv4_only)   echo "仅 IPv4" ;;
        ipv6_only)   echo "仅 IPv6" ;;
        as_is)       echo "不指定" ;;
    esac
}

_write_chain_domain_strategy() {
    local ds="$1" tmp
    mkdir -p "$CONFIG_DIR"
    tmp="$(mktemp "${CONFIG_DIR}/.chain-domain-strategy.XXXXXX")" || return 1
    printf '%s\n' "$ds" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$CHAIN_DOMAIN_STRATEGY_FILE" || { rm -f "$tmp"; return 1; }
    secure_config_permissions
}

_apply_chain_domain_strategy_to_outbound() {
    local ob="$1" ds
    ds="$(_chain_domain_strategy)"
    if [[ "$ds" == "as_is" ]]; then
        echo "$ob" | jq 'del(.domain_strategy, .domain_resolver)'
    elif _chain_domain_resolver_supported; then
        echo "$ob" | jq --arg resolver "$CHAIN_DOMAIN_RESOLVER_TAG" --arg ds "$ds" '
            .domain_resolver = {server:$resolver, strategy:$ds} |
            del(.domain_strategy)
        '
    else
        echo "$ob" | jq --arg ds "$ds" '.domain_strategy=$ds | del(.domain_resolver)'
    fi
}

set_chain_domain_strategy() {
    _header "链式代理解析策略"
    local cur; cur="$(_chain_domain_strategy_label)"
    _dim "当前策略: ${cur}"
    echo ""
    menu_select "选择链式代理访问域名时的解析策略" \
        "优先 IPv4 (推荐)" \
        "优先 IPv6" \
        "仅 IPv4" \
        "仅 IPv6" \
        "不指定 (交给 sing-box 默认)"
    local ds
    case "$MENU_CHOICE" in
        1) ds="prefer_ipv4" ;;
        2) ds="prefer_ipv6" ;;
        3) ds="ipv4_only" ;;
        4) ds="ipv6_only" ;;
        5) ds="as_is" ;;
        *) _warn "已取消"; _pause; return 1 ;;
    esac

    # 仅同步 nodes.json 记录的代理出口；未加入出口的节点会在下次加入时使用新策略。
    ensure_config
    local managed_tags use_resolver
    managed_tags="$(_chain_managed_tags_json)"
    use_resolver=0
    _chain_domain_resolver_supported && use_resolver=1

    if [[ "$ds" == "as_is" ]]; then
        config_apply_checked --argjson managed_tags "$managed_tags" '
            def managed_chain:
                (.tag // "") as $tag | (($managed_tags | index($tag)) != null);

            .outbounds = ((.outbounds // []) | map(
                if managed_chain then del(.domain_strategy, .domain_resolver)
                else .
                end
            ))
        ' || {
            _err "同步代理出口失败 (未写入):"
            _print_config_transition_error
            _pause
            return 1
        }
    else
        if [[ "$use_resolver" == "1" ]]; then
            config_apply_checked --arg resolver "$CHAIN_DOMAIN_RESOLVER_TAG" --arg ds "$ds" --argjson managed_tags "$managed_tags" '
                def managed_chain:
                    (.tag // "") as $tag | (($managed_tags | index($tag)) != null);

                .dns //= {} |
                .dns.servers //= [] |
                (if ([.dns.servers[]? | select((.tag // "") == $resolver and (.type // "") != "local")] | length) > 0 then
                    error("DNS 解析器 tag 冲突: " + $resolver)
                 elif ([.dns.servers[]?.tag] | index($resolver)) then .
                 else .dns.servers += [{type:"local", tag:$resolver}]
                 end) |
                .outbounds = ((.outbounds // []) | map(
                    if managed_chain then
                        .domain_resolver = {server:$resolver, strategy:$ds} |
                        del(.domain_strategy)
                    else .
                    end
                ))
            ' || {
                _err "同步代理出口失败 (未写入):"
                _print_config_transition_error
                _pause
                return 1
            }
        else
            config_apply_checked --arg ds "$ds" --argjson managed_tags "$managed_tags" '
                def managed_chain:
                    (.tag // "") as $tag | (($managed_tags | index($tag)) != null);

                .outbounds = ((.outbounds // []) | map(
                    if managed_chain then
                        .domain_strategy = $ds |
                        del(.domain_resolver)
                    else .
                    end
                ))
            ' || {
                _err "同步代理出口失败 (未写入):"
                _print_config_transition_error
                _pause
                return 1
            }
        fi
    fi

    if ! _write_chain_domain_strategy "$ds"; then
        _err "解析策略文件写入失败, 配置已更新但策略文件未更新。"
        _pause
        return 1
    fi
    _ok "链式代理解析策略已设置为: $(_chain_domain_strategy_label)"
    _restart_if_running
    _pause
}

# 解析链式代理分享链接 -> {name, outbound}。
# 当前只开放 Shadowsocks/SS2022, 二者均使用 ss:// 标准链接:
#   ss://base64(method:password)@host:port#name
#   ss://base64(method:password@host:port)#name
#   ss://method:password@host:port#name
# SS2022 通过 2022-* method 区分, 没有 ss2022:// scheme。
parse_proxy_url() {
    local url="$1" tag="$2"
    local scheme rest frag query name ob

    scheme="${url%%://*}"
    scheme="$(echo "$scheme" | tr '[:upper:]' '[:lower:]')"
    rest="${url#*://}"
    [[ "$url" == "$scheme" || -z "$rest" ]] && { echo "链接格式错误 (缺少 ://)" >&2; return 1; }

    # 提取 #name 片段
    if [[ "$rest" == *"#"* ]]; then
        frag="${rest##*#}"; rest="${rest%%#*}"
        name="$(_urldecode "$frag")"
    fi

    case "$scheme" in
        ss)
            local body="$rest" userpart hostport creds dec method password plugin
            if [[ "$body" == *"?"* ]]; then
                query="${body#*\?}"
                body="${body%%\?*}"
                plugin="$(_qget "$query" plugin)"
                [[ -n "$plugin" ]] && { echo "暂不支持带 plugin 的 ss 链接" >&2; return 1; }
            fi

            if [[ "$body" == *"@"* ]]; then
                userpart="${body%@*}"
                hostport="${body##*@}"
                dec="$(_b64d "$userpart")"
                if [[ "$dec" == *:* ]]; then
                    creds="$dec"
                else
                    creds="$(_urldecode "$userpart")"
                fi
            else
                dec="$(_b64d "$body")"
                [[ "$dec" == *@* ]] || { echo "ss 链接解析失败" >&2; return 1; }
                creds="${dec%@*}"
                hostport="${dec##*@}"
            fi

            hostport="${hostport%%\?*}"
            hostport="${hostport%%/*}"
            [[ "$creds" == *:* ]] || { echo "ss 缺少 method:password" >&2; return 1; }
            method="${creds%%:*}"
            password="${creds#*:}"
            _split_hostport "$hostport"
            [[ -z "$method" || -z "$password" || -z "$HOST" ]] && { echo "ss 参数不完整" >&2; return 1; }
            [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "ss 端口无效: $PORT" >&2; return 1; }
            [[ -z "$name" ]] && {
                if [[ "$method" == 2022-* ]]; then
                    name="SS2022-${HOST}"
                else
                    name="SS-${HOST}"
                fi
            }
            ob="$(jq -n --arg tag "$tag" --arg s "$HOST" --argjson p "$PORT" \
                --arg m "$method" --arg pw "$password" \
                '{ type:"shadowsocks", tag:$tag, server:$s, server_port:$p, method:$m, password:$pw }')"
            ;;
        *)
            echo "不支持的链式代理协议: ${scheme} (当前仅支持 ss://，SS2022 使用 2022-* 加密方法)" >&2
            return 1
            ;;
    esac

    if [[ -z "$ob" ]] || ! echo "$ob" | jq empty 2>/dev/null; then
        echo "解析结果无效" >&2
        return 1
    fi
    # 返回包装对象 {name, outbound}, 便于调用方 (命令替换子shell) 取回节点名
    jq -n --arg name "$name" --argjson ob "$ob" '{name:$name, outbound:$ob}'
    return 0
}

_set_final_outbound_checked() {
    local tag="$1"
    config_apply_checked --arg t "$tag" '
        .outbounds //= [] | .route //= {} | .route.rules //= [] | .route.rule_set //= [] |
        ( if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end ) |
        ( if ([.outbounds[]?.tag] | index("block"))  then . else .outbounds += [{"type":"block","tag":"block"}] end ) |
        .route.final=$t
    '
}

# 返回当前可作为分流目标的链式代理出站 tag 列表。
# 当前支持范围是 sing-box shadowsocks outbound, 覆盖 SS 与 SS2022。
_list_chain_outbound_tags() {
    jq -r '.outbounds[]? | select(.type=="shadowsocks") | .tag' "$CONFIG_FILE" 2>/dev/null
}

#───────────────────────────────────────────────────────────────────────────────
#  节点列表 (nodes.json): 保存导入的链式代理节点, 与运行配置解耦
#───────────────────────────────────────────────────────────────────────────────
ensure_nodes() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$NODES_FILE" ]]; then
        echo '{"version":"1","nodes":[]}' > "$NODES_FILE"
    fi
    secure_config_permissions
}

# 原子写入 nodes.json
nodes_apply() {
    ensure_nodes
    local tmp; tmp="$(mktemp)" || return 1
    if jq "$@" "$NODES_FILE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$NODES_FILE"; secure_config_permissions; return 0
    fi
    rm -f "$tmp"; _err "写入节点列表失败。"; return 1
}

_nodes_count() {
    ensure_nodes
    jq -r '.nodes|length' "$NODES_FILE" 2>/dev/null
}

# 节点是否已加入代理出口: active_tag 对应的 outbound 是否仍在运行配置中。
_node_active_tag_live() {
    local tag="$1"
    [[ -z "$tag" || "$tag" == "null" ]] && return 1
    ensure_config
    jq -e --arg t "$tag" '[.outbounds[]?|select(.tag==$t)]|length>0' "$CONFIG_FILE" >/dev/null 2>&1
}

# 判断 outbound 是否属于当前链式代理支持范围。
_chain_outbound_supported() {
    local ob="$1" type method
    type="$(echo "$ob" | jq -r '.type // ""' 2>/dev/null)"
    method="$(echo "$ob" | jq -r '.method // ""' 2>/dev/null)"
    [[ "$type" == "shadowsocks" && -n "$method" && "$method" != "null" ]]
}

# 解析 SS/SS2022 URL 并存入节点列表; 成功回显节点 id。
_node_add_from_url() {
    local url="$1"
    url="$(echo "$url" | tr -d '[:space:]')"
    [[ -z "$url" ]] && { echo "空链接" >&2; return 1; }

    local wrap
    if ! wrap="$(parse_proxy_url "$url" "__tmp__" 2>/dev/null)"; then
        parse_proxy_url "$url" "__tmp__" >/dev/null   # 打印错误原因到 stderr
        return 1
    fi

    local pname ob type server port id nowts name
    pname="$(echo "$wrap" | jq -r '.name // ""')"
    ob="$(echo "$wrap" | jq 'del(.outbound.tag) | .outbound')"
    type="$(echo "$ob" | jq -r '.type')"
    server="$(echo "$ob" | jq -r '.server')"
    port="$(echo "$ob" | jq -r '.server_port')"
    name="$pname"; [[ -z "$name" ]] && name="${type}-${server}"
    id="$(openssl rand -hex 4 2>/dev/null || date +%s%N | tail -c 9)"
    nowts="$(date '+%Y-%m-%d %H:%M:%S')"

    nodes_apply --arg id "$id" --arg name "$name" --arg url "$url" \
        --arg type "$type" --arg server "$server" --argjson port "$port" \
        --arg added "$nowts" --argjson ob "$ob" '
        .nodes += [{ id:$id, name:$name, url:$url, type:$type, server:$server,
                     server_port:$port, added:$added, active_tag:"", outbound:$ob }]' || return 1
    echo "$id"
    return 0
}

# 按 id 取节点字段。
_node_get() { jq -r --arg id "$1" --arg f "$2" '.nodes[]|select(.id==$id)|.[$f] // ""' "$NODES_FILE" 2>/dev/null; }

# 判断节点列表中的节点是否仍属于当前支持范围。
_node_supported() {
    local ob
    ob="$(jq -c --arg id "$1" '.nodes[]|select(.id==$id)|.outbound' "$NODES_FILE" 2>/dev/null)"
    [[ -n "$ob" && "$ob" != "null" ]] && _chain_outbound_supported "$ob"
}

# 加入代理出口: 把节点列表里的 outbound 写入运行配置, 并记录 active_tag。
_activate_node() {
    local id="$1"
    local name ob type server active_tag
    name="$(_node_get "$id" name)"
    active_tag="$(_node_get "$id" active_tag)"

    # 已加入代理出口且仍在运行配置中, 直接返回
    if _node_active_tag_live "$active_tag"; then
        _warn "节点已是代理出口 (tag: $active_tag)"
        return 0
    fi

    ob="$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)|.outbound' "$NODES_FILE")"
    [[ -z "$ob" || "$ob" == "null" ]] && { _err "节点数据缺失"; return 1; }
    if ! _chain_outbound_supported "$ob"; then
        _err "当前链式代理暂只支持 SS / SS2022 节点。"
        return 1
    fi

    local tag; tag="$(_unique_out_tag "chain-$(_sanitize_tag "$name")")"
    ob="$(echo "$ob" | jq --arg t "$tag" '.tag=$t')"
    ob="$(_apply_chain_domain_strategy_to_outbound "$ob")"

    if ! config_apply_checked --argjson ob "$ob" --arg resolver "$CHAIN_DOMAIN_RESOLVER_TAG" '
        .outbounds //= [] | .route //= {} | .route.rules //= [] | .route.rule_set //= [] |
        ( if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end ) |
        ( if ([.outbounds[]?.tag] | index("block"))  then . else .outbounds += [{"type":"block","tag":"block"}] end ) |
        if ((($ob.domain_resolver // {}) | .server // "") == $resolver) then
            .dns //= {} |
            .dns.servers //= [] |
            if ([.dns.servers[]? | select((.tag // "") == $resolver and (.type // "") != "local")] | length) > 0 then
                error("DNS 解析器 tag 冲突: " + $resolver)
            elif ([.dns.servers[]?.tag] | index($resolver)) then .
            else .dns.servers += [{type:"local", tag:$resolver}]
            end
        else .
        end |
        .outbounds += [$ob]
    '; then
        _err "加入代理出口后配置校验失败 (未写入):"
        _print_config_transition_error
        return 1
    fi

    if ! nodes_apply --arg id "$id" --arg t "$tag" '(.nodes[]|select(.id==$id)|.active_tag)=$t'; then
        _err "记录代理出口状态失败, 正在回滚。"
        config_apply_checked --arg t "$tag" '
            .outbounds = ((.outbounds // []) | map(select(.tag != $t))) |
            .route.rules = ((.route.rules // []) | map(select(.outbound != $t))) |
            ( if (.route.final // "") == $t then (.route.final = "direct") else . end )
        ' >/dev/null 2>&1 || true
        return 1
    fi

    _ok "已加入代理出口: ${name} (tag: ${tag})"
    return 0
}

# 移出代理出口: 从运行配置移除其出口, 并清理相关规则。
_deactivate_node() {
    local id="$1"
    local tag; tag="$(_node_get "$id" active_tag)"
    if ! _node_active_tag_live "$tag"; then
        _warn "该节点当前未加入代理出口。"
        nodes_apply --arg id "$id" '(.nodes[]|select(.id==$id)|.active_tag)=""'
        return 0
    fi
    if config_apply_checked --arg t "$tag" '
        .outbounds = (.outbounds | map(select(.tag != $t))) |
        .route.rules = ((.route.rules // []) | map(select(.outbound != $t))) |
        ( if (.route.final // "") == $t then (.route.final = "direct") else . end )
    '; then
        _ok "已移出代理出口: $tag"
    else
        _err "移出代理出口失败 (未写入):"
        _print_config_transition_error
        return 1
    fi
    nodes_apply --arg id "$id" '(.nodes[]|select(.id==$id)|.active_tag)=""'
    _restart_if_running
    return 0
}

# 从 URL 导入代理节点, 支持一次粘贴多行。
node_import() {
    _header "导入代理节点"
    ensure_nodes
    _dim "支持: ss:// 标准链接 (包含 SS2022 的 2022-* 加密方法)"
    _dim "可一次粘贴多行 (每行一个链接), 输入空行结束。"
    echo ""

    local line urls=()
    echo "  粘贴链接, 每行一个；输入空行开始导入:"
    echo ""
    while IFS= read -r line; do
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && break
        urls+=("$line")
    done
    if [[ ${#urls[@]} -eq 0 ]]; then
        _warn "未输入任何链接。"; _pause; return 1
    fi

    echo ""
    local u id ok=0 fail=0 errf; errf="$(mktemp)"
    local imported_ids=()
    for u in "${urls[@]}"; do
        if id="$(_node_add_from_url "$u" 2>"$errf")" && [[ -n "$id" ]]; then
            ((ok++))
            imported_ids+=("$id")
            _ok "已保存: $(_node_get "$id" name) (${u:0:40}...)"
        else
            ((fail++))
            _err "跳过无效链接: $(cat "$errf")"
            _dim "  ${u:0:60}"
        fi
    done
    rm -f "$errf"

    echo ""
    _ok "导入完成: 成功 ${ok} 个, 失败 ${fail} 个"

    if [[ "$ok" -gt 0 ]]; then
        echo ""
        read -rp "  是否加入代理出口 (让 sing-box 可使用)? [Y/n]: " act
        if [[ ! "$act" =~ ^[Nn]$ ]]; then
            local added=0 add_failed=0 first_active_id=""
            for id in "${imported_ids[@]}"; do
                if _activate_node "$id"; then
                    ((added++))
                    [[ -z "$first_active_id" ]] && first_active_id="$id"
                else
                    ((add_failed++))
                fi
            done
            [[ "$ok" -gt 1 ]] && _ok "加入代理出口完成: 成功 ${added} 个, 失败 ${add_failed} 个"
            local tag=""
            if [[ "$added" -eq 1 && -n "$first_active_id" ]]; then
                tag="$(_node_get "$first_active_id" active_tag)"
            fi
            if _node_active_tag_live "$tag"; then
                read -rp "  是否将默认出口设为该节点? [y/N]: " setf
                if [[ "$setf" =~ ^[Yy]$ ]]; then
                    if _set_final_outbound_checked "$tag"; then
                        _ok "已设为默认出口: $tag"
                    else
                        _err "设置默认出口失败 (未写入):"
                        _print_config_transition_error
                    fi
                fi
                _restart_if_running
            fi
        fi
    fi

    _pause
    return 0
}

_chain_active_count() {
    ensure_nodes
    local n=0 id tag
    while IFS=$'\t' read -r id tag; do
        _node_supported "$id" && _node_active_tag_live "$tag" && ((n++))
    done < <(jq -r '.nodes[]? | [.id, (.active_tag // "")] | @tsv' "$NODES_FILE" 2>/dev/null)
    echo "$n"
}

list_chain_nodes() {
    _header "链式代理节点"
    ensure_nodes
    local count; count="$(_nodes_count)"
    if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
        _dim "暂无节点, 请先导入代理链接。"
        _pause
        return 0
    fi

    printf "  ${W}${BOLD}%-4s %-22s %-12s %-24s %-18s${NC}\n" "序号" "名称" "协议" "服务器" "状态"
    _line
    local i=1
    while IFS=$'\t' read -r id name type server port active_tag; do
        local status="${D}未加入出口${NC}"
        if _node_active_tag_live "$active_tag"; then
            if _node_supported "$id"; then
                status="${G}代理出口: ${active_tag}${NC}"
            else
                status="${Y}代理出口: ${active_tag} (暂不支持)${NC}"
            fi
        elif [[ -n "$active_tag" && "$active_tag" != "null" ]]; then
            status="${Y}已失效${NC}"
        elif ! _node_supported "$id"; then
            status="${Y}暂不支持${NC}"
        fi
        printf "  %-4s ${C}%-22s${NC} %-12s %-24s %b\n" "$i" "${name:0:22}" "$type" "${server}:${port}" "$status"
        ((i++))
    done < <(jq -r '.nodes[]? | [.id,.name,.type,.server,(.server_port|tostring),(.active_tag // "")] | @tsv' "$NODES_FILE" 2>/dev/null)
    _line
    _dim "链式代理域名解析策略: $(_chain_domain_strategy_label)"
    _pause
}

NODE_ID=""
_pick_node_id() {
    local title="${1:-选择节点}"
    ensure_nodes
    NODE_ID=""
    local ids=() opts=()
    local id name type server port active_tag status
    while IFS=$'\t' read -r id name type server port active_tag; do
        [[ -z "$id" ]] && continue
        status="未加入出口"
        if _node_active_tag_live "$active_tag"; then
            if _node_supported "$id"; then
                status="代理出口: ${active_tag}"
            else
                status="代理出口暂不支持: ${active_tag}"
            fi
        elif [[ -n "$active_tag" && "$active_tag" != "null" ]]; then
            status="已失效"
        elif ! _node_supported "$id"; then
            status="暂不支持"
        fi
        ids+=("$id")
        opts+=("${name} (${type}, ${server}:${port}, ${status})")
    done < <(jq -r '.nodes[]? | [.id,.name,.type,.server,(.server_port|tostring),(.active_tag // "")] | @tsv' "$NODES_FILE" 2>/dev/null)

    if [[ ${#ids[@]} -eq 0 ]]; then
        _warn "暂无节点。"
        return 1
    fi
    opts+=("取消")
    menu_select "$title" "${opts[@]}"
    local c="$MENU_CHOICE"
    (( c < 1 || c > ${#ids[@]} )) && return 1
    NODE_ID="${ids[$((c-1))]}"
    return 0
}

manage_chain_node_state() {
    _header "代理出口"
    _pick_node_id "选择节点" || { _warn "已取消"; _pause; return 1; }

    local id="$NODE_ID" name tag
    name="$(_node_get "$id" name)"
    tag="$(_node_get "$id" active_tag)"

    if _node_active_tag_live "$tag"; then
        if ! _node_supported "$id"; then
            menu_select "节点 '${name}' 已加入代理出口但暂不支持" \
                "移出代理出口并清理相关流量规则" \
                "返回"
            case "$MENU_CHOICE" in
                1) _deactivate_node "$id" ;;
                *) _warn "已取消" ;;
            esac
            _pause
            return 0
        fi

        menu_select "节点 '${name}' 已加入代理出口" \
            "移出代理出口并清理相关流量规则" \
            "设为默认出口" \
            "返回"
        case "$MENU_CHOICE" in
            1)
                _deactivate_node "$id"
                ;;
            2)
                if _set_final_outbound_checked "$tag"; then
                    _ok "已设为默认出口: $tag"
                else
                    _err "设置默认出口失败 (未写入):"
                    _print_config_transition_error
                fi
                _restart_if_running
                ;;
            *) _warn "已取消" ;;
        esac
        _pause
        return 0
    fi

    if ! _node_supported "$id"; then
        _err "当前链式代理暂只支持 SS / SS2022 节点。"
        _pause
        return 1
    fi

    _activate_node "$id"
    tag="$(_node_get "$id" active_tag)"
    if _node_active_tag_live "$tag"; then
        read -rp "  是否将默认出口设为该节点? [y/N]: " setf
        if [[ "$setf" =~ ^[Yy]$ ]]; then
            if _set_final_outbound_checked "$tag"; then
                _ok "已设为默认出口: $tag"
            else
                _err "设置默认出口失败 (未写入):"
                _print_config_transition_error
            fi
        fi
        _restart_if_running
    fi
    _pause
}

delete_chain_node() {
    _header "删除链式代理节点"
    _pick_node_id "选择要删除的节点" || { _warn "已取消"; _pause; return 1; }

    local id="$NODE_ID" name tag
    name="$(_node_get "$id" name)"
    tag="$(_node_get "$id" active_tag)"
    read -rp "  确认删除节点 '${name}'? 已加入的代理出口和相关流量规则也会清理 [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { _warn "已取消"; _pause; return 1; }

    if _node_active_tag_live "$tag"; then
        config_apply_checked --arg t "$tag" '
            .outbounds = ((.outbounds // []) | map(select(.tag != $t))) |
            .route.rules = ((.route.rules // []) | map(select(.outbound != $t))) |
            ( if (.route.final // "") == $t then (.route.final = "direct") else . end )
        ' || {
            _err "清理出口失败 (未写入):"
            _print_config_transition_error
            _pause
            return 1
        }
    fi

    nodes_apply --arg id "$id" '.nodes = ((.nodes // []) | map(select(.id != $id)))' \
        && _ok "已删除节点: $name"
    _restart_if_running
    _pause
}

add_chain_proxy() {
    while true; do
        _header "代理节点"
        ensure_nodes
        ensure_config
        local total active
        total="$(_nodes_count)"
        active="$(_chain_active_count)"
        echo -e "  节点: ${W}${total}${NC} 个   代理出口: ${W}${active}${NC} 个"
        echo -e "  解析策略: ${W}$(_chain_domain_strategy_label)${NC}"
        echo ""
        menu_select "请选择操作" \
            "导入节点 (从 URL 粘贴)" \
            "加入 / 移出代理出口" \
            "设置链式代理解析策略" \
            "查看节点列表" \
            "删除节点" \
            "返回"
        case "$MENU_CHOICE" in
            1) node_import ;;
            2) manage_chain_node_state ;;
            3) set_chain_domain_strategy ;;
            4) list_chain_nodes ;;
            5) delete_chain_node ;;
            *) return ;;
        esac
    done
}

# 服务运行时重启以生效
_restart_if_running() {
    if core_installed && systemctl is-active --quiet "$SERVICE"; then
        ensure_singbox_config_link
        secure_config_permissions
        if systemctl restart "$SERVICE" 2>/dev/null; then
            _ok "服务已重启生效"
        else
            _err "服务重启失败, 请查看日志"
        fi
    fi
}

# 选择一个路由目标出站, 结果写入 ROUTE_TARGET。
# 可选项包含 direct/block 与当前支持的 SS/SS2022 链式代理出站。
ROUTE_TARGET=""
_pick_target_outbound() {
    local title="${1:-选择目标出口}"
    local opts=("direct (直连)" "block (拦截)")
    local tags=("direct" "block")
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        opts+=("$t (代理出口)")
        tags+=("$t")
    done < <(_list_chain_outbound_tags)

    menu_select "$title" "${opts[@]}"
    local c="$MENU_CHOICE"
    if (( c < 1 || c > ${#tags[@]} )); then ROUTE_TARGET=""; return 1; fi
    ROUTE_TARGET="${tags[$((c-1))]}"
    return 0
}

# 添加一条 rule_set + 规则
# 参数: tag url_or_path type(remote/local) format target
_add_ruleset_rule() {
    local rtag="$1" src="$2" kind="$3" fmt="$4" target="$5"
    local rsentry
    if [[ "$kind" == "remote" ]]; then
        rsentry="$(jq -n --arg tag "$rtag" --arg fmt "$fmt" --arg url "$src" \
            '{ type:"remote", tag:$tag, format:$fmt, url:$url, download_detour:"direct" }')"
    else
        rsentry="$(jq -n --arg tag "$rtag" --arg fmt "$fmt" --arg path "$src" \
            '{ type:"local", tag:$tag, format:$fmt, path:$path }')"
    fi
    # 去重后追加 rule_set, 并追加规则
    config_apply_checked --argjson rs "$rsentry" --arg tag "$rtag" --arg out "$target" '
        .outbounds //= [] | .route //= {} | .route.rules //= [] | .route.rule_set //= [] |
        ( if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end ) |
        ( if ([.outbounds[]?.tag] | index("block"))  then . else .outbounds += [{"type":"block","tag":"block"}] end ) |
        .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $tag)) + [$rs]) |
        .route.rules   = ((.route.rules // []) + [{ rule_set:[$tag], outbound:$out }])
    '
}

# 特色: 添加用户指定的规则文件 (远程 / 本地)
add_custom_srs() {
    _header "添加规则文件"

    menu_select "规则文件来源" \
        "远程 URL (自动下载)" \
        "本地文件 (服务器上的路径)"
    local kind
    case "$MENU_CHOICE" in
        1) kind="remote" ;;
        2) kind="local" ;;
        *) _warn "已取消"; _pause; return 1 ;;
    esac

    local rtag
    read -rp "  规则名称 (字母数字): " rtag
    rtag="$(_sanitize_tag "$rtag")"
    if [[ -z "$rtag" || "$rtag" == "node" ]]; then
        _err "规则名称无效。"; _pause; return 1
    fi
    if jq -e --arg t "$rtag" '[.route.rule_set[]?|select(.tag==$t)]|length>0' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "规则 '$rtag' 已存在, 将被覆盖更新。"
    fi

    local src fmt
    if [[ "$kind" == "remote" ]]; then
        read -rp "  规则文件 URL (.srs 或 .json): " src
        if [[ ! "$src" =~ ^https?:// ]]; then
            _err "无效 URL, 必须以 http:// 或 https:// 开头。"; _pause; return 1
        fi
        menu_select "规则文件格式" "二进制规则 (.srs, 推荐)" "JSON 规则 (.json)"
        case "$MENU_CHOICE" in
            1) fmt="binary" ;;
            2) fmt="source" ;;
            *) _warn "已取消"; _pause; return 1 ;;
        esac
        # 可达性检测 (不阻断, 仅提示)
        _info "检测 URL 可达性..."
        local code
        code="$(curl -fsSL --max-time 10 -o /dev/null -w '%{http_code}' "$src" 2>/dev/null)"
        if [[ "$code" =~ ^2 || "$code" =~ ^3 ]]; then
            _ok "URL 可访问 (HTTP $code)"
        else
            _warn "URL 暂时无法访问 (HTTP ${code:-连接失败})。仍会写入, 但服务启动时可能下载失败。"
        fi
    else
        read -rp "  本地规则文件绝对路径: " src
        if [[ ! -f "$src" ]]; then
            _err "文件不存在: $src"; _pause; return 1
        fi
        # 按扩展名推断格式
        case "$src" in
            *.srs)  fmt="binary" ;;
            *.json) fmt="source" ;;
            *)
                menu_select "无法从扩展名判断, 请选择格式" "二进制规则 (.srs)" "JSON 规则 (.json)"
                case "$MENU_CHOICE" in
                    1) fmt="binary" ;;
                    2) fmt="source" ;;
                    *) _warn "已取消"; _pause; return 1 ;;
                esac
                ;;
        esac
        # source 格式校验 JSON
        if [[ "$fmt" == "source" ]] && ! jq empty "$src" 2>/dev/null; then
            _err "该文件不是有效 JSON, 无法作为 JSON 规则文件。"; _pause; return 1
        fi
        _ok "本地规则文件有效: $src ($fmt)"
    fi

    echo ""
    _pick_target_outbound "命中这个规则文件的流量走哪个出口?" || { _warn "已取消"; _pause; return 1; }

    if _add_ruleset_rule "$rtag" "$src" "$kind" "$fmt" "$ROUTE_TARGET"; then
        _ok "规则已添加并校验通过: [$rtag] -> $ROUTE_TARGET"
        _restart_if_running
    else
        _err "写入规则失败 (未写入):"
        _print_config_transition_error
        _pause
        return 1
    fi
    _pause
    return 0
}

# 预设: 禁止服务器回国流量
preset_block_cn() {
    _header "禁止回国流量"

    read -rp "  将阻止访问中国 IP / 域名的流量, 继续? [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { _warn "已取消"; _pause; return 1; }

    local rs_geoip rs_geosite
    rs_geoip="$(jq -n --arg u "${GEOIP_BASE}/geoip-cn.srs" '{type:"remote",tag:"geoip-cn",format:"binary",url:$u,download_detour:"direct"}')"
    rs_geosite="$(jq -n --arg u "${GEOSITE_BASE}/geosite-cn.srs" '{type:"remote",tag:"geosite-cn",format:"binary",url:$u,download_detour:"direct"}')"

    if config_apply_checked --argjson a "$rs_geoip" --argjson b "$rs_geosite" '
        .outbounds //= [] | .route //= {} | .route.rules //= [] | .route.rule_set //= [] |
        ( if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end ) |
        ( if ([.outbounds[]?.tag] | index("block"))  then . else .outbounds += [{"type":"block","tag":"block"}] end ) |
        .route.rule_set = ((.route.rule_set // []) | map(select(.tag!="geoip-cn" and .tag!="geosite-cn")) + [$a,$b]) |
        .route.rules   = ([{ rule_set:["geoip-cn","geosite-cn"], outbound:"block" }]
                           + ((.route.rules // []) | map(select((.rule_set // []) | (index("geoip-cn")|not) and (index("geosite-cn")|not)))))
    '; then
        _ok "已配置: geoip-cn/geosite-cn -> block"
        _restart_if_running
    else
        _err "配置校验失败 (未写入):"
        _print_config_transition_error
        _pause
        return 1
    fi
    _pause
}

# 预设: 广告拦截
preset_block_ads() {
    _header "拦截广告"
    local rs
    rs="$(jq -n --arg u "${GEOSITE_BASE}/geosite-category-ads-all.srs" '{type:"remote",tag:"geosite-ads",format:"binary",url:$u,download_detour:"direct"}')"
    if config_apply_checked --argjson rs "$rs" '
        .outbounds //= [] | .route //= {} | .route.rules //= [] | .route.rule_set //= [] |
        ( if ([.outbounds[]?.tag] | index("direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end ) |
        ( if ([.outbounds[]?.tag] | index("block"))  then . else .outbounds += [{"type":"block","tag":"block"}] end ) |
        .route.rule_set = ((.route.rule_set // []) | map(select(.tag!="geosite-ads")) + [$rs]) |
        .route.rules   = ((.route.rules // []) | map(select((.rule_set // []) | (index("geosite-ads")|not)))
                           + [{ rule_set:["geosite-ads"], outbound:"block" }])
    '; then
        _ok "已启用广告拦截 (geosite-category-ads-all -> block)"
        _restart_if_running
    else
        _err "配置校验失败 (未写入):"
        _print_config_transition_error
        _pause
        return 1
    fi
    _pause
}

# 设置默认出口
set_final_outbound() {
    _header "设置默认出口"
    _pick_target_outbound "没有匹配规则时, 流量走哪个出口?" || { _warn "已取消"; _pause; return; }
    if _set_final_outbound_checked "$ROUTE_TARGET"; then
        _ok "默认出口已设为: $ROUTE_TARGET"
    else
        _err "设置默认出口失败 (未写入):"
        _print_config_transition_error
    fi
    _restart_if_running
    _pause
}

# 查看出口与规则
list_outbounds_routes() {
    _header "出口与流量规则"
    ensure_config

    local finalv
    finalv="$(jq -r '.route.final // empty' "$CONFIG_FILE" 2>/dev/null)"
    [[ -z "$finalv" || "$finalv" == "null" ]] && finalv="$(jq -r '.outbounds[0].tag // .outbounds[0].type // "direct"' "$CONFIG_FILE" 2>/dev/null)"

    echo -e "  ${W}${BOLD}当前默认${NC}"
    _line
    echo -e "  未命中任何规则的流量 -> ${G}${finalv}${NC}"
    echo ""

    echo -e "  ${W}${BOLD}可用出口${NC}"
    _line
    printf "  %-6s ${C}%-24s${NC} %-12s ${D}%-24s %s${NC}\n" "用途" "名称" "类型" "地址" "备注"
    jq -r '.outbounds[]? |
        "\(.tag)|\(.type)|\(.server // "-")|\(.server_port // "-")|\(((if ((.domain_resolver // null) | type) == "object" then .domain_resolver.strategy else null end) // .domain_strategy // "-"))"' "$CONFIG_FILE" 2>/dev/null \
    | while IFS='|' read -r tag type srv sport ds; do
        [[ -z "$tag" || "$tag" == "null" ]] && tag="$type"
        local extra=""; [[ "$srv" != "-" ]] && extra="${srv}:${sport}"
        local parse=""; [[ "$ds" != "-" ]] && parse="解析:${ds}"
        local role="可选"
        [[ "$tag" == "$finalv" ]] && role="默认"
        [[ "$tag" == "direct" && "$role" != "默认" ]] && role="直连"
        [[ "$tag" == "block" ]] && role="拦截"
        printf "  %-6s ${C}%-24s${NC} %-12s ${D}%-24s %s${NC}\n" "$role" "$tag" "$type" "$extra" "$parse"
    done

    echo ""
    echo -e "  ${W}${BOLD}流量规则${NC}"
    _line
    local rn
    rn="$(jq -r '.route.rules|length' "$CONFIG_FILE" 2>/dev/null)"
    if [[ ! "$rn" =~ ^[0-9]+$ || "$rn" -eq 0 ]]; then
        _dim "(无流量规则)"
    else
        jq -r '.route.rules | to_entries[] |
            "\(.key+1)|\((.value.rule_set // [] | join(","))// "-")|\(.value.domain_suffix // [] | join(","))|\(.value.outbound // "-")"' \
            "$CONFIG_FILE" 2>/dev/null | while IFS='|' read -r idx rs ds out; do
            local match="$rs"; [[ -z "$match" || "$match" == "-" ]] && match="$ds"
            [[ -z "$match" ]] && match="(其它)"
            printf "  %-3s 条件: ${C}%-28s${NC} -> 出口: ${G}%s${NC}\n" "$idx" "$match" "$out"
        done
    fi

    echo ""
    echo -e "  ${W}${BOLD}规则文件${NC}"
    _line
    local sn
    sn="$(jq -r '.route.rule_set|length' "$CONFIG_FILE" 2>/dev/null)"
    if [[ ! "$sn" =~ ^[0-9]+$ || "$sn" -eq 0 ]]; then
        _dim "(无规则文件)"
    else
        jq -r '.route.rule_set[]? | "\(.tag)|\(.type)|\(.format)|\(.url // .path // "-")"' "$CONFIG_FILE" 2>/dev/null \
        | while IFS='|' read -r tag type fmt loc; do
            printf "  ${C}%-16s${NC} %-8s %-8s ${D}%s${NC}\n" "$tag" "$type" "$fmt" "$loc"
        done
    fi
    _line
    _pause
}

remove_rule_menu() {
    while true; do
        _header "删除流量规则"
        menu_select "请选择" \
            "删除一条规则" \
            "删除规则文件" \
            "返回"
        case "$MENU_CHOICE" in
            1) _remove_rule ;;
            2) _remove_ruleset ;;
            *) return ;;
        esac
    done
}

_remove_rule() {
    local rn
    rn="$(jq -r '.route.rules|length' "$CONFIG_FILE" 2>/dev/null)"
    if [[ ! "$rn" =~ ^[0-9]+$ || "$rn" -eq 0 ]]; then _warn "没有流量规则。"; _pause; return; fi
    local opts=() i
    while IFS= read -r i; do opts+=("$i"); done < <(jq -r '.route.rules|to_entries[]|
        "#\(.key+1)  \((.value.rule_set // [] | join(","))) \((.value.domain_suffix // [] | join(","))) -> \(.value.outbound // "-")"' "$CONFIG_FILE")
    opts+=("取消")
    menu_select "选择要删除的规则" "${opts[@]}"
    local c="$MENU_CHOICE"
    (( c < 1 || c > rn )) && { _warn "已取消"; _pause; return; }
    if config_apply_checked --argjson i "$((c-1))" 'del(.route.rules[$i])'; then
        _ok "已删除规则 #$c"
    else
        _err "删除规则失败 (未写入):"
        _print_config_transition_error
        _pause
        return
    fi
    _restart_if_running
    _pause
}

_remove_ruleset() {
    local tags=() opts=() t
    while IFS= read -r t; do [[ -n "$t" ]] && { tags+=("$t"); opts+=("$t"); }; done < <(jq -r '.route.rule_set[]?.tag' "$CONFIG_FILE" 2>/dev/null)
    if [[ ${#tags[@]} -eq 0 ]]; then _warn "没有规则文件。"; _pause; return; fi
    opts+=("取消")
    menu_select "选择要删除的规则文件" "${opts[@]}"
    local c="$MENU_CHOICE"
    (( c < 1 || c > ${#tags[@]} )) && { _warn "已取消"; _pause; return; }
    local tag="${tags[$((c-1))]}"
    if config_apply_checked --arg t "$tag" '
        .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $t))) |
        .route.rules = ((.route.rules // []) | map(select((.rule_set // []) | (index($t)|not))))
    '; then
        _ok "已删除规则文件 $tag (及引用它的规则)"
    else
        _err "删除规则文件失败 (未写入):"
        _print_config_transition_error
        _pause
        return
    fi
    _restart_if_running
    _pause
}

routing_menu() {
    while true; do
        _header "流量规则"
        _dim "规则从上到下匹配；没有匹配时走默认出口。"
        echo ""
        menu_select "请选择" \
            "禁止回国流量" \
            "拦截广告" \
            "设置默认出口" \
            "添加规则文件" \
            "删除规则" \
            "返回"
        case "$MENU_CHOICE" in
            1) preset_block_cn ;;
            2) preset_block_ads ;;
            3) set_final_outbound ;;
            4) add_custom_srs ;;
            5) remove_rule_menu ;;
            *) return ;;
        esac
    done
}

outbound_menu() {
    while true; do
        _header "出口 / 规则"
        local oc="0" rn="0" finalv=""
        [[ -f "$CONFIG_FILE" ]] && oc="$(jq -r '[.outbounds[]?|select(.type=="shadowsocks")]|length' "$CONFIG_FILE" 2>/dev/null)"
        [[ -f "$CONFIG_FILE" ]] && rn="$(jq -r '(.route.rules // []) | length' "$CONFIG_FILE" 2>/dev/null)"
        [[ -f "$CONFIG_FILE" ]] && finalv="$(jq -r '.route.final // empty' "$CONFIG_FILE" 2>/dev/null)"
        [[ -z "$finalv" || "$finalv" == "null" ]] && finalv="direct"
        echo -e "  默认: ${W}${finalv}${NC}   代理: ${W}${oc}${NC} 个   规则: ${W}${rn}${NC} 条"
        echo ""
        menu_select "请选择" \
            "代理节点" \
            "流量设置" \
            "查看状态" \
            "返回主菜单"
        case "$MENU_CHOICE" in
            1) add_chain_proxy ;;
            2) routing_menu ;;
            3) list_outbounds_routes ;;
            *) return ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  脚本更新
#───────────────────────────────────────────────────────────────────────────────
update_script() {
    _header "更新脚本"

    if [[ ! -f "$SCRIPT_SRC" ]]; then
        _err "无法定位当前脚本路径 (${SCRIPT_SRC})。"
        _pause
        return 1
    fi

    local branch="main" meta tmp url remote_version
    local script_real self_real
    local source_needs_update=0 shortcut_needs_sync=0 shortcuts=""
    _info "检查 GitHub 最新脚本..."
    if meta="$(curl -fsSL --connect-timeout 10 --max-time 15 "$GITHUB_API_REPO" 2>/dev/null)"; then
        branch="$(echo "$meta" | jq -r '.default_branch // empty' 2>/dev/null)"
        branch="${branch:-main}"
    fi

    tmp="$(mktemp)" || { _err "创建临时文件失败"; _pause; return 1; }
    url="${GITHUB_RAW_BASE}/${branch}/singbox-manager.sh"
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$tmp"; then
        rm -f "$tmp"
        _err "下载最新脚本失败: ${url}"
        _pause
        return 1
    fi

    if ! grep -q '^readonly APP_NAME="singbox-click"$' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _err "下载内容不像有效脚本, 已中止。"
        _pause
        return 1
    fi

    shortcuts="$(_list_shortcuts)"
    if ! cmp -s "$SCRIPT_SRC" "$tmp"; then
        source_needs_update=1
    fi
    script_real="$(readlink -f "$SCRIPT_SRC" 2>/dev/null || true)"
    self_real="$(readlink -f "$SELF_INSTALL_PATH" 2>/dev/null || true)"
    if [[ -f "$SELF_INSTALL_PATH" && "$self_real" != "$script_real" ]] && ! cmp -s "$SELF_INSTALL_PATH" "$tmp"; then
        shortcut_needs_sync=1
    fi

    if [[ "$source_needs_update" == "0" && "$shortcut_needs_sync" == "0" ]]; then
        rm -f "$tmp"
        _ok "当前已是最新脚本。"
        _pause
        return 0
    fi

    remote_version="$(sed -nE 's/^readonly SCRIPT_VERSION="([^"]+)".*/\1/p' "$tmp" | head -1)"
    remote_version="${remote_version:-未知}"
    echo -e "  当前版本: ${W}${SCRIPT_VERSION}${NC}"
    echo -e "  最新版本: ${W}${remote_version}${NC}"
    echo -e "  来源分支: ${W}${branch}${NC}"
    if [[ "$shortcut_needs_sync" == "1" ]]; then
        echo -e "  快捷命令: ${W}需要同步${NC}"
        [[ -n "$shortcuts" ]] && echo -e "  已注册命令: ${W}$(echo "$shortcuts" | tr '\n' ' ')${NC}"
    fi
    echo ""
    read -rp "  是否执行更新? [y/N]: " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        rm -f "$tmp"
        _warn "已取消"
        _pause
        return 1
    fi

    if [[ "$source_needs_update" == "1" ]]; then
        if ! cp -f "$tmp" "$SCRIPT_SRC"; then
            rm -f "$tmp"
            _err "替换脚本失败。"
            _pause
            return 1
        fi
        chmod 755 "$SCRIPT_SRC" 2>/dev/null || true
    fi

    if [[ "$shortcut_needs_sync" == "1" ]]; then
        if ! cp -f "$tmp" "$SELF_INSTALL_PATH"; then
            rm -f "$tmp"
            _err "同步快捷命令副本失败。"
            _pause
            return 1
        fi
        chmod 755 "$SELF_INSTALL_PATH" 2>/dev/null || true
    fi

    rm -f "$tmp"

    _ok "脚本已更新。"
    if [[ "$shortcut_needs_sync" == "1" && -n "$shortcuts" ]]; then
        _ok "已同步快捷命令: $(echo "$shortcuts" | tr '\n' ' ')"
    fi
    _dim "请重新运行脚本以加载新版本。"
    _pause
    exit 0
}

#───────────────────────────────────────────────────────────────────────────────
#  快捷命令 / 脚本卸载
#───────────────────────────────────────────────────────────────────────────────
# 列出 /usr/local/bin 下所有指向本脚本副本的软链接 (即已注册的快捷命令)
_list_shortcuts() {
    local target f
    target="$(readlink -f "$SELF_INSTALL_PATH" 2>/dev/null)"
    [[ -z "$target" ]] && return 0
    for f in "$SELF_INSTALL_DIR"/*; do
        [[ -L "$f" ]] || continue
        if [[ "$(readlink -f "$f" 2>/dev/null)" == "$target" ]]; then
            basename "$f"
        fi
    done
}

_shortcut_count() {
    local shortcuts="$1"
    [[ -n "$shortcuts" ]] || { echo 0; return 0; }
    printf '%s\n' "$shortcuts" | sed '/^$/d' | wc -l | tr -d ' '
}

_remove_registered_shortcuts() {
    local shortcuts="$1" keep="${2:-}" name removed=()
    while IFS= read -r name; do
        [[ -z "$name" || "$name" == "$keep" ]] && continue
        if rm -f "${SELF_INSTALL_DIR}/${name}"; then
            removed+=("$name")
        fi
    done <<< "$shortcuts"
    if [[ ${#removed[@]} -gt 0 ]]; then
        _ok "已移除旧快捷命令: ${removed[*]}"
    fi
}

install_shortcut() {
    _header "安装快捷命令"

    if [[ ! -f "$SCRIPT_SRC" ]]; then
        _err "无法定位当前脚本路径 (${SCRIPT_SRC})。"
        _pause; return 1
    fi

    local name
    read -rp "  快捷命令名称 [默认 ${DEFAULT_SHORTCUT}]: " name
    name="${name:-$DEFAULT_SHORTCUT}"

    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        _err "命令名不合法 (仅字母开头, 允许字母/数字/_/-)。"
        _pause; return 1
    fi

    local link="${SELF_INSTALL_DIR}/${name}"
    local old_shortcuts
    old_shortcuts="$(_list_shortcuts)"

    # 若同名命令已存在且不是本脚本的软链接, 提醒避免覆盖系统命令
    if [[ -e "$link" && ! -L "$link" ]]; then
        _err "'${link}' 已存在且不是软链接, 为避免覆盖系统文件已中止。"
        _pause; return 1
    fi
    if command -v "$name" >/dev/null 2>&1 && [[ "$(command -v "$name")" != "$link" ]]; then
        _warn "系统中已存在命令 '$name' ($(command -v "$name"))。"
        read -rp "  仍要在 ${SELF_INSTALL_DIR} 创建同名快捷命令? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { _warn "已取消"; _pause; return 1; }
    fi

    mkdir -p "$SELF_INSTALL_DIR"

    # 把脚本复制到稳定位置 (若当前就是该副本则跳过)
    if [[ "$(readlink -f "$SCRIPT_SRC")" != "$(readlink -f "$SELF_INSTALL_PATH" 2>/dev/null)" ]]; then
        cp -f "$SCRIPT_SRC" "$SELF_INSTALL_PATH" || { _err "复制脚本失败"; _pause; return 1; }
    fi
    chmod 755 "$SELF_INSTALL_PATH"

    _remove_registered_shortcuts "$old_shortcuts" "$name"
    ln -sf "$SELF_INSTALL_PATH" "$link"

    _ok "已安装快捷命令: ${G}${name}${NC}"
    _dim "脚本副本: ${SELF_INSTALL_PATH}"
    _dim "现在任意目录输入 '${name}' 即可启动本脚本。"
    _pause
    return 0
}

uninstall_script() {
    _header "完全卸载"

    local shortcuts self_copy_present=0
    shortcuts="$(_list_shortcuts)"

    echo -e "  将执行以下清理:"
    if _singbox_core_present; then
        echo -e "    · 卸载 sing-box 内核并停止服务"
    else
        echo -e "    · ${D}未检测到 sing-box 内核${NC}"
    fi
    echo -e "    · 删除配置目录: ${W}${CONFIG_DIR}${NC}"
    if [[ -L "$SINGBOX_CONFIG_FILE" ]]; then
        echo -e "    · 删除兼容链接: ${W}${SINGBOX_CONFIG_FILE}${NC}"
    fi
    if [[ -n "$shortcuts" ]]; then
        echo -e "    · 删除快捷命令: ${W}$(echo "$shortcuts" | tr '\n' ' ')${NC}"
    else
        echo -e "    · ${D}未发现已注册的快捷命令${NC}"
    fi
    if [[ -f "$SELF_INSTALL_PATH" ]]; then
        self_copy_present=1
        echo -e "    · 删除脚本副本: ${W}${SELF_INSTALL_PATH}${NC}"
    fi
    echo ""
    _warn "此操作会删除内核、服务、配置、节点列表、证书和快捷命令。"
    read -rp "  确认完全卸载? 输入 ${R}yes${NC} 继续: " confirm
    if [[ "$confirm" != "yes" ]]; then
        _warn "已取消"
        _pause; return 1
    fi

    _remove_singbox_core "yes" || true

    # 先删软链接 (此时副本仍在, readlink 可解析), 再删副本
    local removed=() name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        rm -f "${SELF_INSTALL_DIR}/${name}" && removed+=("$name")
    done <<< "$shortcuts"

    if [[ "$self_copy_present" == "1" ]]; then
        rm -f "$SELF_INSTALL_PATH"
    fi

    if [[ ${#removed[@]} -gt 0 ]]; then
        _ok "已删除快捷命令: ${removed[*]}"
    fi
    if [[ "$self_copy_present" == "1" && ! -f "$SELF_INSTALL_PATH" ]]; then
        _ok "已删除脚本副本"
    fi
    echo ""
    _dim "若你手动放置的原始脚本文件仍需删除, 请自行 rm。"
    echo ""
    _dim "再见 👋"
    echo ""
    exit 0
}

shortcut_menu() {
    while true; do
        _header "快捷命令 / 卸载"
        local shortcuts shortcut_count
        shortcuts="$(_list_shortcuts)"
        shortcut_count="$(_shortcut_count "$shortcuts")"
        if [[ -n "$shortcuts" ]]; then
            echo -e "  已注册命令: ${G}$(echo "$shortcuts" | tr '\n' ' ')${NC}"
            if [[ "$shortcut_count" -gt 1 ]]; then
                _warn "检测到多个旧快捷命令, 安装新命令后只会保留一个。"
            fi
        else
            echo -e "  已注册命令: ${Y}无${NC}"
        fi
        echo ""
        menu_select "请选择操作" \
            "安装快捷命令 (如 sing)" \
            "完全卸载 (脚本 / 内核 / 配置)" \
            "返回主菜单"
        case "$MENU_CHOICE" in
            1) install_shortcut ;;
            2) uninstall_script ;;
            *) return ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  主菜单
#───────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        _header "${APP_NAME} v${SCRIPT_VERSION}"

        # 概览
        local has_core=0
        if core_installed; then
            has_core=1
            echo -e "  内核: ${G}$(core_version)${NC}"
        else
            echo -e "  内核: ${Y}未安装${NC}"
        fi
        if [[ "$has_core" == "1" ]]; then
            local pc="0"
            [[ -f "$CONFIG_FILE" ]] && pc="$(jq -r '.inbounds|length' "$CONFIG_FILE" 2>/dev/null)"
            echo -e "  协议: ${W}${pc}${NC} 个   系统: ${W}${DISTRO_ID:-linux}${NC} / ${W}${PKG_MGR:-?}${NC}"
        else
            echo -e "  状态: ${Y}请先安装内核${NC}   系统: ${W}${DISTRO_ID:-linux}${NC} / ${W}${PKG_MGR:-?}${NC}"
        fi
        echo ""

        local opts=() actions=()
        opts+=("内核管理")
        actions+=("core")
        if [[ "$has_core" == "1" ]]; then
            opts+=("协议管理")
            actions+=("protocol")
            opts+=("出口 / 规则")
            actions+=("outbound")
            opts+=("服务管理")
            actions+=("service")
        fi
        opts+=("更新脚本")
        actions+=("update")
        opts+=("快捷命令")
        actions+=("shortcut")
        opts+=("退出")
        actions+=("exit")

        menu_select "请选择功能" "${opts[@]}"
        local action=""
        if (( MENU_CHOICE >= 1 && MENU_CHOICE <= ${#actions[@]} )); then
            action="${actions[$((MENU_CHOICE-1))]}"
        fi
        case "$action" in
            core) core_menu ;;
            protocol) protocol_menu ;;
            outbound) outbound_menu ;;
            service) service_menu ;;
            update) update_script ;;
            shortcut) shortcut_menu ;;
            *)
                echo ""
                _dim "再见 👋"
                echo ""
                exit 0
                ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
#  入口
#───────────────────────────────────────────────────────────────────────────────
main() {
    guard_environment
    detect_distro
    ensure_dependencies || {
        _err "基础依赖不满足, 无法继续。"
        exit 1
    }
    main_menu
}

main "$@"
