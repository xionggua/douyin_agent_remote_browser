#!/usr/bin/env bash
# douyin_agent_remote_browser 远程浏览器端（浏览器宿主机）一键安装
# 在跑浏览器的 Linux 机器上以 root 执行。
# 用法： bash install.sh <云服务器IP> [SSH端口]   端口缺省 22；不带参数则交互式填写。
# 可选： 出网慢时挂代理  RB_PROXY=socks5h://127.0.0.1:1080 bash install.sh 1.2.3.4
# 可选： 22 端口出网被拦时让隧道本身走代理  RB_SSH_PROXY=socks5://127.0.0.1:1080 bash install.sh 1.2.3.4
set -euo pipefail

CLOUD_HOST="${1:-}"
SSH_PORT="${2:-22}"
if [ -z "$CLOUD_HOST" ]; then
  read -r -p "云服务器 IP：" CLOUD_HOST
  read -r -p "云服务器 SSH 端口 [22]：" SSH_PORT_INPUT
  [ -n "$SSH_PORT_INPUT" ] && SSH_PORT="$SSH_PORT_INPUT"
fi
[ "$(id -u)" = 0 ] || { echo "请用 root 执行：sudo bash install.sh <云服务器IP> [SSH端口]"; exit 1; }
[ -n "$CLOUD_HOST" ] || { echo "!! 云服务器 IP 不能为空"; exit 1; }

PROXY="${RB_PROXY:-}"
CURL_ARGS=()
[ -n "$PROXY" ] && CURL_ARGS=(--proxy "$PROXY")
[ -n "$PROXY" ] && echo "==> 使用出网代理： $PROXY"
# 云服务器侧获取本仓库的地址（默认 GitHub 公开仓库；内测等场景可用 RB_ARCHIVE 覆盖）
ARCHIVE_URL="${RB_ARCHIVE:-https://github.com/xionggua/douyin_agent_remote_browser/archive/refs/heads/main.tar.gz}"

echo "==> 目标云服务器： tunnel@${CLOUD_HOST}（SSH 端口 ${SSH_PORT}，反向隧道将挂到它本地）"

PKG=""
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  echo "!! 仅支持 Debian/Ubuntu（apt）与 RHEL 系（dnf，依赖可能需手动补齐）。未找到包管理器，中止。"
  exit 1
fi
[ "$PKG" = dnf ] && echo "!! dnf 系的 chromium/novnc 包不全，安装后请按 README 手动核对缺项。"

echo "==> 1/6 安装系统依赖（xvfb x11vnc novnc websockify autossh 中文字体）"
if [ "$PKG" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || echo "!! apt update 失败：软件源有问题（换可用镜像后重跑本脚本），先尝试继续……"
  apt-get install -y xdotool xvfb x11vnc novnc websockify autossh openssh-client curl ca-certificates
  # 抖音页面全是中文+emoji，无 CJK 字体会满屏豆腐块
  apt-get install -y fonts-noto-cjk fonts-noto-color-emoji || echo "!! 中文字体安装失败：页面文字将显示为方框，请手动安装 fonts-noto-cjk"
  fc-cache -f >/dev/null 2>&1 || true
  . /etc/os-release 2>/dev/null || true
  if [ "${ID:-}" = ubuntu ]; then
    # Ubuntu 的 chromium/chromium-browser 是 snap 壳，沙箱无法写 /opt/douyin-profile；
    # 优先复用已存在的真二进制，否则安装 Google Chrome 官方 deb（CDP 行为一致）。
    EXISTING="$(command -v chromium || command -v chromium-browser || true)"
    if [ -n "$EXISTING" ] && [ "${EXISTING#/snap}" = "$EXISTING" ]; then
      CHROME_BIN="$EXISTING"
    else
      if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
        if [ -n "$PROXY" ]; then
          # 代理模式：直下 deb 走代理，依赖从国内镜像解析
          cd /tmp
          curl "${CURL_ARGS[@]}" -fsSL --retry 3 -o google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
          apt-get install -y ./google-chrome.deb
          cd /
        else
          install -d -m 0755 /etc/apt/keyrings
          curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /etc/apt/keyrings/google.asc
          echo "deb [signed-by=/etc/apt/keyrings/google.asc] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
          apt-get update -y || true
          apt-get install -y google-chrome-stable
        fi
      fi
      CHROME_BIN="$(command -v google-chrome-stable || command -v google-chrome || true)"
    fi
  else
    apt-get install -y chromium || apt-get install -y chromium-browser || true
    CHROME_BIN="$(command -v chromium || command -v chromium-browser || true)"
  fi
else
  dnf install -y xdotool xorg-x11-server-Xvfb x11vnc autossh openssh-clients curl || true
  dnf install -y chromium novnc websockify || echo "!! dnf 缺包，请手动安装后重跑本脚本"
  # 抖音页面全是中文+emoji，无 CJK 字体会满屏豆腐块（包名因发行版而异，失败不阻断）
  dnf install -y google-noto-sans-cjk-ttc-fonts google-noto-emoji-color-fonts 2>/dev/null \
    || dnf install -y google-noto-cjk-fonts 2>/dev/null \
    || echo "!! 中文字体安装失败：页面文字将显示为方框，请手动安装 Noto CJK 字体"
  fc-cache -f >/dev/null 2>&1 || true
  CHROME_BIN="$(command -v chromium || command -v chromium-browser || true)"
fi
[ -n "$CHROME_BIN" ] || { echo "!! 未找到 chromium，请手动安装后重跑。"; exit 1; }
echo "    chromium 路径： $CHROME_BIN"

echo "==> 2/6 安装 FFmpeg 静态版（视频压缩用，与主插件同方案）"
if ! command -v ffmpeg >/dev/null 2>&1; then
  cd /tmp
  curl "${CURL_ARGS[@]}" -L --retry 3 -o ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
  tar -xf ffmpeg.tar.xz
  install -m755 ffmpeg-*-static/ffmpeg ffmpeg-*-static/ffprobe /usr/local/bin/
  cd /
fi
ffmpeg -version | head -1

echo "==> 3/6 准备目录与 VNC 密码"
install -d -m 755 /opt/douyin-profile
install -d -m 700 /etc/douyin-remote
if [ ! -f /etc/x11vnc.passwd ]; then
  VNC_PASS="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9')"
  VNC_PASS="${VNC_PASS:0:10}"
  x11vnc -storepasswd "$VNC_PASS" /etc/x11vnc.passwd
  printf '%s\n' "$VNC_PASS" > /etc/douyin-remote/vnc-password
  chmod 600 /etc/douyin-remote/vnc-password
  echo "    VNC 密码（已存 /etc/douyin-remote/vnc-password）： $VNC_PASS"
else
  echo "    沿用已有 /etc/x11vnc.passwd"
fi

echo "==> 4/6 生成远程浏览器端隧道密钥 /root/.ssh/douyin_home"
install -d -m 700 /root/.ssh
[ -f /root/.ssh/douyin_home ] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/douyin_home -C douyin-home
HOME_PUB="$(cat /root/.ssh/douyin_home.pub)"

echo "==> 5/6 安装 systemd 五件套"
SRC="$(cd "$(dirname "$0")" && pwd)/units"
sed -e "s|__CLOUD_HOST__|${CLOUD_HOST}|g" -e "s|__SSH_PORT__|${SSH_PORT}|g" "$SRC/douyin-tunnel.service" > /etc/systemd/system/douyin-tunnel.service
if [ -n "${RB_SSH_PROXY:-}" ]; then
  PX="${RB_SSH_PROXY#*://}"
  sed -i "s|/usr/bin/autossh -M 0 -N|/usr/bin/autossh -M 0 -N \"-oProxyCommand=nc -X 5 -x ${PX} %%h %%p\"|" /etc/systemd/system/douyin-tunnel.service
  [ "$PKG" = apt ] && apt-get install -y netcat-openbsd >/dev/null 2>&1 || true
  echo "    隧道 SSH 连接已配置走代理 ${PX}"
fi
for u in xvfb douyin-chrome x11vnc novnc; do
  cp "$SRC/$u.service" /etc/systemd/system/
done
[ "$CHROME_BIN" = /usr/bin/chromium ] || sed -i "s|/usr/bin/chromium|${CHROME_BIN}|g" /etc/systemd/system/douyin-chrome.service
systemctl daemon-reload

echo "==> 6/6 启动服务（重复执行时重启以套用新的单元定义）"
systemctl enable xvfb.service x11vnc.service novnc.service douyin-chrome.service douyin-tunnel.service >/dev/null 2>&1 || true
systemctl restart xvfb.service x11vnc.service novnc.service douyin-chrome.service douyin-tunnel.service

sleep 3
systemctl is-active xvfb douyin-chrome x11vnc novnc douyin-tunnel 2>&1 | paste -sd' ' || true

LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
VNC_SHOW="$(cat /etc/douyin-remote/vnc-password 2>/dev/null || true)"

echo
echo "================ 远程浏览器端安装完成 ================"
echo "【下一步】在云服务器上（root）依次执行以下三行："
echo "  curl -L -o rb.tar.gz ${ARCHIVE_URL}"
echo "  tar xzf rb.tar.gz && cd douyin_agent_remote_browser*"
echo "  bash cloud-setup.sh '$HOME_PUB'"
echo
echo "cloud-setup.sh 结尾会给出回到本机执行的命令，以及插件配置要填的值。"
echo
echo "扫码登录与日常观察（本机或同局域网浏览器打开）： http://${LOCAL_IP:-<本机IP>}:6080/vnc.html"
[ -n "$VNC_SHOW" ] && echo "VNC 密码： $VNC_SHOW （同时存于 /etc/douyin-remote/vnc-password）"
