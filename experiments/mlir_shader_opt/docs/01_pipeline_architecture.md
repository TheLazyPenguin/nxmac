# Architectural Analysis: nxnative Shader Pipeline

## Executive Summary

nxnative executes Nintendo Switch (Switch 1 Maxwell and Switch 2 Ampere) binaries natively on Apple Silicon platforms (macOS and iOS) by reimplementing Nintendo's NVN and NVN2 graphics APIs on top of Apple's Metal (Metal 4 / MSL). Because iOS enforces strict W^X (no runtime JIT code generation without debug entitlements), and because runtime translation of foreign GPU bytecode introduces unacceptable frame stutter, **nxnative operates as a 100% Ahead-Of-Time (AOT) shader translation and caching pipeline**, combined with an innovative **hybrid pipeline runtime architecture** that completely prevents draw-time pipeline stalls.

The complete shader lifecycle spans three distinct phases:
1. **Packaging / AOT Offline Phase**:
   - Extraction of Maxwell/Ampere GPU binaries from ROM/NSP/NUP containers (`shader_split.py`, `pack_nup.py`).
   - Binary machine code to SPIR-V translation via NativeAOT C# translator (`dmsh_xlate` embedding `Ryujinx.Graphics.Shader`).
   - SPIR-V to Metal Shading Language (MSL) cross-compilation via pinned Khronos `spirv-cross`.
   - Extensive AST and source-level MSL rewriting passes (`dmsh_rewrite.py`, `dmsh_entry.py`, `dmsh_reflect.py`, `dmsh_vin.py`, `dmsh_pull.py`, `dmsh_fetch.py`, `dmsh_meshstage.py`).
   - Clang-based Metal compilation (`metal` -> AIR -> `metallib`) accelerated by precompiled header template caching (`dmsh_pch.py`) and content-addressable SQLite storage (`cas.db` / `DMSH_CAS`).
   - Offline compilation of Metal 4 pipeline archives (`.mtl4a`) using Apple's `metal-tt` (`pso_offline.py`).
2. **Startup / PSO Prewarm Phase**:
   - Reading seed manifests (`pso_manifest.tsv`) and on-device recording lists (`pso_user.tsv`).
   - Pre-building pipeline state objects (PSOs) behind an interactive "Preparing shaders" startup screen.
   - Matching offline compiled archives (`.mtl4a`) or compiling pipeline bases on all CPU cores using `MTL4Compiler`.
3. **Runtime Replay & Execution Phase**:
   - Interception of guest NVN commands into an in-memory command stream (`hle_nvn.c`).
   - Replay into Metal 4 command encoders (`nvn_mtl.m`), supporting direct execution or deferred multi-threaded command encoding (`DM_NVN_ENC_THREAD=1` via `nvn_rec.h`).
   - Zero-overhead argument buffer binding (`encode_args_`).
   - **Hybrid Pipelines**: draws encountering a PSO that is still being compiled asynchronously on a worker thread immediately dispatch using the shader pair's **pulling pipeline** (`<key>_bp`), which has no vertex descriptor and fetches vertex attributes in shader code, eliminating stalls.

```
+----------------------------------------------------------------------------------------------------+
|                                    1. AOT EXTRACTION & PACKAGING                                   |
|                                                                                                    |
|  Switch NSP / NUP / Dump                                                                           |
|          |                                                                                         |
|          v                                                                                         |
|  [shader_split.py] ---------> Extracts BNSH, BAHS, GLSLC, Unity, UE containers                     |
|          |                    Produces .bin packages (BTCDBTCD), shader_map.tsv, shader_facts.tsv  |
|          v                                                                                         |
|  [dmsh_xlate] --------------> NativeAOT C# (Ryujinx.Graphics.Shader) translates Maxwell/Ampere     |
|          |                    GPU machine code into SPIR-V (.spv) + reflection facts (.res.json)   |
|          v                                                                                         |
|  [spirv-cross] -------------> Pinned Khronos tool translates SPIR-V to baseline MSL                |
|          |                    Flags: --msl-argument-buffers --msl-texture-buffer-native            |
|          v                                                                                         |
|  MSL Rewriting Pipeline ----> Python AST & text transforms: precise math, wide loads,             |
|                               HMMA simdgroup, shared store, tg_spill, border emu, multi-entrypoint|
|          |                                                                                         |
|          v                                                                                         |
|  [dmsh_build.py] -----------> Spawns library variants: _b (base), _bx (alpha/logic),              |
|                               _bf (framebuffer fetch), _bv (shadow vin), _bp (pulling)             |
|          |                    Compiles via xcrun metal (-O1, -fpreserve-invariance, -fwrapv)       |
|          v                                                                                         |
|  [DMSH_CAS (cas.db)] -------> Content-Addressable Storage stores metallibs, stamps inputs.tsv      |
|          |                                                                                         |
|          v                                                                                         |
|  [pso_offline.py] ----------> Compiles Metal 4 pipeline archive (<arch>.mtl4a) via metal-tt        |
+----------------------------------------------------------------------------------------------------+
                                                   |
                                                   v
+----------------------------------------------------------------------------------------------------+
|                                   2. STARTUP & PSO PREWARM                                         |
|                                                                                                    |
|  Host Boot (dm/host)                                                                               |
|          |                                                                                         |
|          v                                                                                         |
|  pso_prebuild() ------------> Opens bundled <arch>.mtl4a or per-game pso_archive/                  |
|          |                    Reads pso_manifest.tsv (bundled seed) + pso_user.tsv (runtime log)   |
|          v                                                                                         |
|  "Preparing Shaders" -------> Multi-threaded MTL4Compiler warms all PSOs on CPU cores              |
+----------------------------------------------------------------------------------------------------+
                                                   |
                                                   v
+----------------------------------------------------------------------------------------------------+
|                                  3. RUNTIME EXECUTION & REPLAY                                     |
|                                                                                                    |
|  Guest Game NVN calls ------> Recorded in zero-copy guest memory buffers (hle_nvn.c)               |
|          |                                                                                         |
|          v                                                                                         |
|  Submit Queue Replay -------> nvn_mtl.m replays commands onto Metal 4                             |
|          |                    - Direct encoding (Submit thread) OR                                 |
|          |                    - Deferred encoding (Worker thread via nvn_rec.h, DM_NVN_ENC_THREAD)|
|          v                                                                                         |
|  Pipeline Selection --------> If PSO ready: dispatch specialized MTL4RenderPipelineState           |
|                               If PSO building: dispatch HYBRID PULLING PIPELINE (_bp, no stall!)   |
|          v                                                                                         |
|  Argument Encoding ---------> encode_args_ writes Metal argument buffers into arena memory         |
|                               c0/c2 driver tables, uniform shadows, bindless texture handles       |
+----------------------------------------------------------------------------------------------------+
```

---

## 1. Shader Extraction & Container Formats

### 1.1 Extraction Architecture (`shader_split.py` and `pack_nup.py`)
Nintendo Switch software does not distribute shaders as separate loose files on disk; instead, shaders are bundled into game executables, archive packages, or engine-specific serialized containers. nxnative implements comprehensive extraction logic in `dm/gfx/tools/shader_split.py` (over 3,200 lines) supported by `scripts/pack_nup.py`, `dm/gfx/tools/unityfs.py`, `dm/gfx/tools/uepak.py`, and `dm/tools/romfs_image.py`.

The extraction script systematically inspects:
- The main executable (`ExeFS/main` and any sub-SDK NROs).
- All RomFS files, recursively decompressing Zstandard streams (`compression.zstd` / `backports.zstd`), SARC archives, Yaz0 streams, Oodle Kraken chunks, and zip containers.

### 1.2 Switch 1 Maxwell vs Switch 2 Ampere Containers
The container parsing layer differentiates Switch 1 (Tegra X1, Maxwell architecture, NVN 53/55) and Switch 2 (Ampere architecture, NVN2) binary containers:

#### Switch 1 Maxwell BNSH & BAHS
- **NintendoWare BNSH (`BNSH\0\0\0\0`)**: Standard Nintendo binary shader archive found in Nintendo EPD titles (`.bfsha` in Mario Odyssey, Breath of the Wild, etc.).
  - Contains a `grsc` header block with variation tables (`nvar`, `pvar`).
  - Variations index programs for graphics stages (`vs`, `hs`, `ds`, `gs`, `ps`) and compute (`cs`).
  - Programs point to a **Control Section** (`ctl`) and a **Code Area** (`code`).
  - Maxwell control sections have magic `0x98761234` (`CTL_MAGIC`), typical lengths of `0x880` or `0x848` bytes, and control word `+0x704` holding the code area length.
  - Graphics code areas start with a 0x30-byte header with magic `0x12345678` (`GFX_MAGIC`) followed by the 0x50-byte Shader Program Header (SPH). SPH word 0 identifies stage type in bits 10..13.
  - Compute code areas start with magic `0x12345679` (`CS_MAGIC`) or raw instructions with no header.
- **agl BAHS**: Found in `agl` `sharcb` resource packs. Stores control sections and code areas referenced by relative offsets within a memory pool region.

#### Switch 2 Ampere BNSH & BAHS
- NVN2 introduces Ampere code (`sm86` instruction set, 128-bit instructions, 0x80-byte SPH):
  - In `shader_split.py`, `nvn2_ctl(ctl)` identifies NVN2 control sections:
    - Control magic `CTL_MAGIC` (`0x98761234`) followed by version byte `0xc9` (`0x000000c9` at `+4`).
    - Length of code area is at `ctl + 0x44` (instead of `+0x704`).
    - Section length is at `+0x30` (typically `0xd8` in BNSH files, `0xd0` in effects).
    - Stage byte is located at `ctl + 0x56` (`5` = compute `cs`, `6` = task `ts`, `7` = mesh `ms`).
  - In BNSH containers, NVN2 task and mesh shaders appear at offsets `+0x40` (`ts`) and `+0x48` (`ms`) of the variation program record.

#### Third-Party Engine Containers
`shader_split.py` includes dedicated parsers for all major engines:
- **Unity**: Serialized `Shader` and `ComputeShader` objects extracted via `unityfs.py`, matching type trees across bundles.
- **Unreal Engine**: UE 4.18 through 5.6 cooked package shader code archives, IoStore containers, and Oodle-compressed blocks parsed via `uepak.py`.
- **GLSLC Loose Binaries**: Raw Nintendo GLSLC outputs with section headers.
- **Other engines**: RE Engine (`SDF`), Koei Tecmo (`G2S` / `LINKDATA`), Retro Studios (`SNVN` / `RFRM`), MercurySteam (`MSHD` / `bshdat`), PlatinumGames (`PGSO`), FromSoftware (`BND3` / `dvdbnd`), Frostbite superbundles, Snowdrop SDF slices.

### 1.3 Keying Scheme and Record Serialization
A shader is uniquely keyed by its content hash to ensure deduplication across container variants and updates:
```python
key = sha256(key_ctl(ctl) + code)[:16]
```
- For Switch 1: `key_ctl` normalizes `ctl[0:0x880]`, masking non-deterministic runtime pointer slots and build timestamps.
- For Switch 2 NVN2: `key_ctl` normalizes `ctl[:0x48]` with `ctl[0x30:0x34]` zeroed.
- The 16-character hex string (64-bit truncated SHA-256) serves as `dm_ctl_sha16`, the universal identifier used across tools, filenames, logs, and runtime hashes.

`shader_split.py` serializes extracted shaders into stage-partitioned binary archive packages in `<pkg>/`:
- File naming: `<stage>_<group>.bin` (e.g. `vs_RomFS.bin`, `ps_RomFS.bin`, `cs_RomFS.bin`).
- Record format:
  - Magic separator: `BTCDBTCD` (8 bytes)
  - Key: 8 bytes binary (16 hex chars)
  - Reserved padding: 0x28 bytes
  - Header: `uint32_t ctl_len`, `uint32_t code_len` (8 bytes)
  - Payload: `code` bytes followed immediately by `ctl` bytes.

Along with binary packages, extraction generates:
- `shader_map.tsv`: maps `package`, `index`, `stage`, `dm_ctl_sha16`, and `source` provenance.
- `shader_facts.tsv`: records compute local threadgroup dimensions `[x, y, z]` and shared memory bytes extracted from control sections (`at (0x748, 0x754)` for Maxwell, `(0x58, 0x64)` for NVN2), merged with any manual entries in `shader_facts_manual.tsv`.
- `shader_pairs.tsv` and `pso_pairs.tsv`: explicit (vertex key, pixel key) pairs observed together in container variations.

---

## 2. Maxwell/Ampere to SPIR-V Translation

### 2.1 Native Translator Architecture (`dmsh_xlate`)
Translation of Maxwell and Ampere machine code into standard Vulkan-compatible SPIR-V is performed by `dmsh_xlate`:
- **Source**: `dm/gfx/tools/dmsh_xlate/Program.cs` and `dmsh_xlate.csproj`.
- **Implementation**: Written in C# targeting .NET 10.0, published via NativeAOT into a standalone, universal Mach-O binary (`dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate` supporting both `arm64` and `x86_64`). It requires no installed .NET runtime on user systems.
- **Core Engine**: Direct compilation against `Ryujinx.Graphics.Shader` (located in `dm/third_party/ryujinx`).
- **Input/Output Contract**:
  - Invocation: `dmsh_xlate <job.json> <output_dir>`
  - Job structure: JSON array specifying `key`, `stage` (`vs`, `ps`, `cs`, `gs`, `ts`, `ms`), `code` file path, `arch` (`sm86` for Ampere, omitted for Maxwell), constant buffer data (`c1`), query answers (`tex`, `img`, `attr`, `fout`, `local`, `shared`), and flags (`reduced`, `debug`, `softfloat64`).
  - Output files: `<key>.spv` (binary SPIR-V bytecode) and `<key>.res.json` (reflection metadata).

### 2.2 Truthful Query Answering via `IGpuAccessor`
The Ryujinx translator was originally written for an emulator that queries emulator state on demand. In nxnative's AOT batch mode, `dmsh_xlate` implements `IGpuAccessor` through its `Accessor` class:
1. **Accurate Format & Dimension Feedback**: Answering texture types (1D, 2D, 3D, Cube, Array, Multisample) and image formats from `shader_facts.tsv` rather than falling back to 2D defaults.
2. **Handle Table Demangling**: Demangles 32-bit texture and sampler handle words from Maxwell/Ampere driver constant banks `c[2]` (`0x20 + 8*slot` for combined textures, `0x120 + 8*slot` for images, `0x168 + 8*slot` for separate textures, `0x568 + 8*slot` for separate samplers).
3. **Constant Buffer 1 (`c1`) Readback**: Feeds the embedded 0x100-byte constant segment `c1` directly into `ConstantBuffer1Read(int offset)` so the translator can resolve indirect branch jump tables (`BRX` / `LDC c[1]`). Without this, indirect branches loop indefinitely or fail control flow reconstruction.
4. **Depth Semantics Preservation**: `QueryGraphicsState()` specifies `depth not rewritten` (z goes out unchanged in NVN near=0 coordinates), origin upper-left, and early fragment test flags from `ctl + 0x718`.

### 2.3 Maxwell `sm50` vs Ampere `sm86` Decoding
When `"arch": "sm86"` is passed:
- `TranslationFlags.Ampere` is enabled in `Translator.CreateContext`.
- Ryujinx uses the Ampere instruction decoder for 128-bit SASS instructions (supporting new Ampere instructions such as `BMSK`, `PLOP3`, `LEA.SX32`, `HADD2`, `HFMA2.H0_NH1`, `FRND.F16`, `SUATOM.CAS`, `HMMA`, `LDSM`).
- Decodes task and mesh stage metadata and push blocks (`QueryAmpereStageBank` and `QueryAmpereStageMemory`).

### 2.4 Pre-SPIR-V Workarounds: `VertexCounterLowering`
Certain shaders use features that SPIRV-Cross cannot map to Metal (e.g. Tears of the Kingdom 1.4.3 visibility counter vertex shader using `OpGroupNonUniformBallot` and `SubgroupLocalInvocationId`). Metal does not support subgroup builtins in vertex stages. `VertexCounterLowering` intercepts the generated SPIR-V binary directly and rewrites the subgroup ballot into a singleton invocation fallback.

---

## 3. SPIRV-Cross Integration & ABI Conventions

### 3.1 Pinned Binary & Tool Verification
SPIRV-Cross translates SPIR-V bytecode into MSL source code:
- **Location**: `dm/gfx/tools/spirv_cross_bin/spirv-cross`.
- **Commit Pin**: Vulkan SDK release `vulkan-sdk-1.4.363.0` (commit `f11ba9f0b21ba8fc15153d50a2a1ae31ab1cf8f7`).
- **Reproducibility**: Built via `build.sh` as a universal binary (`arm64;x86_64`) with `SOURCE_DATE_EPOCH` pinned. Its SHA-256 is tracked in `dm/gfx/tools/dmsh_chain.lock`.
- Verified at runtime by `test_spirv_cross_pin.py` and `tool_lock.py`.

### 3.2 Command-Line Flags & Configuration
In `dm/gfx/tools/dmsh_build.py`, SPIRV-Cross is invoked with base flags:
```python
XC = [
    '--msl',
    '--msl-version', '20300',             # MSL 2.3 baseline
    '--msl-argument-buffers',              # Emits argument buffer structs (struct set0)
    '--msl-texture-buffer-native',         # Native Metal texture buffers
    '--msl-pad-fragment-output'            # Ensures render target outputs match attachments
]
```
When a module contains image atomics (`OpImageTexelPointer`), `dmsh_atomic.py` detects it and dynamically elevates `--msl-version` to `30100` (MSL 3.1).

### 3.3 ABI Specifications (`dmsh_abi.h` & `dmsh_abi.py`)
`dm/gfx/nvn/dmsh_abi.h` is the single source of truth defining the interface contract between offline translation (`dmsh_build.py`, `dmsh_reflect.py`) and runtime replay (`nvn_mtl.m`, `hle_nvn.c`). It is parsed strictly by `dmsh_abi.py`:

```c
// Driver Constant Segment Bounds
#define DMSH_DRV_SIZE          0xA00   // 2560 bytes driver bank

// Driver Bank c2: Handle Tables (8 bytes per slot)
#define DMSH_C2_ROW            8
#define DMSH_C2_TEX            0x20    // Combined textures (41 slots)
#define DMSH_C2_TEX_SLOTS      41
#define DMSH_C2_IMG            0x120   // Images (8 slots)
#define DMSH_C2_IMG_SLOTS      8
#define DMSH_C2_SEPTEX         0x168   // Separate textures (128 slots)
#define DMSH_C2_SAMP           0x568   // Separate samplers (128 slots)
#define DMSH_C2_SEP_SLOTS      128
#define DMSH_SEPTEX_SLOT0      128     // Separate texture slot offset

// Driver Bank c0: Storage Buffers & Fixed System Offsets (16 bytes per entry)
#define DMSH_C0_ROW            0x10
#define DMSH_C0_SSBO_SLOTS     16
#define DMSH_C0_SSBO_VS        0x110   // Vertex SSBO table
#define DMSH_C0_SSBO_CS        0x310   // Compute SSBO table
#define DMSH_C0_SSBO_GS        0x410   // Geometry SSBO table
#define DMSH_C0_SSBO_PS        0x510   // Pixel SSBO table
#define DMSH_C0_SSBO_TS        0x670   // Task SSBO table
#define DMSH_C0_SSBO_MS        0x770   // Mesh SSBO table
#define DMSH_C0_DISPATCH       0x200   // Compute dispatch workgroups (x, y, z)
#define DMSH_C0_DISPATCH_NVN2  4       // NVN2 compute dispatch workgroups
#define DMSH_C0_CS_UBO         0x210   // Compute uniform buffer table
#define DMSH_C0_POINT_SIZE     0x610   // Largest point size clamp
#define DMSH_C0_BASE_INSTANCE  0x644   // Base instance offset

// Special Buffer Bindings
#define DMSH_ALPHA_BUFFER      30      // Fragment alpha-test buffer
#define DMSH_LOGIC_BUFFER      29      // Fragment logic-operation buffer
#define DMSH_BLEND_BUFFER      28      // Blend zero options buffer
#define DMSH_TG_SLOT           30      // Compute threadgroup spilled memory buffer
#define DMSH_TG_MAX            0x8000  // 32 KB Metal threadgroup limit
```

---

## 4. MSL Generation & Post-Processing Transformations

Raw MSL output directly from SPIRV-Cross cannot be executed correctly on Apple GPUs without extensive semantic transformations. `dmsh_build.py` orchestrates a pipeline of specialized post-processing passes:

### 4.1 Post-Processing Rewriting Modules
1. **Precise Math & NaN Preservation (`dmsh_rewrite.precise`)**:
   - Replaces `fast::min`, `fast::max`, and `fast::clamp` with `precise::min`, `precise::max`, `precise::clamp` to match Maxwell IEEE-754 NaN propagation rules.
2. **Memory Barriers vs Fences (`dmsh_rewrite.membar_fence`)**:
   - Maxwell `MEMBAR` instructions are memory fences, not execution barriers. Translates incorrect `threadgroup_barrier(mem_flags::mem_device)` into `atomic_thread_fence`.
3. **Bounded Uniform Loads (`dmsh_fetch.select_guards`)**:
   - Rewrites branches inserted by the translator for bounded uniform loads into single loads followed by `select()`.
4. **Wide Storage Loads Fusion (`dmsh_wide.wide_loads`)**:
   - Ryujinx splits 64-bit and 128-bit global/storage loads into multiple 32-bit scalar loads. `dmsh_wide.py` fuses adjacent scalar loads back into single vectorized `ulong`, `uint2`, or `uint4` memory operations.
5. **Ampere HMMA Tensor Core Operations (`dmsh_rewrite.hmma_msl`)**:
   - Lowers Ampere `HMMA` matrix multiply-accumulate instructions to Metal SIMD-group matrix intrinsics (`simdgroup_matrix<half, 8, 8>`).
6. **Shared Memory Byte Stores (`dmsh_rewrite.shared_store_msl`)**:
   - Converts 8-bit and 16-bit CAS emulation loops in threadgroup memory into direct sub-word memory writes.
7. **Threadgroup Memory Spill (`dmsh_rewrite.tg_spill`)**:
   - If compute shared memory exceeds Metal's 32 KB per-threadgroup limit, spills excess memory into an auxiliary device buffer bound at `buffer(30)`.
8. **Sampler Border Color Emulation (`dmsh_rewrite.border_emu`)**:
   - Metal hardware samplers only support `transparentBlack`, `opaqueBlack`, and `opaqueWhite`. Custom border colors are emulated by creating a twin sampler (`_w`) and evaluating a mathematical blend factor `bk` in shader code.
9. **Native Image Atomics (`dmsh_atomic.py`)**:
   - Eliminates SPIRV-Cross's pointer emulation (which fails on Tegra block-linear deswizzled layouts) in favor of native MSL 3.1 texture atomics (`atomic_fetch_max`, `atomic_fetch_min`). Combines twin 32-bit atomics on RG32UI into native 64-bit texture atomics on `ulong`.

### 4.2 Entry Points & Variants Generation (`dmsh_entry.py`)
Each compiled shader library exposes multiple specialized entry points to satisfy runtime state changes without recompilation:
- **`main0` vs `main0_z` (Depth Mode Convention)**:
  - NVN allows games to configure depth range dynamically via `nvnDeviceSetDepthMode`: GL convention (`near = -w`, where clip z is normalized as `z' = z/2 + w/2`) vs DirectX/Metal convention (`near = 0`, where clip z is unchanged).
  - Rather than recompiling, `vs_depth` generates both `main0` (with GL z-transformation) and `main0_z` (unchanged z) within the same library.
- **`main0_u` & `main0_m` (Integer Render Target Outputs)**:
  - Generated by `fs_uint` for pipelines binding integer color attachments.
- **`main0_d` (Dual-Source Blending)**:
  - Generated by `fs_dual` when fragment output 1 is used as secondary blend color factor.
- **`main0_l` & `main0_lz` (Layer Replication)**:
  - Generated by `vs_layer_entry` when a geometry shader is folded away and the vertex shader writes `[[render_target_array_index]]`.
- **`main0_discard`**:
  - Emitted by `vs_discard` for transform-feedback draws that discard rasterization.
- **`main0_f` (Readable-Tile Framebuffer Fetch, `<key>_bf`)**:
  - Generated by `dmsh_fetch.fold` using MSL subpass inputs (`[[color(n)]]`), avoiding costly texture readbacks.
- **`main0_a` & `main0_l` (Side Libraries, `<key>_bx`)**:
  - Generated by `dmsh_side.py` for legacy alpha-testing (`dmsh_alpha.py`) and logic-op emulation (`dmsh_logic.py`).

### 4.3 Vertex Input Shadowing & Pulling Variants
- **Shadow Vertex Inputs (`<key>_bv.metallib`, `dmsh_vin.py`)**:
  - Handles mismatches where an attribute declared as integer is fed a float or normalized format. Maps extra float and integer shadows to attribute slots 16..30 and bit-casts them together.
- **Pulling Vertex Inputs (`<key>_bp.metallib`, `dmsh_pull.py`)**:
  - Removes `[[stage_in]]` entirely. Injects `dmsh_pull.metal` at `buffer(16)`, performing software attribute fetch and format conversion using vertex ID, instance ID, and base instance.
  - Used for **hybrid pipelines** at runtime to completely eliminate PSO creation stalls.

---

## 5. Metal Shader Library Compilation

### 5.1 Compilation Workflow & Toolchain Flags
Metal libraries are compiled using the Xcode command-line toolchain (`xcrun -sdk macosx metal` and `metallib`):
```
Source (.metal) 
    --(metal -c)--> Intermediate Representation (.air) 
    --(metallib)--> Metal Library (.metallib)
```

The exact compiler command line executed by `mac_compile` in `dmsh_build.py` is:
```bash
xcrun -sdk macosx metal -c -O1 \
    -mmacosx-version-min=13.0 \
    -fpreserve-invariance \
    -fwrapv \
    -fbracket-depth=1024 \
    -isysroot <SDK_PATH> \
    -include-pch <PCH_PATH> \
    <input>.metal -o <output>.air

xcrun -sdk macosx metallib <output>.air -o <output>.metallib
```
Key compiler options:
- `-O1`: Balances compiler optimization with compile time. Avoids severe control-flow lowering bugs present at `-O2` in Apple's Clang frontend on large nested shaders.
- `-fpreserve-invariance`: Ensures `[[invariant]]` position calculations match bit-for-bit across different pipeline variants (preventing z-fighting between normal and pulling pipelines).
- `-fwrapv`: Enforces two's-complement signed integer wrapping. SASS and SPIR-V rely on wrapping overflow; in standard MSL, signed overflow is undefined, leading Clang to miscompile loop counters and packed bitfield arithmetic.
- `-fbracket-depth=1024`: Increases maximum parser bracket nesting depth from 256 to 1024 (accommodating complex machine-generated ASTs).

### 5.2 Precompiled Header Acceleration (`dmsh_pch.py`)
Profiling revealed that over 80% of Clang's frontend time was spent instantiating Metal texture template classes (`texture2d<float>`, `memory_coherence_device`, etc.).
`dmsh_pch.py` solves this by synthesizing an internal prefix header (`prefix.h`) containing static assertions of all common Metal template instantiations:
```metal
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;
static_assert(sizeof(texture2d<float, access::sample, memory_coherence_device>) > 0);
// ... instantiations for all texture types and coherence modes
```
It precompiles this header into `prefix.pch` once per process session. Compilations passing `-include-pch prefix.pch` bypass template instantiation, reducing per-shader compilation time by up to 5x.

### 5.3 Host Internal Metal Shaders (`host_msl.py`)
The host emulator's internal graphics operations (`dm/gfx/msl/*.metal`, including blits, format deswizzling, resolves, clears, and presentation scaling) are compiled AOT at host build time via `dm/gfx/tools/host_msl.py`. The resulting bytecode is embedded into C byte arrays in `host_msl.h`. The host runtime creates libraries using `newLibraryWithData:`, ensuring `newLibraryWithSource:` is never invoked during gameplay.

---

## 6. Compilation Lifecycle & Execution Phases

| Phase | When Occurs | Tools & Mechanisms | Artifacts / Actions |
|---|---|---|---|
| **AOT Packaging** | During build/packaging (`build_ipa_from_nsp.py`) | `shader_split.py`, `dmsh_xlate`, `spirv_cross`, `dmsh_build.py`, `pso_offline.py` | Extracts all shaders, translates to SPIR-V, generates MSL variants, compiles `.metallib` files, stores in `cas.db`, produces `<arch>.mtl4a` pipeline archives. |
| **Startup PSO Prewarm** | At game launch, prior to first frame | `pso_prebuild` in `nvn_mtl.m`, `MTL4Compiler` | Displays "Preparing shaders" UI. Pre-compiles all pipeline states listed in `pso_manifest.tsv` and `pso_user.tsv` across all CPU cores. |
| **Runtime Execution** | During active gameplay frame replay | `nvn_mtl.m`, `pso_build`, background compile queue | Matches PSOs by state hash. If specialized PSO is missing, **dispatches immediately using pulling pipeline (`_bp`)** while background thread compiles specialized PSO. Appends new PSOs to `pso_user.tsv`. |

### Hybrid Pipelines: Stutter-Free Runtime
Traditional emulators suffer from "shader compilation stutter" when a game issues a draw call with an unseen combination of vertex format, shader pair, and render target state.
nxnative eliminates this entirely:
1. Every shader pair pre-compiles a **pulling pipeline** (`<key>_bp`).
2. The pulling pipeline has **no vertex descriptor** (it decodes vertex streams in software) and unspecialized color attachments.
3. If a draw call's specialized hardware-accelerated pipeline has not finished compiling, nxnative issues the draw call using the pulling pipeline.
4. Concurrently, a background thread compiles the specialized pipeline using `MTL4Compiler`.
5. Once compiled, subsequent draws switch to the specialized pipeline.
6. The draw never waits; framerate remains locked.

---

## 7. Metal Runtime Execution & Replay Architecture

### 7.1 Command Recording & Replay Layer (`hle_nvn.c` & `nvn_mtl.m`)
- **Recording (`dm/gfx/nvn/hle_nvn.c`)**:
  - Host intercept thunks in `nvn_thunks.S` route 523 NVN APIs to `hle_nvn.c`.
  - Commands and state changes are recorded into zero-copy command memory provided by the guest application.
- **Replay (`dm/gfx/nvn/nvn_mtl.m`)**:
  - Replays the command stream as Metal 4 commands at queue submission time (`nvnQueueSubmitCommands`).
  - Employs zero-copy unified memory buffers (`MTLBuffer`) where CPU and GPU addresses match.

### 7.2 Direct vs Deferred Command Encoding (`DM_NVN_ENC_THREAD`)
Encoding draw commands, binding argument buffers, and configuring render pass state accounts for ~40% of the replay thread's CPU time. nxnative provides two execution modes:
- **Direct Encoding (`DM_NVN_ENC_THREAD=0`)**:
  - Replay commands directly call `[e drawPrimitives:...]` on `id<MTL4RenderCommandEncoder>` or `id<MTL4ComputeCommandEncoder>` from the submission thread.
- **Deferred Encoding (`DM_NVN_ENC_THREAD=1`, default on iOS)**:
  - Implemented in `dm/gfx/nvn/nvn_rec.h`.
  - The submit thread dispatches commands to lightweight stand-ins that write fixed-size operation records (`RO_*`) into ring blocks.
  - A dedicated background worker thread (`dm-encode`) drains the records and makes the actual Metal API calls.
  - A secondary copy worker thread (`dm-ub-copy`) asynchronously populates large uniform buffer shadows (`ubp_get`).

### 7.3 Argument Encoding (`encode_args_`)
Arguments are bound into Metal argument buffers defined by `struct set0`:
- **Driver Banks (`c0` and `c2`)**:
  - Filled at `encode_args_` based on the reflection metadata (`drv_reads`).
  - Driver bank `c2` populates texture, image, and sampler handles from bound slots.
  - Driver bank `c0` populates storage buffer base addresses, dispatch dimensions, and point sizes.
- **Uniform Buffers (`c[3..16]`)**:
  - Mapped directly or copied through arena memory if bounds padding is required (`ub_padded`).
- **Texture & Sampler Resource IDs**:
  - Placed into argument buffer slots `aid` as 64-bit Metal GPU resource IDs (`MTLResourceID`).

---

## 8. Shader Caching, Archiving, and Resource Management

### 8.1 Content-Addressable Storage (`DMSH_CAS` / `cas.db`)
`dm/tools/shader_cache.py` implements a SQLite-backed CAS database:
- Path: `<cache_dir>/cas.db` (configurable via `DMSH_CAS`).
- Tables:
  - `blob (id INTEGER PRIMARY KEY, hash BLOB UNIQUE, data BLOB)`
  - `entry (name TEXT PRIMARY KEY, blob INTEGER, mtime REAL) WITHOUT ROWID`
- Stores:
  - Compiled Metal libraries: `metallib/<target>/<digest>.metallib` (deduplicated by MSL text and compiler flags).
  - Shader outputs: `shader/<digest>/<target>/<file>`.
  - Shader index records: `index/<key>.json`.
- Concurrent multi-process safe: utilizes SQLite Write-Ahead Logging (WAL) with `PRAGMA synchronous=NORMAL`.

### 8.2 Stamp and Safety Verification
- **`inputs.tsv`**: Placed in `b-<V>/inputs.tsv`. Contains the SHA-256 digest of all input tables (`shader_facts.tsv`, `shader_map.tsv`, `shader_pairs.tsv`) and profile keys. The host validates this stamp on boot; a mismatch causes the host to reject the cached libraries.
- **`c1_full.tsv` (`c1_guard.py`)**: Uses formal interval arithmetic over MSL code to prove which shaders have bounded reads of constant buffer 1. Shaders not proven safe receive a private 64 KiB zeroed allocation.
- **`cb_extent.tsv` (`cb_extent.py`)**: Computes the exact byte extent read by each shader for each uniform buffer slot, allowing `DM_NVN_UB_DEFER` to copy only necessary ranges.

### 8.3 Offline Pipeline Archives (`pso_offline.py` & `.mtl4a`)
To avoid compiling pipeline state objects on the target device, `dm/gfx/tools/pso_offline.py` compiles pipeline bases offline using Apple's `metal-tt` (Metal Toolchain Tools):
- Input: `shader_pairs.tsv`, `pso_pairs.tsv`, `pso_manifest.tsv`, and `.metallib` files.
- Output: `<arch>.mtl4a` (e.g. `applegpu_g18p.mtl4a` for Apple A19 / A19 Pro) and `prebuilt.tsv`.
- Merging: Groups of 1,000 bases are compiled in parallel batches and merged using `metal-pack`.
- Runtime: `nvn_mtl.m` opens the archive via `newArchiveWithURL:` (`MTL4Archive`) and instantiates PSOs in ~0.06 ms instead of 10–80 ms.

---

## 9. Inventory of Files, Tools, and Build Targets

### 9.1 Core Files and Directories

| Path | Primary Responsibility |
|---|---|
| `dm/gfx/tools/shader_split.py` | Universal container extraction (BNSH, BAHS, GLSLC, Unity, UE, etc.) and record packaging. |
| `dm/gfx/tools/dmsh_xlate/` | C# NativeAOT tool invoking `Ryujinx.Graphics.Shader` to translate SASS to SPIR-V. |
| `dm/gfx/tools/dmsh_xlate_bin/` | Compiled universal binary `dmsh_xlate`. |
| `dm/gfx/tools/spirv_cross_bin/` | Pinned Khronos `spirv-cross` universal binary. |
| `dm/gfx/tools/dmsh_build.py` | Orchestrator for AOT MSL generation, rewriting passes, and Metal library compilation. |
| `dm/gfx/tools/dmsh_chain.py` | Manages chain version hash `DMSH_CHAIN`, tool locking, and `inputs.tsv` stamps. |
| `dm/gfx/tools/dmsh_rewrite.py` | MSL source rewriting passes (precise math, fences, wide loads, HMMA, shared memory). |
| `dm/gfx/tools/dmsh_entry.py` | Entry point generation (`main0`, `main0_z`, `main0_u`, `main0_m`, `main0_d`, `main0_l`). |
| `dm/gfx/tools/dmsh_reflect.py` | Reflection extractor; computes attribute layouts, binding indices, and raster facts. |
| `dm/gfx/tools/dmsh_vin.py` | Shadow vertex input conversion variant generator (`<key>_bv`). |
| `dm/gfx/tools/dmsh_pull.py` & `.metal` | Pulling vertex input variant generator (`<key>_bp`) for hybrid pipelines. |
| `dm/gfx/tools/dmsh_fetch.py` | Framebuffer fetch / programmable tile read variant generator (`<key>_bf`). |
| `dm/gfx/tools/dmsh_meshstage.py` | NVN2 task & mesh shader lowering to Metal mesh shading pipelines. |
| `dm/gfx/tools/dmsh_pch.py` | Precompiled header generation and management for Metal Clang. |
| `dm/gfx/tools/dmsh_mtlcache.py` | MSL-keyed compilation cache layer for `dmsh_build.py`. |
| `dm/gfx/tools/c1_guard.py` | Interval arithmetic analyzer for constant buffer 1 read safety (`c1_full.tsv`). |
| `dm/gfx/tools/cb_extent.py` | Uniform buffer access extent bounding tool (`cb_extent.tsv`). |
| `dm/gfx/tools/pso_offline.py` | Offline PSO pipeline archive compiler (`metal-tt` -> `.mtl4a`). |
| `dm/gfx/tools/host_msl.py` | AOT compiler for host internal shaders (`dm/gfx/msl/*.metal`). |
| `dm/tools/shader_cache.py` | SQLite CAS implementation (`cas.db`). |
| `dm/tools/shader_lib.py` | Single-file archive packaging (`.img` format) for shader distributions. |
| `dm/gfx/nvn/dmsh_abi.h` | C header defining driver segments, bindings, and hardware constant buffer offsets. |
| `dm/gfx/nvn/dmsh_chain.h` | Generated header defining the active `DMSH_CHAIN` version string. |
| `dm/gfx/nvn/hle_nvn.c` | Guest NVN API interception and command recording layer. |
| `dm/gfx/nvn/nvn_mtl.m` | Metal 4 command replay, PSO caching, argument encoding, and presentation pacer. |
| `dm/gfx/nvn/nvn_rec.h` | Multi-threaded deferred command encoder (`DM_NVN_ENC_THREAD=1`). |

### 9.2 Key Build Targets & Tool Commands
- **Rebuild Native Tools**:
  ```bash
  dm/tools/native_tools.sh dmsh_xlate
  ```
- **Update Tool Lock & Chain Header**:
  ```bash
  python3 dm/gfx/tools/tool_lock.py --update-lock
  python3 dm/gfx/tools/dmsh_chain.py --header
  ```
- **Run AOT Shader Build**:
  ```bash
  python3 dm/gfx/tools/dmsh_build.py <Switch_pkg_dir> <output_cache_dir>
  ```
- **Generate Offline Pipeline Archive**:
  ```bash
  python3 dm/gfx/tools/pso_offline.py --msl <b-chain_dir> --out <pso_dir> --work <work_dir> --game <title_id> --gpu g18p
  ```
- **Build Full Host**:
  ```bash
  make -C dm/host GAME=<title_id>
  ```

---

## 10. Opportunities & Architectural Considerations for MLIR Optimization

Based on this architectural inspection, several clear opportunities emerge where MLIR (`mlir-opt`) can substantially improve or modernize nxnative's shader pipeline:

1. **Replacing Fragile Text/Regex Rewriting Passes**:
   - Currently, MSL post-processing relies on regex string substitutions and bracket parsing in Python (`dmsh_rewrite.py`, `dmsh_wide.py`, `dmsh_atomic.py`).
   - Operating on an MLIR intermediate representation (such as the `spirv` dialect or an LLVM/Metal dialect) would allow robust, mathematically verified structural transformations (e.g. wide vector load fusion, accurate interval bounds analysis, SIMD matrix lowering).
2. **SPIR-V Dialect Optimizations Prior to MSL Emission**:
   - Ryujinx emits SPIR-V containing excessive temporaries, split 32-bit loads, redundant constant buffer indexing, and complex control flow for bounds checking.
   - An MLIR optimization pipeline running standard canonicalization, dead-code elimination, memory-to-reg, and loop optimizations on SPIR-V can clean up the code before it ever reaches SPIRV-Cross.
3. **Cross-Stage Optimization (VS -> PS Varying Elimination)**:
   - In `dmsh_build.py`, `vs_pad` manually parses pixel shader inputs to pad unused vertex shader outputs with `(0, 0, 0, 1)`.
   - In MLIR, paired shaders can be optimized jointly as a single module, eliminating dead varyings and matching attribute locations automatically.
4. **Direct Vectorization of Global Memory Access**:
   - Instead of pattern-matching adjacent array indices in generated MSL strings, MLIR vector dialects can analyze affine access patterns on storage buffers and emit optimal 64-bit and 128-bit memory instructions.
5. **Deterministic Math and Fast-Math Scoping**:
   - Rather than relying on global Clang flags (`-O1`, `-fwrapv`) or blanket regex replacements of `fast::` with `precise::`, MLIR can decorate individual operations with precise arithmetic fast-math flags (`arith.fastmath`), unlocking aggressive optimization on unaffected subgraphs while strictly preserving Maxwell IEEE behavior on sensitive calculations.
