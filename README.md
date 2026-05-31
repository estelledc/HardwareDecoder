# hardware-decoder

macOS 上的 H.264 硬件解码 CLI 底座，基于 VideoToolbox。从一个 Xcode demo 长出来，现在是可分发、可被任何语言通过 subprocess 调用的命令行工具，输出 JSONL meta 行 + JPG/PNG/raw BGRA8 帧。

下游用例之一是给我自己的 video evaluation agent 项目当 frame-level pipeline；但这个仓不依赖任何下游，它就是一份 macOS H.264 裸流处理工具。

## 安装

需要 macOS 12+ / Swift 5.9+。

```bash
swift build -c release           # 产物: .build/release/hardware-decoder
make install                     # 复制到 /usr/local/bin/hardware-decoder
```

## CLI 用法

两个子命令: `probe` 不解码任何帧，只读 SPS + 扫一遍 NAL 拿元数据；`decode` 实际解出帧。

### probe — 输出元数据 + IDR 索引

```bash
hardware-decoder probe --input video.h264
```

stdout 一行 JSON:

```json
{
  "stream_id": "2e4a3b715643dc45",
  "width": 852, "height": 480,
  "profile_idc": 100, "level_idc": 30,
  "chroma_format_idc": 1, "num_ref_frames": 5,
  "fps_hint": 23.0,
  "has_b_frames_hint": true,
  "frame_count_estimate": 1496,
  "estimated_duration_s": 65.04,
  "idr_index": [
    {"frame_idx": 0,   "nalu_offset": 3,   "ts": 0.0},
    {"frame_idx": 89,  "nalu_offset": 94,  "ts": 3.87},
    ...
  ]
}
```

`stream_id` 是 SPS+PPS 的 sha256[:16]，可用作 cache key。`idr_index.ts` 用 fps_hint 推算，给 `decode --seek-to-ts` 当导航表。

### decode — 解出帧

```bash
hardware-decoder decode \
    --input video.h264 \
    --output-dir frames/ \
    --format jpg \                  # jpg | png | raw
    --quality 70 \                  # JPG quality 0-100
    --max-height 480 \              # 0 = 原分辨率
    --fps 1 \                       # 输出 fps，跳过中间帧
    --ts-start 10 --ts-end 20 \     # 时间窗
    --seek-to-ts 12 \               # 跳到 ≤12s 的最近 IDR 起解
    --probe-meta probe.jsonl        # 复用 probe 的 idr_index 不重扫
```

stdout 每帧一行 JSONL:

```json
{"ts":11.57,"frame_idx":0,"width":852,"height":480,"path":"frames/f_00000.jpg"}
```

**`--format raw` 模式**：不落盘，直接把 BGRA8 像素 bytes 写 stdout。每帧顺序 = JSONL meta 行 + `size_bytes` 个原始字节。`--output-dir` 在 raw 模式下被忽略（仍 required，传 `/dev/null` 即可）。

```json
{"ts":1.0,"frame_idx":0,"width":426,"height":240,"size_bytes":408960,"format":"bgra8"}
<408960 raw BGRA bytes>
{"ts":2.0,"frame_idx":1,...}
<...>
```

### Exit codes

| code | 含义 |
|---|---|
| 0 | OK |
| 2 | 输入文件不存在 / 不可读 |
| 3 | 不是有效 H.264 裸流 / 找不到 SPS+PPS |
| 4 | VTSession 创建失败（硬解 + 软解都失败）|
| 5 | 解码中断（紧急恢复也失败）|
| 130 | SIGINT |

## 作为底座的几个设计选择

**1. AVCC 帧化** — VT `nalUnitHeaderLength=4` 要求每个 NAL 加 4 字节 big-endian 长度前缀（不是 Annex-B start code）。原 demo 喂 Annex-B 给 VT，每帧返 -12909。Core 在 `feed(naluData:)` 内部统一 strip start code → 加长度前缀 → 送 VT。

**2. VTSession spec dict 只放 specification keys** — `RealTime / ThreadCount / QoSTier` 是 *property* keys，塞进 specification dict 会让 VT 构造出无法满足的 spec。这些属性在 session 创建后用 `VTSessionSetProperty` 单独设。

**3. 三层 fallback** — adapter 层（硬解失败 → 软解 retry）+ session 层（创建失败 → no-spec 兜底）+ decode 层（-12909 → 紧急重建 session + 强制软解）。任何一层失败下游不会全崩。

**4. 每个 IDR 重建解码会话** — `idrSessionRebuild` 配置项保留 demo 的可靠性策略：检测到 `nal_type==5` 就 `cleanUp() → buildFormatDescription → createSession`，避免某些流上累积状态导致后续 IDR 失败。

**5. NAL forbidden_bit 防御** — 某些流的 NAL 头 `forbidden_zero_bit` 被损坏成 1，VT 会拒。Core 在送 VT 前强制清零（`& 0x7F`）。

**6. SPS bitstream 解析** — 不依赖 ffprobe / ffmpeg。150 行 Swift 实现 Exp-Golomb + emulation prevention byte stripping，自己读 `pic_width_in_mbs / VUI time_scale / num_units_in_tick` 拿真实 width / height / fps，不再写死 1920×1080。

## 已知局限

- H.264 baseline / main / high profile，**不支持 HEVC / mp4 容器** — 本仓只做裸流
- macOS-only（VideoToolbox）— Linux 部署需要另起 VAAPI / NVDEC 仓
- 假设无 B 帧 DTS/PTS 重排 — 主流 bilibili 视频通常无 B，但严格场景需要扩展
- `duration_s` 只能估算（裸流无容器时间基准）：`frame_count_estimate / fps_hint`
- fps 来自 SPS VUI，部分流 VUI 不准（典型偏差 ~5-10%）

## 内部架构

```
Sources/
├── HardwareDecoderCore/        — 库 target，可被其他 Swift 项目 import
│   ├── HardwareDecoderCore.swift  log + version
│   ├── H264Stream.swift           NAL 切分 / SPS-PPS 提取（纯函数，无副作用）
│   ├── H264Decoder.swift          实例化 H264Decoder（VT 解码器）
│   ├── SPSParser.swift            SPS bitstream parser
│   └── IDRIndex.swift             IDR 索引 + nearestIDR 查询
└── HardwareDecoderCLI/         — 可执行 target
    ├── main.swift                 ArgumentParser 入口
    ├── DecodeCommand.swift        decode 子命令
    ├── ProbeCommand.swift         probe 子命令
    ├── FrameSaver.swift           JPG/PNG 落盘 + raw stdout 流
    ├── JSONLWriter.swift          stdout 单行 JSON 输出
    └── JSONLReader.swift          --probe-meta 解析

Tests/
└── HardwareDecoderCoreTests/   — 12 tests: NAL parse / SPS / IDR index
    └── Fixtures/1.h264         — 1.7M 最小测试素材
```

`HardwareDecoder/` 旧 demo 目录保留作历史参考（含 main.swift + 7 个 .h264 测试素材），不参与 SPM 编译。

## 跑测试

```bash
make test                        # 12 个单测
make run-probe                   # smoke probe 1.h264
make run-decode                  # smoke decode 1.h264 → /tmp/hwdec-out
```

## 开发笔记

修了 demo 在 macOS 26 / Apple Silicon / Swift 6 上从未真正解码过帧的 2 个 bug（AVCC vs Annex-B framing + spec/property dict 混用），细节见 `H264Decoder.swift` 顶部注释。
