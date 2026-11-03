#!/bin/bash
# ==============================================================================
# Project: CF-WARP-Tailscale-microsocks Tunnel Stack Installer
# Author: Self-host
# License: MIT
# Description: One-click installer for Cloudflare WARP Connector + Tailscale + microsocks SOCKS5
# Target OS: Debian 12 Bookworm amd64
# Github Notes:
#   - This script only deploy 3 components: WARP, Tailscale, microsocks
#   - Auto switch script: CFON / TSON / STATUS / STOPALL
#   - microsocks listen 0.0.0.0:1080, compatible both tunnel
# ==============================================================================
set -eo pipefail

# ====================== Color define ======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ====================== Function ======================
info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}
warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
success() {
    echo -e "${GREEN}[OK] $1${NC}"
}
error() {
    echo -e "${RED}[ERROR] $1${NC}"
}
pause() {
    read -r -p $'\n按回车继续，输入 Ctrl+C 退出安装...'
    echo ""
}

# ====================== Pre-check ======================
clear
cat <<'BANNER'
================================================================================
          CF WARP + Tailscale + microsocks 隧道套装一键部署脚本
================================================================================
【组件清单】
✅ Cloudflare WARP Connector (Zero Trust Mesh)
✅ Tailscale P2P Mesh
✅ microsocks SOCKS5 代理 0.0.0.0:1080
✅ 自动切换脚本：CFON / TSON / STATUS / STOPALL
✅ 两套隧道独立保活，互斥运行，不会同时在线冲突

【前置要求，必须全部满足】
1. 全新重装 Debian 12 Bookworm amd64
2. 必须 root 用户执行
3. 你提前准备好 Cloudflare Zero Trust WARP Connector Token
4. 服务器能访问外网（泰国阿里云小鸡已内置DNS适配）
5. 本脚本不会自动获取 CF Token，Token 需要你自己在 CF Zero Trust 后台获取

【重要提醒】
- 两套隧道互斥，同一时间只能启用其中一个
- microsocks 监听 0.0.0.0:1080，切换隧道无需重新改代理
- 安装完成后：
    CFON   = 切换 CF WARP 隧道 + 启用WARP保活
    TSON   = 切换 Tailscale 隧道 + 启用TS保活
    STATUS = 查看隧道状态、保活任务
    STOPALL= 关闭全部隧道，清空定时保活
    menu   = 调出交互式管理菜单
================================================================================
BANNER
pause

# 检查root
if [ "$(id -u)" -ne 0 ]; then
    error "必须使用 root 用户运行此脚本！"
    exit 1
fi

# 检查系统版本
OS_VER=$(cat /etc/debian_version | cut -d'.' -f1)
if [ "${OS_VER}" != "12" ]; then
    warn "检测非 Debian12，脚本只在 Debian12 Bookworm 测试，继续可能失败！"
    pause
fi

info "步骤 1/7：配置DNS（适配泰国阿里云VPS，解决UDP53污染解析失败）"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'DNSCONF'
nameserver 8.8.8.8
nameserver 223.5.5.5
options timeout:2 attempts:2
DNSCONF
success "DNS写入完成：8.8.8.8 / 223.5.5.5"
pause

info "步骤 2/7：更新源 & 安装基础依赖包"
apt update -y
apt install -y curl wget git build-essential
success "基础依赖安装完成"
pause

info "步骤 3/7：安装 Cloudflare WARP Connector"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update -y
apt install -y cloudflare-warp
success "WARP客户端安装完成"

cat <<'WARPTOKEN_TIP'
----------------------------------------
【重要：WARP 注册环节】
你需要从 Cloudflare Zero Trust 后台获取 WARP Connector Token
路径：Zero Trust → Settings → Devices → WARP Connector → Add connector
复制生成的一长串 token，稍后粘贴进去
如果暂时没有token，可以先跳过，后续手动执行命令注册：
warp-cli connector new 你的token
----------------------------------------
WARPTOKEN_TIP
read -r -p "是否现在输入 WARP Connector Token？(y=输入，n=跳过，后续手动注册) " warp_choose
if [[ "${warp_choose,,}" == "y" ]]; then
    read -r -p "粘贴你的 WARP Token：" WARP_TOKEN
    if [ -n "${WARP_TOKEN}" ]; then
        info "正在注册WARP connector..."
        warp-cli connector new "${WARP_TOKEN}"
        success "WARP注册成功"
    else
        warn "输入为空，跳过注册，请之后手动执行 warp-cli connector new [token]"
    fi
else
    warn "跳过WARP注册，请拿到token后手动注册"
fi
pause

info "步骤 4/7：安装 Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
success "Tailscale 安装完成"
cat <<'TS_TIP'
----------------------------------------
【重要：Tailscale入网授权】
脚本不会自动帮你登录！
等全部安装结束后，你手动执行：
tailscale up
执行后会输出一条授权链接，复制链接浏览器打开，登录你的Tailscale账号批准设备
----------------------------------------
TS_TIP
pause

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
pause

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
pause

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
    echo "===== Current Status ====="
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
pause

# ====================== Final summary ======================
clear
cat <<'FINAL'
================================================================================
                        ✅ 全部部署完成！
================================================================================
【已部署组件】
1. Cloudflare WARP Connector
   命令注册： warp-cli connector new 【你的token】
2. Tailscale
   入网授权： tailscale up
3. microsocks SOCKS5
   监听： 0.0.0.0:1080  systemd自启
4. 切换脚本别名（新开ssh窗口别名才会完全生效）
   CFON     切换 CF WARP 隧道，自动关闭TS，加载WARP保活
   TSON     切换 Tailscale 隧道，自动关闭CF，加载TS保活
   STATUS   查看当前隧道状态、定时保活任务
   STOPALL  关闭全部隧道，清空定时保活
   menu     调出交互式管理菜单

👉 交互式管理菜单（推荐使用）：
    menu

【客户端代理设置（火狐SOCKS5）】
👉 CF模式：代理IP 100.96.0.2 端口 1080
👉 TS模式：执行 STATUS 查看 Tailscale 分配的内网IP，端口1080

【日志查看命令】
tail -f /var/log/warp-watch.log
tail -f /var/log/ts-watch.log

【故障排查】
1. STATUS 查看隧道是否Connected
2. microsocks异常： systemctl restart microsocks
3. 别名不生效：新开一个SSH会话
4. WARP注册失败：检查token是否复制完整，不要带空格换行
================================================================================
FINAL
