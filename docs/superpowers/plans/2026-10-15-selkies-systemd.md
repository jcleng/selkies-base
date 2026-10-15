# Selkies 容器 systemd 化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `selkies-base` 镜像的 PID 1 从 s6-overlay 换成真 systemd，复用底包现有脚本以保留 Selkies 全部功能，并支持容器内 Docker、sshd、宝塔/1Panel。

**Architecture:** 保留 `ghcr.io/linuxserver/baseimage-selkies:debiantrixie` 底包（含 s6 二进制与 `/etc/s6-overlay/s6-rc.d/*` 脚本）。启动时用一个 oneshot 把 PID 1 环境写入 `/run/s6/container_environment/`，使底包脚本自带的 `with-contenv` / `s6-setuidgid` 继续可用；随后用一条 systemd oneshot 链复刻 s6 的 `dependencies.d` 顺序，再用 8 个 `Type=simple` 服务复刻 s6 longrun。s6 只作为二进制库存在，不再当 PID 1。

**Tech Stack:** Docker（amd64）、systemd、s6-overlay（仅复用脚本/命令）、LinuxServer baseimage-selkies、nginx/pulseaudio/dbus/Xvfb/labwc。

**Spec:** `docs/superpowers/specs/2026-10-15-selkies-systemd-design.md`

---

## 前置说明

- 本仓库提交一律直接在 `main`，提交信息用中文（见 `AGENTS.md` §7）。本项目不做多分支/worktree。
- 本机 `uname -m` 必须是 `x86_64`（仅 amd64）。
- 本机网络：`raw.githubusercontent.com` / `github.com` 可直连；`https_proxy=http://192.168.195.18:20171` 当前不通，**不要**设置代理。
- 本机磁盘 99% 已用（约 19G 可用）。构建前先清理构建缓存：
  ```bash
  docker builder prune -af
  ```
  （只清 builder 缓存，不动 `docker images`。）
- "测试"形态说明：本任务是镜像/基础设施，没有单元测试框架。每个任务的验证 = **静态校验**（`systemd-analyze verify`、`bash -n`、软链检查）+ **端到端验证**（构建、运行、`systemctl`/`curl` 断言）。先写校验命令并确认其失败/通过，再写实现——顺序遵循 TDD 精神。

## 文件结构（先锁定分解）

```
Dockerfile                                           # 修改：装 systemd/sshd/工具、删守卫、换入口、COPY root
root/usr/local/bin/selkies-container-env             # 新建：把 PID1 环境灌入 /run/s6/container_environment
root/usr/local/bin/selkies-root-password             # 新建：按 ROOT_PASSWORD 设置 root 密码
root/etc/systemd/system/selkies-container-env.service
root/etc/systemd/system/selkies-init-adduser.service
root/etc/systemd/system/selkies-init-envfile.service
root/etc/systemd/system/selkies-init-device-perms.service
root/etc/systemd/system/selkies-init-os-end.service
root/etc/systemd/system/selkies-init-selkies.service
root/etc/systemd/system/selkies-init-nginx.service
root/etc/systemd/system/selkies-init-selkies-config.service
root/etc/systemd/system/selkies-init-video.service
root/etc/systemd/system/selkies-init-selkies-end.service
root/etc/systemd/system/selkies-init-config.service
root/etc/systemd/system/selkies-init-config-end.service
root/etc/systemd/system/selkies-init-custom-files.service
root/etc/systemd/system/selkies-init-services.service
root/etc/systemd/system/selkies-root-password.service
root/etc/systemd/system/selkies-xorg.service
root/etc/systemd/system/selkies-pulseaudio.service
root/etc/systemd/system/selkies-nginx.service
root/etc/systemd/system/selkies-dbus.service
root/etc/systemd/system/selkies-selkies.service
root/etc/systemd/system/selkies-de.service
root/etc/systemd/system/selkies-xsettingsd.service
root/etc/systemd/system/selkies-watchdog.service
root/etc/systemd/system/docker.service.d/container.conf
root/etc/ssh/sshd_config.d/10-selkies.conf
root/etc/systemd/system/multi-user.target.wants/*      # enable 软链（含 ssh/docker）
README.md                                            # 修改：用法/compose/端口/privileged
AGENTS.md                                            # 修改：入口、服务、构建说明
```

单元文件都放在 `/etc/systemd/system/`（而非 `/lib/systemd/system/`），保证第三方脚本可覆盖且优先级最高。enable 用**随镜像携带的软链**（`root/etc/systemd/system/multi-user.target.wants/`），构建期不运行 `systemctl`（构建时 systemd 未运行，避免不确定性）。

**统一约定**（所有单元）：
- oneshot：`Type=oneshot` + `RemainAfterExit=yes`；longrun：`Type=simple` + `Restart=always` + `RestartSec=1` + `UMask=0022`。
- 依赖脚本路径固定为 `/etc/s6-overlay/s6-rc.d/<name>/{run,up}`。
- 命令一律写绝对路径 `/etc/s6-overlay/s6-rc.d/...`，不依赖 PATH。

---

## Task 1: 环境桥接与 root 密码脚本

**Files:**
- Create: `root/usr/local/bin/selkies-container-env`
- Create: `root/usr/local/bin/selkies-root-password`
- Create: `root/etc/systemd/system/selkies-container-env.service`
- Create: `root/etc/systemd/system/selkies-root-password.service`

- [ ] **Step 1: 写 selkies-container-env（复刻 s6 的 container_environment）**

创建 `root/usr/local/bin/selkies-container-env`：

```bash
#!/bin/bash
# Populate /run/s6/container_environment from PID 1's environment.
#
# s6-overlay normally does this in its stage1. We run systemd as PID 1 instead,
# so we recreate the same envdir layout that the LSIO `with-contenv` helper and
# the baseimage init scripts expect. Format: one file per variable, filename is
# the variable name, contents is the value with NO trailing newline.
set -e

ENVDIR=/run/s6/container_environment
mkdir -p "$ENVDIR"

while IFS= read -r -d '' entry; do
  [ -n "$entry" ] || continue
  name=${entry%%=*}
  value=${entry#*=}
  printf '%s' "$value" > "$ENVDIR/$name"
done < /proc/1/environ
```

- [ ] **Step 2: 写 selkies-root-password**

创建 `root/usr/local/bin/selkies-root-password`：

```bash
#!/bin/bash
# Set the root password from $ROOT_PASSWORD, only when it is provided.
# Run via `with-contenv` so the container environment is visible.
set -e

if [ -z "${ROOT_PASSWORD:-}" ]; then
  echo "[selkies] ROOT_PASSWORD not set, keeping the account passwordless (key-only ssh login)"
  exit 0
fi

printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
echo "[selkies] root password set from ROOT_PASSWORD"
```

- [ ] **Step 3: 赋可执行位并做语法检查**

```bash
chmod +x root/usr/local/bin/selkies-container-env root/usr/local/bin/selkies-root-password
bash -n root/usr/local/bin/selkies-container-env
bash -n root/usr/local/bin/selkies-root-password
echo "OK"
```
Expected: 打印 `OK`，且无语法错误输出。

- [ ] **Step 4: 写 selkies-container-env.service**

创建 `root/etc/systemd/system/selkies-container-env.service`：

```ini
[Unit]
Description=Selkies: populate /run/s6/container_environment from PID 1 environment
After=systemd-tmpfiles-setup.service
Before=selkies-init-adduser.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/selkies-container-env

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: 写 selkies-root-password.service**

创建 `root/etc/systemd/system/selkies-root-password.service`：

```ini
[Unit]
Description=Selkies: set root password from ROOT_PASSWORD
After=selkies-init-adduser.service
Requires=selkies-container-env.service
Before=ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/with-contenv /usr/local/bin/selkies-root-password

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: 静态校验单元**

```bash
systemd-analyze verify root/etc/systemd/system/selkies-container-env.service root/etc/systemd/system/selkies-root-password.service 2>&1 | grep -Ei "unknown|invalid|failed to parse|bad" || echo "NO-SYNTAX-ERRORS"
```
Expected: 打印 `NO-SYNTAX-ERRORS`。允许出现 "Command ... not executable" 之类的告警（宿主上没有 `/etc/s6-overlay/...`、`/usr/local/bin/...` 路径，属预期）。

- [ ] **Step 7: 提交**

```bash
git add root/usr/local/bin/selkies-container-env root/usr/local/bin/selkies-root-password \
        root/etc/systemd/system/selkies-container-env.service \
        root/etc/systemd/system/selkies-root-password.service
git commit -m "systemd: 增加环境桥接与 root 密码 oneshot 单元"
```

---

## Task 2: 初始化链（13 个 oneshot 单元）

**Files:**
- Create: `root/etc/systemd/system/selkies-init-{adduser,envfile,device-perms,os-end,selkies,nginx,selkies-config,video,selkies-end,config,config-end,custom-files,services}.service`

- [ ] **Step 1: 写基础三连（adduser / envfile / device-perms）**

`root/etc/systemd/system/selkies-init-adduser.service`：

```ini
[Unit]
Description=Selkies init: adduser (PUID/PGID remap, chown /config)
After=selkies-container-env.service
Requires=selkies-container-env.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-adduser/run

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-envfile.service`：

```ini
[Unit]
Description=Selkies init: FILE__ secret env files
After=selkies-init-adduser.service
Requires=selkies-init-adduser.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-envfile/run

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-device-perms.service`：

```ini
[Unit]
Description=Selkies init: attached device permissions
After=selkies-init-adduser.service
Requires=selkies-init-adduser.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-device-perms/run

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: 写标记单元（os-end / selkies / selkies-end / config / config-end / services）**

标记单元只用于排序，`ExecStart=/bin/true`。

`root/etc/systemd/system/selkies-init-os-end.service`：

```ini
[Unit]
Description=Selkies init: OS init complete (marker)
Requires=selkies-init-adduser.service selkies-init-envfile.service selkies-init-device-perms.service
After=selkies-init-adduser.service selkies-init-envfile.service selkies-init-device-perms.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-selkies.service`：

```ini
[Unit]
Description=Selkies init: start of selkies init (marker)
Requires=selkies-init-os-end.service
After=selkies-init-os-end.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-selkies-end.service`：

```ini
[Unit]
Description=Selkies init: end of selkies init (marker)
Requires=selkies-init-video.service
After=selkies-init-video.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-config.service`：

```ini
[Unit]
Description=Selkies init: config (marker, upstream is no-op)
Requires=selkies-init-selkies-end.service
After=selkies-init-selkies-end.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-config-end.service`：

```ini
[Unit]
Description=Selkies init: config end (marker)
Requires=selkies-init-config.service
After=selkies-init-config.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-services.service`：

```ini
[Unit]
Description=Selkies init: services may start (marker)
Requires=selkies-init-custom-files.service
After=selkies-init-custom-files.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: 写执行单元（nginx / selkies-config / video / custom-files）**

`root/etc/systemd/system/selkies-init-nginx.service`：

```ini
[Unit]
Description=Selkies init: nginx config, TLS cert, dashboard, manifest
Requires=selkies-init-selkies.service
After=selkies-init-selkies.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-nginx/up

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-selkies-config.service`：

```ini
[Unit]
Description=Selkies init: session config, first-run /defaults copy, locale, hardening
Requires=selkies-init-nginx.service
After=selkies-init-nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-selkies-config/up

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-video.service`：

```ini
[Unit]
Description=Selkies init: GPU/video device detection
Requires=selkies-init-selkies-config.service
After=selkies-init-selkies-config.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-video/up

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-init-custom-files.service`：

```ini
[Unit]
Description=Selkies init: run /custom-cont-init.d scripts
Requires=selkies-init-config-end.service
After=selkies-init-config-end.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/s6-overlay/s6-rc.d/init-custom-files/run

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: 静态校验全部初始化单元**

```bash
systemd-analyze verify root/etc/systemd/system/selkies-init-*.service \
  root/etc/systemd/system/selkies-container-env.service 2>&1 \
  | grep -Ei "unknown|invalid|failed to parse|bad" || echo "NO-SYNTAX-ERRORS"
```
Expected: `NO-SYNTAX-ERRORS`（"not executable" 类告警可忽略）。

- [ ] **Step 5: 校验依赖顺序（关键：不要成环）**

```bash
grep -H "^\(After\|Requires\)=" root/etc/systemd/system/selkies-init-*.service
```
Expected: 形成单链
`container-env ← adduser ← {envfile,device-perms} ← os-end ← selkies ← nginx ← selkies-config ← video ← selkies-end ← config ← config-end ← custom-files ← services`，
且 `systemd-analyze verify` 未报 ordering cycle。

- [ ] **Step 6: 提交**

```bash
git add root/etc/systemd/system/selkies-init-*.service
git commit -m "systemd: 复刻 Selkies s6 初始化链为 13 个 oneshot 单元"
```

---

## Task 3: 常驻服务（8 个 longrun 单元）

**Files:**
- Create: `root/etc/systemd/system/selkies-{xorg,pulseaudio,nginx,dbus,selkies,de,xsettingsd,watchdog}.service`

- [ ] **Step 1: 写无额外依赖的 4 个服务（xorg / pulseaudio / nginx / watchdog）**

`root/etc/systemd/system/selkies-xorg.service`：

```ini
[Unit]
Description=Selkies: Xvfb (X11) or idle (Wayland)
Requires=selkies-init-services.service
After=selkies-init-services.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-xorg/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-pulseaudio.service`：

```ini
[Unit]
Description=Selkies: PulseAudio
Requires=selkies-init-services.service
After=selkies-init-services.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-pulseaudio/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-nginx.service`：

```ini
[Unit]
Description=Selkies: nginx reverse proxy (3000/3001)
Requires=selkies-init-services.service
After=selkies-init-services.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-nginx/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-watchdog.service`：

```ini
[Unit]
Description=Selkies: RESTART_APP watchdog for the autostart process
Requires=selkies-init-services.service
After=selkies-init-services.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-watchdog/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: 写带依赖的 4 个服务（dbus / selkies / de / xsettingsd）**

`root/etc/systemd/system/selkies-dbus.service`：

```ini
[Unit]
Description=Selkies: system D-Bus
Requires=selkies-init-services.service selkies-xorg.service
After=selkies-init-services.service selkies-xorg.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-dbus/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-selkies.service`：

```ini
[Unit]
Description=Selkies: streaming backend (pixelflux + selkies server)
Requires=selkies-init-services.service selkies-nginx.service selkies-pulseaudio.service
After=selkies-init-services.service selkies-nginx.service selkies-pulseaudio.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-selkies/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-de.service`：

```ini
[Unit]
Description=Selkies: desktop session (labwc/openbox + autostart app)
Requires=selkies-init-services.service selkies-nginx.service selkies-selkies.service selkies-xorg.service
After=selkies-init-services.service selkies-nginx.service selkies-selkies.service selkies-xorg.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-de/run
ExecStopPost=/etc/s6-overlay/s6-rc.d/svc-de/finish
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`root/etc/systemd/system/selkies-xsettingsd.service`：

```ini
[Unit]
Description=Selkies: xsettingsd (X11 DPI)
Requires=selkies-init-services.service selkies-nginx.service selkies-xorg.service
After=selkies-init-services.service selkies-nginx.service selkies-xorg.service

[Service]
Type=simple
UMask=0022
ExecStart=/etc/s6-overlay/s6-rc.d/svc-xsettingsd/run
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: 静态校验**

```bash
systemd-analyze verify root/etc/systemd/system/selkies-xorg.service \
  root/etc/systemd/system/selkies-pulseaudio.service \
  root/etc/systemd/system/selkies-nginx.service \
  root/etc/systemd/system/selkies-watchdog.service \
  root/etc/systemd/system/selkies-dbus.service \
  root/etc/systemd/system/selkies-selkies.service \
  root/etc/systemd/system/selkies-de.service \
  root/etc/systemd/system/selkies-xsettingsd.service 2>&1 \
  | grep -Ei "unknown|invalid|failed to parse|bad|cycle" || echo "NO-SYNTAX-ERRORS"
```
Expected: `NO-SYNTAX-ERRORS`。

- [ ] **Step 4: 校验 svc-de 的 finish 脚本存在性（源码层）**

```bash
ls -l /tmp/opencode/baseimage-selkies/root/etc/s6-overlay/s6-rc.d/svc-de/finish 2>/dev/null || \
  echo "WARN: 本地无底包源码副本，靠 Task 7 的运行时验证兜底"
```
Expected: 有则打印路径；无则打印 WARN（不影响后续）。

- [ ] **Step 5: 提交**

```bash
git add root/etc/systemd/system/selkies-xorg.service \
        root/etc/systemd/system/selkies-pulseaudio.service \
        root/etc/systemd/system/selkies-nginx.service \
        root/etc/systemd/system/selkies-watchdog.service \
        root/etc/systemd/system/selkies-dbus.service \
        root/etc/systemd/system/selkies-selkies.service \
        root/etc/systemd/system/selkies-de.service \
        root/etc/systemd/system/selkies-xsettingsd.service
git commit -m "systemd: 复刻 Selkies s6 常驻服务为 8 个 longrun 单元"
```

---

## Task 4: Docker 管理、sshd 配置与 enable 软链

**Files:**
- Create: `root/etc/systemd/system/docker.service.d/container.conf`
- Create: `root/etc/ssh/sshd_config.d/10-selkies.conf`
- Create: `root/etc/systemd/system/multi-user.target.wants/*`（22 个软链）

- [ ] **Step 1: 写 docker drop-in**

创建 `root/etc/systemd/system/docker.service.d/container.conf`：

```ini
# Only start the inner Docker daemon when the container is privileged.
# /dev/cpu_dma_latency is only present in privileged containers, which is the
# same probe the upstream s6 `svc-docker` service uses.
[Unit]
ConditionPathExists=/dev/cpu_dma_latency
```

- [ ] **Step 2: 写 sshd 配置**

创建 `root/etc/ssh/sshd_config.d/10-selkies.conf`：

```
PermitRootLogin yes
```

- [ ] **Step 2b: mask systemd 自带的 dbus（避免与 svc-dbus 抢 system bus）**

底包用 `svc-dbus` 运行 `dbus-daemon --system`；Debian 的 `dbus.service`/`dbus.socket` 若被启用会抢占
`/run/dbus/system_bus_socket`。用指向 `/dev/null` 的软链把它们 mask 掉（随镜像携带）：

```bash
cd root/etc/systemd/system
ln -sf /dev/null dbus.service
ln -sf /dev/null dbus.socket
ln -sf /dev/null dbus-broker.service
cd - >/dev/null
ls -l root/etc/systemd/system/dbus.*
```
Expected: 三个软链均指向 `/dev/null`。

- [ ] **Step 3: 创建 enable 软链（本仓库自带，构建期不跑 systemctl）**

```bash
cd root/etc/systemd/system/multi-user.target.wants
for u in selkies-container-env selkies-init-adduser selkies-init-envfile \
         selkies-init-device-perms selkies-init-os-end selkies-init-selkies \
         selkies-init-nginx selkies-init-selkies-config selkies-init-video \
         selkies-init-selkies-end selkies-init-config selkies-init-config-end \
         selkies-init-custom-files selkies-init-services selkies-root-password \
         selkies-xorg selkies-pulseaudio selkies-nginx selkies-dbus \
         selkies-selkies selkies-de selkies-xsettingsd selkies-watchdog; do
  ln -sf "../${u}.service" "${u}.service"
done
ln -sf "/lib/systemd/system/ssh.service" ssh.service
ln -sf "/lib/systemd/system/docker.service" docker.service
cd - >/dev/null
```

- [ ] **Step 4: 校验软链**

```bash
find root/etc/systemd/system/multi-user.target.wants -type l | sort
echo "--- broken links (should be empty except absolute system units not on host) ---"
find root/etc/systemd/system/multi-user.target.wants -type l ! -exec test -e {} \; -print \
  | grep -v -E "ssh.service|docker.service" || echo "NO-BROKEN-RELATIVE-LINKS"
```
Expected: 列出 25 个软链；`NO-BROKEN-RELATIVE-LINKS`（`ssh.service` / `docker.service` 指向宿主不存在的 `/lib/systemd/system/...`，属预期）。

- [ ] **Step 5: 校验每个启用单元都有对应文件**

```bash
cd root/etc/systemd/system
for l in multi-user.target.wants/selkies-*.service; do
  t=$(basename "$l"); [ -f "$t" ] || echo "MISSING: $t"
done
echo "ENABLE-CHECK-DONE"
cd - >/dev/null
```
Expected: 只打印 `ENABLE-CHECK-DONE`，无 `MISSING`。

- [ ] **Step 6: 提交**

```bash
git add root/etc/systemd/system/docker.service.d/container.conf \
        root/etc/ssh/sshd_config.d/10-selkies.conf \
        root/etc/systemd/system/dbus.service \
        root/etc/systemd/system/dbus.socket \
        root/etc/systemd/system/dbus-broker.service \
        root/etc/systemd/system/multi-user.target.wants
git commit -m "systemd: 增加 docker/sshd 配置、dbus mask 与 enable 软链"
```

---

## Task 5: 改造 Dockerfile

**Files:**
- Modify: `Dockerfile`（整体重写）

- [ ] **Step 1: 重写 Dockerfile**

用以下内容整体替换 `Dockerfile`：

```dockerfile
# syntax=docker/dockerfile:1
#
# Minimal Selkies environment running xeyes, with real systemd as PID 1.
# s6-overlay is kept in the image only as a library (its helpers/scripts are
# reused by systemd units); it is no longer the init process.
# x86_64 only by design (no aarch64).

FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie

# set version label
ARG BUILD_DATE
ARG VERSION
LABEL build_version="version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="jcleng"

# title + default application started by the session
# APP: command (with arguments) launched in the desktop session, override at runtime.
# container=docker: standard hint for systemd inside a container.
ENV TITLE=xeyes \
    PIXELFLUX_WAYLAND=true \
    APP=xeyes \
    container=docker

RUN \
  echo "**** add icon ****" && \
  { curl -fsSL -o /usr/share/selkies/www/icon.png \
      https://raw.githubusercontent.com/linuxserver/docker-templates/master/linuxserver.io/img/selkies-logo.png || \
    :; } && \
  echo "**** install packages ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    x11-apps \
    xterm \
    systemd \
    systemd-sysv \
    openssh-server \
    docker-compose-plugin \
    ca-certificates \
    curl \
    wget \
    unzip \
    zstd \
    tar && \
  echo "**** avoid socket-vs-service conflicts ****" && \
  rm -f /etc/systemd/system/sockets.target.wants/ssh.socket \
        /etc/systemd/system/sockets.target.wants/docker.socket && \
  echo "**** allow services to run under systemd (drop the docker guards) ****" && \
  dpkg-divert --local --rename --remove /sbin/initctl || true && \
  rm -f /usr/sbin/policy-rc.d /sbin/initctl && \
  echo "**** cleanup ****" && \
  apt-get autoclean && \
  rm -rf \
    /config/.cache \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/*

# add local files (systemd units, helper scripts, sshd/docker config)
COPY /root /

# make helper scripts executable regardless of checkout file modes
RUN chmod +x /usr/local/bin/selkies-container-env /usr/local/bin/selkies-root-password

# ports and volumes
EXPOSE 3001

VOLUME /config

# stop systemd gracefully on `docker stop`
STOPSIGNAL SIGRTMIN+3

# systemd as PID 1
ENTRYPOINT ["/sbin/init"]
CMD ["--system", "--unit=multi-user.target"]
```

- [ ] **Step 2: 校验 Dockerfile 语法（dry-run 解析）**

```bash
docker build --check . 2>&1 | tail -20 || true
```
Expected: 无 `ERROR` 行（若当前 docker 不支持 `--check`，命令报未知参数，忽略即可，靠 Step 3 构建验证）。

- [ ] **Step 3: 提交**

```bash
git add Dockerfile
git commit -m "Dockerfile: 改用 systemd 作为 PID 1，安装 systemd/sshd/运维工具并移除 docker 守卫"
```

---

## Task 6: 构建镜像并做静态/运行前检查

**Files:** 无（验证任务）

- [ ] **Step 1: 清理构建缓存（磁盘紧张）**

```bash
docker builder prune -af
df -h / | tail -1
```
Expected: 释放若干空间，剩余可用空间增大。

- [ ] **Step 2: 构建**

```bash
docker build -t selkies-base-systemd:dev . 2>&1 | tail -40
```
Expected: 结束于 `naming to docker.io/library/selkies-base-systemd:dev`（无 ERROR）。
若 `apt-get install systemd` 因 maintainer 脚本失败，记录完整错误再处理（不要盲目加 `|| true`）。

- [ ] **Step 3: 确认镜像内的关键前提（不启动容器）**

```bash
docker run --rm --entrypoint /bin/bash selkies-base-systemd:dev -lc '
  echo "== entrypoint cmd =="; 
  ls -l /sbin/init;
  echo "== s6 helpers =="; 
  command -v with-contenv s6-setuidgid /command/with-contenv;
  echo "== base scripts =="; 
  ls /etc/s6-overlay/s6-rc.d/svc-selkies/run /etc/s6-overlay/s6-rc.d/init-nginx/up;
  echo "== guards removed =="; 
  ls -l /usr/sbin/policy-rc.d /sbin/initctl 2>&1;
  echo "== units present =="; 
  ls /etc/systemd/system/selkies-*.service | wc -l;
  echo "== enabled =="; 
  ls /etc/systemd/system/multi-user.target.wants/ | sort
'
```
Expected:
- `/sbin/init` 存在且指向 systemd；
- `with-contenv`、`s6-setuidgid`、`/command/with-contenv` 均可找到；
- 两个底包脚本存在；
- `policy-rc.d` / `initctl` 均 `No such file`；
- 单元数 ≥ 23；
- `multi-user.target.wants` 列出全部 selkies 单元 + ssh + docker。

- [ ] **Step 4: 提交（如有因构建失败产生的修复）**

若无改动，跳过。若有修复：
```bash
git add -A
git commit -m "systemd: 构建阶段修复"
```

---

## Task 7: 运行时端到端验证

**Files:** 无（验证任务）

- [ ] **Step 1: 全新 /config 启动容器**

```bash
docker rm -f selkies-sd 2>/dev/null
mkdir -p /tmp/opencode/sd-config && rm -rf /tmp/opencode/sd-config/*
docker run -d --name selkies-sd \
  --privileged \
  --tmpfs /run --tmpfs /tmp \
  --shm-size=1gb \
  -p 3001:3001 \
  -v /tmp/opencode/sd-config:/config \
  selkies-base-systemd:dev
sleep 20
docker ps --filter name=selkies-sd --format '{{.Status}}'
```
Expected: 状态为 `Up ...`（不退出）。

- [ ] **Step 2: 断言 systemd 在跑**

```bash
docker exec selkies-sd systemctl is-system-running
docker exec selkies-sd systemctl --failed --no-legend
```
Expected: `running`（或 `degraded`）；`--failed` 列表为空或仅少量非关键单元（逐条判断，必要时记录并在 §5.9 的 mask 清单里处理）。

- [ ] **Step 3: 断言 Selkies 服务与 ssh/docker 均 active**

```bash
docker exec selkies-sd systemctl is-active \
  selkies-xorg selkies-pulseaudio selkies-nginx selkies-dbus \
  selkies-selkies selkies-de selkies-xsettingsd selkies-watchdog \
  ssh docker
```
Expected: 每个都输出 `active`。特别注意 `selkies-selkies` 与 `selkies-de` 必须 `active`。

- [ ] **Step 4: 断言 nginx 监听 3001 且页面可达**

```bash
docker exec selkies-sd bash -lc 'ss -lntp | grep -E ":(3000|3001)" || true'
docker exec selkies-sd bash -lc 'curl -ksS -o /dev/null -w "%{http_code}\n" https://localhost:3001/'
```
Expected: 有 3000/3001 监听；HTTP 200。

- [ ] **Step 5: 断言 /defaults 首次复制到 /config 生效**

```bash
ls -l /tmp/opencode/sd-config/.config/labwc/autostart /tmp/opencode/sd-config/.config/labwc/menu.xml
grep -n "APP\|xeyes" /tmp/opencode/sd-config/.config/labwc/autostart
```
Expected: 两个文件存在；autostart 内容含 xeyes（来自 `/defaults/autostart_wayland`）。

- [ ] **Step 6: 断言容器内 docker 可用（privileged）**

```bash
docker exec selkies-sd systemctl is-active docker
docker exec selkies-sd docker info --format '{{.ServerVersion}}'
```
Expected: `active`；打印 dockerd 版本号。

- [ ] **Step 7: 断言能切换默认软件（APP=xterm）**

```bash
docker rm -f selkies-sd-x 2>/dev/null
docker run -d --name selkies-sd-x --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb \
  -p 3002:3001 -e APP=xterm -v /tmp/opencode/sd-config-x:/config selkies-base-systemd:dev
sleep 20
docker exec selkies-sd-x systemctl is-active selkies-de
docker exec selkies-sd-x bash -lc 'pgrep -a -u abc xterm | head'
```
Expected: `active`；能列出 xterm 进程。

- [ ] **Step 8: 断言 X11 模式可用**

```bash
docker rm -f selkies-sd-x11 2>/dev/null
docker run -d --name selkies-sd-x11 --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb \
  -p 3003:3001 -e PIXELFLUX_WAYLAND=false -v /tmp/opencode/sd-config-x11:/config selkies-base-systemd:dev
sleep 20
docker exec selkies-sd-x11 systemctl is-active selkies-xorg selkies-de selkies-xsettingsd
docker exec selkies-sd-x11 bash -lc 'pgrep -a Xvfb | head'
```
Expected: `active`；能列出 Xvfb 进程。

- [ ] **Step 9: 断言 journal 无致命错误**

```bash
docker exec selkies-sd journalctl -b -p err --no-pager | tail -30
```
Expected: 无致命错误；若有，逐条判断是否为容器内 systemd 的常见无害告警。

- [ ] **Step 10: 清理验证容器**

```bash
docker rm -f selkies-sd selkies-sd-x selkies-sd-x11 2>/dev/null
echo done
```

---

## Task 8: 更新文档（README / AGENTS）

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: 更新 README 的运行说明与 compose 示例**

在 `README.md` 中：
- 新增"本镜像以 systemd 作为 PID 1"的说明；
- 把运行命令改为（`--privileged` + `--tmpfs /run --tmpfs /tmp`）：
  ```bash
  docker run -d --privileged --tmpfs /run --tmpfs /tmp --shm-size=1gb \
    -p 3001:3001 -v ./config:/config \
    registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest
  ```
- 给出非 privileged 的最小组合（容器内 docker 不可用）：
  `--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp`
- 新增 `ROOT_PASSWORD`（sshd）与"容器内可安装宝塔/1Panel"的说明；
- 更新 docker-compose 示例（加 `privileged: true`、`tmpfs: [/run, /tmp]`、去掉不再需要的项）。

- [ ] **Step 2: 更新 AGENTS.md 的入口/服务/构建章节**

在 `AGENTS.md` 中：
- §1/§3：说明 PID 1 已从 s6-overlay 换成 systemd，`ENTRYPOINT /sbin/init`、`STOPSIGNAL SIGRTMIN+3`；
- §3：新增"systemd 服务清单"小节，列出 §5.3/§5.4 的单元表与"复用底包 `/etc/s6-overlay/s6-rc.d/*` 脚本 + `/run/s6/container_environment` 桥接"的机制；
- §3：把 `APP`/`APP_CLI` 的说明从 "autostart" 更新为仍在 autostart 内展开（行为不变），补充运行参数要求；
- §4：更新本地运行命令（加 `--privileged --tmpfs`）；
- §7：新增"用户明确要求 systemd 化"作为对 §7 原有"不引入额外组件"的说明例外；记录 `DOCKER_MODS`/`HARDEN_*`/`UMASK` 不再保证。

- [ ] **Step 3: 校验文档里没有遗留旧命令**

```bash
grep -rn "docker run --rm -it --shm-size=1gb -p 3001:3001" README.md AGENTS.md || echo "NO-STALE-RUN-COMMAND"
```
Expected: `NO-STALE-RUN-COMMAND`（旧命令已替换）。

- [ ] **Step 4: 提交**

```bash
git add README.md AGENTS.md
git commit -m "文档: 同步 systemd 化后的运行方式、服务清单与环境变量"
```

---

## Task 9: 收尾（推送与 CI 构建）

**Files:** 无

- [ ] **Step 1: 确认全部改动已提交且工作区干净**

```bash
git status --short
git log --oneline -8
```
Expected: `git status` 无输出；日志含本计划各任务的中文提交。

- [ ] **Step 2: 推送 main**

```bash
git push origin main
```
Expected: 推送成功。

- [ ] **Step 3: 触发镜像构建（需用户确认后执行）**

```bash
gh workflow run build-repo.yml --repo jcleng/action-sync-images \
  -f arg_repo_url=https://github.com/jcleng/selkies-base.git \
  -f arg_branch_name=main \
  -f arg_username=gitbuild \
  -f arg_name=selkies-base \
  -f arg_aliyunurl=registry.cn-hangzhou.aliyuncs.com \
  -f arg_aliyunuser=jcleng

gh run list --repo jcleng/action-sync-images --workflow build-repo.yml --limit 3
```
Expected: 新 run 出现；`gh run watch <run-id> --repo jcleng/action-sync-images` 至 success。

- [ ] **Step 4: 记录构建结果**

在 `AGENTS.md` §5 的"已执行的构建记录"表追加新的 Run ID / 时间 / digest。

```bash
git add AGENTS.md
git commit -m "文档: 记录 systemd 版镜像的构建 Run ID 与 digest"
```

---

## 自检（Self-Review）

**Spec 覆盖检查：**
- §5.1 镜像与入口 → Task 5（ENTRYPOINT/CMD/STOPSIGNAL/ENV container）。
- §5.2 环境桥接 → Task 1（脚本 + 单元）。
- §5.3 初始化链 13 个 oneshot → Task 2。
- §5.4 常驻服务 8 个 → Task 3。
- §5.5 容器内 Docker 原生 service + drop-in → Task 4（Step 1）+ Task 7（Step 6）。
- §5.6 sshd + ROOT_PASSWORD → Task 1（脚本/单元）+ Task 4（Step 2）+ Task 7（Step 3）。
- §5.7 运行时参数 → Task 7（启动命令）+ Task 8（文档）。
- §5.8 文件布局 → 所有 Create 路径一致。
- §5.9 单元裁剪 → Task 7 Step 2 的 `--failed` 判定。
- §6 验证计划 → Task 7 覆盖第 1-9 条；第 10 条 → Task 9。
- §7 特性取舍 → Task 8 Step 2（AGENTS §7 记录）。
- §3.2 反-systemd 守卫清理 → Task 5（`dpkg-divert --remove` + `rm policy-rc.d`）。

**占位符扫描：** 无 TBD/TODO；每个文件均给出完整内容。

**类型/命名一致性：** 单元名在 Task 1-4 定义，Task 5-8 引用一致；脚本路径统一为
`/etc/s6-overlay/s6-rc.d/<name>/{run,up}`；helper 路径统一为 `/usr/local/bin/selkies-*`。

**已知取舍（写进实现，不阻塞）：**
- 标记单元用 `/bin/true` 而非执行底包空 `up` 脚本（等价且更明确）。
- enable 用随镜像软链而非构建期 `systemctl enable`（构建期无 systemd）。
- `UMASK` 不生效，统一 `UMask=0022`（spec §7 已声明放弃）。
