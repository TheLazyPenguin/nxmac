# MLIR Shader Optimization Benchmark Report

| Shader Key | Stage | Category | Status | Base MSL (KB) | Opt MSL (KB) | Base GPU (µs) | Opt GPU (µs) | GPU Perf Delta | Bit-Exact Correctness |
|---|---|---|---|---|---|---|---|---|---|
| `cb419aff2729bbd5` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 14.1 | - | 10.13 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `8cb99c6f388bfe41` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 14.1 | - | 11.88 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `adf1e88a963b552e` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 14.4 | - | 10.25 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `e0a9a229f67fb4fa` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 25.0 | - | 18.25 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `0d2dc8b8ea1eb34e` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 23.2 | - | 17.83 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `322a4642e110348c` | cs | effect_minigame | *UNSUPPORTED_MLIR* | 14.4 | - | 11.71 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `ab00a7150d4383ac` | vs | model | **OK** | 4.5 | 4.4 | 25.04 | 25.12 | **-0.3%** | MATCH |
| `634f217dd0d06d13` | vs | model | **OK** | 11.9 | 11.9 | 25.79 | 25.50 | **+1.1%** | MATCH |
| `5a2f0642bad58c17` | vs | model | **OK** | 10.4 | 10.8 | 25.50 | 24.63 | **+3.4%** | MATCH |
| `e513e604d81c6d2b` | vs | model | **OK** | 18.4 | 18.7 | 29.37 | 28.96 | **+1.4%** | MATCH |
| `d3bcf79efc5649d9` | vs | model | **OK** | 39.0 | 37.5 | 35.92 | 33.83 | **+5.8%** | MATCH |
| `9dd05a809ca14c02` | vs | model | *UNSUPPORTED_MLIR* | 144.1 | - | 93.21 | - | - | N/A (<unknown>:0: error: unknown <id> 47used ) |
| `fa22520882130a48` | vs | model | *UNSUPPORTED_MLIR* | 144.0 | - | 90.67 | - | - | N/A (<unknown>:0: error: unknown <id> 47used ) |
| `1249b312a203e6b5` | ps | foliage | **OK** | 0.4 | 0.5 | 24.00 | 27.25 | **-13.5%** | MATCH |
| `9286f6e541bdf44d` | ps | model | *UNSUPPORTED_MLIR* | 46.3 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled opcode 26) |
| `9bca452958153be7` | ps | model | *UNSUPPORTED_MLIR* | 168.5 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled opcode 26) |
| `46a6ac916ba1a4d2` | ps | model | *UNSUPPORTED_MLIR* | 140.1 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `3eb55cf0973039ab` | ps | model | *UNSUPPORTED_MLIR* | 165.3 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled deserializ) |
| `8c06d7f5528a58e8` | ps | terrain | *UNSUPPORTED_MLIR* | 526.2 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled opcode 105) |
| `f48b4781b92b1664` | ps | terrain | *UNSUPPORTED_MLIR* | 527.4 | - | 0.00 | - | - | N/A (<unknown>:0: error: unhandled opcode 105) |
