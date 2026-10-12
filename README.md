# Selkies 运行 xeyes (Selkies Base)

一个**最小可用**的 [Selkies](https://github.com/selkies-project/selkies) 使用环境示例，基于 LinuxServer 的 Selkies 基础镜像，
默认启动 `xeyes`，并可通过环境变量切换启动的软件。

- 仅构建 `amd64`（无 `aarch64`）。
- 只安装 `x11-apps`（提供 `xeyes`）与 `xterm`（用于在会话中排错/恢复）。
- Dockerfile 结构参考 <https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile>。

## 快速开始

```bash
docker build -t selkies-base .

docker run --rm -it \
  --shm-size=1gb \
  -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=true \
  -v $PWD/config:/config \
  selkies-base
```

然后浏览器打开 <https://localhost:3001>，接受自签名证书即可看到 `xeyes` 在运行。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `APP` | `xeyes` | 会话中启动的命令（可带参数），例如 `-e APP=xterm`、`-e APP="xeyes -shape rounded"` |
| `APP_CLI` | 空 | 追加到 `APP` 之后的参数，例如 `-e APP_CLI="-geometry 800x600"` |
| `TITLE` | `xeyes` | 浏览器标签标题 |
| `PIXELFLUX_WAYLAND` | `true` | `true` 使用 labwc/Wayland 会话，`false` 回退 Openbox/X11 会话 |

基础镜像自带的其它环境变量（`SELKIES_*`、`HARDEN_*`、分辨率等）同样可用，
详见 <https://docs.linuxserver.io/selkies/user-guide/configuration/>。

### 示例

```bash
# 默认 xeyes（Wayland 会话）
docker run --rm -it --shm-size=1gb -p 3001:3001 selkies-base

# 换成 xterm
docker run --rm -it --shm-size=1gb -p 3001:3001 -e APP=xterm selkies-base

# xeyes 指定几何尺寸，并使用 X11/Openbox 会话
docker run --rm -it --shm-size=1gb -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=false \
  -e APP=xeyes -e APP_CLI="-geometry 800x600" \
  selkies-base

# 手动进入容器（不启动 Web 界面时排错）
docker run --rm -it --shm-size=1gb -p 3001:3001 selkies-base bash
```

## 目录结构

```
.
├── Dockerfile
└── root/
    └── defaults/
        ├── autostart           # X11(Openbox) 会话启动的命令
        ├── autostart_wayland   # Wayland(labwc) 会话启动的命令
        ├── menu.xml            # X11 右键菜单
        └── menu_wayland.xml    # Wayland 右键菜单
```

`/defaults/autostart*` 与 `/defaults/menu*.xml` 只会在首次运行时复制到 `/config`，
之后用户对 `/config` 中副本的修改会一直生效。改了这些文件后需要清空 `/config` 才能看到新版本。

## 说明

- 仅支持 `amd64`。
- 需要 `--shm-size=1gb`（或更大），否则浏览器/渲染进程可能崩溃。
- 端口 `3001` 为 HTTPS 自签名证书。

## 镜像体积说明

本镜像基于 `ghcr.io/linuxserver/baseimage-selkies:debiantrixie`，镜像体积较大是**Selkies 底包本身决定的**，不是 `xeyes` 或本仓库 `Dockerfile` 的问题。

### 实测大小

| 项目 | 值 |
| --- | --- |
| `docker images` 显示（含层压缩） | `~3.95 GB`（`registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`） |
| 解压后实际占用（`du -xsh /`） | `~2.8 GB` |
| 本项目新增内容 | 主要为 `x11-apps`（`xeyes`）与 `xterm`，约数十 MB |

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
