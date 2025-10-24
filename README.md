# 🖼️ VIZ — The Vision Engine for Zig

<div align="center">
  <img src="assets/icons/viz.png" alt="VIZ Logo" width="200" />
</div>

[![Zig](https://img.shields.io/badge/Built_with-Zig-orange?style=flat-square&logo=zig)](https://ziglang.org)
[![GPU Optimized](https://img.shields.io/badge/NVIDIA-Accelerated-green?style=flat-square&logo=nvidia)](https://developer.nvidia.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)

**VIZ** (short for *Vision*) is a modern, GPU-accelerated image processing toolkit written in **Zig**,  
designed as a high-performance, memory-safe alternative to ImageMagick and GraphicsMagick — built for Linux.

---

## ✨ Philosophy

> Minimal, predictable, and *blazingly fast*.  
> No dependency hell, no runtime magic — just pure Zig performance.

VIZ redefines the classic image manipulation pipeline with a **compile-time typed core**,  
**deterministic SIMD/GPU kernels**, and **zero-copy pipelines** that scale from CLI tools to native apps.

---

## 🚀 Key Features

### � Prototype Core (v0.1 dev)
- Pure-Zig `viz.Image` type with allocator-safe pixel storage.
- Binary **PPM (P6)** load/save helpers.
- Simple brightness scaling in-place.

### 🛠️ Early CLI Utilities
- `viz info <image.ppm>` prints dimensions.
- `viz brighten <in.ppm> <out.ppm> <factor>` scales brightness.

### 🧭 Status
> The current branch is an early research prototype. PNG/JPEG codecs,
> SIMD/GPU backends, and effect chaining are still roadmap items (see below).

```zig
const std = @import("std");
const viz = @import("viz");

pub fn run() !void {
  const allocator = std.heap.page_allocator;
  var image = try viz.Image.loadPPMFile(allocator, "input.ppm");
  defer image.deinit();

  image.applyBrightness(1.2);
  try image.writePPMFile("output.ppm");
}
```

---

## 🔗 Integrations

| Tool    | Purpose                          |
|---------|----------------------------------|
| Babylon | Package & provenance management  |
| ZIM     | Toolchain control                |
| Apollo  | Telemetry, performance, metrics  |
| ZMake   | Build orchestration              |

---

## 🧬 Architecture

```
       ┌────────────────────────┐
       │       VIZ CLI          │
       │   (zig build run)      │
       └───────────┬────────────┘
                   │
       ┌───────────▼────────────┐
       │    Core Engine         │ → Image Ops, Color, Geometry
       └───────────┬────────────┘
                   │
       ┌───────────▼────────────┐
       │    GPU Backend         │ → CUDA / Vulkan / CPU Fallback
       └───────────┬────────────┘
                   │
       ┌───────────▼────────────┐
       │     Exporters          │ → PNG, JPEG, WebP, HDR, BMP
       └────────────────────────┘
```

---

## 🧩 Roadmap

- [ ] SIMD-optimized CPU filters (AVX2, NEON)
- [ ] Vulkan compute kernel support
- [ ] Native integration with Archon (GPU context sharing)
- [ ] Support for animated WebP/GIF
- [ ] Scripting bindings (Python / Zig API)
- [ ] Live preview + GUI toolkit plugin

---

## 🧰 Build & Run

### Requirements

- Zig ≥ 0.16.0
- (Optional) NVIDIA CUDA toolkit for GPU acceleration

### Installation

```bash
git clone https://github.com/ghostkellz/viz.git
cd viz
zig build run -- --help
```

### Usage

Inspect an image (PPM only for now):

```bash
zig build run -- info path/to/input.ppm
```

Brighten an image in place:

```bash
zig build run -- brighten path/to/input.ppm zig-out/output.ppm 1.25
```

---

## 💡 Vision

VIZ is the visual layer of the GhostStack ecosystem — a foundation for high-performance rendering, visualization, and generative media tools built entirely in Zig.

> "VIZ is not just faster ImageMagick — it's what ImageMagick would have been if it were born in 2025."

---

## 🪶 License

MIT © 2025 Christopher Kelley (GhostKellz)

