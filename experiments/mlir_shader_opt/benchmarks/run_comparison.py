#!/usr/bin/env python3
"""
Full Automated Benchmark & Comparison Runner:
Baseline (SPIR-V -> SPIRV-Cross -> Metal) vs. Experimental (SPIR-V -> MLIR -> MLIR Passes -> SPIR-V -> SPIRV-Cross -> Metal)
on Apple Silicon GPU (Apple M4).
"""
import os, sys, json, time, subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DATASET_DIR = Path('/Volumes/Yannis T7/nup_extracted/mlir_experiment_dataset')
MANIFEST_PATH = REPO_ROOT / 'experiments/mlir_shader_opt/shader_dataset/manifest.json'
RESULTS_DIR = REPO_ROOT / 'experiments/mlir_shader_opt/results'
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

MLIR_TRANSLATE = '/opt/homebrew/opt/llvm/bin/mlir-translate'
MLIR_OPT = '/opt/homebrew/opt/llvm/bin/mlir-opt'
SPIRV_CROSS = str(REPO_ROOT / 'dm/gfx/tools/spirv_cross_bin/spirv-cross')
METAL_BENCH = str(REPO_ROOT / 'experiments/mlir_shader_opt/metal/metal_bench')

XC_ARGS = ['--msl', '--msl-version', '20300', '--msl-argument-buffers', '--msl-texture-buffer-native', '--msl-pad-fragment-output']
MLIR_PASSES = ['--no-implicit-module', '--canonicalize', '--cse', '--sccp', '--spirv-canonicalize-gl', '--symbol-dce']

def main():
    manifest = json.loads(MANIFEST_PATH.read_text())
    print(f"Loaded {len(manifest)} shaders from manifest.")
    
    report_rows = []
    detailed_results = []
    
    for entry in manifest:
        k = entry['key']
        stage = entry['stage']
        cat = entry['category']
        spv_orig = entry['spv_path']
        
        print(f"\n==========================================")
        print(f"Processing {k} [{stage.upper()}] ({cat})")
        print(f"==========================================")
        
        # 1. Baseline: SPIR-V -> SPIRV-Cross -> MSL
        msl_base = DATASET_DIR / f"{k}_baseline.metal"
        t_spv_msl_0 = time.perf_counter()
        r_cross = subprocess.run([SPIRV_CROSS, *XC_ARGS, spv_orig, '--output', str(msl_base)], capture_output=True, text=True)
        t_spv_msl_1 = time.perf_counter()
        spv_to_msl_base_ms = (t_spv_msl_1 - t_spv_msl_0) * 1000.0
        
        if r_cross.returncode != 0:
            print(f"[FAIL Baseline SPIRV-Cross] {r_cross.stderr.strip()[:80]}")
            continue
            
        base_msl_size = msl_base.stat().st_size
        print(f"Baseline MSL: {base_msl_size} bytes (cross time: {spv_to_msl_base_ms:.2f} ms)")
        
        # Benchmark Baseline on GPU
        bench_base = None
        r_bench_base = subprocess.run([METAL_BENCH, str(msl_base), stage, '10', '30'], capture_output=True, text=True)
        if r_bench_base.returncode == 0:
            try: bench_base = json.loads(r_bench_base.stdout)
            except Exception: pass
            
        if bench_base:
            print(f"Baseline Metal Compile: {bench_base['compile_ms']:.2f} ms | GPU Median: {bench_base['gpu_median_us']:.2f} us | Checksum: {bench_base.get('checksum')}")
        else:
            print(f"[Baseline Benchmark Error]: {r_bench_base.stderr.strip()[:80]}")
            
        # 2. Experimental: SPIR-V -> MLIR -> Passes -> SPIR-V -> SPIRV-Cross -> MSL
        mlir_raw = DATASET_DIR / f"{k}.mlir"
        mlir_opt = DATASET_DIR / f"{k}_opt.mlir"
        spv_opt = DATASET_DIR / f"{k}_opt.spv"
        msl_opt = DATASET_DIR / f"{k}_opt.metal"
        
        t_mlir_0 = time.perf_counter()
        r_deser = subprocess.run([MLIR_TRANSLATE, '--deserialize-spirv', spv_orig, '-o', str(mlir_raw)], capture_output=True, text=True)
        mlir_import_ok = (r_deser.returncode == 0)
        
        res_item = {
            'key': k,
            'stage': stage,
            'category': cat,
            'code_size_bytes': entry['code_size_bytes'],
            'spv_orig_size': Path(spv_orig).stat().st_size,
            'base_msl_size': base_msl_size,
            'spv_to_msl_base_ms': spv_to_msl_base_ms,
            'bench_base': bench_base,
            'mlir_supported': mlir_import_ok,
            'mlir_error': r_deser.stderr.strip() if not mlir_import_ok else None
        }
        
        if not mlir_import_ok:
            print(f"MLIR Import: UNSUPPORTED ({r_deser.stderr.strip()[:60]})")
            report_rows.append({
                'key': k, 'stage': stage, 'cat': cat, 'status': 'UNSUPPORTED_MLIR',
                'reason': r_deser.stderr.strip()[:40],
                'base_msl_kb': base_msl_size / 1024.0,
                'opt_msl_kb': 0,
                'base_gpu_us': bench_base['gpu_median_us'] if bench_base else 0,
                'opt_gpu_us': 0,
                'gpu_speedup': 0
            })
            detailed_results.append(res_item)
            continue
            
        # Run MLIR Optimization Passes
        r_pass = subprocess.run([MLIR_OPT, *MLIR_PASSES, str(mlir_raw), '-o', str(mlir_opt)], capture_output=True, text=True)
        if r_pass.returncode != 0:
            print(f"[FAIL MLIR Passes] {r_pass.stderr.strip()[:80]}")
            continue
            
        # Normalize legacy BufferBlock if present
        opt_text = mlir_opt.read_text()
        if 'BufferBlock' in opt_text:
            mlir_opt.write_text(opt_text.replace('BufferBlock', 'Block'))
            
        # Reserialize to SPIR-V
        r_ser = subprocess.run([MLIR_TRANSLATE, '--serialize-spirv', '--no-implicit-module', str(mlir_opt), '-o', str(spv_opt)], capture_output=True, text=True)
        if r_ser.returncode != 0:
            print(f"[FAIL MLIR Serialize] {r_ser.stderr.strip()[:80]}")
            continue
            
        t_mlir_1 = time.perf_counter()
        mlir_pipeline_time_ms = (t_mlir_1 - t_mlir_0) * 1000.0
        
        # Cross compile optimized SPIR-V to MSL
        r_cross_opt = subprocess.run([SPIRV_CROSS, *XC_ARGS, str(spv_opt), '--output', str(msl_opt)], capture_output=True, text=True)
        if r_cross_opt.returncode != 0:
            print(f"[FAIL Opt SPIRV-Cross] {r_cross_opt.stderr.strip()[:80]}")
            continue
            
        opt_msl_size = msl_opt.stat().st_size
        print(f"Optimized MSL: {opt_msl_size} bytes (MLIR overhead: {mlir_pipeline_time_ms:.2f} ms, MSL size delta: {opt_msl_size - base_msl_size} B)")
        
        # Benchmark Optimized on GPU
        bench_opt = None
        r_bench_opt = subprocess.run([METAL_BENCH, str(msl_opt), stage, '10', '30'], capture_output=True, text=True)
        if r_bench_opt.returncode == 0:
            try: bench_opt = json.loads(r_bench_opt.stdout)
            except Exception: pass
            
        if bench_opt and bench_base:
            speedup = ((bench_base['gpu_median_us'] - bench_opt['gpu_median_us']) / bench_base['gpu_median_us']) * 100.0
            chk_base = bench_base.get('checksum')
            chk_opt = bench_opt.get('checksum')
            chk_match = (chk_base == chk_opt) if (chk_base and chk_opt) else False
            print(f"Optimized Metal Compile: {bench_opt['compile_ms']:.2f} ms | GPU Median: {bench_opt['gpu_median_us']:.2f} us (Delta: {speedup:+.1f}%) | Checksum Match: {chk_match}")
            report_rows.append({
                'key': k, 'stage': stage, 'cat': cat, 'status': 'OPTIMIZED',
                'base_msl_kb': base_msl_size / 1024.0,
                'opt_msl_kb': opt_msl_size / 1024.0,
                'base_gpu_us': bench_base['gpu_median_us'],
                'opt_gpu_us': bench_opt['gpu_median_us'],
                'gpu_speedup': speedup,
                'checksum_match': chk_match
            })
            res_item.update({
                'opt_msl_size': opt_msl_size,
                'mlir_pipeline_time_ms': mlir_pipeline_time_ms,
                'bench_opt': bench_opt,
                'speedup_pct': speedup,
                'checksum_match': chk_match
            })
            
        detailed_results.append(res_item)
        
    (RESULTS_DIR / 'benchmark_data.json').write_text(json.dumps(detailed_results, indent=2))
    print(f"\nWrote full benchmark data to: {RESULTS_DIR / 'benchmark_data.json'}")
    
    # Generate Markdown Summary Table
    md = ["# MLIR Shader Optimization Benchmark Report\n",
          "| Shader Key | Stage | Category | Status | Base MSL (KB) | Opt MSL (KB) | Base GPU (µs) | Opt GPU (µs) | GPU Perf Delta | Bit-Exact Correctness |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for r in report_rows:
        if r['status'] == 'OPTIMIZED':
            chk_str = "MATCH" if r.get('checksum_match') else "DIFF"
            md.append(f"| `{r['key']}` | {r['stage']} | {r['cat']} | **OK** | {r['base_msl_kb']:.1f} | {r['opt_msl_kb']:.1f} | {r['base_gpu_us']:.2f} | {r['opt_gpu_us']:.2f} | **{r['gpu_speedup']:+.1f}%** | {chk_str} |")
        else:
            md.append(f"| `{r['key']}` | {r['stage']} | {r['cat']} | *{r['status']}* | {r['base_msl_kb']:.1f} | - | {r.get('base_gpu_us', 0):.2f} | - | - | N/A ({r['reason']}) |")
            
    summary_path = RESULTS_DIR / '06_benchmark_report.md'
    summary_path.write_text('\n'.join(md) + '\n')
    print(f"Summary report written to: {summary_path}")

if __name__ == '__main__':
    main()
