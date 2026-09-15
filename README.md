# BRay Demo

This demo builds a small executable and shared library, instruments function
entries and exits with BOLT, and writes a nested Chrome Trace containing each
function's inclusive and exclusive time.

## Quick Start

```sh
./run.sh
```

All generated LLVM files live under one top-level directory:

```text
llvm-build/
  llvm-project/ # shallow checkout of bolt_BRay
  build/        # CMake/Ninja output
```

`bootstrap.sh` shallow-clones
`https://github.com/Jinjie-Huang/llvm-project.git` branch `bolt_BRay`, or
fetches that branch's latest commit when the checkout already exists. It
rebuilds BOLT when the source revision changes. It also checks the environment
for unversioned and versioned tools such as `clang-17` and
`llvm-symbolizer-17`; existing tools are reused, while missing Clang, LLD, or
symbolizer tools are built alongside BOLT. The default build uses at most 16
compile jobs and two link jobs; override it with `BRAY_JOBS=<n>`.

Tool paths can be overridden with `BRAY_CLANG`, `BRAY_CLANGXX`, `BRAY_LLD`,
and `BRAY_SYMBOLIZER`.

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

Each thread maintains a stack of active calls. Entry pushes only the function
PC and timestamp; exit pops the frame, computes inclusive time, and subtracts
child time to get exclusive time. No symbol lookup or demangling runs in the
Hook path.

At process exit the Hook library writes raw PC events plus module mappings.
`run.sh` groups unique PCs by module, resolves each one once with
`llvm-symbolizer`, and then writes the final Chrome Trace.

The demo intentionally does not link with `--export-dynamic` or `-rdynamic`.
Internal workload functions are hidden from the dynamic symbol table and are
still resolved from the BOLT output's regular symbol table.

The script writes:

```text
build/bray-trace.json
```

Load it in `chrome://tracing` or <https://ui.perfetto.dev>. Chrome Trace and
the terminal both fold repeated invocations with the same call path into one
flame-graph-style node. Each node contains total inclusive time, self time,
average time, and call count. The intermediate
`build/bray-trace.raw.json` preserves every dynamic invocation with its PC,
timing data, thread/depth information, and module mapping.

Example:

```text
[BRay] aggregated call tree (total inclusive / self, average inclusive, calls):
[BRay] main 24.723 ms / 0.025 ms, avg 24.723 ms, calls=1
[BRay]   bray_demo::handle_request(int) 24.697 ms / 3.143 ms, avg 8.232 ms, calls=3
[BRay]     bray_demo::run_pipeline(int) 21.554 ms / 0.012 ms, avg 7.185 ms, calls=3
[BRay]       bray_demo::parse_request(int) 6.168 ms / 6.168 ms, avg 2.056 ms, calls=3
[BRay]       bray_demo::compute_score(int) 12.216 ms / 12.216 ms, avg 4.072 ms, calls=3
[BRay]       bray_demo::persist_result(int) 3.159 ms / 3.159 ms, avg 1.053 ms, calls=3
```

Each Chrome Trace event uses phase `X`; `dur` is total inclusive time, while
`args.total_exclusive_us`, `args.average_inclusive_us`, and `args.calls`
describe the aggregated node.

## Files

- `bootstrap.sh`: initializes and builds the LLVM/BOLT toolchain.
- `run.sh`: builds, instruments, and runs the demo.
- `src/main.cpp`: executable entry point.
- `src/workload.cpp`: nested workload compiled as `libworkload.so`.
- `runtime/bray_trace.cpp`: preloadable BRay Hook library and raw event writer.
- `runtime/symbolize_trace.py`: batched offline symbolization and Chrome Trace
  writer.
