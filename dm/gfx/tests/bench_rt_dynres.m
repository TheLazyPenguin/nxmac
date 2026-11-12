// Dynamic resolution scaling (DRS) and transient render-target aliasing benchmark (GitHub issue #1831).
// Simulates 1000 frames of fluctuating render-target resolutions (720p, 810p, 900p, 1080p)
// and transient G-buffer passes to measure:
// - Peak GPU heap memory allocated (MB)
// - Cumulative OS memory allocated / churn (MB)
// - Heap reallocations created vs reused
// - CPU allocation/deallocation overhead (ms)
// - Memory savings percentage (%)
#include "../nvn/nvn_mtl.m"

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

typedef struct {
    unsigned w;
    unsigned h;
    const char *name;
} res_preset_t;

static const res_preset_t PRESETS[] = {
    {1280, 720,  "720p"},
    {1440, 810,  "810p"},
    {1600, 900,  "900p"},
    {1920, 1080, "1080p"}
};

// Realistic DRS profile across 1000 frames
static res_preset_t get_drs_preset(int frame) {
    if (frame < 100) return PRESETS[3]; // 1080p steady (calm vista)
    if (frame < 200) return PRESETS[2]; // 900p (moderate load)
    if (frame < 300) return PRESETS[1]; // 810p (dense geometry)
    if (frame < 420) return PRESETS[0]; // 720p (heavy combat / alpha particles)
    if (frame < 500) return PRESETS[1]; // 810p (recovery)
    if (frame < 600) return PRESETS[2]; // 900p (transition)
    if (frame < 700) return PRESETS[3]; // 1080p (calm area)
    if (frame < 850) {
        // Fast camera motion / rapid DRS shifts every 25 frames
        int cycle = (frame - 700) / 25;
        switch (cycle % 4) {
            case 0: return PRESETS[0]; // 720p
            case 1: return PRESETS[1]; // 810p
            case 2: return PRESETS[2]; // 900p
            default: return PRESETS[1]; // 810p
        }
    }
    // Final dynamic stress sequence fluctuating every 10 frames
    int cycle = (frame - 850) / 10;
    return PRESETS[cycle % 4];
}

static tex_t make_target(pool_t *pool, uint64_t serial, uint64_t off, unsigned w, unsigned h, NVNformat fmt) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){
        .target = NVN_TEXTURE_TARGET_2D,
        .format = fmt,
        .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE,
        .width = w,
        .height = h,
        .depth = 1,
        .levels = 1,
        .samples = 1
    };
    nvn_tex_layout(&t.d, &t.L);
    return t;
}

enum {
    PASS_GBUFFER_ALBEDO = 0,
    PASS_GBUFFER_NORMAL,
    PASS_GBUFFER_MATERIAL,
    PASS_GBUFFER_DEPTH,
    PASS_LIGHTING_HDR,
    PASS_BLOOM_HALF,
    PASS_SSAO_QUARTER,
    PASS_DISPLAY_1080P,
    PASS_TARGET_COUNT
};

int main(int argc, const char **argv) { @autoreleasepool {
    int total_frames = 1000;
    int json_output = 0;
    int pressure_at_frame = -1;
    int verbose = 0;
    const char *mode_name = "default";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            total_frames = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--json")) {
            json_output = 1;
        } else if (!strcmp(argv[i], "--pressure-at") && i + 1 < argc) {
            pressure_at_frame = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
            mode_name = argv[++i];
        } else if (!strcmp(argv[i], "--verbose")) {
            verbose = 1;
        }
    }

    mtl_init();

    // 512 MB GPU-only pool for render targets
    uint64_t pool_size = 512ull << 20;
    void *mem = NULL;
    if (posix_memalign(&mem, 16384, pool_size) != 0 || !mem) {
        fprintf(stderr, "Failed to allocate pool memory\n");
        return 1;
    }
    memset(mem, 0, pool_size);
    pool_t pool = {
        .magic = MAGIC('P','O','O','L'),
        .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS |
                 NVN_MEMORY_POOL_FLAGS_GPU_CACHED |
                 NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE,
        .mem = mem,
        .size = pool_size
    };

    int recycle_on = sw_on(rh_mode());
    uint64_t rh_cap_bytes = RH_CAP;

    if (!json_output) {
        printf("============================================================\n");
        printf("NVN RT Recycle DRS Benchmark (Issue #1831)\n");
        printf("Mode: %s | Recycle: %s | RH_CAP: %llu MB | Frames: %d\n",
               mode_name, recycle_on ? "ON" : "OFF", (unsigned long long)(rh_cap_bytes >> 20), total_frames);
        printf("============================================================\n");
    }

    uint64_t serial_counter = 100000;
    uint64_t targets_requested = 0;
    uint64_t peak_gpu_bytes = 0;
    uint64_t peak_rh_bytes = 0;
    uint64_t cumulative_os_alloc_bytes = 0;
    uint64_t cpu_alloc_ns = 0;
    uint64_t cpu_release_ns = 0;
    uint64_t cpu_drain_trim_ns = 0;

    int pressure_triggered = 0;
    uint64_t pressure_before_bytes = 0;
    uint64_t pressure_after_bytes = 0;

    uint64_t prev_rh_made = 0;
    uint64_t bench_start_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC);

    for (int frame = 0; frame < total_frames; frame++) {
        uint64_t t0, t1;

        // Start submission for current frame
        t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        mtl_sub_begin();
        t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        cpu_drain_trim_ns += (t1 - t0);

        // Check simulated OS memory pressure event
        if (pressure_at_frame >= 0 && frame == pressure_at_frame && recycle_on) {
            os_unfair_lock_lock(&g_rh_lk);
            pressure_before_bytes = g_rh_bytes;
            os_unfair_lock_unlock(&g_rh_lk);

            rh_trim_drop(1); // Immediate purge of all idle waiting heaps

            os_unfair_lock_lock(&g_rh_lk);
            pressure_after_bytes = g_rh_bytes;
            os_unfair_lock_unlock(&g_rh_lk);

            pressure_triggered = 1;
            if (verbose && !json_output) {
                printf("[Frame %4d] Simulated OS Memory Pressure: purged %llu MB -> %llu MB\n",
                       frame, (unsigned long long)(pressure_before_bytes >> 20), (unsigned long long)(pressure_after_bytes >> 20));
            }
        }

        res_preset_t res = get_drs_preset(frame);
        unsigned w = res.w;
        unsigned h = res.h;

        // Build target descriptors for this frame
        tex_t targets[PASS_TARGET_COUNT];
        uint64_t off = 0;

        // Pass 1: G-Buffer
        targets[PASS_GBUFFER_ALBEDO]   = make_target(&pool, serial_counter++, off, w, h, NVN_FORMAT_RGBA8);
        off += (targets[PASS_GBUFFER_ALBEDO].L.size + 65535) & ~65535ull;

        targets[PASS_GBUFFER_NORMAL]   = make_target(&pool, serial_counter++, off, w, h, NVN_FORMAT_RGBA16F);
        off += (targets[PASS_GBUFFER_NORMAL].L.size + 65535) & ~65535ull;

        targets[PASS_GBUFFER_MATERIAL] = make_target(&pool, serial_counter++, off, w, h, NVN_FORMAT_RGBA8);
        off += (targets[PASS_GBUFFER_MATERIAL].L.size + 65535) & ~65535ull;

        targets[PASS_GBUFFER_DEPTH]    = make_target(&pool, serial_counter++, off, w, h, NVN_FORMAT_RGBA16F);
        off += (targets[PASS_GBUFFER_DEPTH].L.size + 65535) & ~65535ull;

        // Pass 2: Lighting
        targets[PASS_LIGHTING_HDR]     = make_target(&pool, serial_counter++, off, w, h, NVN_FORMAT_RGBA16F);
        off += (targets[PASS_LIGHTING_HDR].L.size + 65535) & ~65535ull;

        // Pass 3: Transient downsamples & display
        targets[PASS_BLOOM_HALF]       = make_target(&pool, serial_counter++, off, w / 2, h / 2, NVN_FORMAT_RGBA16F);
        off += (targets[PASS_BLOOM_HALF].L.size + 65535) & ~65535ull;

        targets[PASS_SSAO_QUARTER]     = make_target(&pool, serial_counter++, off, w / 4, h / 4, NVN_FORMAT_RGBA8);
        off += (targets[PASS_SSAO_QUARTER].L.size + 65535) & ~65535ull;

        targets[PASS_DISPLAY_1080P]    = make_target(&pool, serial_counter++, off, 1920, 1080, NVN_FORMAT_RGBA8);

        // Allocate / acquire Metal textures for each pass
        t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        for (int i = 0; i < PASS_TARGET_COUNT; i++) {
            mtl_tex_init(&targets[i]);
            id<MTLTexture> mt = tex_mtl(&targets[i]);
            targets_requested++;

            if (!recycle_on) {
                if (mt) cumulative_os_alloc_bytes += mt.allocatedSize;
            } else {
                if (g_rh_made > prev_rh_made) {
                    if (mt && mt.heap) cumulative_os_alloc_bytes += mt.heap.size;
                    prev_rh_made = g_rh_made;
                }
            }
        }
        t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        cpu_alloc_ns += (t1 - t0);

        // Track peak GPU allocated memory
        uint64_t cur_gpu = g_dev ? g_dev.currentAllocatedSize : 0;
        if (cur_gpu > peak_gpu_bytes) peak_gpu_bytes = cur_gpu;

        os_unfair_lock_lock(&g_rh_lk);
        uint64_t cur_rh = g_rh_bytes;
        os_unfair_lock_unlock(&g_rh_lk);
        if (cur_rh > peak_rh_bytes) peak_rh_bytes = cur_rh;

        // Release transient G-buffer targets and frame targets at end of frame
        t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        for (int i = 0; i < PASS_TARGET_COUNT; i++) {
            mtl_tex_release(&targets[i]);
        }
        t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        cpu_release_ns += (t1 - t0);

        // Commit frame submission and drain feedback
        mtl_sub_commit();
        mtl_drain();

        dispatch_sync(g_feedback_q, ^{});

        t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        defer_drain();
        t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        cpu_drain_trim_ns += (t1 - t0);

        if (verbose && !json_output && ((frame + 1) % 100 == 0 || frame == total_frames - 1)) {
            printf("[Frame %4d/%4d] Preset: %5s | GPU Alloc: %4llu MB | Waiting: %4llu MB | Made: %llu | Reused: %llu\n",
                   frame + 1, total_frames, res.name,
                   (unsigned long long)(cur_gpu >> 20), (unsigned long long)(cur_rh >> 20),
                   (unsigned long long)g_rh_made, (unsigned long long)g_rh_reused);
        }
    }

    // Clean up
    mtl_alias_drop_pool(&pool);
    free(mem);

    uint64_t bench_end_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    double bench_wall_ms = (bench_end_ns - bench_start_ns) / 1000000.0;

    uint64_t total_cpu_overhead_ns = cpu_alloc_ns + cpu_release_ns + cpu_drain_trim_ns;
    double cpu_overhead_ms = total_cpu_overhead_ns / 1000000.0;
    double cpu_overhead_per_frame_us = (double)total_cpu_overhead_ns / (total_frames * 1000.0);

    uint64_t heaps_created = recycle_on ? g_rh_made : targets_requested;
    uint64_t heaps_reused = recycle_on ? g_rh_reused : 0;
    uint64_t heaps_trimmed = recycle_on ? g_rh_trimmed : 0;
    double reuse_pct = (heaps_created + heaps_reused) > 0 ?
                       ((double)heaps_reused / (heaps_created + heaps_reused) * 100.0) : 0.0;

    double peak_gpu_mb = (double)peak_gpu_bytes / (1024.0 * 1024.0);
    double peak_rh_mb = (double)peak_rh_bytes / (1024.0 * 1024.0);
    double cumulative_os_alloc_mb = (double)cumulative_os_alloc_bytes / (1024.0 * 1024.0);

    if (json_output) {
        printf("{\n");
        printf("  \"mode\": \"%s\",\n", mode_name);
        printf("  \"recycle_enabled\": %d,\n", recycle_on);
        printf("  \"rh_cap_mb\": %llu,\n", (unsigned long long)(rh_cap_bytes >> 20));
        printf("  \"total_frames\": %d,\n", total_frames);
        printf("  \"targets_requested\": %llu,\n", (unsigned long long)targets_requested);
        printf("  \"peak_gpu_allocated_mb\": %.2f,\n", peak_gpu_mb);
        printf("  \"peak_waiting_heaps_mb\": %.2f,\n", peak_rh_mb);
        printf("  \"cumulative_os_alloc_mb\": %.2f,\n", cumulative_os_alloc_mb);
        printf("  \"heaps_created\": %llu,\n", (unsigned long long)heaps_created);
        printf("  \"heaps_reused\": %llu,\n", (unsigned long long)heaps_reused);
        printf("  \"heaps_trimmed\": %llu,\n", (unsigned long long)heaps_trimmed);
        printf("  \"stale_aliases_taken\": %llu,\n", (unsigned long long)g_alias_taken);
        printf("  \"heap_reuse_percentage\": %.2f,\n", reuse_pct);
        printf("  \"cpu_alloc_overhead_ms\": %.3f,\n", cpu_alloc_ns / 1000000.0);
        printf("  \"cpu_release_overhead_ms\": %.3f,\n", cpu_release_ns / 1000000.0);
        printf("  \"cpu_drain_trim_overhead_ms\": %.3f,\n", cpu_drain_trim_ns / 1000000.0);
        printf("  \"cpu_overhead_total_ms\": %.3f,\n", cpu_overhead_ms);
        printf("  \"cpu_overhead_per_frame_us\": %.2f,\n", cpu_overhead_per_frame_us);
        printf("  \"bench_wall_ms\": %.2f,\n", bench_wall_ms);
        printf("  \"pressure_simulated\": %d,\n", pressure_triggered);
        printf("  \"pressure_before_mb\": %.2f,\n", (double)pressure_before_bytes / (1024.0 * 1024.0));
        printf("  \"pressure_after_mb\": %.2f\n", (double)pressure_after_bytes / (1024.0 * 1024.0));
        printf("}\n");
    } else {
        printf("\n================ Results: %s ================\n", mode_name);
        printf("Peak GPU Heap Allocated:        %8.2f MB\n", peak_gpu_mb);
        printf("Peak Waiting Heaps Memory:      %8.2f MB\n", peak_rh_mb);
        printf("Cumulative OS Memory Allocated: %8.2f MB\n", cumulative_os_alloc_mb);
        printf("Heap Allocations Created:       %8llu\n", (unsigned long long)heaps_created);
        printf("Heap Allocations Reused:        %8llu (%.2f%% reuse)\n", (unsigned long long)heaps_reused, reuse_pct);
        printf("Heap Allocations Trimmed:       %8llu\n", (unsigned long long)heaps_trimmed);
        printf("Stale Aliases Taken Over:       %8llu\n", (unsigned long long)g_alias_taken);
        printf("CPU Overhead Total:             %8.3f ms\n", cpu_overhead_ms);
        printf("CPU Overhead Per Frame:         %8.2f us/frame\n", cpu_overhead_per_frame_us);
        printf("Benchmark Wall Time:            %8.2f ms\n", bench_wall_ms);
        if (pressure_triggered) {
            printf("Memory Pressure Purge:          %8.2f MB -> %.2f MB\n",
                   (double)pressure_before_bytes / (1024.0 * 1024.0), (double)pressure_after_bytes / (1024.0 * 1024.0));
        }
        printf("============================================================\n");
    }

    return 0;
} }
