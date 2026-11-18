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

## 安装

插件市场索引里点「安装」，或直接：

```sh
dsh plugin add dsh-sanming-pet
```

指定版本：

```sh
dsh plugin add dsh-sanming-pet@1.9.0
```

装完重启当前 profile 的 DSH 实例即可，侧边栏会出现「三明文旅乐园」入口，设置页会多一项同名配置。

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
3. `/data/dsh-users/<uid>/.dsh/sanming-pet`
4. `$HOME/.dsh/sanming-pet`

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

本包内的三明文旅 IP 形象、手绘地图与景区图片素材，版权归权利人所有，随本插件在 DSH 内使用；**未经授权不得单独提取、二次分发或用于商业用途**。代码部分可自行修改以适配本地部署。
