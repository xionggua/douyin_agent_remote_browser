# douyin_agent_remote_browser

<a href="https://t.me/xuqingci_douyin_agent"><img src="https://raw.githubusercontent.com/xionggua/douyin_agent_remote_browser/main/assets/badge_telegram.svg" alt="Telegram 交流群"></a>
<a href="https://qm.qq.com/q/rQK9dPdVoA"><img src="https://raw.githubusercontent.com/xionggua/douyin_agent_remote_browser/main/assets/badge_qq.svg" alt="QQ 交流群"></a>

[抖音Agent（astrbot_douyin_agent）](https://github.com/xionggua/astrbot_douyin_agent) 的远程浏览器端：**浏览器跑在家用宽带的电脑上，AstrBot 跑在云服务器上**，两者用反向 SSH 隧道连接。家用 IP 出口对抖音风控更友好，云服务器 2 核 2G 即可稳定运行。

```
[远程浏览器端 Linux 机]                                [云服务器]
Xvfb 虚拟屏 :99                                AstrBot + 抖音Agent 插件
  └─ chromium（CDP 127.0.0.1:9222）◄──── 9222 反向隧道 ────┘ worker 遥控浏览器
  └─ x11vnc(5900) ─ noVNC(6080) 观察窗          ssh -p 2222 ──► 远程浏览器端 root
                                                （遥控下载 / FFmpeg 压缩 / 真实点击）
```

## 前置要求

- 远程浏览器端一台常开的 Linux 机器（Debian/Ubuntu 优先，走家用宽带），4 核以上更流畅；
- 一台云服务器（已装 AstrBot 与抖音Agent 插件，Node.js 20+ 与 FFmpeg 已装）；
- 远程浏览器端与云服务器都能以 root 操作。

## 快速开始（三步）

**第 1 步 · 远程浏览器端机器**（root 执行）：

```bash
# 下载发行包并解压（发行包只含部署所需文件；unzip 缺了先装：apt-get install -y unzip 或 dnf install -y unzip）
curl -L -o rb.zip https://github.com/xionggua/douyin_agent_remote_browser/releases/latest/download/douyin_agent_remote_browser.zip
unzip rb.zip && cd douyin_agent_remote_browser
# 直接运行，交互式填写云服务器 IP 和 SSH 端口
bash install.sh
```

执行成功后，结尾会打印形如下面的输出——**记下 VNC 密码**，第 2 步要用的命令也在其中：

```
================ 远程浏览器端安装完成 ================
【下一步】在云服务器上（root）依次执行以下三行：
  curl -L -o rb.tar.gz https://github.com/xionggua/douyin_agent_remote_browser/...
  tar xzf rb.tar.gz && cd douyin_agent_remote_browser*
  bash cloud-setup.sh 'ssh-ed25519 AAAAC3Nza... douyin-home'

扫码登录与日常观察（本机或同局域网浏览器打开）： http://192.168.x.x:6080/vnc.html
VNC 密码： Xxxxx12345 （同时存于 /etc/douyin-remote/vnc-password）
```

**第 2 步 · 云服务器**（root 执行）：**请完整复制第 1 步输出中打印的三行命令，粘贴到云服务器执行**——公钥已包含在命令里，无需手动拼接。

执行成功后，结尾会打印形如下面的输出——第 3 步要执行的命令就在其中：

```
================ 云服务器侧配置完成 ================
下一步：在【远程浏览器端机器】上执行下面这行（执行完隧道即告通）：
  echo 'ssh-ed25519 AAAAC3Nza... douyin-vm-ctrl' >> /root/.ssh/authorized_keys && systemctl restart douyin-tunnel
```

**第 3 步 · 远程浏览器端机器**：**复制第 2 步输出中打印的命令，粘贴到远程浏览器端机器执行**——执行完隧道即告通。

## 验证与登录

云服务器上验证两条隧道：

```bash
curl -s http://127.0.0.1:9222/json/version      # 返回 JSON = 浏览器已连通
ssh -p 2222 -i /root/.ssh/douyin_vm -o StrictHostKeyChecking=accept-new root@127.0.0.1 'echo OK'
```

两条都通过即部署完成——**插件的远程浏览器配置已由第 2 步自动填写并生效**，无需手动修改；如需核对，可在插件配置面板中查看。

**扫码登录抖音**：在同一局域网用浏览器打开 `http://<远程浏览器端IP>:6080/vnc.html`，输入 VNC 密码（安装时打印，存于远程浏览器端 `/etc/douyin-remote/vnc-password`）即可看到虚拟屏里的 chromium，按主插件文档完成登录与绑定。

## 常见问题

- **apt 源 403 / 更新失败**：换可用镜像（如阿里云 `https://mirrors.aliyun.com/ubuntu`）后重跑 `install.sh`；脚本对 update 失败会给出警告并尝试继续。
- **Ubuntu 上装的是 Google Chrome？** Ubuntu 官方源的 chromium 是 snap 壳，沙箱限制导致无法读写 `/opt/douyin-profile`，因此 Ubuntu 系统自动改装 Google Chrome 官方 deb（CDP 行为完全一致）。Debian 系统仍用 chromium。
- **隧道连不上且 cq 侧日志报 `connect to host ... port 22: Connection timed out`**：家庭宽带对 22 端口出网受限（部分路由/旁路由策略）。让隧道走 SOCKS5 代理：重跑 `RB_SSH_PROXY=socks5://<代理地址> bash install.sh <云服务器地址>`。
- **隧道不通**：远程浏览器端 `systemctl status douyin-tunnel` 看重试日志；云端确认 `tunnel` 用户的 `authorized_keys` 与远程浏览器端公钥一致。autossh 带 `ServerAliveInterval=30`，断网恢复后会自动重连。
- **重启自愈**：五个服务全部 `Restart=always` 且已 enable，远程浏览器端或云服务器重启后无需人工干预。
- **noVNC 打不开**：确认远程浏览器端 `ss -tlnp | grep 6080` 在监听；6080/5900 默认监听所有网卡，但**仅限局域网访问**——请勿在路由器上对这些端口做端口映射。
- **点击位置偏移**：属个例，在插件配置的「远程点击纵向偏移」中微调（默认 80）。

## 卸载（远程浏览器端）

```bash
systemctl disable --now xvfb douyin-chrome x11vnc novnc douyin-tunnel
rm -f /etc/systemd/system/{xvfb,douyin-chrome,x11vnc,novnc,douyin-tunnel}.service
systemctl daemon-reload
```

保留 `/opt/douyin-profile`（抖音登录资料）即可在重装后免扫码。

## 许可

AGPL-3.0，见 [LICENSE](LICENSE)。
