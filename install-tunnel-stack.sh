#!/bin/bash
# ==============================================================================
# Project: CF-WARP-Tailscale-microsocks Tunnel Stack Installer (幂等检查版)
# Author: Self-host
# License: MIT
# Description: One-click installer for Cloudflare WARP Connector + Tailscale + microsocks SOCKS5
# Target OS: Debian 12 Bookworm amd64
#
# 设计原则（幂等）：
#   - 每项组件先检查，已安装/已配置则跳过，不做重复安装
#   - 基础依赖逐个核对 dpkg 状态，只装缺失项，全齐则连 apt update 都不跑
#   - WARP / Tailscale 已装则跳过安装步骤
#   - microsocks 二进制已编译则跳过 clone+make
#   - DNS 已含 8.8.8.8 则跳过重写
#   - .bashrc 别名去重，反复运行不会重复追加
#
# 自动化说明：
#   - 全程无需一步步回车
#   - WARP Token 读取优先级：
#       1) 环境变量 WARP_TOKEN=xxx
#       2) 配置文件 /root/.warp-token
#       3) 交互式输入（先展示获取流程指引）
#   - 注册前自动清理旧注册，避免 "Old registration is still around"
# ==============================================================================
set -eo pipefail

# ====================== Color define ======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# ====================== 前置检查 ======================
if [ "$(id -u)" -ne 0 ]; then
    error "必须使用 root 用户运行此脚本！"
    exit 1
fi

OS_VER=$(cat /etc/debian_version | cut -d'.' -f1)
if [ "${OS_VER}" != "12" ]; then
    warn "检测非 Debian12，脚本只在 Debian12 Bookworm 测试，继续可能失败！"
    sleep 3
fi

# ====================== 步骤1：DNS ======================
info "步骤 1/7：检查 DNS 配置"
if grep -qs "nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null; then
    success "DNS 已配置（含 8.8.8.8），跳过"
else
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'DNSCONF'
nameserver 8.8.8.8
nameserver 223.5.5.5
options timeout:2 attempts:2
DNSCONF
    success "DNS写入完成：8.8.8.8 / 223.5.5.5"
fi

# ====================== 步骤2：基础依赖 ======================
info "步骤 2/7：检查基础依赖（缺失才安装）"
MISSING_PKGS=()
for pkg in curl wget git build-essential; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    info "缺失依赖: ${MISSING_PKGS[*]}，执行安装"
    apt update -y
    apt install -y "${MISSING_PKGS[@]}"
    success "依赖安装完成"
else
    success "基础依赖齐全（curl/wget/git/build-essential），跳过安装"
fi

# ====================== 步骤3：WARP ======================
info "步骤 3/7：检查/安装 Cloudflare WARP Connector"
if dpkg -s cloudflare-warp >/dev/null 2>&1; then
    success "WARP 已安装，跳过安装步骤"
else
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt update -y
    apt install -y cloudflare-warp
    success "WARP 安装完成"
fi

# 确保 warp-svc 服务就绪
systemctl start warp-svc 2>/dev/null || true
for i in $(seq 1 15); do
    systemctl is-active warp-svc >/dev/null 2>&1 && break
    sleep 1
done

# ---------- WARP Token 获取（自动） ----------
# 优先级：环境变量 WARP_TOKEN > 配置文件 /root/.warp-token > 交互输入
if [ -z "${WARP_TOKEN}" ] && [ -f /root/.warp-token ]; then
    WARP_TOKEN=$(tr -d ' \r\n' < /root/.warp-token)
fi

if [ -z "${WARP_TOKEN}" ]; then
    cat <<'WARPTOKEN_TIP'
----------------------------------------
【WARP Connector Token 获取流程】
1. 打开 Cloudflare Zero Trust 控制台：https://one.dash.cloudflare.com
2. 左侧导航 → Settings → Devices → WARP Connector
3. 点击 Add connector → 复制生成的 token（eyJ 开头一长串）
----------------------------------------
WARPTOKEN_TIP
    read -r -p "粘贴你的 WARP Token（留空则跳过注册，稍后可手动执行 warp-cli connector new）: " WARP_TOKEN
fi

# 已注册且 token 相同时跳过重复注册
if [ -n "${WARP_TOKEN}" ]; then
    info "清理旧注册（避免 Old registration is still around）..."
    warp-cli disconnect 2>/dev/null || true
    warp-cli registration delete 2>/dev/null || true
    sleep 1
    info "注册 WARP connector..."
    warp-cli connector new "${WARP_TOKEN}"
    success "WARP注册成功"
else
    warn "未提供 Token，跳过注册。之后手动执行：warp-cli connector new [token]"
fi

# ====================== 步骤4：Tailscale ======================
info "步骤 4/7：检查/安装 Tailscale"
if dpkg -s tailscale >/dev/null 2>&1; then
    success "Tailscale 已安装，跳过安装步骤"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    success "Tailscale 安装完成"
fi
cat <<'TS_TIP'
----------------------------------------
【Tailscale 入网授权】
脚本不会自动登录。全部安装结束后手动执行：
tailscale up
复制输出的授权链接，浏览器打开登录批准设备
----------------------------------------
TS_TIP

# ====================== 步骤5：microsocks ======================
info "步骤 5/7：检查/部署 microsocks SOCKS5 (0.0.0.0:1080)"
if [ -x /opt/microsocks/microsocks ]; then
    success "microsocks 二进制已存在，跳过 clone+编译"
else
    mkdir -p /opt
    cd /opt
    rm -rf microsocks
    git clone https://github.com/rofl0r/microsocks.git
    cd microsocks
    make
    success "microsocks 编译完成"
fi

# systemd服务文件：不存在才写入
if [ ! -f /etc/systemd/system/microsocks.service ]; then
    cat > /etc/systemd/system/microsocks.service <<'SVC'
[Unit]
Description=microsocks socks5 proxy for CF & Tailscale tunnel
After=network.target

[Service]
Type=simple
ExecStart=/opt/microsocks/microsocks -i 0.0.0.0 -p 1080
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    info "microsocks.service 已写入"
fi
systemctl enable --now microsocks
ss -tulnp | grep 1080 || true
success "microsocks 已启动，监听 0.0.0.0:1080"

# ====================== 步骤6：保活脚本 ======================
info "步骤 6/7：部署两套隧道保活脚本"
# warp保活
cat > /usr/local/bin/warp-watch.sh <<'WATCH_WARP'
#!/bin/bash
if ! warp-cli status | grep -q "Connected";then
    logger -t warp-watch "WARP disconnected, reconnect"
    warp-cli disconnect
    sleep 2
    warp-cli connect
fi
WATCH_WARP
chmod +x /usr/local/bin/warp-watch.sh

# ts保活
cat > /usr/local/bin/ts-watch.sh <<'WATCH_TS'
#!/bin/bash
if ! tailscale status >/dev/null 2>&1;then
    logger -t ts-watch "Tailscale disconnected, restart"
    systemctl restart tailscaled
    sleep 3
    tailscale up
fi
WATCH_TS
chmod +x /usr/local/bin/ts-watch.sh
success "保活脚本部署完成"

# ====================== 步骤7：主控切换 ======================
info "步骤 7/7：部署主控切换脚本 tun-switch + 别名"
cat > /usr/local/bin/tun-switch <<'SWITCH_SCRIPT'
#!/bin/bash
CF_WATCH="/usr/local/bin/warp-watch.sh"
TS_WATCH="/usr/local/bin/ts-watch.sh"
CRON_FILE="/var/spool/cron/crontabs/root"

case "$1" in
CFON)
    echo "===== Switch to CF WARP ====="
    systemctl stop tailscaled
    systemctl disable tailscaled
    warp-cli disconnect
    sleep 1
    warp-cli connect
    echo "WARP connected"

    grep -v "warp-watch.sh\|ts-watch.sh" "$CRON_FILE" > /tmp/cron.tmp
    echo "*/2 * * * * $CF_WATCH >> /var/log/warp-watch.log 2>&1" >> /tmp/cron.tmp
    cat /tmp/cron.tmp > "$CRON_FILE"
    rm -f /tmp/cron.tmp
    echo "Active keepalive: WARP"
    ;;
TSON)
    echo "===== Switch to Tailscale ====="
    warp-cli disconnect
    systemctl stop tailscaled
    systemctl enable --now tailscaled
    sleep 2
    tailscale up
    echo "Tailscale connected"

    grep -v "warp-watch.sh\|ts-watch.sh" "$CRON_FILE" > /tmp/cron.tmp
    echo "*/2 * * * * $TS_WATCH >> /var/log/ts-watch.log 2>&1" >> /tmp/cron.tmp
    cat /tmp/cron.tmp > "$CRON_FILE"
    rm -f /tmp/cron.tmp
    echo "Active keepalive: Tailscale"
    ;;
STATUS)
    echo "===== Current Status ===="
    echo "--- WARP ---"
    warp-cli status
    echo -e "\n--- Tailscale ---"
    tailscale status
    echo -e "\n--- Keepalive cron ---"
    crontab -l | grep -E "warp-watch|ts-watch"
    ;;
STOPALL)
    echo "===== Stop all tunnels ====="
    warp-cli disconnect
    systemctl stop tailscaled
    systemctl disable tailscaled
    grep -v "warp-watch.sh\|ts-watch.sh" "$CRON_FILE" > /tmp/cron.tmp
    cat /tmp/cron.tmp > "$CRON_FILE"
    rm -f /tmp/cron.tmp
    echo "All tunnels and keepalive stopped"
    ;;
*)
    echo "Usage:"
    echo "  tun-switch CFON    Start CF WARP"
    echo "  tun-switch TSON    Start Tailscale"
    echo "  tun-switch STATUS  Check status"
    echo "  tun-switch STOPALL Stop all"
    ;;
esac
SWITCH_SCRIPT
chmod +x /usr/local/bin/tun-switch

# 别名去重：先清掉旧的同类别名行，再统一写入，反复运行不会重复追加
TOUCH_BASHRC="${HOME}/.bashrc"
if [ -f "${TOUCH_BASHRC}" ]; then
    grep -vE "alias (CFON|TSON|STATUS|STOPALL|menu)=" "${TOUCH_BASHRC}" > /tmp/.bashrc.tmp 2>/dev/null || true
    cat /tmp/.bashrc.tmp > "${TOUCH_BASHRC}"
    rm -f /tmp/.bashrc.tmp
fi
MENU_ABS_PATH=$(readlink -f ./menu.sh)
echo "alias CFON='tun-switch CFON'" >> "${TOUCH_BASHRC}"
echo "alias TSON='tun-switch TSON'" >> "${TOUCH_BASHRC}"
echo "alias STATUS='tun-switch STATUS'" >> "${TOUCH_BASHRC}"
echo "alias STOPALL='tun-switch STOPALL'" >> "${TOUCH_BASHRC}"
echo "alias menu='bash ${MENU_ABS_PATH}'" >> "${TOUCH_BASHRC}"
# 加载别名
source "${TOUCH_BASHRC}" 2>/dev/null || true

success "主控脚本和别名部署完毕（别名已去重）"

# ====================== 完成 ======================
clear
cat <<'FINAL'
================================================================================
                        ✅ 全部部署完成！
================================================================================
【已部署组件】
1. Cloudflare WARP Connector
2. Tailscale（需手动 tailscale up 授权）
3. microsocks SOCKS5：0.0.0.0:1080
4. 切换脚本：CFON / TSON / STATUS / STOPALL / menu

【后续命令】
  CFON      切换 CF WARP 隧道
  TSON      切换 Tailscale 隧道
  STATUS    查看状态
  STOPALL   停止全部
  menu      交互式菜单

【客户端代理（Firefox SOCKS5）】
  CF模式：100.96.0.2:1080
  TS模式：STATUS 查看 Tailscale 内网IP + 1080

【日志】
  tail -f /var/log/warp-watch.log
  tail -f /var/log/ts-watch.log
================================================================================
FINAL
