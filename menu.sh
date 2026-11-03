#!/bin/bash
# ==============================================
# menu.sh - Tunnel Stack Management Menu
# 配套 install-tunnel-stack.sh
# CF WARP + Tailscale + microsocks
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# 检查是否root
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 用户运行菜单！"
    exit 1
fi

SCRIPT_PATH=$(readlink -f "$0")
BASE_DIR=$(dirname "$SCRIPT_PATH")
INSTALL_SCRIPT="${BASE_DIR}/install-tunnel-stack.sh"

show_menu() {
    clear
    cat <<EOF
=============================================
          Tunnel Stack 管理菜单
  CF WARP + Tailscale + microsocks SOCKS5
=============================================
  01 | 一键部署全套隧道（运行安装脚本）
  02 | 切换 CF WARP 隧道 CFON
  03 | 切换 Tailscale 隧道 TSON
  04 | 查看当前隧道状态 STATUS
  05 | 停止全部隧道 STOPALL
  06 | 查看 WARP 保活实时日志
  07 | 查看 Tailscale 保活实时日志
  08 | 卸载全套服务（清空隧道、脚本、定时、microsocks）
  00 | 退出菜单
=============================================
EOF
    read -r -p "请输入选项数字: " opt
    case ${opt} in
        01)
            if [ ! -f "${INSTALL_SCRIPT}" ]; then
                error "找不到安装脚本 install-tunnel-stack.sh，和menu.sh放同一目录！"
            else
                info "开始执行一键部署脚本..."
                chmod +x "${INSTALL_SCRIPT}"
                bash "${INSTALL_SCRIPT}"
            fi
            read -r -p $'\n回车返回菜单...'
            ;;
        02)
            info "执行 CFON，切换到 CF WARP"
            CFON
            read -r -p $'\n回车返回菜单...'
            ;;
        03)
            info "执行 TSON，切换到 Tailscale"
            TSON
            read -r -p $'\n回车返回菜单...'
            ;;
        04)
            info "查询隧道状态"
            STATUS
            read -r -p $'\n回车返回菜单...'
            ;;
        05)
            info "停止全部隧道"
            STOPALL
            read -r -p $'\n回车返回菜单...'
            ;;
        06)
            info "实时查看 warp-watch.log，Ctrl+C 退出日志"
            tail -f /var/log/warp-watch.log
            ;;
        07)
            info "实时查看 ts-watch.log，Ctrl+C 退出日志"
            tail -f /var/log/ts-watch.log
            ;;
        08)
            warn "⚠️  即将卸载全部组件，microsocks、保活脚本、切换脚本、定时任务全部清除！"
            read -r -p "确认卸载？输入 YES 确认: " confirm
            if [ "${confirm}" = "YES" ]; then
                info "停止服务..."
                STOPALL
                systemctl stop microsocks
                systemctl disable microsocks
                rm -f /etc/systemd/system/microsocks.service
                systemctl daemon-reload

                info "删除脚本文件"
                rm -f /usr/local/bin/tun-switch
                rm -f /usr/local/bin/warp-watch.sh
                rm -f /usr/local/bin/ts-watch.sh
                rm -rf /opt/microsocks

                info "清理crontab保活任务"
                crontab -l | grep -vE "warp-watch|ts-watch" | crontab -

                warn "⚠️  WARP、Tailscale 包本身不会自动卸载（如需彻底删包手动执行 apt remove cloudflare-warp tailscale）"
                success "卸载流程完成！"
            else
                info "取消卸载"
            fi
            read -r -p $'\n回车返回菜单...'
            ;;
        00)
            info "退出菜单"
            exit 0
            ;;
        *)
            error "输入无效，请重新选择！"
            sleep 1
            ;;
    esac
}

# 循环菜单
while true; do
    show_menu
done
