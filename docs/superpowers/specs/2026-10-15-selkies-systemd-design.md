# Selkies 容器 systemd 化设计

- 日期：2026-10-15
- 分支：`main`
- 状态：已评审通过（待实现）
- 关联：`Dockerfile`、`root/`、`README.md`、`AGENTS.md`

## 1. 背景与目标

当前镜像 `FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie` 使用 **s6-overlay** 作为
PID 1（`ENTRYPOINT /init`）来托管一整套初始化脚本和常驻服务。这个模式对"最小运行 xeyes"
足够，但无法在容器内使用 `systemctl`，导致依赖 systemd 的运维面板（宝塔 / 1Panel）及需要
按系统服务方式安装的软件无法正常工作。

**目标**：把 PID 1 从 s6-overlay 换成 **真 systemd**，在保留 Selkies 网页桌面全部功能的
前提下，让容器表现得像一台普通 Linux 主机：

1. `/sbin/init`（systemd）作为 PID 1，`systemctl` 可用；
2. Selkies 完整功能保留（Wayland/X11 会话、`APP=xeyes`、3001 端口、`/config` 持久化）；
3. 容器内可运行 Docker（`--privileged` 时），支持安装宝塔 / 1Panel；
4. 新增 sshd（允许 root）、docker-compose、常用运维工具。

## 2. 非目标

- 不提供 aarch64（沿用项目一贯的 amd64-only 约定）；
- 不追求 1:1 保留 LSIO 全部特性（`DOCKER_MODS`、`/custom-services.d`、`HARDEN_*` 硬化族等
  不做移植，见 §7）；
- 不改写底包的 Selkies/Xvfb/pixelflux/nginx 启动逻辑（采用"复用现有脚本"路线，见 §4）；
- 不新增 Selkies Desktop / Pelorus / 浏览器等组件。

## 3. 现状分析（s6 链路）

底包 `linuxserver/docker-baseimage-selkies` 叠加在 `linuxserver/docker-baseimage-debian`
之上。与本项目相关的 s6 单元（目录 `root/etc/s6-overlay/s6-rc.d/`）如下。

一次性初始化（oneshot，按 `dependencies.d` 顺序）：

```
init-os-end ─► init-selkies ─► init-nginx ─► init-selkies-config ─► init-video
            ─► init-selkies-end ─► init-config ─► init-config-end
            ─► (init-mods…) ─► init-custom-files ─► init-services
```

其中 `init-adduser`、`init-device-perms`、`init-envfile`、`init-custom-files` 来自
baseimage-debian；其余来自 baseimage-selkies。`init-selkies`、`init-os-end`、
`init-config`、`init-config-end`、`init-services` 等为**空标记脚本**（只用于排序）。

常驻服务（longrun，带 `finish` 的会做进程树清理）：

| s6 服务 | 作用 | 依赖 |
| --- | --- | --- |
| `svc-xorg` | Xvfb（X11 模式）；Wayland 模式下 `sleep infinity` | init-services |
| `svc-dbus` | system dbus | init-services, svc-xorg |
| `svc-nginx` | 反向代理（3000/3001） | init-services |
| `svc-pulseaudio` | 音频 | init-services |
| `svc-selkies` | Selkies 后端（HTTP/WS） | init-services, svc-nginx, svc-pulseaudio |
| `svc-de` | 桌面会话（labwc/openbox + `startwm*.sh` → autostart） | init-services, svc-nginx, svc-selkies, svc-xorg |
| `svc-xsettingsd` | X11 下的 DPI | init-services, svc-nginx, svc-xorg |
| `svc-watchdog` | `RESTART_APP=true` 时守护 autostart | init-services |
| `svc-docker` | 探测 privileged 后起内层 dockerd | init-services |

### 3.1 关键机制

所有脚本都是普通 bash，仅依赖两个辅助命令：

- **`with-contenv`**：`/usr/bin/with-contenv` 是 LSIO 自己的 wrapper（docker-mods 的
  `with-contenv.v1`），最终 `exec /command/with-contenv "$@"`。其作用是**把
  `/run/s6/container_environment/` 下每个文件（文件名为变量名，内容为变量值、无换行）
  读入环境**。
- **`s6-setuidgid abc <cmd>`**：来自 s6-overlay 的 `symlinks-arch` 包，落在
  `/usr/bin/s6-setuidgid`，默认 PATH 即可命中。

脚本还会**反过来写**该目录，例如：

- `init-video/run` → `printf "true" > /run/s6/container_environment/AUTO_GPU`、
  `LIBVA_DRIVER_NAME`、`__GLX_VENDOR_LIBRARY_NAME`
- `init-selkies-config/run` → `LANGUAGE`、`LANG`、`PATH`、`XDG_RUNTIME_DIR`、
  `CUPS_SERVER`、`PIXELFLUX_CU`、`ROOT_PATH`、多个 `SELKIES_*`
- `init-selkies-config/run` 还负责**首次把 `/defaults/autostart*`、`/defaults/menu*.xml`
  复制进 `/config/.config/{labwc,openbox}/`**（即 AGENTS.md 里"只在首次运行生效"的来源）。

> 结论：只要在启动时把容器环境变量写进 `/run/s6/container_environment/`，并保留 s6 的
> 二进制（仅不再以 PID 1 运行 `/init`），上述脚本**可以原样复用**。

### 3.2 反-systemd 守卫

baseimage-debian 刻意阻止服务在容器内自启，systemd 化后必须移除：

- `/usr/sbin/policy-rc.d`（内容 `exit 101`）——会让 apt 安装软件时跳过服务启用，正是
  宝塔/1Panel 安装脚本会踩的坑；
- `/sbin/initctl`（`dpkg-divert` 生成的 stub）。

## 4. 方案选择

| | A1：systemd 直接托管底包现有脚本（**采用**） | A2：自写全部服务启动逻辑 |
| --- | --- | --- |
| 逻辑复制 | 几乎为零 | 需抄 `init-selkies-config`(17KB)、`init-video`(6KB) 等 |
| 底包升级 | 自动跟随 | 手工跟进，易失效 |
| 风险 | 中（依赖底包内部路径，LSIO 不官方支持） | 高（自维护整套启动逻辑） |
| 可读性 | 一般 | 好 |

社区检索结论（`selkies-project/selkies` issue #70、1Panel 社区镜像等）显示**没有现成的
systemd 化 Selkies 方案**：官方明确回复"not supportable"，社区 1Panel/宝塔镜像走的是
DooD 或仿冒 `systemctl` 路线。因此本项目采用 A1 自行实现。

## 5. 详细设计

### 5.1 镜像与入口

- 保持 `FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie`（amd64）。
  **不**改用参考里的 `library-ubuntu:20.04`——那会把 Selkies/Xvfb/pixelflux/nginx 整套栈
  推倒重来。
- 新增安装：`systemd`、`systemd-sysv`、`openssh-server`，以及
  `ca-certificates wget curl unzip zstd tar`；`docker-compose-plugin` 若底包未带则补上
  （底包 Dockerfile 已含 docker-ce / containerd.io / buildx / compose plugin，实现时先探测）。
- 移除 3.2 的反-systemd 守卫。
- 入口：

  ```dockerfile
  ENV container=docker
  STOPSIGNAL SIGRTMIN+3
  ENTRYPOINT ["/sbin/init"]
  CMD ["--system", "--unit=multi-user.target"]
  ```

  保留 `EXPOSE 3001`、`VOLUME /config`。**不**把 `/run`、`/tmp`、`/sys/fs/cgroup` 声明为
  `VOLUME`（避免匿名卷遮蔽），改由运行时参数提供（§5.7）。

### 5.2 环境变量桥接

新增 `/usr/local/bin/selkies-container-env`，把 PID 1 的环境写入
`/run/s6/container_environment/`：

```bash
#!/bin/bash
set -e
ENVDIR=/run/s6/container_environment
mkdir -p "$ENVDIR"
while IFS= read -r -d '' entry; do
  printf '%s' "${entry#*=}" > "$ENVDIR/${entry%%=*}"
done < /proc/1/environ
```

对应单元 `selkies-container-env.service`（oneshot，`RemainAfterExit=yes`），作为整条初始化链
的第一个依赖。

- 顺带白拿 `FILE__*` 密钥支持：桥接会把 `FILE__X` 写进 envdir，`init-envfile/run` 再解析。
- `UMASK` 不生效（`with-contenv` 的 umask 逻辑只在 cwd 匹配 `/servicedirs/svc-` 时触发）。
  折中：各服务单元显式 `UMask=0022`；自定义 `UMASK` 属被放弃的 LSIO 特性（§7）。

### 5.3 一次性初始化单元（Type=oneshot, RemainAfterExit=yes）

| systemd 单元 | 执行内容 | After / Requires |
| --- | --- | --- |
| `selkies-container-env` | §5.2 脚本 | （链首） |
| `selkies-init-adduser` | debian `init-adduser/run` | container-env |
| `selkies-init-envfile` | debian `init-envfile/run` | adduser |
| `selkies-init-device-perms` | debian `init-device-perms/run` | adduser |
| `selkies-init-os-end` | 标记 | 上面三个 |
| `selkies-init-selkies` | 标记 | os-end |
| `selkies-init-nginx` | selkies `init-nginx/run` | selkies |
| `selkies-init-selkies-config` | selkies `init-selkies-config/run` | init-nginx |
| `selkies-init-video` | selkies `init-video/run` | init-selkies-config |
| `selkies-init-selkies-end` | 标记 | init-video |
| `selkies-init-config` | 标记（debian） | selkies-end |
| `selkies-init-config-end` | 标记 | init-config |
| `selkies-init-custom-files` | debian `init-custom-files/run` | config-end |
| `selkies-init-services` | 标记（"服务可启动"） | custom-files |

`DOCKER_MODS` 相关 `init-mods*` / `init-crontab-config` / `init-migrations` 不移植（§7）。

表中标注"标记"的单元只用于复刻排序，`ExecStart=/bin/true`；其余单元的 `ExecStart` 直接调用
现成脚本（脚本自带 `#!/usr/bin/with-contenv bash` 或自身调用带该 shebang 的 `run`）。示例：

```ini
# /etc/systemd/system/selkies-init-nginx.service
[Unit]
Description=Selkies init: nginx config
After=selkies-init-selkies.service
Requires=selkies-init-selkies.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-nginx/up
[Install]
WantedBy=multi-user.target
```

### 5.4 常驻服务单元（Type=simple, Restart=always, RestartSec=1）

| systemd 单元 | 执行脚本 | After |
| --- | --- | --- |
| `selkies-xorg` | `svc-xorg/run` | init-services |
| `selkies-pulseaudio` | `svc-pulseaudio/run` | init-services |
| `selkies-nginx` | `svc-nginx/run` | init-services |
| `selkies-dbus` | `svc-dbus/run` | init-services, selkies-xorg |
| `selkies-selkies` | `svc-selkies/run` | init-services, selkies-nginx, selkies-pulseaudio |
| `selkies-de` | `svc-de/run`（+`ExecStopPost=.../svc-de/finish`） | init-services, selkies-nginx, selkies-selkies, selkies-xorg |
| `selkies-xsettingsd` | `svc-xsettingsd/run` | init-services, selkies-nginx, selkies-xorg |
| `selkies-watchdog` | `svc-watchdog/run` | init-services |

约定：
- 每个服务 `Requires=selkies-init-services.service` + `After=selkies-init-services.service`，
  由 `Requires`/`After` 传递拉起整条初始化链；
- `Restart=always` 对应 s6 longrun 的自动重启；`svc-de/finish` 通过 `ExecStopPost` 复刻；
- `UMask=0022`；`WantedBy=multi-user.target`，用 `/etc/systemd/system/multi-user.target.wants/`
  软链完成 enable（构建期不启动 systemd，用软链而非 `systemctl enable`）。

### 5.5 容器内 Docker

弃用 `svc-docker`，改用 docker-ce 自带的原生 `docker.service`（`systemctl status docker`
与面板调用均正常）。drop-in
`/etc/systemd/system/docker.service.d/container.conf`：

```ini
[Unit]
ConditionPathExists=/dev/cpu_dma_latency
```

效果与 `svc-docker` 的探测等价：`--privileged`（`/dev/cpu_dma_latency` 存在）时启动内层
dockerd，否则静默跳过。`/tmp` 的 tmpfs 处理改由运行时 `--tmpfs /tmp` 提供。

### 5.6 sshd

- 安装 `openssh-server`，启用 `ssh.service`（若镜像是 socket 激活则同时 enable `ssh.socket`）。
- `/etc/ssh/sshd_config.d/10-selkies.conf`：`PermitRootLogin yes`。
- 可选环境变量 `ROOT_PASSWORD`：设置后由 `selkies-root-password.service`（oneshot）
  `chpasswd` 写入 root 密码；不设置则仅允许密钥登录（与官方镜像一致的默认安全姿态）。

### 5.7 运行时要求

```bash
docker run -d --privileged --shm-size=1gb \
  --tmpfs /run --tmpfs /tmp \
  -p 3001:3001 -v ./config:/config \
  registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest
```

- 不用 `--privileged` 的最小组合：`--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  --tmpfs /run --tmpfs /tmp`（此时容器内 docker 不可用）。
- 如有 seccomp 报错，追加 `--security-opt seccomp=unconfined`。

### 5.8 文件布局

```
root/
├── defaults/…                                       # 现状不变
├── etc/systemd/system/selkies-*.service             # 初始化链 + 常驻服务
├── etc/systemd/system/multi-user.target.wants/…     # enable 软链
├── etc/systemd/system/docker.service.d/container.conf
├── etc/ssh/sshd_config.d/10-selkies.conf
└── usr/local/bin/selkies-container-env
```

`Dockerfile` 负责：安装 systemd/sshd/工具、删守卫、`COPY /root /`、创建 enable 软链、
设置 `ENTRYPOINT`/`CMD`/`STOPSIGNAL`。同步更新 `README.md`（用法、compose 示例）与
`AGENTS.md`（第 3/4/5 节：入口、服务、构建）。

### 5.9 可能需要的 systemd 单元裁剪

在容器中以 PID 1 运行时，个别 Debian 默认单元可能无意义或失败（如
`systemd-remount-fs`、`systemd-update-utmp`、`dev-hugepages.mount`、`systemd-modules-load`
等）。实现阶段以 `systemctl --failed` 实测为准，仅在确有影响时 `mask`，并在设计文档/注释中
记录原因。

## 6. 验证计划

1. `docker build` 成功（amd64）。
2. `docker run --privileged …` 启动，容器不退出。
3. `systemctl is-system-running` 返回 `running`（或 `degraded` 且 failed 列表为空/已知）。
4. `systemctl status selkies-{nginx,selkies,de,xorg,pulseaudio,dbus} ssh docker` 均为 active。
5. 浏览器访问 `https://localhost:3001`，能看到并操作 xeyes；`APP=xterm` 可切换。
6. 容器内 `docker ps`、`systemctl restart selkies-selkies` 正常。
7. `-e PIXELFLUX_WAYLAND=false` 走 X11 路径同样正常。
8. 全新 `/config` 下确认 `/defaults` 首次复制生效。
9. `journalctl -b` 无致命报错。
10. 构建产物推送（CI）后拉镜像复验；记录 Run ID / digest。

## 7. 保留 / 放弃的特性

**保留**：Selkies 全部功能、`PUID`/`PGID`、`TZ`、`LC_ALL`、`APP`/`APP_CLI`、`TITLE`、
`PIXELFLUX_WAYLAND`、`CUSTOM_USER`/`PASSWORD`（nginx 基础认证）、`SUBFOLDER`、
`CUSTOM_PORT`/`CUSTOM_HTTPS_PORT`/`CUSTOM_WS_PORT`、`/custom-cont-init.d`、`FILE__*` 密钥、
GPU/`DRINODE` 探测、`RESTART_APP`。

**放弃**：`DOCKER_MODS`（`init-mods*`）及其包安装逻辑、`/custom-services.d`、
`HARDEN_*`/`DISABLE_*` 部分语义（`init-selkies-config` 仍在，但依赖 `policy-rc.d` 的行为
不再保证）、`UMASK`。

## 8. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| 依赖底包内部脚本路径，升级后失效 | 桥接层薄（仅 env + unit 调度）；锁版本或升级时回归测试 |
| systemd 需要更重的运行参数 | 文档明确 `--privileged` 组合，compose 示例同步更新 |
| LSIO 不官方支持，行为差异（如 umask） | §7 明确列出；取舍以 Selkies 可用性优先 |
| 反-systemd 守卫删除带来副作用 | 仅在镜像内生效；`policy-rc.d` 删除是容器内跑面板的前提 |
| `--privileged` 安全面变大 | 文档标注风险；提供非 privileged 的最小组合（无内层 docker） |

## 9. 后续步骤

1. 按本设计写实现计划（writing-plans）；
2. 实现 `Dockerfile` + `root/` 单元与脚本；
3. 本地构建验证（§6）；
4. 更新 `README.md` / `AGENTS.md`；
5. 提交并触发 `jcleng/action-sync-images` 的 `build-repo.yml`，记录 Run ID / digest。
