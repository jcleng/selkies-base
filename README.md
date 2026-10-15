# Selkies 运行 xeyes (Selkies Base)

一个**最小可用**的 [Selkies](https://github.com/selkies-project/selkies) 使用环境示例，基于 LinuxServer 的 Selkies 基础镜像，
默认启动 `xeyes`，并可通过环境变量切换启动的软件。

- 仅构建 `amd64`（无 `aarch64`）。
- **以真正的 `systemd` 作为 PID 1**（取代底包默认的 s6-overlay）。因此容器内可以
  `systemctl` 管理服务、可运行内层 Docker，并可直接安装宝塔 / 1Panel 等面板。
- 只安装 `x11-apps`（提供 `xeyes`）、`xterm`（用于在会话中排错/恢复），以及
  `systemd`/`systemd-sysv`、`openssh-server`、`docker-compose-plugin` 与若干常用运维工具。
- Dockerfile 结构参考 <https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile>。

> Selkies 的会话、流式服务、nginx、PulseAudio 等仍然复用底包自带的脚本
> （`/etc/s6-overlay/s6-rc.d/*`），只是改由 systemd 单元按依赖顺序拉起，
> 因此网页桌面的功能与底包保持一致。

## 快速开始

```bash
docker build -t selkies-base .

# 注意：systemd 作为 PID 1 需要 --privileged（内层 Docker 也需要它），
# 并建议单独挂载可写的 /run 与 /tmp。
docker run -d \
  --privileged \
  --tmpfs /run \
  --tmpfs /tmp \
  --shm-size=1gb \
  -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=true \
  -v $PWD/config:/config \
  selkies-base
```

然后浏览器打开 <https://localhost:3001>，接受自签名证书即可看到 `xeyes` 在运行。

### 非 `--privileged` 的最小组合

如果不需要容器内 Docker，可以不用 `--privileged`，改用 cgroup 挂载（systemd 需要）：

```bash
docker run -d \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run \
  --tmpfs /tmp \
  --shm-size=1gb \
  -p 3001:3001 \
  -v $PWD/config:/config \
  selkies-base
```

> 该组合下内层 `docker.service` 因缺少 `/dev/cpu_dma_latency` 而不会启动（这是有意设计）。

## 环境变量

### 本项目自定义

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `APP` | `xeyes` | 会话中启动的命令（可带参数），例如 `-e APP=xterm`、`-e APP="xeyes -shape rounded"` |
| `APP_CLI` | 空 | 追加到 `APP` 之后的参数，例如 `-e APP_CLI="-geometry 800x600"` |
| `TITLE` | `xeyes` | 浏览器标签标题（同时用于 PWA manifest 的 `name`/`short_name`） |
| `PIXELFLUX_WAYLAND` | `true` | `true` 使用 labwc/Wayland 会话，`false` 回退 Openbox/X11 会话 |
| `ROOT_PASSWORD` | 空 | 设置后容器内 `root` 的 ssh 登录密码（配合 `openssh-server`，`PermitRootLogin yes`）。不设置则 root 为空密码，建议只用密钥登录 |

### 底包常用变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PUID` | `911` | 运行用户 `abc` 的 UID，映射宿主目录属主时使用 |
| `PGID` | `911` | 运行用户 `abc` 的 GID |
| `TZ` | `Etc/UTC` | 时区。**不处理 `TZ`**：容器内 `/etc/localtime` 仍指向 `Etc/UTC`（已验证），若需真实时区需自行挂载 `/etc/localtime` |
| `LC_ALL` | `en_US.UTF-8` | 区域设置。仅当设置了该变量时，初始化脚本才会同时写入 `LANG`/`LANGUAGE`；镜像内已预生成全部 locale（含 `zh_CN.UTF-8`） |
| `CUSTOM_USER` | `abc` | HTTP 基础认证用户名，仅在同时设置了 `PASSWORD` 时生效 |
| `PASSWORD` | 空 | HTTP 基础认证密码。设置后 nginx 开启基础认证（`/etc/nginx/.htpasswd`），未设置则直接访问 |
| `CUSTOM_PORT` | `3000` | 内部 HTTP 端口 |
| `CUSTOM_HTTPS_PORT` | `3001` | 内部 HTTPS 端口（即映射到宿主机的端口） |
| `CUSTOM_WS_PORT` | `8082` | 内部 WebSocket 端口 |
| `SUBFOLDER` | `/` | 反向代理子路径 |
| `DASHBOARD` | `selkies-dashboard` | 使用的前端 dashboard（另有 `selkies-dashboard-wish`） |

> 注：因为 PID 1 换成了 systemd，底层 s6-overlay 的扩展钩子 **`DOCKER_MODS`、`/custom-services.d`、
> `HARDEN_*`、`UMASK` 等不再生效**。`APP` / `APP_CLI` / `TITLE` / `PIXELFLUX_WAYLAND` 以及上表中
> 的 PUID/PGID、`TZ`、`LC_ALL`、`CUSTOM_USER`/`PASSWORD`、端口等仍照常工作。

其余 `SELKIES_*`（编码器、分辨率、剪贴板、文件传输等）同样可用，
详见 <https://docs.linuxserver.io/selkies/user-guide/configuration/>。

### 容器内安装面板

容器已经是真 systemd，可直接在容器里安装宝塔 / 1Panel 等面板（需以 `--privileged` 运行）：

```bash
docker exec -it selkies-base bash
# 例如宝塔：
# curl -sSO https://download.bt.cn/install/install_panel.sh && bash install_panel.sh
```

底包原有的“禁止服务自启”守卫（`/usr/sbin/policy-rc.d` 与 `dpkg-divert` 的 `/sbin/initctl`
stub）已在构建时移除，面板的安装脚本可以正常 `systemctl enable --now`。

### docker-compose 示例

```yaml
services:
  selkies-base:
    image: registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base
    container_name: selkies-base
    privileged: true
    tmpfs:
      - /run
      - /tmp
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - LC_ALL=zh_CN.UTF-8
      - CUSTOM_USER=USER
      - PASSWORD=PASS
      - ROOT_PASSWORD=ROOTPASS
    ports:
      - "3001:3001"
    shm_size: 1gb
    volumes:
      - ./config:/config
    restart: unless-stopped
```

`PASSWORD` 一旦设置，访问 <https://localhost:3001> 会弹出基础认证框，用户名/密码即
`CUSTOM_USER`/`PASSWORD`；不设置则无需认证直接进入。

### 示例

```bash
# 默认 xeyes（Wayland 会话，需要 --privileged + 可写 /run /tmp）
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 selkies-base

# 换成 xterm
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 -e APP=xterm selkies-base

# xeyes 指定几何尺寸，并使用 X11/Openbox 会话
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=false \
  -e APP=xeyes -e APP_CLI="-geometry 800x600" \
  selkies-base

# 中文环境 + 基础认证 + root ssh 密码
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 \
  -e PUID=1000 -e PGID=1000 -e TZ=Asia/Shanghai -e LC_ALL=zh_CN.UTF-8 \
  -e CUSTOM_USER=USER -e PASSWORD=PASS -e ROOT_PASSWORD=ROOTPASS \
  selkies-base

# 手动进入容器（systemd 作为 PID 1 时用 exec 进入）
docker exec -it <容器名> bash

# 会话内查看服务状态
docker exec -it <容器名> systemctl status selkies-selkies selkies-de
```

## 目录结构

```
.
├── Dockerfile
└── root/
    ├── defaults/
    │   ├── autostart           # X11(Openbox) 会话启动的命令
    │   ├── autostart_wayland   # Wayland(labwc) 会话启动的命令
    │   ├── menu.xml            # X11 右键菜单
    │   └── menu_wayland.xml    # Wayland 右键菜单
    ├── etc/
    │   ├── ssh/sshd_config.d/10-selkies.conf       # PermitRootLogin yes
    │   └── systemd/system/                          # systemd 单元
    │       ├── selkies-container-env.service        # 环境桥接（PID1 → /run/s6/container_environment）
    │       ├── selkies-init-*.service               # 13 个初始化 oneshot（复刻 s6 dependencies.d 顺序）
    │       ├── selkies-*.service                    # 8 个常驻 longrun（xorg/pulseaudio/nginx/dbus/selkies/de/xsettingsd/watchdog）
    │       ├── dbus.service -> /dev/null            # mask 掉 systemd 自带 dbus，避免与 svc-dbus 冲突
    │       ├── docker.service.d/container.conf      # 仅 privileged 时启动内层 docker
    │       └── multi-user.target.wants/             # enable 软链（含 ssh/docker）
    └── usr/local/bin/
        ├── selkies-container-env                    # 把 PID1 环境写入 /run/s6/container_environment
        └── selkies-root-password                    # 按 ROOT_PASSWORD 设置 root 密码
```

`/defaults/autostart*` 与 `/defaults/menu*.xml` 只会在首次运行时复制到 `/config`，
之后用户对 `/config` 中副本的修改会一直生效。改了这些文件后需要清空 `/config` 才能看到新版本。

## 说明

- 仅支持 `amd64`。
- **必须**给足 `--shm-size=1gb`（或更大），否则浏览器/渲染进程可能崩溃。
- **推荐** `--privileged`（systemd 作为 PID 1 需要更完整的权限，且这是容器内 Docker 可用的前提）；
  若不需要内层 Docker，可用 `--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` 代替，
  但建议同时挂载 `--tmpfs /run --tmpfs /tmp`。
- 端口 `3001` 为 HTTPS 自签名证书。
- 停止容器使用 `docker stop` 即可（已设置 `STOPSIGNAL SIGRTMIN+3`，systemd 会优雅退出）。

## 镜像体积说明

本镜像基于 `ghcr.io/linuxserver/baseimage-selkies:debiantrixie`，镜像体积较大是**Selkies 底包本身决定的**，不是 `xeyes` 或本仓库 `Dockerfile` 的问题。

### 实测大小

| 项目 | 值 |
| --- | --- |
| `docker images` 显示（含层压缩） | `~3.95 GB`（`registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`，systemd 化后会略有增加） |
| 解压后实际占用（`du -xsh /`） | `~2.8 GB` |
| 本项目新增内容 | `x11-apps`（`xeyes`）、`xterm`、`systemd`/`systemd-sysv`、`openssh-server`、`docker-compose-plugin` 及少量运维工具，合计约一百多 MB |

### 主要体积来源

| 目录 | 大小 | 原因 |
| --- | --- | --- |
| `/usr/lib/x86_64-linux-gnu` | ~680M | Mesa/LLVM（`libLLVM.so.19.1`、`dri`、`libgallium`、`libz3`、Vulkan 等图形栈） |
| `/usr/lib/locale` | ~411M | `locales-all`（全语言 locale） |
| `/lsiopy` | ~318M | Python venv（`selkies`、`pixelflux`、`pcmflux`、`pelorus`） |
| `/usr/share/fonts` | ~171M | Noto 字体（CJK + Color Emoji） |
| `/usr/share/locale` | ~106M | gettext 翻译文件 |
| `/usr/lib/firmware` | ~104M | 非自由固件包 |
| `/usr/share/icons` | ~49M | 图标主题 |
| `/usr/share/cmake-3.31` | ~21M | 构建工具元数据 |
| `/usr/share/selkies` | ~20M | Selkies Web 前端、interposer 等 |
| `/usr/share/i18n` | ~17M | glibc 区域数据 |

底包包含完整的桌面流式栈（Xvfb/Xwayland、labwc/Openbox、PulseAudio、nginx、s6-overlay 等）以及可选的 DinD 能力，这些是「full featured web native Linux desktop」的设计取向。想大幅减小体积，需要从头重构底包，而不是裁剪这个最小示例。

> 简单结论：**体积主要来自 Selkies 底包，不是本项目的 Dockerfile。**
