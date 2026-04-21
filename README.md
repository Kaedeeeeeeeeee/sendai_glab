# SDG-Lab

> 仙台を舞台にした、中学生向け 3D 地質学習ゲーム。
> A 3D geology education game set in Sendai, for middle-school students.

[![Platform](https://img.shields.io/badge/platform-iPadOS%2018+-blue)]()
[![Swift](https://img.shields.io/badge/Swift-5.10+-orange)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Status](https://img.shields.io/badge/status-Phase_0-yellow)]()

---

## 什么是 SDG-Lab?

SDG-Lab 是一款运行在 iPad / iPhone 上的 3D 地质教育游戏。玩家扮演一名仙台的中学生,被卷入一场山体滑坡事件后加入秘密地质研究机构 **G-Lab**,在真实仙台市的街道、山林中进行钻探采样、理解脚下的地层与灾害风险。

**项目名 SDG-Lab** 同时致敬:

- 剧情设定:**S**endai **D**r.Kaede's **G**eography Lab
- [**S**endai Framework for **D**isaster Risk Reduction](https://www.undrr.org/implementing-sendai-framework/what-sendai-framework) — 2015 年在仙台通过的联合国国际减灾框架
- [**S**ustainable **D**evelopment **G**oals](https://sdgs.un.org/goals) — 联合国可持续发展目标,特别是 Goal 11(可持续城市) 与 Goal 13(气候行动)

## 特点

- 🗾 **真实仙台舞台**:基于 PLATEAU 国土交通省 3D 都市模型,覆盖東北学院大学 → 広瀬川 → 青葉城跡 → 東北大川内 → 青葉山 的 5 km 走廊
- ⛏️ **真实地质教学**:钻探、薄片观察、图鉴收集;所有内容基于仙台真实地层(青葉山層等)
- 🌊 **地震 / 洪水事件**:结合 PLATEAU 灾害图层数据
- 🎨 **二次元卡通美术**:Toon Shader 渲染,参考原神 / 塞尔达风格
- 🌍 **三语**:日本語 / English / 简体中文
- 🆓 **完全免费 · 开源**

## 技术栈

- **Swift 5.10+** · **RealityKit** · **SwiftUI** · **Metal**
- **3D 资产**:[PLATEAU-GIS-Converter](https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter) + [Meshy.ai](https://meshy.ai) Studio
- **BGM**:AI 生成(Suno / Udio)
- **最低系统要求**:iPadOS / iOS 18.0+

## 状态

🚧 **Phase 0 基础建设中** · 启动日 2026-04-21 · 预计 **Phase 1 POC** 于 2026-05 完成

详见 [GDD.md](GDD.md) 与 [Docs/](Docs/)。

## 项目结构

```
sendai_glab/
├── SendaiGLab.xcodeproj      # (待创建)
├── Sources/                   # Swift 源码
├── Resources/                 # 资产(USDZ, JSON, Localization)
├── Tools/                     # 数据管线脚本
├── Tests/                     # 单测 + 集成测试
├── Docs/
│   ├── ArchitectureDecisions/ # ADR 架构决策记录
│   └── AssetPipeline.md
├── GDD.md                     # 游戏设计文档(总纲)
├── AGENTS.md                  # 贡献者指南
└── README.md
```

## 原 Unity 项目

本项目是对前作 [GeoModelTest](https://github.com/Kaedeeeeeeeeee/GeoModelTest) 的完全重构。主要动机:

- 从 Unity + C# 迁移至 Swift + RealityKit,原生 iPad 体验
- 基于严格的分层架构(View / Store / ECS)避免重蹈"屎山"覆辙
- 裁剪废案(CSG 布尔运算、样本切割小游戏、仓储系统)
- 引入 PLATEAU 真实仙台数据 + 灾害事件玩法

## 致谢

- **数据**:[Project PLATEAU](https://www.mlit.go.jp/plateau/)(国土交通省)
- **3D 生成**:[Meshy.ai](https://meshy.ai)
- **PLATEAU 转换工具**:[PLATEAU-GIS-Converter](https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter)
- 地质薄片资料:f.shera 研究室(东北学院大学)/ [USGS Photo Library](https://www.usgs.gov/photo-galleries) / [産総研 地質標本館](https://www.gsj.jp/Muse/)

## License

[MIT](LICENSE) — 自由复制、修改、商用,保留版权声明即可。

## Contact

- 作者: f.shera(東北学院大学)
- Issues: https://github.com/Kaedeeeeeeeeee/sendai_glab/issues
