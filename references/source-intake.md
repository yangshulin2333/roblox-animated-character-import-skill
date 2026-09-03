# 原始资源接收与标准化

本阶段解决“用户给的是任意原始资源，而不一定是 FBX”的问题。它只识别、清点和生成检测工作目录，不修改原包，也不代表模型已经适用于 Roblox。

## 输入优先级

1. 用户明确指定的文件或目录是唯一来源边界。
2. 压缩包内部文件属于该来源。
3. 原包旁边已经生成的 `_Roblox.fbx`、`.blend`、贴图修复文件和旧报告属于历史派生物；除非用户明确指定，否则不得作为本轮源候选。
4. 标准化工作目录和最终交付目录必须分离，避免下次审计把自己的输出选回去。

## 第一步命令

只识别容器，不解包：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/intake_source.ps1 `
  -Source "D:\原始资源" `
  -WorkDir "D:\检测工作区\资源名"
```

识别并标准化：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/intake_source.ps1 `
  -Source "D:\原始资源" `
  -WorkDir "D:\检测工作区\资源名" `
  -Extract
```

RAR/7z 工具不在 PATH 时：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/intake_source.ps1 `
  -Source "D:\原始资源.part1.rar" `
  -WorkDir "D:\检测工作区\资源名" `
  -ArchiveToolPath "C:\Program Files\7-Zip\7z.exe" `
  -Extract
```

## 识别规则

| 实际容器 | 识别方法 | 标准化行为 |
| --- | --- | --- |
| UnityPackage/GZIP | GZIP 签名、TAR `ustar`、首层 Unity GUID | 安全解包并根据 `pathname/asset/asset.meta` 还原逻辑目录 |
| ZIP | `PK` 文件签名 | 校验所有相对路径后解包 |
| RAR5/RAR 分卷 | RAR 签名和 `.partN.rar` 连续编号 | 归并为一个资源组，从 part1 联合读取 |
| 7z | 7z 文件签名 | 使用新版 7-Zip 列目录、校验路径、再解包 |
| Unity 工程 | `Assets/`、`ProjectSettings/` 或 Unity 资源扩展名 | 保留工程结构，查找 FBX、动画、材质和贴图 |
| Unreal 工程 | `.uproject`、`.uasset` | 优先找便携 FBX/glTF；只有 UAsset 时要求原生 Unreal 导出 |
| DCC/便携文件 | `.blend/.max/.fbx/.glb/.gltf` 或内容签名 | 精确文件进入内容审计，不扫描包外历史派生物 |

## 多资源与分卷区别

- `name.part1.rar` 到 `name.part4.rar` 是一个资源组，不是四个任务。
- 四个名称不同的 ZIP/RAR 是四个独立资源组。默认先列中文清单，让用户选择后再解包，避免一次展开大量无关资源。
- 分卷缺号、文件损坏或加密时立即停止，不对后续分卷分别重试。

## 安全与空间门禁

- 拒绝绝对路径、盘符路径、UNC 路径和包含 `..` 的越界条目。
- 不自动递归解包嵌套压缩包；先报告并确认资源层级。
- 对大型包先记录压缩体积、分卷总量和目标磁盘空间。
- 解包失败后保留报告，不覆盖原始资源，不自动删除可能用于诊断的工作目录。
- RAR5 必须使用支持该格式的新版 7-Zip/WinRAR；旧工具返回“无法作为压缩包打开”时标记 `EXTRACTOR_REQUIRED`，不是模型损坏。
- 7-Zip 官方下载页：<https://www.7-zip.org/download.html>。Windows x64 电脑优先选择官方 64-bit x64 安装包；不要覆盖其他软件目录中自带的旧版 `7z.exe`。

## 阶段输出

`source_intake.json` 至少包含：

- 原始路径、真实容器类型、文件签名；
- 分卷成员、缺失卷和总大小；
- 标准化工作目录；
- 检测到的 Unity/Unreal/Blender/3ds Max 生态；
- 可读取模型候选、原生工程文件、贴图和嵌套压缩包；
- 中文阻止原因、警告和下一步；
- 可选 SHA-256 来源哈希。

`SOURCE_NORMALIZED` 只允许进入下一阶段，不代表 Roblox 兼容或 Studio 可用。
