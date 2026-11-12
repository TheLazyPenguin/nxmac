// Standalone Metal Shader Benchmark & Correctness Harness for nxnative MLIR Experiment
// Measures: Metal library compilation time, PSO creation time, GPU execution time via hardware timestamps,
// and output verification checksums.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

static double time_ms(uint64_t t0, uint64_t t1, mach_timebase_info_data_t tb) {
    return (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
}

static uint64_t fnv1a_hash(const void *data, size_t len) {
    uint64_t hash = 14695981039346656037ULL;
    const uint8_t *ptr = (const uint8_t *)data;
    for (size_t i = 0; i < len; i++) {
        hash ^= ptr[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: metal_bench <shader.metal> [stage: cs|vs|ps] [warmup_iters] [bench_iters]\n");
            return 1;
        }
        
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *stage = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"cs";
        int warmup = argc > 3 ? atoi(argv[3]) : 10;
        int iters = argc > 4 ? atoi(argv[4]) : 30;
        
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "Error: No Metal device available.\n");
            return 1;
        }
        
        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (!src) {
            fprintf(stderr, "Error: Could not read source %s: %s\n", argv[1], [[err localizedDescription] UTF8String]);
            return 1;
        }
        
        // 1. Measure Metal compilation time
        uint64_t t0 = mach_absolute_time();
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        uint64_t t1 = mach_absolute_time();
        double compile_ms = time_ms(t0, t1, tb);
        
        if (!lib) {
            fprintf(stderr, "Compile error: %s\n", [[err localizedDescription] UTF8String]);
            return 2;
        }
        
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
        if (!fn) {
            NSArray *fns = [lib functionNames];
            if (fns.count > 0) fn = [lib newFunctionWithName:fns[0]];
        }
        if (!fn) {
            fprintf(stderr, "Error: No valid entrypoint found in library.\n");
            return 3;
        }
        
        // 2. Measure PSO creation time
        uint64_t t_pso0 = mach_absolute_time();
        id<MTLComputePipelineState> compute_pso = nil;
        id<MTLRenderPipelineState> render_pso = nil;
        
        if ([stage isEqualToString:@"cs"]) {
            compute_pso = [dev newComputePipelineStateWithFunction:fn error:&err];
            if (!compute_pso) {
                fprintf(stderr, "Compute PSO error: %s\n", [[err localizedDescription] UTF8String]);
                return 4;
            }
        } else {
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            
            if ([stage isEqualToString:@"vs"]) {
                rd.vertexFunction = fn;
                NSString *dummy_ps = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 dummy_ps() { return float4(1.0, 0.5, 0.25, 1.0); }\n";
                id<MTLLibrary> pslib = [dev newLibraryWithSource:dummy_ps options:nil error:nil];
                rd.fragmentFunction = [pslib newFunctionWithName:@"dummy_ps"];
                
                // Set up vertex descriptor to satisfy stage_in attributes
                MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
                for (NSUInteger i = 0; i < 16; i++) {
                    vd.attributes[i].format = MTLVertexFormatFloat4;
                    vd.attributes[i].offset = i * 16;
                    vd.attributes[i].bufferIndex = 16;
                }
                vd.layouts[16].stride = 16 * 16;
                vd.layouts[16].stepFunction = MTLVertexStepFunctionPerVertex;
                rd.vertexDescriptor = vd;
            } else {
                // Fragment shader: dummy fullscreen triangle vertex function
                NSString *dummy_vs = @"#include <metal_stdlib>\n"
                                     "using namespace metal;\n"
                                     "vertex float4 dummy_vs(uint vid [[vertex_id]]) {\n"
                                     "    float2 p = float2((vid << 1) & 2, vid & 2);\n"
                                     "    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);\n"
                                     "}\n";
                id<MTLLibrary> vslib = [dev newLibraryWithSource:dummy_vs options:nil error:nil];
                rd.vertexFunction = [vslib newFunctionWithName:@"dummy_vs"];
                rd.fragmentFunction = fn;
            }
            
            render_pso = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            if (!render_pso) {
                fprintf(stderr, "Render PSO error: %s\n", [[err localizedDescription] UTF8String]);
                return 4;
            }
        }
        uint64_t t_pso1 = mach_absolute_time();
        double pso_ms = time_ms(t_pso0, t_pso1, tb);
        
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        
        // 3. Set up memory buffers and argument buffers
        const NSUInteger buf_size = 1024 * 1024;
        id<MTLBuffer> buf0 = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];
        id<MTLBuffer> buf1 = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];
        id<MTLBuffer> buf2 = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];
        id<MTLBuffer> buf3 = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];
        id<MTLBuffer> vbuf = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        id<MTLBuffer> argBuf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        
        // Initialize buffers with deterministic values
        float *p0 = (float *)buf0.contents;
        for (NSUInteger i = 0; i < buf_size / sizeof(float); i++) p0[i] = (float)(i % 1024) * 0.125f;
        float *pv = (float *)vbuf.contents;
        for (NSUInteger i = 0; i < 65536 / sizeof(float); i++) pv[i] = (float)(i % 256) * 0.05f;
        
        // Tier 2 Argument buffer table: fill with pointer to buf0
        uint64_t *ptrs = (uint64_t *)argBuf.contents;
        for (NSUInteger i = 0; i < 512; i++) {
            ptrs[i] = buf0.gpuAddress;
        }
        
        // Target texture for render shaders
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        
        // 4. GPU Execution & Timings
        NSMutableArray<NSNumber *> *gpu_times = [NSMutableArray new];
        uint64_t final_checksum = 0;
        
        int total_runs = warmup + iters;
        for (int r = 0; r < total_runs; r++) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            
            if (compute_pso) {
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:compute_pso];
                [enc useResource:buf0 usage:MTLResourceUsageRead];
                [enc setBuffer:argBuf offset:0 atIndex:0];
                [enc setBuffer:buf0 offset:0 atIndex:1];
                [enc setBuffer:buf1 offset:0 atIndex:2];
                [enc setBuffer:buf2 offset:0 atIndex:3];
                [enc setBuffer:buf3 offset:0 atIndex:4];
                
                MTLSize tg = MTLSizeMake(MIN((NSUInteger)64, compute_pso.maxTotalThreadsPerThreadgroup), 1, 1);
                MTLSize grid = MTLSizeMake(1024, 1, 1);
                [enc dispatchThreads:grid threadsPerThreadgroup:tg];
                [enc endEncoding];
            } else if (render_pso) {
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor new];
                rpd.colorAttachments[0].texture = target;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
                [enc setRenderPipelineState:render_pso];
                [enc useResource:buf0 usage:MTLResourceUsageRead stages:MTLRenderStageVertex | MTLRenderStageFragment];
                
                if ([stage isEqualToString:@"vs"]) {
                    [enc setVertexBuffer:argBuf offset:0 atIndex:0];
                    for (NSUInteger b = 1; b < 16; b++) [enc setVertexBuffer:buf0 offset:0 atIndex:b];
                    [enc setVertexBuffer:vbuf offset:0 atIndex:16];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                } else {
                    [enc setFragmentBuffer:argBuf offset:0 atIndex:0];
                    for (NSUInteger b = 1; b < 16; b++) [enc setFragmentBuffer:buf0 offset:0 atIndex:b];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [enc endEncoding];
            }
            
            [cb commit];
            [cb waitUntilCompleted];
            
            if (cb.status != MTLCommandBufferStatusCompleted) {
                fprintf(stderr, "CommandBuffer error: %s\n", [[cb.error localizedDescription] UTF8String]);
                return 5;
            }
            
            if (r >= warmup) {
                CFTimeInterval dt = cb.GPUEndTime - cb.GPUStartTime;
                if (dt > 0) {
                    [gpu_times addObject:@(dt * 1e6)]; // microseconds
                }
            }
        }
        
        // 5. Verification Hash
        if (compute_pso) {
            final_checksum = fnv1a_hash(buf1.contents, 4096);
        } else if (render_pso) {
            uint8_t pixelBytes[256 * 256 * 4];
            [target getBytes:pixelBytes bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
            final_checksum = fnv1a_hash(pixelBytes, sizeof(pixelBytes));
        }
        
        [gpu_times sortUsingSelector:@selector(compare:)];
        double median_us = gpu_times.count ? [gpu_times[gpu_times.count / 2] doubleValue] : 0.0;
        double min_us = gpu_times.count ? [gpu_times[0] doubleValue] : 0.0;
        double max_us = gpu_times.count ? [gpu_times[gpu_times.count - 1] doubleValue] : 0.0;
        
        // Output JSON result
        NSDictionary *res = @{
            @"path": path,
            @"stage": stage,
            @"compile_ms": @(compile_ms),
            @"pso_creation_ms": @(pso_ms),
            @"gpu_median_us": @(median_us),
            @"gpu_min_us": @(min_us),
            @"gpu_max_us": @(max_us),
            @"samples": @(gpu_times.count),
            @"checksum": [NSString stringWithFormat:@"0x%016llx", final_checksum],
            @"device": dev.name
        };
        
        NSData *out_data = [NSJSONSerialization dataWithJSONObject:res options:NSJSONWritingPrettyPrinted error:nil];
        printf("%s\n", [[[NSString alloc] initWithData:out_data encoding:NSUTF8StringEncoding] UTF8String]);
    }
    return 0;
}