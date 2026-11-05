#!/bin/bash
# ==============================================================================
# Project: CF-WARP-Tailscale-microsocks Tunnel Stack Installer (自动化版)
# Author: Self-host
# License: MIT
# Description: One-click installer for Cloudflare WARP Connector + Tailscale + microsocks SOCKS5
# Target OS: Debian 12 Bookworm amd64
#
# 自动化说明：
#   - 全程无需一步步回车，自动执行到结束
#   - WARP Token 读取优先级：
#       1) 环境变量 WARP_TOKEN=xxx
#       2) 配置文件 /root/.warp-token（文件内只写 token 一行）
#       3) 交互式输入（脚本会先展示获取流程指引）
#   - 注册前自动清理旧注册（warp-cli registration delete），
#     避免报错 "Old registration is still around"
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
info "步骤 1/7：配置DNS（适配泰国阿里云VPS，解决UDP53污染解析失败）"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'DNSCONF'
nameserver 8.8.8.8
nameserver 223.5.5.5
options timeout:2 attempts:2
DNSCONF
success "DNS写入完成：8.8.8.8 / 223.5.5.5"

# ====================== 步骤2：基础依赖 ======================
info "步骤 2/7：更新源 & 安装基础依赖包"
apt update -y
apt install -y curl wget git build-essential
success "基础依赖安装完成"

# ====================== 步骤3：WARP ======================
info "步骤 3/7：安装 Cloudflare WARP Connector"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update -y
apt install -y cloudflare-warp

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
info "步骤 4/7：安装 Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
success "Tailscale 安装完成"
cat <<'TS_TIP'
----------------------------------------
【Tailscale 入网授权】
脚本不会自动登录。全部安装结束后手动执行：
tailscale up
复制输出的授权链接，浏览器打开登录批准设备
----------------------------------------
TS_TIP

# ====================== 步骤5：microsocks ======================
info "步骤 5/7：编译部署 microsocks SOCKS5 (0.0.0.0:1080)"
mkdir -p /opt
cd /opt
rm -rf microsocks
git clone https://github.com/rofl0r/microsocks.git
cd microsocks
make

# 写入systemd服务
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
systemctl enable --now microsocks
ss -tulnp | grep 1080
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

# 获取menu绝对路径，设置 menu 别名
MENU_ABS_PATH=$(readlink -f ./menu.sh)
# 写入别名到bashrc
echo "alias CFON='tun-switch CFON'" >> ~/.bashrc
echo "alias TSON='tun-switch TSON'" >> ~/.bashrc
echo "alias STATUS='tun-switch STATUS'" >> ~/.bashrc
echo "alias STOPALL='tun-switch STOPALL'" >> ~/.bashrc
echo "alias menu='bash ${MENU_ABS_PATH}'" >> ~/.bashrc
# 加载别名
source ~/.bashrc

success "主控脚本和别名部署完毕"

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
