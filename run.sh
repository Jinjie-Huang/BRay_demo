#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLVM_BUILD_DIR="${BRAY_LLVM_BUILD_DIR:-${ROOT_DIR}/llvm-build}"
BUILD_DIR="${ROOT_DIR}/build"
TRACE_FILE="${BRAY_TRACE_FILE:-${BUILD_DIR}/bray-trace.json}"

if [[ ! -x "${LLVM_BUILD_DIR}/bin/llvm-bolt" ]]; then
  "${ROOT_DIR}/bootstrap.sh"
fi

CLANGXX="${LLVM_BUILD_DIR}/bin/clang++"
BOLT="${LLVM_BUILD_DIR}/bin/llvm-bolt"
RUNTIME="${LLVM_BUILD_DIR}/lib/libbolt_rt_iwyn.a"

if [[ ! -x "${CLANGXX}" || ! -x "${BOLT}" || ! -f "${RUNTIME}" ]]; then
  echo "error: BRay toolchain is incomplete under ${LLVM_BUILD_DIR}" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

COMMON_FLAGS=(-O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls)

echo "[1/4] Building the demo application and tracing hook..."
"${CLANGXX}" "${COMMON_FLAGS[@]}" -fPIC -shared \
  "${ROOT_DIR}/workload.cpp" \
  -Wl,-soname,libworkload.so \
  -o "${BUILD_DIR}/libworkload.so"
"${CLANGXX}" "${COMMON_FLAGS[@]}" \
  "${ROOT_DIR}/main.cpp" \
  -L"${BUILD_DIR}" -lworkload \
  -Wl,-rpath,'$ORIGIN' -Wl,--export-dynamic \
  -o "${BUILD_DIR}/bray-demo"
"${CLANGXX}" "${COMMON_FLAGS[@]}" -fPIC -shared \
  "${ROOT_DIR}/bray_trace.cpp" \
  -ldl -pthread \
  -o "${BUILD_DIR}/libbray_trace.so"

cat >"${BUILD_DIR}/workload-functions.txt" <<'EOF'
_ZN9bray_demo
EOF

cat >"${BUILD_DIR}/main-functions.txt" <<'EOF'
main
EOF

echo "[2/4] Instrumenting the workload shared library..."
"${BOLT}" "${BUILD_DIR}/libworkload.so" \
  -o "${BUILD_DIR}/libworkload.bray.so" \
  --runtime-instrument-what-u-need-lib="${RUNTIME}" \
  --instrument=func-entry,func-exit \
  --instrument-func-list-file="${BUILD_DIR}/workload-functions.txt" \
  --relocs=0 --lite=0 \
  --instrument-func-print

echo "[3/4] Instrumenting the main executable..."
"${BOLT}" "${BUILD_DIR}/bray-demo" \
  -o "${BUILD_DIR}/bray-demo.bray" \
  --runtime-instrument-what-u-need-lib="${RUNTIME}" \
  --instrument=func-entry,func-exit \
  --instrument-func-list-file="${BUILD_DIR}/main-functions.txt" \
  --relocs=0 --lite=0 \
  --instrument-func-print

ln -sf libworkload.bray.so "${BUILD_DIR}/libworkload.so"

echo "[4/4] Running the instrumented program..."
rm -f "${TRACE_FILE}"
(
  cd "${BUILD_DIR}"
  BRAY_TRACE_FILE="${TRACE_FILE}" \
    LD_PRELOAD="${BUILD_DIR}/libbray_trace.so" \
    ./bray-demo.bray >program.out
)
cat "${BUILD_DIR}/program.out"

if [[ ! -s "${TRACE_FILE}" ]]; then
  echo "error: trace file was not generated: ${TRACE_FILE}" >&2
  exit 1
fi

echo
echo "Chrome Trace: ${TRACE_FILE}"
echo "Open chrome://tracing or https://ui.perfetto.dev and load the JSON file."
