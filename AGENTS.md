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
| 默认启动 | `xeyes`（可用环境变量切换为任意软件） |
| 访问端口 | `3001`（HTTPS，自签名证书） |
| 持久化卷 | `/config` |
| Dockerfile 参考 | https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile |

目标：给出一个能跑起来、结构最小、可作为其它 Selkies 应用镜像起点的样板；不追求功能完整，
不引入 Selkies Desktop / Pelorus / 浏览器等额外组件。

## 2. 目录结构

```
.
├── AGENTS.md                       # 本文件
├── Dockerfile                      # 镜像定义（仅 amd64）
├── README.md                       # 面向用户的使用说明
├── .dockerignore                   # 排除 .git / config / *.log
└── root/                           # 构建上下文根，整体 COPY 到镜像 /
    └── defaults/
        ├── autostart               # X11(Openbox) 会话启动命令
        ├── autostart_wayland       # Wayland(labwc) 会话启动命令
        ├── menu.xml                # X11 右键菜单
        └── menu_wayland.xml        # Wayland 右键菜单
```

`root/` 下的路径与镜像内路径一一对应（`COPY /root /`）。基础镜像在首次运行时把
`/defaults/autostart*`、`/defaults/menu*.xml` 复制到 `/config/.config/{labwc,openbox}/`，
之后以用户副本为准。

## 3. Dockerfile 说明

- 首行 `# syntax=docker/dockerfile:1`。
- `FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie`：amd64 基础镜像（x86_64 only）。
- `ARG BUILD_DATE` / `ARG VERSION` 仅用于 `LABEL build_version`，由 CI 注入或留空。
- 安装包：`x11-apps`（提供 `xeyes`）、`xterm`（会话内排错/恢复用），使用
  `--no-install-recommends`，结尾 `apt-get autoclean` 并清理 `/var/lib/apt/lists/*`、`/tmp/*` 等。
- 图标：下载 `linuxserver/docker-templates` 的 `selkies-logo.png` 覆盖
  `/usr/share/selkies/www/icon.png`（失败不阻断构建，回退为 `:`）。
- 末尾 `COPY /root /`、`EXPOSE 3001`、`VOLUME /config`。
- **不要**添加 `Dockerfile.aarch64`，本项目有意只支持 amd64。

### 环境变量

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `APP` | `xeyes` | 会话中启动的命令（可含参数），这是「用环境变量控制默认启动软件」的开关 |
| `APP_CLI` | 空 | 追加到 `APP` 之后的参数 |
| `TITLE` | `xeyes` | 浏览器标签标题 |
| `PIXELFLUX_WAYLAND` | `true` | `true`=labwc/Wayland 会话；`false`=Openbox/X11 会话 |

`APP` / `APP_CLI` 在 `root/defaults/autostart` 与 `root/defaults/autostart_wayland` 中展开：

```bash
if [ -z "${APP}" ]; then APP="xeyes"; fi
exec ${APP} ${APP_CLI}
```

基础镜像自带的 `SELKIES_*`、`HARDEN_*`、分辨率等变量同样可用，见
<https://docs.linuxserver.io/selkies/user-guide/configuration/>。

### 修改 autostart / menu 的注意事项

这些文件**只在首次运行时**复制到 `/config`。改了镜像内的默认文件后，必须使用全新的
`/config`（新卷或不挂载卷）才能看到效果——这是最容易踩的坑。

## 4. 本地使用（可选）

本地构建仅用于验证，**不是**本项目的发布方式（发布走第 5 节的 CI）：

```bash
docker build -t selkies-base .

docker run --rm -it --shm-size=1gb -p 3001:3001 \
  -v $PWD/config:/config selkies-base
# 打开 https://localhost:3001，信任自签名证书

# 切换默认软件
docker run --rm -it --shm-size=1gb -p 3001:3001 -e APP=xterm selkies-base

# X11 会话 + 自定义参数
docker run --rm -it --shm-size=1gb -p 3001:3001 \
  -e PIXELFLUX_WAYLAND=false -e APP=xeyes -e APP_CLI="-geometry 800x600" selkies-base
```

`--shm-size=1gb` 必须给足，否则渲染/浏览器进程可能崩溃。

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

网络受限时（本机环境）为 `gh` / `curl` / `git` 加代理：
`https_proxy=http://192.168.195.18:20171`。注意该代理只对本机命令生效，
CI 在 GitHub 上运行不需要代理。

### 已执行的构建记录

| 时间(UTC) | Run ID | 结果 | 产物 |
| --- | --- | --- | --- |
| 2026-10-12T07:12:16Z | `38216442259` | success（约 3 分钟） | `registry.cn-hangzhou.aliyuncs.com/jcleng/gitbuild-selkies-base:latest`<br>digest `sha256:018cfb1fb661f2615d877b2befdd8b0bdca7a5ae29201f0daefb022c6e28f796` |

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
- 未经明确要求不要新增 aarch64 支持、不要引入 Selkies Desktop / Pelorus / 浏览器等组件，
  保持镜像最小。

## 8. 参考链接

- Selkies 文档：https://docs.linuxserver.io/selkies/
- 构建自定义镜像：https://docs.linuxserver.io/selkies/developer-guide/building-images/
- 配置参考：https://docs.linuxserver.io/selkies/user-guide/configuration/
- 基础镜像源码：https://github.com/linuxserver/docker-baseimage-selkies
- Dockerfile 参考：https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile
- 构建仓库：https://github.com/jcleng/action-sync-images
