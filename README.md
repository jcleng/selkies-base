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
