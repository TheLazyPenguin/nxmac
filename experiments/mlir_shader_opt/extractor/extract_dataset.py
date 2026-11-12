#!/usr/bin/env python3
"""
Extract a representative dataset of 20 real Nintendo Switch shaders
from the extracted NUP RomFS and compile them to SPIR-V using dmsh_xlate.
"""
import os, sys, json, struct, subprocess
from pathlib import Path

os.environ['DM_GAME'] = '0400486024DEC000'
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / 'dm/gfx/tools'))
sys.path.insert(0, str(REPO_ROOT / 'dm/tools'))

import shader_split, dmsh_facts, dmsh_ampere

ROMFS_PATH = '/Volumes/Yannis T7/nup_extracted/0400486024DEC000_build/extract/v131072/RomFS.img'
XLATE_BIN = str(REPO_ROOT / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate')
OUTPUT_DIR = Path('/Volumes/Yannis T7/nup_extracted/mlir_experiment_dataset')
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
MANIFEST_PATH = REPO_ROOT / 'experiments/mlir_shader_opt/shader_dataset/manifest.json'

ARCHIVES = [
    ('Effect/Animal_ButterflyToFairy.Nin_Ounce_NVN2.vsetb.byml.zs', 'effect_butterfly'),
    ('Effect/Animal_Butterfly_Minigame.Nin_Ounce_NVN2.vsetb.byml.zs', 'effect_minigame'),
    ('Shader/TerrainGround.Product.110.product.Nin_Ounce_NVN2.bfsha.zs', 'terrain'),
    ('Shader/Foliage.Product.110.product.Nin_Ounce_NVN2.bfsha.zs', 'foliage'),
    ('Shader/Model.Product.110.product.Nin_Ounce_NVN2.bfsha.zs', 'model'),
]

def main():
    print("Loading zstd dictionaries from RomFS...")
    zdicts = shader_split.zs_dicts(ROMFS_PATH)
    shader_split._pool_init(None, {}, zdicts)
    facts_table = dmsh_facts.load()
    
    scanned_shaders = {}
    
    for rel, cat in ARCHIVES:
        full_path = os.path.join(ROMFS_PATH, rel)
        print(f"Scanning archive: {rel}...")
        try:
            res = shader_split.scan_file((full_path, rel))
            for k, v in res[1].items():
                scanned_shaders[k] = (*v, cat)
        except Exception as e:
            print(f"Error scanning {rel}: {e}")
            
    print(f"Total candidate shaders scanned: {len(scanned_shaders)}")
    
    by_stage = {'vs': [], 'ps': [], 'cs': [], 'ms': [], 'ts': []}
    for k, (where, stage, ctl, code, cat) in scanned_shaders.items():
        if stage in by_stage:
            by_stage[stage].append((k, where, stage, ctl, code, cat))
            
    print("Found stages:", {s: len(v) for s, v in by_stage.items()})
    
    selected = []
    # 6 Compute shaders
    selected.extend(by_stage['cs'][:6])
    # 7 Vertex shaders
    sorted_vs = sorted(by_stage['vs'], key=lambda x: len(x[4]))
    if len(sorted_vs) >= 7:
        selected.extend([sorted_vs[0], sorted_vs[len(sorted_vs)//6], sorted_vs[len(sorted_vs)//3],
                         sorted_vs[len(sorted_vs)//2], sorted_vs[2*len(sorted_vs)//3], sorted_vs[-2], sorted_vs[-1]])
    else:
        selected.extend(sorted_vs[:7])
        
    # 7 Pixel shaders
    sorted_ps = sorted(by_stage['ps'], key=lambda x: len(x[4]))
    if len(sorted_ps) >= 7:
        selected.extend([sorted_ps[0], sorted_ps[len(sorted_ps)//6], sorted_ps[len(sorted_ps)//3],
                         sorted_ps[len(sorted_ps)//2], sorted_ps[2*len(sorted_ps)//3], sorted_ps[-2], sorted_ps[-1]])
    else:
        selected.extend(sorted_ps[:7])
        
    print(f"Selected {len(selected)} representative shaders for translation.")
    
    manifest = []
    
    for k, where, stage, ctl, code, cat in selected:
        rec = bytearray(b'BTCDBTCD' + bytes.fromhex(k) + bytes(0x28))
        struct.pack_into('<2I', rec, 0x28, len(ctl), len(code))
        rec += code + ctl
        
        ci = rec.find(bytes.fromhex('34127698'), 0x38)
        code_bytes = rec[0x38:ci]
        extra = {}
        c1 = None
        if dmsh_ampere.is_nvn2(rec[ci:]):
            c1 = dmsh_ampere.c1_segment(rec[ci:], code_bytes)
            code_bytes = code_bytes[:dmsh_ampere.inst_len(rec[ci:])]
            extra['arch'] = 'sm86'
            if stage == 'cs':
                extra['nvn2_cs'] = [rec[ci + 0xb1], rec[ci + 0xb2], rec[ci + 0xb3], struct.unpack_from('<H', rec, ci + 0xba)[0], rec[ci + 0xa9] * 4, rec[ci + 0xb4], rec[ci + 0xb5], rec[ci + 0xaa] * 4]
        
        raw_bin_path = OUTPUT_DIR / f"{k}.bin"
        raw_bin_path.write_bytes(code_bytes)
        
        job = {
            'key': k, 'stage': stage if stage != 'ms' else 'cs', 'code': str(raw_bin_path),
            'tex': {}, 'img': {}, 'attr': {}, 'fout': {},
            'c1': c1.hex() if c1 else '', **extra, 'debug': True, 'reduced': True
        }
        job.update(facts_table.get(k, {}))
        
        job_file = OUTPUT_DIR / f"job_{k}.json"
        job_file.write_text(json.dumps([job]))
        
        r = subprocess.run([XLATE_BIN, str(job_file), str(OUTPUT_DIR)], capture_output=True, text=True)
        spv_path = OUTPUT_DIR / f"{k}.spv"
        res_path = OUTPUT_DIR / f"{k}.res.json"
        
        status = "ok" if r.returncode == 0 and spv_path.exists() else f"failed: {r.stderr.strip()[:60]}"
        print(f"[{status}] {k} ({stage}, {cat}, code={len(code_bytes)}B, spv={spv_path.stat().st_size if spv_path.exists() else 0}B)")
        
        res_data = json.loads(res_path.read_text()) if res_path.exists() else {}
        
        manifest.append({
            'key': k,
            'stage': stage,
            'category': cat,
            'source_path': where,
            'code_size_bytes': len(code_bytes),
            'spv_size_bytes': spv_path.stat().st_size if spv_path.exists() else 0,
            'spv_path': str(spv_path),
            'bin_path': str(raw_bin_path),
            'resources': res_data.get('bindings', {}),
            'threads': res_data.get('threads', [1, 1, 1]) if stage in ('cs', 'ms') else None,
            'status': status
        })
        
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    print(f"Manifest written to: {MANIFEST_PATH}")

if __name__ == '__main__':
    main()
