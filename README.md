# CF-WARP-Tailscale-microsocks Tunnel Stack
> Debian12 Bookworm amd64 一键部署脚本，CF Mesh / Tailscale 双隧道互斥切换 + SOCKS5代理

## 功能清单
- Cloudflare WARP Connector（Zero Trust Mesh）
- Tailscale P2P内网隧道
- microsocks SOCKS5代理 `0.0.0.0:1080`
- 互斥切换脚本：同一时间只跑一条隧道，避免路由冲突
- 自动保活（每2分钟检测掉线重连）
- 简单别名命令：`CFON / TSON / STATUS / STOPALL`
- 交互式菜单，输入 `menu` 唤起

## 前置准备
1. 全新重装 Debian 12 Bookworm amd64
2. Root 用户
3. 提前获取 Cloudflare WARP Connector Token
   > Zero Trust → Settings → Devices → WARP Connector → Add connector
4. 准备好 Tailscale 账号

## 快速安装
```bash
apt update && apt install git wget curl -y
git clone https://github.com/reckyzhao/tunnel-stack-installer.git
cd tunnel-stack-installer
chmod +x install-tunnel-stack.sh menu.sh
./install-tunnel-stack.sh
```

## 使用命令
```bash
CFON     # 切换 CF WARP 隧道
TSON     # 切换 Tailscale 隧道
STATUS   # 查看隧道状态
STOPALL  # 关闭全部隧道和保活
menu     # 打开交互式管理菜单
```

### 交互式菜单（推荐）
```bash
menu
```
菜单选项：
```
01 | 一键部署全套隧道
02 | 切换 CF WARP (CFON)
03 | 切换 Tailscale (TSON)
04 | 查看状态 (STATUS)
05 | 停止全部隧道 (STOPALL)
06 | 查看 WARP 保活日志
07 | 查看 TS 保活日志
08 | 卸载全套服务
00 | 退出菜单
```

## 客户端代理配置（Firefox SOCKS5）
- CF 隧道：`100.96.0.2:1080`
- TS 隧道：执行 `STATUS` 查看Tailscale分配内网IP + 1080端口

## 日志
```bash
tail -f /var/log/warp-watch.log
tail -f /var/log/ts-watch.log
```

## ⚠️ 注意事项
1. 两套隧道**互斥**，不能同时在线
2. 脚本仅适配 Debian12 amd64
3. Tailscale 需要手动执行 `tailscale up` 浏览器授权
4. WARP 需要手动填入Connector Token注册
5. microsocks 监听 `0.0.0.0:1080`，切换隧道无需修改代理服务
6. 别名需要**新开SSH会话**才会生效

## 彻底卸载软件包（菜单卸载只删配置，不删软件）
```bash
apt remove cloudflare-warp tailscale -y
```

## License
MIT
