# 三明文旅乐园（dsh-sanming-pet）

给 DSH 用的三明文旅主题桌宠插件：三只 3D 手办质感的吉祥物（明奇奇 / 明灵灵 / 明宝宝），配手绘三明地图巡游、打卡印章、成就、皮肤、相册、漫游引导，以及一只常驻悬浮桌宠。

## 功能

- **三只宠物、逐帧动作**：待机、行走、挥手、鼓掌、跳、翻滚、抱抱、欢呼等，512×512 透明序列帧，CSS 逐帧播放
- **手绘地图巡游**：以三明手绘地图为背景，宠物在三元、沙县、永安、尤溪、大田、明溪、清流、宁化、建宁、泰宁、将乐 11 个区县间行走
- **景区与特产**：各区县景区、特产、美食图文详情，点击放大
- **打卡 / 成就 / 皮肤 / 相册**：打卡印章、成就解锁、皮肤商店、打卡相册、漫游引导
- **悬浮桌宠**：可拖拽、点击对话、尺寸与位置可调、3D 序列帧与矢量骨架两种形态切换
- **知识库问答**：内置三明本地底稿检索，命中不到时可按配置走联网兜底；也可在设置页接自己的 MCP 知识库
- **设置页**：宠物选择、尺寸、边距、MCP 连接管理（URL / Token / 知识库 ID / 超时）

## 安装（二选一）

两种用法互相独立，按你手上有什么选一种就行：

- **要接进 DSH**（侧边栏「三明文旅乐园」+ 悬浮桌宠 + 知识库）：装 DSH 插件 → 方式 A
- **只想在 Windows 桌面上养一只**（不装 DSH，双击就装）：用桌面版安装包 → 方式 B

### 方式 A：装成 DSH 插件

插件市场索引里点「安装」，或直接用仓库 tag 源安装（不需要 npm 账号、不需要发布过 npm 包）：

```sh
dsh plugin add git+https://github.com/lin7397100/dsh-sanming-pet.git#1.9.20
```

锁定到某个 commit（最严格）：把 `#1.9.20` 换成 `#<40 位 commit SHA>`，当前 release 指向的 SHA 见仓库 tag 页：

```sh
dsh plugin add git+https://github.com/lin7397100/dsh-sanming-pet.git#<commit-sha>
```

离线 / 内网 / 需要校验哈希时，下载 `dsh-sanming-pet-1.9.20.tgz` 后本地安装：

```sh
dsh plugin add file:/绝对路径/dsh-sanming-pet-1.9.20.tgz
```

> 1.9.20 是插件侧的正式版本号，与桌面版 exe 的 1.9.x 编号各自独立。`1.9.0` 是早期草稿，包内 `repository` / `homepage` / `bugs` 三处仍是占位用户名，**请勿再引用或安装**。

装完重启当前 profile 的 DSH 实例即可，侧边栏会出现「三明文旅乐园」入口，设置页会多一项同名配置。

### 方式 B：Windows 桌面版（单个 exe，双击即装）

不用装 DSH、不用管 Node，下载一个 exe 双击就能用：

**[下载 SanmingPet-Setup-1.9.20.exe](dist/SanmingPet-Setup-1.9.20.exe)**（约 38 MB）

1. 双击 `SanmingPet-Setup-1.9.20.exe`
2. 点「立即安装」，默认装到 `%LOCALAPPDATA%\SanmingPetOverlay`，想换位置点「更改…」
3. 勾上「开机自动启动」，登录后会自动贴上桌宠
4. 装完桌面多一个「三明文宠」快捷方式（图标是明奇奇的头像，不是 PowerShell 蓝底图标），双击启动；开始菜单里也有一份（关掉之后从开始菜单还能搜到）；`Ctrl+Alt+K` 打开本地知识库

安装包做的事：解包 141 个文件到目标目录 → 建桌面 + 开始菜单（以及可选的开机自启）快捷方式 → 在「设置 → 应用」里登记一条卸载项 → 拉起浮窗。

**关掉 / 再打开 / 卸载是三件事**：

| 你想要 | 怎么做 |
|---|---|
| 今天不想看见它 | 点宠物 → 设置面板右下角「关闭浮窗」→ 进程直接结束，桌面上干净，任务栏不留托盘图标 |
| 再打开 | 双击桌面「三明文宠」，或在开始菜单搜「三明文宠」 |
| 开机不想让它自己冒出来 | 删 `shell:startup` 里的「三明文宠.lnk」，或重装时不勾「开机自动启动」 |
| 彻底不要了 | 再跑一次这个 exe 加 `/uninstall`（或在「设置 → 应用」里找到「三明文宠」点卸载） |

> 关掉只是结束进程：绑过的文件夹、模型设置、宠物位置都存在 `data\` 里，下次打开原样恢复。
> 双击两次不会叠出两只宠物——脚本带单实例锁，第二次启动会自己退出。

命令行静默安装（批量分发用）：

```sh
SanmingPet-Setup-1.9.20.exe -silent -autostart
SanmingPet-Setup-1.9.20.exe -silent -nolaunch -target "D:\Tools\SanmingPet"
```

浮窗运行时会优先找 PowerShell 7（`pwsh`：scoop / Program Files / PATH），找不到才退回系统自带的 Windows PowerShell。想让界面和检索都稳，建议先装 [PowerShell 7](https://github.com/PowerShell/PowerShell/releases)。

校验值：

```
SHA256  06DDF4DB3A541D5135D0776A307A2FF9606B45E2BE9DFD3E274995D8B5C87CA3
MD5     B85E79C4BABAE8C924AB21CE8D30F61D
```

> 桌面版 1.9.20：修了两处。一是知识库答案卡里的 markdown 表格（`| 序号 | 姓名 | …`）现在渲染成真表格（表头底色、细边框、按列宽、`:---:` 对齐、`<br>` 换行），原文片段卡也不再显示竖线和 `| --- |`；二是安装器在 SAG 检索服务占用 `tools\sag\sag.exe` 时会卡在 robocopy 默认「重试一百万次」上——现在安装前先停掉 sag 进程，并改用 `/R:2 /W:2`。
>
> 桌面版 1.9.19：在 1.9.18（快捷方式改名「三明文宠」、图标换成明奇奇头像）基础上，修了安装器三处、卸载残留与知识库中文乱码（`assets/icon/sanmingpet.ico`，6 个尺寸），不再是 PowerShell 的蓝底图标；卸载项、安装器标题也同步改名。
>
> 1.9.19 起：平台运维类问答整体移出发布包 —— 原来那份内部排障资料带着部署细节与运维命令，不适合对外分发；问答只剩三元区深度库 → 三明十景区 → 联网兜底。同版修掉了中文绑定目录在知识库面板里显示乱码的问题。1.9.17 加了「关闭浮窗」按钮、开始菜单入口与单实例锁；1.9.16 是知识库面板美化（绑定按钮、文件夹列表）。
>
> 插件版 1.9.20：只修发布元数据与授权说明，功能、素材、检索逻辑与 1.9.19 完全一致。移除 1.9.0 遗留的占位用户名，新增 `NOTICE.md` 明确「代码 MIT / 素材另授」的分发条件，README 安装指引改成可公开核验的 git tag 源。
>
> 安装包没有做代码签名（个人项目没有证书），第一次运行时 Windows 可能弹「SmartScreen 已阻止」：点「更多信息」→「仍要运行」即可。介意的话可以直接用方式 A，或用下面的命令行静默安装。

## 配置

`cordis.patch.yml` 里只有一个可选项：

```yaml
- insert:
    - id: sanming-pet
      name: dsh-sanming-pet
      config:
        dataDir: ""
```

`dataDir` 留空时按顺序尝试：

1. `$SANMING_PET_DIR`
2. `$DSH_HOME/sanming-pet`
3. `$HOME/.dsh/sanming-pet`

打卡记录、穿戴皮肤、相册索引都落在该目录的 `state.json`，原子写入。

## 接口

宿主侧挂在 DSH 同源 API 下，前缀 `/api/sanming-pet`：

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/scenes` | 景区 / 皮肤 / 成就静态数据 |
| GET | `/state` | 读档：打卡记录、时间戳、穿戴皮肤 |
| POST | `/checkin` | 打卡（幂等） |
| POST | `/skin` | 穿戴 / 解锁皮肤 |
| POST | `/reset` | 重置存档 |
| POST | `/chat` | 知识库路由问答 |
| GET | `/mcp-config` | 读 MCP 连接配置 |
| POST | `/mcp-config-save` | 写 MCP 连接配置 |
| POST | `/mcp-test` | 测试 MCP 连通性 |

## 兼容性

- `engines.dsh >= 0.2.0-rc.2`
- 仅宿主半使用 Node 内置模块，无第三方依赖
- 前端注入依赖 `@deepseek-ai/dsh-client-ui-sidebar`

## 授权

**代码 MIT；素材另有条件**，两者不可混用：

- 代码（`lib/*.js`、`cordis.patch.yml`）：MIT，见 [LICENSE](LICENSE)。
- 素材（`lib/assets/**` 共 151 个文件：三只宠物全部动作帧、手绘三明地图、11 区县景区/特产/美食图、图标皮肤、知识库底稿）：著作权归作者所有，**允许随完整插件包安装、缓存、镜像与在 DSH 界面内展示**；**不允许单独提取、二次分发、用于模型训练或商业使用**。

完整条款、再分发义务与商业授权联系方式见 [NOTICE.md](NOTICE.md)。
