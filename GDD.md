# SDG-Lab — 游戏设计文档 & 开发路线图

> 版本 v0.2 · 2026-04-21 · 起草 Claude / 确认 f.shera
>
> 本文档是对现有 Unity 项目 `GeoModelTest` 的重构规划。目标:用 **Swift + RealityKit** 重新实现,部署到 iPad/iOS,开源发行。
>
> **项目名 SDG-Lab 的多重含义**:
> - 剧情上:**S**endai **D**r.Kaede's **G**eography Lab(剧中的秘密地质研究机构)
> - 国际上:呼应联合国 **S**endai Framework for **D**isaster Risk Reduction(2015 年仙台通过的国际减灾框架)
> - 教育上:呼应联合国 **S**ustainable **D**evelopment **G**oals(尤其 Goal 11 可持续城市 + Goal 13 气候行动)

---

## 目录

- [0. 项目概览](#0-项目概览)
- [1. 游戏设计](#1-游戏设计)
- [2. 技术架构](#2-技术架构)
- [3. 系统清单(保留 / 新增 / 删除)](#3-系统清单)
- [4. 开发路线图](#4-开发路线图)
- [5. 资产清单](#5-资产清单)
- [6. Meshy.ai 集成工作流](#6-meshyai-集成工作流)
- [7. PLATEAU 数据管线](#7-plateau-数据管线)
- [8. 风险清单 & 预案](#8-风险清单--预案)
- [9. 待决事项](#9-待决事项)

---

## 0. 项目概览

| 项 | 决策 |
|---|---|
| **项目名** | **SDG-Lab**(三重语义:剧情 G-Lab + 仙台减灾框架 + 可持续发展目标) |
| **类型** | 3D 地质教学 / 轻度剧情冒险 |
| **目标受众** | 日本中学生(可扩展至高中/大学通识) |
| **单次游玩时长** | 约 1 小时 |
| **平台** | iPadOS / iOS 18.0+(iPad 优先) |
| **技术栈** | Swift + RealityKit + SwiftUI |
| **美术风格** | Toon Shader(二次元卡通,参考:原神、塞尔达 BotW) |
| **地理舞台** | 仙台市青葉区走廊:东北学院大学 → 広瀬川 → 青葉城跡 → 東北大川内 → 東北大青葉山(~5 km) |
| **语言** | 日本語(主)、English、简体中文 |
| **发行** | App Store 免费;开源仓库(MIT) |
| **团队** | Solo(开发者:f.shera) |
| **上游数据** | PLATEAU 仙台 2024(CityGML),Meshy.ai Studio(角色/道具),研究室薄片照片 |

### 游戏一句话定位

> *"中学生被卷入仙台山体滑坡事件,加入秘密地质研究机构 G-Lab,用真实仙台城市和地层数据,边玩边学地质、边追查一个跨越年代的地质异常。"*

---

## 1. 游戏设计

### 1.1 愿景

**"把中学生的通学路变成地质学教科书。"**

让玩家认出身边的街道和山——东北学院大学的校门、広瀬川的桥、青葉城跡的石垣、青葉山露头——然后在这些真实地点上,通过钻探和采样,理解脚下的岩层、断层、灾害风险。

### 1.2 故事(第一章)

**来源**:延续 Unity 项目 `StorySummary.md`。

**主线**:
- 主角(中学生,性别可选)野外课遭遇山体滑坡,发现层次清晰的异常岩石
- 研究员 **Dr. Kaede** 和 G-Lab 介入,邀请主角加入调查
- 首次任务:采集仙台地层样本 → 薄片分析 → 发现仙台地层中存在"不该存在的物质"
- Kaede 断定:此物质可能是仙台地层脆化的元凶
- 扩展调查:跨越走廊的多地点采样 → 发现灾害风险关联
- 高潮:**地震/洪水事件**爆发,玩家用学到的知识理解为什么此地发生

**角色**:
| 角色 | 身份 | 作用 |
|---|---|---|
| 主角(プレイヤー) | 中学生,性别可选 | 玩家化身 |
| Dr. Kaede(カエデ) | G-Lab 地质灾害预测班研究员 | 教学/指示 NPC |
| 教師 | 野外课引率 | 开场引入 |
| 研究员 A | G-Lab 通信担当 | 中后期出场 |
| 路人 NPC | 校园/街道氛围 | 环境点缀 |

### 1.3 玩法核心

#### 核心循环

```
移动探索 → 定位地质露头 → 使用工具(锤/钻/钻塔)采样
  → 返回 G-Lab 工作台/显微镜分析
  → 薄片教学(真实仙台地层)
  → 图鉴解锁 → 剧情推进 → 新任务
```

#### 五种工具

| 工具 | 来源 | 用途 |
|---|---|---|
| 地质ハンマー | 原项目 HammerTool | 采集表层薄片样本 |
| シンプルドリル | 原项目 BoringTool | 2m 深钻探,单点采样 |
| 钻塔 | 原项目 DrillTowerTool | 0-10m 多深度采样(5 次循环) |
| 无人机 | 原项目 DroneController | 空中探索,到达步行不便地点 |
| 钻车 | 原项目 DrillCarController | 地面载具,移动钻探站 |

#### 地层呈现机制(简化版,去 CSG)

继承原项目 [DrillingCylinderGenerator.cs:107](../Unity/GeoModelTest/Assets/Scripts/GeologySystem/SimplifiedDetection/DrillingCylinderGenerator.cs#L107) 的算法:

```
钻点上方 raycast 向下 → 命中每个地层 mesh,记录 entry/exit Y 坐标
→ 计算每层厚度
→ 程序化生成堆叠圆柱 mesh(每段对应一层)
→ 材质复用原地层的 PBR material(Toon shader 重着色)
```

**RealityKit 对应 API**:`scene.raycast()` + `MeshResource.generate(from: MeshDescriptor)` + 自定义 `PhysicallyBasedMaterial`(带 Toon 修改)。

### 1.4 关卡结构(1 小时游玩路径)

| 时段 | 地点 | 剧情节点 | 玩法 |
|---|---|---|---|
| **0–10 min**| 青葉山露头(东北大) | 开场滑坡,偶遇 G-Lab | 简单走路,第一次通讯对话 |
| **10–25 min**| G-Lab 研究室(秘密基地) | Kaede 首次教学,发工具 | 工具说明,第一次采样 → 工作台分析 |
| **25–45 min**| 青叶区走廊 3 个露头 | 主任务:跨校区采样 | 钻探,显微镜薄片观察,图鉴解锁 |
| **45–55 min**| G-Lab 研究室 | 数据汇总,发现异常关联 | 对话,报告填写(A/B/C 评价) |
| **55–60 min**| 走廊某点(广瀬川/青叶山) | **地震 or 洪水事件爆发** | 受灾可视化,用知识理解灾害 |
| 尾声 | G-Lab | 第一章结束,暗示第二章 | 存档,图鉴成就展示 |

### 1.5 UX 流程

#### 主 HUD(横屏限定,iPad/iPhone 均横屏)

```
┌─────────────────────────────────────────────┐
│ [任务摘要]                      [语言][设置] │
│                                              │
│                                              │
│              (3D 主场景视口)                  │
│                                              │
│                                              │
│ [移动摇杆]   [工具轮盘]         [动作按钮]  │
└─────────────────────────────────────────────┘
```

- **左下**:虚拟摇杆(保留原 MobileSystem 设计)
- **右下**:情境动作按钮(采样 / 对话 / 进入载具 / 查看)
- **下中**:Tab / 长按 呼出工具轮盘(原项目 InventoryUISystem 样式)
- **上**:任务、语言、设置
- **Apple Pencil**:显微镜模式下可在薄片上"圈注"(教学扩展)

#### 关键界面

| 界面 | 形态 | 技术 |
|---|---|---|
| 对话框 | 底部文字框 + 立绘 | SwiftUI overlay |
| 工具轮盘 | 8 槽圆盘,点击选择 | SwiftUI Canvas + SpringAnimation |
| 显微镜 | 全屏照片查看器 + 缩放 | SwiftUI + `Image` + `MagnificationGesture` |
| 图鉴 | 左列表 + 右 3D 视口 | SwiftUI NavigationSplitView + RealityView |
| 设置 | 标准 Form(语言/音量/关于) | SwiftUI Form |
| 报告/评价 | 选择题 + 简答 | SwiftUI Form |

---

## 2. 技术架构

### 2.1 技术栈

| 层 | 技术 |
|---|---|
| **语言** | Swift 5.10+ |
| **3D 渲染** | RealityKit(主)+ Metal(自定义 Toon Shader) |
| **UI** | SwiftUI,`@Observable` 宏 |
| **3D 场景工具** | Reality Composer Pro(材质/实体合成) |
| **物理** | RealityKit `PhysicsBodyComponent` |
| **输入** | SwiftUI gestures + `GameController.framework`(手柄) |
| **音频** | AVAudioEngine / PHASE(空间音频) |
| **数据/存档** | SwiftData(结构化)+ UserDefaults(设置) |
| **多语言** | Foundation `String Catalog` (.xcstrings) |
| **资产格式** | USDZ(角色/道具),glTF 中间态,PNG/HEIC(贴图) |
| **依赖管理** | Swift Package Manager |
| **CI/CD** | Xcode Cloud(免费额度够 solo 用) |

### 2.2 目录结构(建议)

```
sendai_glab/
├── SendaiGLab.xcodeproj
├── Sources/
│   ├── App/                      # App 入口, AppDelegate, Scene
│   ├── Core/                     # ECS Components, Events, 全局服务
│   ├── Gameplay/
│   │   ├── Drilling/             # 钻探、钻塔
│   │   ├── Geology/              # 地层检测、样本生成
│   │   ├── Samples/              # 背包、薄片、图鉴数据
│   │   ├── Vehicles/             # 无人机、钻车
│   │   └── Story/                # 对话、任务、场景流程
│   ├── UI/
│   │   ├── HUD/
│   │   ├── Dialogue/
│   │   ├── Inventory/
│   │   ├── Microscope/
│   │   └── Encyclopedia/
│   ├── World/                    # 场景加载、PLATEAU 集成、地图流式
│   ├── Assets/                   # Swift 代码引用的资产 ID 定义
│   └── Platform/                 # 平台适配:iPad、iPhone、手柄
├── Resources/
│   ├── Story/                    # .json 对话脚本(移植自 Unity)
│   ├── Localization/             # .xcstrings
│   ├── Characters/               # .usdz(Meshy 产出)
│   ├── Props/                    # .usdz 道具
│   ├── Environment/              # .usdz(PLATEAU 转换产出)
│   ├── Geology/                  # 地层数据 JSON、薄片照片
│   └── Audio/
├── Tools/
│   ├── plateau-pipeline/         # shell 脚本:CityGML → glTF → USDZ
│   ├── meshy-pipeline/           # Meshy API 批量生成 + rigging 脚本
│   └── asset-validator/          # 资产一致性检查
├── Tests/
│   ├── UnitTests/
│   └── IntegrationTests/
├── Docs/
│   ├── GDD.md                    # 本文档
│   ├── ArchitectureDecisions/    # ADR 记录
│   └── AssetPipeline.md
├── .github/workflows/            # CI
└── README.md
```

### 2.3 模块架构(防屎山的关键)

原 Unity 项目的"屎山"根源:**所有逻辑塞进 MonoBehaviour,单例互相调用,事件系统薄弱**。新架构用三层隔离:

```
┌──────────────────────────────────────────┐
│    SwiftUI Views (无业务逻辑)             │  <- 只 render @Observable state
└──────────────┬───────────────────────────┘
               │ 读状态 / 发意图
┌──────────────▼───────────────────────────┐
│    Stores(@Observable 状态容器)          │  <- GameStore, StoryStore, InventoryStore...
│    接收 Intent → 更新状态 → 派发 Events   │
└──────────────┬───────────────────────────┘
               │ Events(发布/订阅)
┌──────────────▼───────────────────────────┐
│    ECS(RealityKit Entity/Component/System)│  <- 3D 世界里的一切
│    DrillingSystem, GeologyDetectionSystem │
└──────────────────────────────────────────┘
```

**关键规则**(写进 AGENTS.md / CLAUDE.md):
1. SwiftUI View **不得**直接操作 Entity,只通过 Store
2. ECS System **不得**引用 SwiftUI,只发 Event
3. Store 之间**不得**互相引用,只通过 Event 总线
4. 所有跨模块通信走 **Event**,禁止单例直接 call

### 2.4 数据流示例:一次钻探

```
[View]  用户点击"钻探"按钮
   ↓ intent: .drillAt(position)
[Store] DrillingStore 接收 → 校验位置 → 更新状态 .drilling
   ↓ publish event: DrillRequested(position, depth)
[ECS]   DrillingSystem 订阅 → 执行 raycast → 生成样本 Entity
   ↓ publish event: SampleCreated(sampleData)
[Store] InventoryStore 订阅 → 添加到背包
   ↓ @Observable 触发
[View]  背包 UI 自动刷新
```

**收益**:每一步都能单测,View 层永远只负责 render。

### 2.5 资产管线

```
[PLATEAU CityGML]
  → plateau-gis-converter(Rust CLI) → glTF (.glb)
  → Blender 批处理脚本(Toon 材质配置 + LOD 简化)
  → Reality Converter → USDZ
  → 入库 Resources/Environment/

[Meshy 生成角色/道具]
  → Meshy API(image-to-3d) → GLB(带 PBR texture)
  → Meshy Rigging API → GLB(带骨骼)
  → Meshy Animate API(Studio plan) → GLB(带动画 clip)
  → Blender 脚本(Toon 材质 override,如需要)
  → Reality Converter → USDZ
  → 入库 Resources/Characters/

[薄片照片]
  → 原始 JPG/TIFF(研究室素材)
  → ImageOptim / HEIC 压缩
  → 入库 Resources/Geology/ThinSections/
```

所有脚本放在 `Tools/`,用 Make / 简单 shell 能一键重跑。

---

## 3. 系统清单

### 3.1 ✅ 保留的系统(从原 Unity 项目继承逻辑,重写代码)

| 原 Unity 系统 | 新名 | 重写难度 | 备注 |
|---|---|---|---|
| Controllers / FirstPersonController | PlayerControlSystem | 🟡 中 | 触屏 FPS 控制 |
| GeologySystem(去 CSG) | GeologyDetectionSystem | 🟢 低 | 纯 raycast + Y 差值 |
| DrillTowerSystem | DrillTowerSystem | 🟡 中 | 多深度循环钻探 |
| Tools | ToolSystem | 🟢 低 | 5 种工具模板 |
| SampleSystem | SampleSystem | 🟡 中 | 生成、icon、浮动显示 |
| InventorySystem | InventoryStore + UI | 🟢 低 | 统一背包(合并 Warehouse) |
| StorySystem | DialogueSystem | 🟢 低 | JSON → Codable |
| QuestSystem | QuestStore | 🟢 低 | PlayerPrefs → UserDefaults |
| SceneSystem | WorldRouter | 🟡 中 | 多场景异步加载 |
| Localization | LocalizationService | 🟢 低 | xcstrings |
| WorkbenchSystem | MicroscopeView | 🟡 中 | 使用真实薄片照片 |
| Encyclopedia | EncyclopediaStore + UI | 🟡 中 | 图鉴 + 3D 查看器 |
| VehicleSystem | DroneControl / DrillCarControl | 🔴 高 | RealityKit 物理 + 相机跟随 |
| MobileSystem | TouchInputService | 🟢 低 | 虚拟摇杆/手势(架构直接翻译) |
| Managers / Core | AppCoordinator / EventBus | 🟢 低 | 彻底换新架构 |
| GuidanceSystem | GuidanceOverlay | 🟢 低 | UI 箭头/高亮 |

### 3.2 🆕 新增系统

| 系统 | 难度 | 说明 |
|---|---|---|
| PLATEAUEnvironmentLoader | 🟡 中 | 流式加载 USDZ tile,LOD 切换 |
| ToonShader(Metal) | 🔴 高 | 自定义 MaterialX / CustomShader |
| DisasterEventSystem | 🟡 中 | 地震/洪水事件调度 + 可视化 |
| HazardLayerOverlay | 🟢 低 | 叠加 PLATEAU 灾害图层 |
| LocationGeologyContent | 🟢 低 | 按 GPS/场景位置加载地质教学数据 |

### 3.3 ❌ 删除的系统

| 系统 | 原规模 | 理由 |
|---|---|---|
| SampleCuttingSystem | ~11K 行 | 废案,用户未使用 |
| WarehouseSystem | ~5.4K 行 | 1 小时节奏不需要仓-包二段 |
| MeshBooleanOperations / CSG | ~3K 行 | 废案,算法已简化 |
| MineralSystem | ~1K 行 | 合并到 Encyclopedia |
| MultipleLanguages 文档 | - | 被 Localization 取代 |
| 所有 Fixer / Cleaner / Debug UI | ~8K 行 | 屎山累积物,架构重做后不需要 |

---

## 4. 开发路线图

**总排期:Solo 开发全职 6-8 个月 / 兼职 10-14 个月**

### Phase 0:基础建设(2 周)

**目标**:工具链齐备,能把 PLATEAU 数据跑进 RealityKit。

- [ ] Xcode 项目初始化,Git 仓库 + MIT 协议
- [ ] CI 配置(Xcode Cloud,build on PR)
- [ ] Tools/plateau-pipeline:CityGML → USDZ 脚本跑通,至少 1 个 tile
- [ ] Tools/meshy-pipeline:API 调用能生成一个角色 + 骨骼 + idle 动画
- [ ] Reality Composer Pro 工程创建,导入 1 个 PLATEAU 建筑 + 1 个 Meshy 角色
- [ ] AGENTS.md / ArchitectureDecisions/0001-layered-architecture.md

**交付物**:iPad 上能跑起来一个空场景 + 1 栋真实仙台建筑 + 1 个动画角色。

### Phase 1:POC(3-4 周)

**目标**:验证"地质玩法可做"。

- [ ] 核心架构:Event Bus + Store + RealityKit ECS 骨架
- [ ] 玩家控制(第一人称 / 虚拟摇杆)
- [ ] 一个测试场景:3-4 层堆叠地质 mesh(模拟露头)
- [ ] 钻探工具:点击 → raycast → 生成堆叠圆柱样本
- [ ] 背包 + 样本 icon 生成
- [ ] 最小 Toon Shader(描边 + 平直光照)

**交付物**:打包上 iPad 真机跑通"走路 → 钻探 → 拿到样本"一整个循环。

### Phase 2:Alpha(3-4 个月)

**目标**:玩法系统全部上线,故事可跑通完整 1 小时主线。

#### 月 1:玩法系统

- [ ] 全部 5 种工具
- [ ] 载具(钻车 + 无人机)+ 相机跟随
- [ ] 工作台 + 显微镜 UI(接入真实薄片照片)
- [ ] 图鉴 UI + 3D 查看器
- [ ] Quest / Dialogue 系统 + JSON 脚本
- [ ] 多语言切换

#### 月 2:内容与场景

- [ ] PLATEAU 走廊 5 tile 全部 Toon 化并集成
- [ ] G-Lab 研究室场景建模(Meshy 生成装置)
- [ ] 5-8 个采样露头布置
- [ ] 所有主要角色生成 + 基础动画(idle / walk / talk)
- [ ] 主线对白完整移植(从 StorySummary 翻译成 JSON)

#### 月 3:灾害事件

- [ ] 地震事件:相机抖动 + 建筑预设动画 + 音效
- [ ] 洪水事件:水位 Shader + PLATEAU 浸水图层可视化
- [ ] 事件触发与剧情挂钩

#### 月 4:缓冲 & Bug fix

- [ ] 内部游玩测试(找 5-10 个中学生 / 同学试玩)
- [ ] 关键 bug 修复
- [ ] 教学内容校对(你自己的地质研究背书)

**交付物**:Alpha 版本,封闭测试可玩,主线可通关。

### Phase 3:Beta(2 个月)

**目标**:打磨体验,适配 + 性能 + 多语言完整。

- [ ] iPhone 适配(保持横屏,紧凑 HUD 变体)
- [ ] 手柄支持
- [ ] 三语翻译完整 + 校对(日语原生、英语、中文)
- [ ] 音效 + BGM(用 AVAudioEngine / 空间音频)
- [ ] 性能优化(LOD,纹理压缩,entity pooling)
- [ ] TestFlight 公开测试(最多 10,000 人)
- [ ] 社区反馈收集

**交付物**:TestFlight beta,稳定可用。

### Phase 4:发布 & 长尾(1-2 个月)

- [ ] App Store 商店页面(截图、视频、描述、关键词)
- [ ] 开源仓库 README / CONTRIBUTING / LICENSE(MIT)
- [ ] 申请 [PLATEAU Awards](https://www.mlit.go.jp/plateau/) 参赛
- [ ] 学术成果(研究室 / 会议海报)
- [ ] 第二章规划文档

---

## 5. 资产清单

### 5.1 3D 模型(Meshy 生成)

| 资产 | 数量 | 优先级 | 预估 Meshy credit |
|---|---|---|---|
| 主角(男/女) | 2 | P0 | 2 代 × 多次迭代 ≈ 10 |
| Dr. Kaede | 1 | P0 | 5 |
| 教師 | 1 | P1 | 3 |
| 研究員 A | 1 | P2 | 3 |
| 路人 NPC | 3-5 | P2 | 5-8 |
| 工具(锤/钻/瓶)| 3 | P0 | 5 |
| 钻塔 | 1 | P1 | 3 |
| 无人机 | 1 | P1 | 3 |
| 钻车 | 1 | P1 | 5 |
| 显微镜 / 工作台 | 2 | P0 | 5 |
| 实验室装置 | 5-8 | P1 | 10 |
| 自然装饰(树/石) | 5-10 | P2 | 10 |
| **合计** | ~30 个 | | **~80 代**(Studio plan 绝对够) |

### 5.2 角色动画(Meshy Animate 或 Mixamo)

每个主要角色需要:
- idle / walk / run / talk / wave / kneel(采样动作)

主角额外:
- hammer_swing / drill_push / drive_sit / drone_ride

### 5.3 环境(PLATEAU)

| Tile 覆盖 | 建筑数估算 | 转换后 USDZ 大小估算 |
|---|---|---|
| 土樋/五橋(东北学院大)| ~200 栋 | 30-50 MB |
| 広瀬川走廊 | ~100 栋 | 20 MB |
| 青葉城跡 | ~50 栋 + 地形 | 40 MB |
| 東北大川内 | ~80 栋 | 20 MB |
| 青葉山 | 地形为主 | 30 MB |
| **合计** | 430+ 栋 | **~150 MB**(App Thinning 后每用户 ~80 MB) |

### 5.4 地质素材(你研究室自备)

- [ ] 青葉山層 薄片照片 × 若干
- [ ] 其他走廊地层样本照片
- [ ] 地层柱状图(可做成游戏内插画)
- [ ] 断层分布图(教学 UI 用)

这些是**游戏真实感与教学价值的核心**,请按地点分类准备。

### 5.5 音频(待后续)

- BGM × 3(探索 / 实验室 / 灾害)
- SFX(脚步、钻探、采集成功、对话提示等)
- 环境音(风、流水、街道)

---

## 6. Meshy.ai 集成工作流

### 6.1 API 端点(Meshy v2 文档确认)

| 端点 | 用途 |
|---|---|
| `/text-to-3d` | 文字 → 3D 模型 |
| `/image-to-3d` | 图片 → 3D 模型(风格一致性最佳) |
| `/multi-image-to-3d` | 多视角图 → 3D |
| `/rigging` | 为模型绑定骨骼 |
| `/animation` | 生成动画 clip(需 Studio plan) |
| `/retexture` | 重新贴图(换风格) |
| `/remesh` | 拓扑重建(优化网格) |

调用方式:**异步任务**,提交后轮询状态。

### 6.2 角色生产流程

```
Step 1. 准备 concept art
  - 主角:先用 Midjourney / NijiJourney 生 3 张三视图(front / side / back)
  - 风格关键词:anime, chibi, 3-head proportion, middle-school uniform, soft shading
  - 定稿 1 张作为"风格基准图"

Step 2. Meshy image-to-3d
  - 用基准图提交
  - 生成 GLB(带 PBR texture)
  - 如不满意,用 /retexture 调色

Step 3. Rigging
  - /rigging 端点自动绑骨(humanoid)
  - 或用 Mixamo 补救

Step 4. Animation
  - /animation 端点 + 动作 prompt(walk, idle, wave...)
  - 导出 GLB(带 multiple animation clips)

Step 5. Blender 后处理
  - 清理法线、合并材质
  - 导出 FBX 或保持 GLB

Step 6. Reality Converter
  - GLB → USDZ
  - 检查材质与动画保真

Step 7. 入库 → Xcode
```

### 6.3 脚本化(Tools/meshy-pipeline/)

写一个 Python 脚本 `meshy_batch.py`:

```python
# 伪代码
for character in characters_to_generate:
    task_id = meshy.image_to_3d(image=character.ref_image)
    glb = meshy.wait(task_id)
    rigged = meshy.rigging(glb)
    animated = meshy.animation(rigged, animations=character.anims)
    save(animated, f"raw/{character.name}.glb")
```

跑一次生成全部,降低手动成本。

---

## 7. PLATEAU 数据管线

### 7.1 数据下载

来源:[geospatial.jp/ckan/dataset/plateau-04100-sendai-shi-2024](https://www.geospatial.jp/ckan/dataset/plateau-04100-sendai-shi-2024)

需下载:
- [ ] 建筑 CityGML(LOD2)— 覆盖走廊 5 tiles
- [ ] 地形 CityGML(LOD1)
- [ ] 植被 CityGML(LOD2)
- [ ] 桥梁 CityGML(LOD3)— 広瀬川桥梁
- [ ] 灾害图层 GeoJSON(洪水浸水 / 津波 / 土砂)

### 7.2 转换(Tools/plateau-pipeline/convert.sh)

```bash
#!/bin/bash
# 使用 plateau-gis-converter(Rust CLI)

for gml in input/*.gml; do
  name=$(basename "$gml" .gml)
  # CityGML → glTF
  plateau-gis-converter convert \
    --input "$gml" \
    --output "intermediate/$name.glb" \
    --format gltf \
    --lod 2

  # glTF → 经 Blender 批处理(toon 材质 + 简化)→ USDZ
  blender --background --python blender_toon_pipeline.py -- \
    --input "intermediate/$name.glb" \
    --output "../Resources/Environment/$name.usdz"
done
```

### 7.3 Toon 化(Blender 脚本)

```python
# blender_toon_pipeline.py 伪代码
import bpy

def toon_convert(input_glb, output_usdz):
    bpy.ops.import_scene.gltf(filepath=input_glb)

    # 1. 简化所有 mesh 的三角形数(保留剪影)
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            decimate = obj.modifiers.new('Decimate', 'DECIMATE')
            decimate.ratio = 0.5

    # 2. 替换所有材质为 Toon 节点组
    for mat in bpy.data.materials:
        apply_toon_shader(mat, keep_texture=True)

    # 3. 导出 USDZ
    bpy.ops.wm.usd_export(filepath=output_usdz)
```

关键:**保留原贴图**,但光照改用 ramp(二分明暗),再加后期描边(RealityKit 里用 post-process)。

### 7.4 LOD / 流式加载策略

iPad 跑不下整个走廊全精度。方案:

```
近距离(< 50m): LOD2 全贴图
中距离(50-200m): 简化 mesh + 降采样贴图
远距离(> 200m): silhouette-only(剪影 + flat color)
```

实现:`RealityKit.ModelComponent` 的 `lod` 支持,或自己基于相机距离切换 Entity。

---

## 8. 风险清单 & 预案

| 风险 | 等级 | 影响 | 预案 |
|---|---|---|---|
| **RealityKit Toon Shader 实现难度** | 🔴 高 | 美术效果不达预期 | Phase 0 先用简单材质 POC;必要时降级到 SceneKit(有 toon 案例多) |
| **Meshy 动画质量不稳定** | 🟡 中 | 角色动作诡异 | 降级用 Mixamo 标准动画,或者手动在 Blender 做关键帧 |
| **PLATEAU 数据包体过大** | 🟡 中 | App Store 下载大 | App Thinning + On-Demand Resources;分区下载 |
| **iPad 性能瓶颈** | 🟡 中 | 掉帧 | LOD + Entity pooling + 纹理压缩;必要时减走廊 tile |
| **Meshy API 限额/费用超支** | 🟢 低 | 进度阻塞 | Studio plan 一次性投入 $80,有余量;用完降级到 Mixamo |
| **Solo 开发耗时超预期** | 🟡 中 | 项目拖延 | 每 Phase 严格门槛;内容不达就砍内容,不延工期 |
| **PLATEAU 许可使用条款变更** | 🟢 低 | 合规风险 | Phase 0 复查最新政策,存档当前版本的数据 |
| **Asset Store 残留(原 Unity 项目)泄漏** | 🟢 低 | 法律 | 新项目完全从零资产,不带任何旧 Asset Store 内容 |
| **中学生游玩体验不佳** | 🟡 中 | 发行失败 | Alpha 阶段找真实用户 playtest,尽早校准 |
| **架构退化成新屎山** | 🟡 中 | 重蹈覆辙 | AGENTS.md / ADR 写死"三层规则",code review 自我检查 |

---

## 9. 待决事项(已确认)

截至 2026-04-21,以下事项全部确认:

| # | 事项 | 决定 |
|---|---|---|
| 1 | **项目名** | ✅ **SDG-Lab** |
| 2 | **主角概念图** | ✅ 使用 **Nano Banana (Google Gemini)** 生成三视图 → 喂给 **Meshy image-to-3d** |
| 3 | **显微镜薄片照片** | ✅ 以 f.shera 研究室自拍为主;补充 **USGS 公共领域**、**産業技術総合研究所 地質標本館**(CC-BY);**爬图仅作最后手段且必须逐张确认许可** |
| 4 | **BGM** | ✅ AI 生成(**Suno / Udio Pro**,$10/月商业许可) |
| 5 | **字体** | ✅ 免费商用字体(**Source Han Sans** 覆盖中日英,或 **M PLUS 1p** 日文) |
| 6 | **开发启动日** | ✅ **2026-04-21**(今日) |
| 7 | **学术归属** | ✅ 无经费支持;论文作者 = f.shera + 导师;App Store 可挂研究室名作为鸣谢 |
| 8 | **数据版权声明** | ✅ App 内"关于"页展示 PLATEAU / USGS / 産総研 / Meshy / Suno 等使用表示(参见 Phase 4 交付物) |

---

## 10. 变更记录

| 日期 | 版本 | 变更 | 作者 |
|---|---|---|---|
| 2026-04-21 | v0.1 | 初稿起草 | Claude |
| 2026-04-21 | v0.2 | 确认项目名 SDG-Lab;待决事项全部 close;Phase 0 启动 | f.shera + Claude |

---

## 附录 A:术语表

| 术语 | 释义 |
|---|---|
| CityGML | OGC 定义的 XML 3D 城市模型标准格式 |
| PLATEAU | 日本国土交通省 3D 城市模型项目名 |
| LOD | Level of Detail,细节层级(0/1/2/3,数字越大越精细) |
| ECS | Entity-Component-System,一种解耦 3D 游戏逻辑的架构模式 |
| RealityKit | Apple 的高级 3D 引擎,基于 ECS |
| USDZ | Apple 推的 3D 资产封装格式(基于 Pixar USD) |
| Toon Shader | 卡通着色器,通常包含描边 + 明暗分段 |
| App Thinning | App Store 按设备下发对应切片,减小下载大小 |

## 附录 B:参考资源

- [RealityKit Documentation](https://developer.apple.com/documentation/realitykit)
- [Meshy API Docs](https://docs.meshy.ai/en)
- [PLATEAU-GIS-Converter](https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter)
- [PLATEAU 仙台 2024 数据](https://www.geospatial.jp/ckan/dataset/plateau-04100-sendai-shi-2024)
- [Mixamo](https://www.mixamo.com/)(自动绑骨 + 动画库)
- [Reality Composer Pro 教程](https://developer.apple.com/documentation/visionos/designing-realitykit-content-with-reality-composer-pro)

---

**文档结束** · 后续修订记入本文件 `## 变更记录` 节。
