#!/usr/bin/env bash
# douyin_agent_remote_browser 云服务器侧配置
# 在跑 AstrBot 的云服务器上以 root 执行。
# 用法： bash cloud-setup.sh <远程浏览器端公钥文件或公钥字符串>
set -euo pipefail

INPUT="${1:-}"
[ "$(id -u)" = 0 ] || { echo "请用 root 执行"; exit 1; }
[ -n "$INPUT" ] || { echo "用法： bash cloud-setup.sh <远程浏览器端公钥文件或公钥字符串>"; exit 1; }

if [ -f "$INPUT" ]; then
  HOME_PUB="$(cat "$INPUT")"
else
  HOME_PUB="$INPUT"
fi
echo "$HOME_PUB" | grep -qE '^ssh-(ed25519|rsa) ' || { echo "!! 传入的不是合法的 ssh 公钥"; exit 1; }

echo "==> 1/4 创建受限隧道用户 tunnel（仅允许反向端口转发，不能登录 shell）"
id tunnel >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin tunnel
install -d -m 700 -o tunnel -g tunnel /home/tunnel/.ssh

echo "==> 2/4 写入受限 authorized_keys（只允许监听 127.0.0.1:9222 与 127.0.0.1:2222）"
printf 'restrict,port-forwarding,permitlisten="127.0.0.1:9222",permitlisten="127.0.0.1:2222" %s\n' "$HOME_PUB" > /home/tunnel/.ssh/authorized_keys
chown tunnel:tunnel /home/tunnel/.ssh/authorized_keys
chmod 600 /home/tunnel/.ssh/authorized_keys

echo "==> 3/4 生成云服务器遥控远程浏览器端的密钥 /root/.ssh/douyin_vm"
install -d -m 700 /root/.ssh
[ -f /root/.ssh/douyin_vm ] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/douyin_vm -C douyin-vm-ctrl
CLOUD_PUB="$(cat /root/.ssh/douyin_vm.pub)"

echo "==> 4/4 自动填写插件的远程浏览器配置"
WD="$(systemctl cat astrbot 2>/dev/null | awk '/^WorkingDirectory=/{sub(/^WorkingDirectory=/,"");print}' | head -1)"
CFGDIR="${WD:-/data/astrbot}/data/config"
CFG="$CFGDIR/astrbot_douyin_agent_config.json"
if [ ! -f "$CFG" ]; then
  CFG="$(ls "$CFGDIR" 2>/dev/null | grep -i '^astrbot_douyin_agent.*\.json$' | head -1 | sed "s|^|$CFGDIR/|" || true)"
fi
if [ -n "${CFG:-}" ] && [ -f "$CFG" ]; then
  python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8-sig'))
d['browser_remote_cdp'] = 'http://127.0.0.1:9222'
d['vm_ssh_host'] = '127.0.0.1'
d['vm_ssh_port'] = 2222
d['vm_ssh_user'] = 'root'
d['vm_ssh_key'] = '/root/.ssh/douyin_vm'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('    已写入 browser_remote_cdp 与 vm_ssh_* 五项')
PYEOF
  systemctl restart astrbot && echo "    astrbot 已重启，配置生效"
else
  echo "    !! 未找到插件配置文件（$CFGDIR 下无 astrbot_douyin_agent*.json）——确认插件已加载后重跑本脚本"
fi

echo
echo "================ 云服务器侧配置完成 ================"
echo "下一步：在【远程浏览器端机器】上执行下面这行（执行完隧道即告通）："
echo "  echo '$CLOUD_PUB' >> /root/.ssh/authorized_keys && systemctl restart douyin-tunnel"
echo
echo "验证隧道（在本云服务器上执行）："
echo "  curl -s http://127.0.0.1:9222/json/version   # 返回 JSON 即浏览器已连通"
echo "  ssh -p 2222 -i /root/.ssh/douyin_vm -o StrictHostKeyChecking=accept-new root@127.0.0.1 'echo OK'"
echo
echo "验证通过后即可使用。AstrBot 插件配置已自动填写（可在插件配置面板核对）："
echo "  远程浏览器地址    http://127.0.0.1:9222"
echo "  远程主机 SSH 地址 127.0.0.1"
echo "  远程主机 SSH 端口 2222"
echo "  远程主机 SSH 用户 root"
echo "  远程主机 SSH 私钥路径 /root/.ssh/douyin_vm"
