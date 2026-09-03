# 贴图兼容性预处理

本阶段位于本地模型转换之后、Roblox Studio 上传之前。目标是把第三方 DCC、Unity、Unreal 或图片工具导出的外部贴图，转换成结构简单、可复核的 Roblox 上传文件；它不修改原始图片，也不能替代 Roblox 审核、资产权限或运行时加载验收。

## 为什么扩展名正确仍会失败

常见来源包括：

- 文件扩展名与真实编码不一致、PNG CRC/结尾损坏；
- 16 位、调色板、CMYK、带方向的 EXIF 或多帧图片；
- ICC、XMP、iTXt、pHYs 等应用元数据触发不同解析器行为；
- 宽高超过平台上限；
- 原图可以被某个桌面软件容错打开，但 Studio 上传器拒绝；
- 图片本身正常，但失败实际来自审核、Creator 或体验权限。

因此不能只检查文件名，也不能把“本地能打开”当作上传通过。

## 自动化输出契约

正式 `separate` 贴图默认执行 `roblox_png_v1`：

1. 按真实内容解码，只对多帧图片使用第一帧并写入警告；
2. 应用 EXIF 方向；
3. 有有效 ICC 时转换到 sRGB，否则保持像素颜色；
4. 输出 8 位 RGB 或 RGBA PNG；
5. 默认最大边长 4096，不放大较小图片；
6. 移除 EXIF、ICC、XMP、文本、DPI 和其他非必要 PNG 辅助块；
7. 检查 PNG 签名、IHDR、CRC、IEND、尾随字节、色深和颜色类型；
8. 重新解码输出并逐字节比较编码前后的像素；
9. 输出 `texture_normalization.json`，同时更新 `texture_manifest.json`、`bundle_manifest.json` 和文件 SHA-256；
10. 正式文件统一命名为 `*_Roblox.png`，原始来源保持不变。

Roblox 官方[纹理规范](https://create.roblox.com/docs/art/modeling/texture-specifications)目前说明普通纹理支持最高 4096×4096；Albedo/Normal 建议使用 24 位 RGB，数据贴图使用 8 位灰度。当前自动化保证通用的 8 位 RGB/RGBA 上传契约，但不会猜测或合并缺失的 PBR 通道。复杂 PBR 必须先在材质清单中明确 Color、Normal、Roughness、Metalness、Emissive 和 Alpha 的用途。

## 主流程

`run_pipeline.ps1` 在默认 `TextureMode=separate` 下自动执行，无需额外命令：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_pipeline.ps1 `
  -Source "D:\source\character.fbx" `
  -OutputDir "D:\output\character" `
  -BaseColorTexture "D:\source\Color.png" `
  -AllActions -FixMaxInfluences
```

需要主动降低移动端贴图时显式设置：

```powershell
  -MaxTextureDimension 2048
```

脚本需要 Python 3 和 Pillow。若当前 Python 没有 Pillow，默认把固定版本安装到 `%LOCALAPPDATA%\CodexTools\roblox-animated-character-import\python-packages`，不写入项目和系统 Python。禁止自动下载时加 `-NoTextureToolInstall`；缺少工具会停止为 `TEXTURE_TOOL_REQUIRED`。

## 修复旧交付包

只修复已经生成的 `separate` 包：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/normalize_roblox_textures.ps1 `
  -BundleDir "D:\output\bundle_attempt_001" `
  -MaxDimension 4096
```

单张图片测试：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/normalize_roblox_textures.ps1 `
  -InputPath "D:\source\Color.png" `
  -OutputPath "D:\output\Color_Roblox.png" `
  -ReportPath "D:\output\texture_normalization.json"
```

单张模式拒绝覆盖输入；输出已存在且哈希不同时也拒绝覆盖，除非显式加 `-ReplaceOutput`。

## 门禁

- `TEXTURE_NORMALIZATION_PASS`：本地格式、结构和像素回读通过，可以进入 Studio 上传。
- `TEXTURE_NORMALIZATION_SKIPPED`：正式包没有外部贴图，只允许用于明确接受的无贴图任务。
- `TEXTURE_TOOL_REQUIRED`：缺少 Python/Pillow，且自动安装不可用或被禁用。
- `TEXTURE_COMPATIBILITY_BLOCKED`：来源无法解码、损坏、输出回读失败或超过已配置规则。

即使达到 `TEXTURE_NORMALIZATION_PASS`，Studio 仍需验证上传结果、审核状态、体验授权以及 fresh Play 的直接 `rbxassetid://` 加载。
