# AGENTS.md

本文件汇总 `selkies-base` 项目（Selkies 运行 xeyes）的结构、约定、构建与发布流程，供人和 AI Agent 使用。

## 1. 项目概述

| 项 | 值 |
| --- | --- |
| 项目名称 | Selkies 运行 xeyes |
| 仓库 | https://github.com/jcleng/selkies-base （public） |
| 默认分支 | `main` |
| 定位 | **最小可用**的 Selkies 使用环境示例 |
| 基础镜像 | `ghcr.io/linuxserver/baseimage-selkies:debiantrixie` |
| 架构 | **仅 amd64**（明确不提供 aarch64 / `Dockerfile.aarch64`） |
| PID 1 | **`systemd`**（`/sbin/init`，取代底包默认的 s6-overlay；s6 仅作为二进制库复用其脚本/helper） |
| 运行参数 | 推荐 `--privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb` |
| 默认启动 | `xeyes`（可用环境变量切换为任意软件） |
| 访问端口 | `3001`（HTTPS，自签名证书） |
| 持久化卷 | `/config` |
| Dockerfile 参考 | https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile |

目标：给出一个能跑起来、结构最小、可作为其它 Selkies 应用镜像起点的样板；不追求功能完整，
不引入 Selkies Desktop / Pelorus / 浏览器等额外组件。

> 例外：本项目**有意**把 PID 1 换成 systemd，并在镜像中加入 `systemd`、`openssh-server`、
> `docker-compose-plugin` 及少量运维工具，以便容器内可 `systemctl`、可运行内层 Docker、可安装
> 宝塔 / 1Panel 等面板。除此之外不引入其它组件。

## 2. 目录结构

```
.
├── AGENTS.md                       # 本文件
├── Dockerfile                      # 镜像定义（仅 amd64）
├── README.md                       # 面向用户的使用说明
├── .dockerignore                   # 排除 .git / config / *.log
├── docs/superpowers/               # 设计文档与实现计划
└── root/                           # 构建上下文根，整体 COPY 到镜像 /
    ├── defaults/
    │   ├── autostart               # X11(Openbox) 会话启动命令
    │   ├── autostart_wayland       # Wayland(labwc) 会话启动命令
    │   ├── menu.xml                # X11 右键菜单
    │   └── menu_wayland.xml        # Wayland 右键菜单
    ├── etc/
    │   ├── ssh/sshd_config.d/10-selkies.conf    # PermitRootLogin yes
    │   └── systemd/system/                      # systemd 单元（见 §3.1）
    └── usr/local/bin/
        ├── selkies-container-env                # PID1 环境 → /run/s6/container_environment
        └── selkies-root-password                # 按 ROOT_PASSWORD 设置 root 密码
```

`root/` 下的路径与镜像内路径一一对应（`COPY /root /`）。基础镜像在首次运行时把
`/defaults/autostart*`、`/defaults/menu*.xml` 复制到 `/config/.config/{labwc,openbox}/`，
之后以用户副本为准。

**注意**：`root/etc/systemd/system/multi-user.target.wants/` 下的软链是本仓库自带的
「enable」产物（构建期不运行 `systemctl enable`，因为构建时 systemd 未运行）。
其中 `dbus.service` / `dbus.socket` / `dbus-broker.service` 是指向 `/dev/null` 的 **mask** 软链，
用于屏蔽 systemd 自带的 dbus，避免与底包的 `svc-dbus` 抢占 system bus。

## 3. Dockerfile 说明

- 首行 `# syntax=docker/dockerfile:1`。
- `FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie`：amd64 基础镜像（x86_64 only）。
- `ARG BUILD_DATE` / `ARG VERSION` 仅用于 `LABEL build_version`，由 CI 注入或留空。
- 安装包：`x11-apps`（提供 `xeyes`）、`xterm`（会话内排错/恢复用）、`systemd` + `systemd-sysv`、
  `openssh-server`、`docker-compose-plugin`，以及 `ca-certificates`/`curl`/`wget`/`unzip`/`zstd`/`tar`。
  使用 `--no-install-recommends`，结尾 `apt-get autoclean` 并清理 `/var/lib/apt/lists/*`、`/tmp/*` 等。
- 图标：下载 `linuxserver/docker-templates` 的 `selkies-logo.png` 覆盖
  `/usr/share/selkies/www/icon.png`（失败不阻断构建，回退为 `:`）。
- **移除反-systemd 守卫**（关键）：
  - `dpkg-divert --local --rename --remove /sbin/initctl` 撤销底包对 `initctl` 的重命名占用；
  - `rm -f /usr/sbin/policy-rc.d /sbin/initctl` 删除返回 101 的 `policy-rc.d` 与 `initctl` stub。
  - 否则容器内的面板/软件安装脚本无法 `systemctl enable --now` 服务。
- 清理可能造成端口冲突的 socket 激活软链：
  `rm -f /etc/systemd/system/sockets.target.wants/{ssh.socket,docker.socket}`。
- 末尾 `COPY /root /`、`chmod +x` 两个 helper 脚本、`EXPOSE 3001`、`VOLUME /config`、
  `STOPSIGNAL SIGRTMIN+3`、`ENTRYPOINT ["/sbin/init"]`、`CMD ["--system","--unit=multi-user.target"]`。
- 环境变量 `container=docker` 用于提示 systemd 处于容器中。
- **不要**添加 `Dockerfile.aarch64`，本项目有意只支持 amd64。

### 3.1 systemd 服务与 s6 复用机制

PID 1 是 systemd，但**业务逻辑全部复用底包 `/etc/s6-overlay/s6-rc.d/*` 里的脚本**，没有重写。
桥接机制：

1. `selkies-container-env.service`（oneshot）运行 `/usr/local/bin/selkies-container-env`，
   把 `/proc/1/environ` 逐条写入 `/run/s6/container_environment/<NAME>`（**无结尾换行**），
   复刻 s6 的 envdir 布局。
2. 底包脚本自带的 shebang `#!/usr/bin/with-contenv bash` 会读取该 envdir 注入环境，因此
   `PATH`（含 `/lsiopy/bin`）、`HOME=/config`、locale、`PUID/PGID` 等照常可见；
   `s6-setuidgid abc`（`/usr/bin/` 下）也能继续把服务降权到 `abc`。
3. **初始化链**（13 个 oneshot，严格复刻 `dependencies.d` 顺序）：
   `container-env → adduser → {envfile, device-perms} → os-end → selkies → nginx →
   selkies-config → video → selkies-end → config → config-end → custom-files → services`。
   其中 `os-end`/`selkies`/`selkies-end`/`config`/`config-end`/`services` 是排序用的标记单元
   （`ExecStart=/bin/true`），其余执行对应的 `init-*/run` 脚本。
4. **常驻服务**（8 个 `Type=simple`）：`selkies-xorg`、`selkies-pulseaudio`、`selkies-nginx`、
   `selkies-dbus`、`selkies-selkies`、`selkies-de`、`selkies-xsettingsd`、`selkies-watchdog`，
   分别运行 `svc-*/run`；`selkies-de` 额外用 `ExecStopPost` 调用 `svc-de/finish` 清理会话。
   所有常驻服务 `After=Requires=selkies-init-services.service`（按各自依赖再叠加）。
5. `Umask`：统一 `UMask=0022`（放弃底包 `with-contenv` 的 umask 语义）。

**已知坑**：`init-video/run`、`init-selkies-config/run` 会**反向写** `/run/s6/container_environment/*`
（如 `AUTO_GPU`、`LIBVA_DRIVER_NAME`、`XDG_RUNTIME_DIR`、`LANGUAGE`），因此桥接目录必须存在且机制一致。

### 3.2 systemd 化实测坑（首轮运行修正）

首轮 CI 镜像实测发现以下问题，均已修正（详见 `root/` 内对应文件与 Dockerfile）：

1. **必须调 `run`，不能调 `up`**。底包里 `init-*/up` 是 **644 不可执行**的间接指向文件，内容只有一行
   “`/etc/s6-overlay/s6-rc.d/init-<x>/run`”；真正可执行的脚本是 `init-*/run`（755）。
   早先 `selkies-init-nginx/-selkies-config/-video` 三个单元误用 `up`，导致 `status=203/EXEC`。
2. **禁用底包 enable 的 Debian `nginx.service`**。底包在 `/etc/systemd/system/multi-user.target.wants/`
   里 enable 了 Debian 自带 nginx（监听 80），它会与我们的 `selkies-nginx.service`（svc-nginx，监听
   3000/3001）争用同一份 `/etc/nginx/nginx.conf`。Dockerfile 构建期 `rm -f …/multi-user.target.wants/nginx.service`。
3. **禁用 `exim4.service`**。本镜像不需要 MTA，且其因 `/var/log/exim4/mainlog` 权限问题启动失败。
   同样在构建期 `rm -f …/multi-user.target.wants/exim4.service`。
4. **`systemd-logind` 需排在 `selkies-dbus` 之后**。logind 启动时连 system bus；而我们 mask 了 systemd
   自带的 `dbus.service`，system bus 由 `selkies-dbus.service`（`svc-dbus`）提供。Debian 自带的
   `systemd-logind.service.d/dbus.conf` 只判断 dbus **二进制是否存在**，在这里起不到保护作用，logind
   会在 bus 就绪前重试 5 次并永久失败（`Failed to connect to system bus: No such file or directory`）。
   修正：
   - `root/etc/systemd/system/systemd-logind.service.d/selkies.conf`：`After=`/`Wants=selkies-dbus.service`；
   - `root/usr/local/bin/selkies-wait-dbus` + `selkies-dbus.service` 的 `ExecStartPost=`：等
     `/run/dbus/system_bus_socket` 真正出现后 start job 才算完成，避免竞态。
   修正后 `systemctl is-system-running` 返回 `running`，无 failed 单元。
5. **禁用 `getty@tty1.service`**。底包 enable 了 tty1 上的 agetty；本镜像是无头 web 桌面（外壳走
   `docker exec` / ssh），`--privileged` 下 `/dev/tty1` 还可能是宿主控制台。agetty 会反复被 SIGHUP
   秒退并触发 start-limit，把 systemd 拖成 `degraded`。故构建期
   `rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service`（仍可手动 `systemctl start`）。

> 上述修正后的运行验证（`--privileged`，全新 `/config` + 全新容器）：`systemctl is-system-running`
> 返回 `running`，failed 单元为空；8 个常驻服务全部 active；nginx 监听 3000/3001，selkies 监听 8082，
> sshd 监听 22；`curl -k https://localhost:3001/` 返回 200；内层 `docker info` 可用（overlayfs）。

### 环境变量

本项目自定义：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `APP` | `xeyes` | 会话中启动的命令（可含参数），这是「用环境变量控制默认启动软件」的开关 |
| `APP_CLI` | 空 | 追加到 `APP` 之后的参数 |
| `TITLE` | `xeyes` | 浏览器标签标题（兼 PWA manifest 名称） |
| `PIXELFLUX_WAYLAND` | `true` | `true`=labwc/Wayland 会话；`false`=Openbox/X11 会话 |
| `ROOT_PASSWORD` | 空 | 设置容器内 `root` 的 ssh 登录密码（`selkies-root-password.service` 用 `chpasswd` 写入） |

底包常用变量（完整列表见
<https://docs.linuxserver.io/selkies/user-guide/configuration/>）：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `PUID` / `PGID` | `911` | 运行用户 `abc` 的 UID/GID（`init-adduser` 用 `usermod`/`groupmod` 改写） |
| `TZ` | `Etc/UTC` | 时区。**底包不处理 `TZ`**（已实测 `/etc/localtime` 仍为 `Etc/UTC`），需要真时区就挂载 `/etc/localtime` |
| `LC_ALL` | `en_US.UTF-8` | 区域设置，设置后 `init-selkies-config` 同时写入 `LANG`/`LANGUAGE`；镜像已预生成全部 locale |
| `CUSTOM_USER` | `abc` | HTTP 基础认证用户名 |
| `PASSWORD` | 空 | 设置后 `init-nginx` 写 `/etc/nginx/.htpasswd` 并开启基础认证 |
| `CUSTOM_PORT` / `CUSTOM_HTTPS_PORT` / `CUSTOM_WS_PORT` | `3000` / `3001` / `8082` | 内部端口，nginx 配置会按此替换 |
| `SUBFOLDER` | `/` | 反向代理子路径 |
| `DASHBOARD` | `selkies-dashboard` | 前端 dashboard 选择 |

> **systemd 化后不再生效**：底包 s6-overlay 的扩展钩子 `DOCKER_MODS`、`/custom-services.d`、
> `HARDEN_*`、`RESTART_APP`、`UMASK` 等不再被处理（本项目不再有 s6 stage1/2）。
> 上表中的 PUID/PGID、`TZ`、`LC_ALL`、`CUSTOM_USER`/`PASSWORD`、端口、`SELKIES_*`、分辨率等仍照常工作。

`APP` / `APP_CLI` 在 `root/defaults/autostart` 与 `root/defaults/autostart_wayland` 中展开：

```bash
if [ -z "${APP}" ]; then APP="xeyes"; fi
exec ${APP} ${APP_CLI}
```

基础镜像自带的 `SELKIES_*`、分辨率等变量同样可用，见
<https://docs.linuxserver.io/selkies/user-guide/configuration/>。

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

设置 `PASSWORD` 后访问会弹 HTTP 基础认证；不设置则免认证。

### 修改 autostart / menu 的注意事项

这些文件**只在首次运行时**复制到 `/config`。改了镜像内的默认文件后，必须使用全新的
`/config`（新卷或不挂载卷）才能看到效果——这是最容易踩的坑。

## 4. 本地使用（可选）

本地构建仅用于验证，**不是**本项目的发布方式（发布走第 5 节的 CI）：

```bash
docker build -t selkies-base .

# systemd 作为 PID 1：推荐 --privileged + 可写 /run /tmp
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 \
  -v $PWD/config:/config selkies-base
# 打开 https://localhost:3001，信任自签名证书

# 切换默认软件
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 -e APP=xterm selkies-base

# X11 会话 + 自定义参数
docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=false -e APP=xeyes -e APP_CLI="-geometry 800x600" selkies-base

# 会话内排错
docker exec -it selkies-base bash
docker exec -it selkies-base systemctl status selkies-selkies selkies-de
```

`--shm-size=1gb` 必须给足，否则渲染/浏览器进程可能崩溃。
不需要内层 Docker 时可不用 `--privileged`，改 `--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`。

## 5. Workflow Actions 构建流程

本项目**不在本地构建**。镜像由独立的私有仓库 **`jcleng/action-sync-images`** 的
workflow `build-repo.yml`（名称 `RUN Repo Url && PUSH AliYun`）构建并推送到阿里云 ACR。

- Workflow 页面：https://github.com/jcleng/action-sync-images/actions/workflows/build-repo.yml
- 触发方式：`workflow_dispatch`（该 workflow 也声明了 `repository_dispatch`，但其脚本读取
  `github.event.inputs.*`，只有 `workflow_dispatch` 会填充这些输入）

### 输入参数

| 输入 | 本项目取值 | 说明 |
| --- | --- | --- |
| `arg_repo_url` | `https://github.com/jcleng/selkies-base.git` | 被构建的仓库地址 |
| `arg_branch_name` | `main` | 分支名 |
| `arg_username` | `gitbuild` | 镜像名前缀 |
| `arg_name` | `selkies-base` | 镜像名（可带 tag，如 `selkies-base:1.0`） |
| `arg_aliyunurl` | `registry.cn-hangzhou.aliyuncs.com` | 推送的 registry |
| `arg_aliyunuser` | `jcleng` | registry 用户名/命名空间 |

### 流程步骤

1. `actions/checkout@v3` 拉取 action-sync-images 自身。
2. `docker/setup-buildx-action@v2.9.1` 准备 buildx。
3. `docker/login-action@v2.2.0` 用 secrets `ALIDOCKER_USERNAME` / `ALIDOCKER_PASSWORD`
   登录 `arg_aliyunurl`。
4. `git clone --depth=1 -b <branch> <repo_url> work_src`，在 `work_src` 内
   `docker build` 并 `docker push`：
   `<arg_aliyunurl>/<arg_aliyunuser>/<arg_username>-<arg_name>`。
5. 生成 release 说明，`softprops/action-gh-release@v1` 以 tag
   `<arg_username>-<arg_name>` 在 action-sync-images 仓库创建/更新 release，附带
   `release.txt` 与被构建仓库的 `Dockerfile`。

镜像命名规则：`<arg_aliyunurl>/<arg_aliyunuser>/<arg_username>-<arg_name>`，
即本项目为：

```
registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest
```

### 触发命令

```bash
gh workflow run build-repo.yml --repo jcleng/action-sync-images \
  -f arg_repo_url=https://github.com/jcleng/selkies-base.git \
  -f arg_branch_name=main \
  -f arg_username=gitbuild \
  -f arg_name=selkies-base \
  -f arg_aliyunurl=registry.cn-hangzhou.aliyuncs.com \
  -f arg_aliyunuser=jcleng

# 观察运行结果
gh run list  --repo jcleng/action-sync-images --workflow build-repo.yml --limit 3
gh run watch <run-id> --repo jcleng/action-sync-images
```

本机当前**直连** GitHub / GHCR 可用（`gh`、`git`、`curl` 均无需代理）。
历史笔记：本机曾用代理 `https_proxy=http://192.168.195.18:20171`，该代理现已失效，请优先直连；
CI 在 GitHub 上运行，与代理无关。

### 已执行的构建记录

| 时间(UTC) | Run ID | 结果 | 产物 |
| --- | --- | --- | --- |
| 2026-10-12T07:12:16Z | `38216442259` | success（约 3 分钟） | `registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`<br>digest `sha256:018cfb1fb661f2615d877b2befdd8b0bdca7a5ae29201f0daefb022c6e28f796` |
| 2026-10-15T08:15:59Z | `38704432504` | success（约 1 分 41 秒） | `registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`<br>digest `sha256:120edfc9a08032d7bf3b45af39f54872e352b679a76d48e1e4ff5711efd09ec3`<br>（**systemd 版**：entrypoint 换为 `/sbin/init`） |
| 2026-10-15T08:52:12Z | `38708756913` | success（约 1 分 49 秒） | digest `sha256:b30f344a1d3d3656ad6b4f60d69ee7d0e1a884841e817e30f93a71dbb76c374a`<br>（修正 `up`→`run`、禁用 Debian nginx/exim4、logind 排序；实测仍剩 `getty@tty1` 失败） |
| 2026-10-15T08:58:21Z | `38709494981` | success（约 1 分 31 秒） | `registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`<br>digest `sha256:98f0b70470784216d8aef581f2e6fd8bc683cf036e0353c68b855032bde4a1c7`<br>（**当前最新**：额外禁用 `getty@tty1`；全新容器实测 `is-system-running=running`、failed 为空、3001=200、内层 docker 可用） |

Release：https://github.com/jcleng/action-sync-images/releases/tag/gitbuild-selkies-base

### 工作流已知限制

- workflow 只执行 `docker build` + `docker push`，**不启动容器做运行验证**；
  会话内是否真的跑起 xeyes 需要拉镜像后手动确认。
- 无多架构构建，只有 amd64（与项目「不要 aarch64」的要求一致）。
- 使用 actions/checkout@v3 等旧版 action，会有 Node.js 20 弃用告警，不影响构建。

## 6. 镜像体积

镜像约 **3.95GB**（`docker images` 显示）/ **2.8GB**（解压后 `du -xsh /`），
其中本项目新增内容（`x11-apps` + `xterm`）仅数十 MB，**绝大部分体积来自 Selkies 底包**。

主要占用：`/usr/lib/x86_64-linux-gnu` ~680M（Mesa/LLVM/Vulkan 图形栈）、
`/usr/lib/locale` ~411M（`locales-all`）、`/lsiopy` ~318M（selkies/pixelflux/pcmflux venv）、
`/usr/share/fonts` ~171M（Noto CJK/Emoji）、`/usr/share/locale` ~106M、
`/usr/lib/firmware` ~104M、`/usr/share/icons` ~49M。

完整表格见 [README.md](README.md#镜像体积说明)。结论：体积由底包决定，
不要为减小体积去裁剪这个最小示例；真要减体积需另立项目从头重构底包。

## 7. 变更与发布约定

- 分支：`main`，提交信息用中文简述改动。
- 改完 Dockerfile 或 `root/` 下文件后：
  1. `git add -A && git commit && git push`；
  2. 重新触发第 5 节的 workflow；
  3. 记录新的 Run ID / digest（必要时更新本文件的构建记录表）。
- 本地清理构建缓存（本项目不本地构建，缓存只用于验证）：
  ```bash
  docker builder prune -af && docker image prune -af
  ```
- 涉及 `root/defaults/*` 的改动属于「首次运行才生效」的语义，验证时必须使用全新的 `/config`。
- 涉及 `root/etc/systemd/system/*` 的改动：新增单元后记得在 `multi-user.target.wants/` 里补软链
  （本仓库用自带软链代替 `systemctl enable`），并用 `systemd-analyze verify` 校验单元语法。
- 未经明确要求不要新增 aarch64 支持、不要引入 Selkies Desktop / Pelorus / 浏览器等组件，
  保持镜像最小。**唯一已获授权的例外**是把 PID 1 换成 systemd 并加入 systemd/sshd/docker-cli 等
  基础组件（见 §1 例外说明）；如需再加其它组件，先与用户确认。

## 8. 参考链接

- Selkies 文档：https://docs.linuxserver.io/selkies/
- 构建自定义镜像：https://docs.linuxserver.io/selkies/developer-guide/building-images/
- 配置参考：https://docs.linuxserver.io/selkies/user-guide/configuration/
- 基础镜像源码：https://github.com/linuxserver/docker-baseimage-selkies
- Dockerfile 参考：https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile
- 构建仓库：https://github.com/jcleng/action-sync-images
