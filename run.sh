#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLVM_BUILD_DIR="${BRAY_LLVM_BUILD_DIR:-${ROOT_DIR}/llvm-build/build}"
TOOLCHAIN_FILE="${ROOT_DIR}/llvm-build/toolchain.env"
BUILD_DIR="${ROOT_DIR}/build"
TRACE_FILE="${BRAY_TRACE_FILE:-${BUILD_DIR}/bray-trace.json}"
RAW_TRACE_FILE="${TRACE_FILE%.json}.raw.json"

"${ROOT_DIR}/bootstrap.sh"

if [[ ! -f "${TOOLCHAIN_FILE}" ]]; then
  echo "error: toolchain manifest was not generated: ${TOOLCHAIN_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${TOOLCHAIN_FILE}"

if [[ ! -x "${BRAY_CLANGXX_BIN}" || ! -x "${BRAY_LLD_BIN}" ||
      ! -x "${BRAY_BOLT_BIN}" || ! -x "${BRAY_SYMBOLIZER_BIN}" ||
      ! -f "${BRAY_RUNTIME_LIB}" ]]; then
  echo "error: BRay toolchain manifest contains invalid paths" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

COMMON_FLAGS=(-O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls)
LINKER_FLAGS=(-fuse-ld="${BRAY_LLD_BIN}")

echo "[1/5] Building the demo application and tracing hook..."
"${BRAY_CLANGXX_BIN}" "${COMMON_FLAGS[@]}" -fvisibility=hidden -fPIC -shared \
  "${ROOT_DIR}/src/workload.cpp" \
  "${LINKER_FLAGS[@]}" \
  -Wl,-soname,libworkload.so \
  -o "${BUILD_DIR}/libworkload.so"
"${BRAY_CLANGXX_BIN}" "${COMMON_FLAGS[@]}" \
  "${ROOT_DIR}/src/main.cpp" \
  "${LINKER_FLAGS[@]}" \
  -L"${BUILD_DIR}" -lworkload \
  -Wl,-rpath,'$ORIGIN' \
  -o "${BUILD_DIR}/bray-demo"
"${BRAY_CLANGXX_BIN}" "${COMMON_FLAGS[@]}" -fPIC -shared \
  "${ROOT_DIR}/runtime/bray_trace.cpp" \
  "${LINKER_FLAGS[@]}" \
  -pthread \
  -o "${BUILD_DIR}/libbray_trace.so"

cat >"${BUILD_DIR}/workload-functions.txt" <<'EOF'
_ZN9bray_demo
EOF

cat >"${BUILD_DIR}/main-functions.txt" <<'EOF'
main
EOF

echo "[2/5] Instrumenting the workload shared library..."
"${BRAY_BOLT_BIN}" "${BUILD_DIR}/libworkload.so" \
  -o "${BUILD_DIR}/libworkload.bray.so" \
  --runtime-bray-lib="${BRAY_RUNTIME_LIB}" \
  --instrument=func-entry,func-exit \
  --instrument-func-list-file="${BUILD_DIR}/workload-functions.txt" \
  --relocs=0 --lite=0 \
  --instrument-func-print

echo "[3/5] Instrumenting the main executable..."
"${BRAY_BOLT_BIN}" "${BUILD_DIR}/bray-demo" \
  -o "${BUILD_DIR}/bray-demo.bray" \
  --runtime-bray-lib="${BRAY_RUNTIME_LIB}" \
  --instrument=func-entry,func-exit \
  --instrument-func-list-file="${BUILD_DIR}/main-functions.txt" \
  --relocs=0 --lite=0 \
  --instrument-func-print

ln -sf libworkload.bray.so "${BUILD_DIR}/libworkload.so"

echo "[4/5] Recording raw function events..."
rm -f "${RAW_TRACE_FILE}" "${TRACE_FILE}"
printf 'Running: cd %q && BRAY_RAW_TRACE_FILE=%q LD_PRELOAD=%q %q\n' \
  "${BUILD_DIR}" "${RAW_TRACE_FILE}" "${BUILD_DIR}/libbray_trace.so" \
  "./bray-demo.bray"
(
  cd "${BUILD_DIR}"
  BRAY_RAW_TRACE_FILE="${RAW_TRACE_FILE}" \
    LD_PRELOAD="${BUILD_DIR}/libbray_trace.so" \
    ./bray-demo.bray >program.out
)
cat "${BUILD_DIR}/program.out"

if [[ ! -s "${RAW_TRACE_FILE}" ]]; then
  echo "error: raw trace file was not generated: ${RAW_TRACE_FILE}" >&2
  exit 1
fi

echo "[5/5] Symbolizing unique PCs and writing Chrome Trace..."
python3 "${ROOT_DIR}/runtime/symbolize_trace.py" \
  --raw "${RAW_TRACE_FILE}" \
  --output "${TRACE_FILE}" \
  --symbolizer "${BRAY_SYMBOLIZER_BIN}"

if [[ ! -s "${TRACE_FILE}" ]]; then
  echo "error: trace file was not generated: ${TRACE_FILE}" >&2
  exit 1
fi

echo
echo "Chrome Trace: ${TRACE_FILE}"
echo "Open chrome://tracing or https://ui.perfetto.dev and load the JSON file."
