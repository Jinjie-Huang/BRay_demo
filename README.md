# BRay Demo

This demo builds a small executable and shared library, instruments function
entries and exits with BOLT, and writes a nested Chrome Trace containing each
function's inclusive and exclusive time.

## Quick Start

```sh
./run.sh
```

If `llvm/` is absent, `bootstrap.sh` adds
`https://github.com/Jinjie-Huang/llvm-project.git` as a shallow Git submodule
from branch `bolt_BRay`, then builds Clang, LLD, BOLT, and the BRay runtime in
`llvm-build/`.

To reuse an existing build:

```sh
BRAY_LLVM_BUILD_DIR=/path/to/llvm-build ./run.sh
```

## What It Demonstrates

The instrumented call tree is:

```text
main
  bray_demo::handle_request
    bray_demo::run_pipeline
      bray_demo::parse_request
      bray_demo::compute_score
      bray_demo::persist_result
```

The Hook library implements:

```cpp
extern "C" void __bolt_probe_enter(uint64_t function_pc);
extern "C" void __bolt_probe_exit(uint64_t function_pc);
```

Each thread maintains a stack of active calls. Entry pushes a frame; exit pops
it, computes inclusive time, subtracts child time to get exclusive time, and
emits a Chrome Trace complete event.

The script writes:

```text
build/bray-trace.json
```

Load it in `chrome://tracing` or <https://ui.perfetto.dev>. The terminal also
prints the same nested call tree with inclusive and self time.

Example:

```text
[BRay] main 24.742 ms / 0.047 ms
[BRay]   bray_demo::handle_request(int) 8.266 ms / 1.066 ms
[BRay]     bray_demo::run_pipeline(int) 7.200 ms / 0.011 ms
[BRay]       bray_demo::parse_request(int) 2.063 ms / 2.063 ms
[BRay]       bray_demo::compute_score(int) 4.072 ms / 4.072 ms
[BRay]       bray_demo::persist_result(int) 1.054 ms / 1.054 ms
```

Each Chrome Trace event uses phase `X`; `dur` is inclusive time, while
`args.exclusive_us` is the function's self time after subtracting completed
children.

## Files

- `bootstrap.sh`: initializes and builds the LLVM/BOLT toolchain.
- `run.sh`: builds, instruments, and runs the demo.
- `main.cpp`: executable entry point.
- `workload.cpp`: nested workload compiled as `libworkload.so`.
- `bray_trace.cpp`: preloadable BRay Hook library and Chrome Trace writer.
