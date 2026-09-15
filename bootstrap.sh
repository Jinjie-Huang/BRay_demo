#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLVM_REPOSITORY="https://github.com/Jinjie-Huang/llvm-project.git"
LLVM_BRANCH="bolt_BRay"
LLVM_ROOT_DIR="${ROOT_DIR}/llvm-build"
LLVM_DIR="${BRAY_LLVM_DIR:-${LLVM_ROOT_DIR}/llvm-project}"
LLVM_BUILD_DIR="${BRAY_LLVM_BUILD_DIR:-${LLVM_ROOT_DIR}/build}"
TOOLCHAIN_FILE="${LLVM_ROOT_DIR}/toolchain.env"
SOURCE_REVISION_FILE="${LLVM_BUILD_DIR}/.bray-source-revision"
DETECTED_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
if [[ -n "${BRAY_JOBS:-}" ]]; then
  JOBS="${BRAY_JOBS}"
elif ((DETECTED_JOBS > 16)); then
  JOBS=16
else
  JOBS="${DETECTED_JOBS}"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' was not found" >&2
    exit 1
  fi
}

absolute_tool_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "$(cd -- "$(dirname -- "${path}")" && pwd)" \
      "$(basename -- "${path}")"
  fi
}

find_external_tool() {
  local override="$1"
  local name="$2"

  if [[ -n "${override}" ]]; then
    if [[ ! -x "${override}" ]]; then
      echo "error: configured ${name} is not executable: ${override}" >&2
      exit 1
    fi
    absolute_tool_path "${override}"
    return
  fi

  local environment_tool
  environment_tool="$(command -v "${name}" 2>/dev/null || true)"
  if [[ -z "${environment_tool}" ]]; then
    local version
    for version in {30..11}; do
      environment_tool="$(
        command -v "${name}-${version}" 2>/dev/null || true
      )"
      if [[ -n "${environment_tool}" ]]; then
        break
      fi
    done
  fi
  if [[ -n "${environment_tool}" ]]; then
    absolute_tool_path "${environment_tool}"
  fi
}

find_clang_pair() {
  if [[ -n "${BRAY_CLANG:-}" || -n "${BRAY_CLANGXX:-}" ]]; then
    if [[ -z "${BRAY_CLANG:-}" || -z "${BRAY_CLANGXX:-}" ||
          ! -x "${BRAY_CLANG}" || ! -x "${BRAY_CLANGXX}" ]]; then
      echo "error: BRAY_CLANG and BRAY_CLANGXX must name executable tools" >&2
      exit 1
    fi
    CLANG="$(absolute_tool_path "${BRAY_CLANG}")"
    CLANGXX="$(absolute_tool_path "${BRAY_CLANGXX}")"
    NEED_CLANG=0
    return
  fi

  local environment_clang=""
  local environment_clangxx=""
  local version
  for version in "" {30..11}; do
    environment_clang="$(
      command -v "clang${version:+-${version}}" 2>/dev/null || true
    )"
    environment_clangxx="$(
      command -v "clang++${version:+-${version}}" 2>/dev/null || true
    )"
    if [[ -n "${environment_clang}" && -n "${environment_clangxx}" ]]; then
      break
    fi
  done

  if [[ -n "${environment_clang}" && -n "${environment_clangxx}" ]]; then
    CLANG="$(absolute_tool_path "${environment_clang}")"
    CLANGXX="$(absolute_tool_path "${environment_clangxx}")"
    NEED_CLANG=0
  elif [[ -x "${LLVM_BUILD_DIR}/bin/clang" &&
          -x "${LLVM_BUILD_DIR}/bin/clang++" ]]; then
    CLANG="${LLVM_BUILD_DIR}/bin/clang"
    CLANGXX="${LLVM_BUILD_DIR}/bin/clang++"
    NEED_CLANG=0
  else
    CLANG=""
    CLANGXX=""
    NEED_CLANG=1
  fi
}

find_tools() {
  find_clang_pair
  LLD="$(find_external_tool "${BRAY_LLD:-}" ld.lld)"
  if [[ -n "${LLD}" ]]; then
    NEED_LLD=0
  elif [[ -x "${LLVM_BUILD_DIR}/bin/ld.lld" ]]; then
    LLD="${LLVM_BUILD_DIR}/bin/ld.lld"
    NEED_LLD=0
  else
    LLD=""
    NEED_LLD=1
  fi

  SYMBOLIZER="$(find_external_tool "${BRAY_SYMBOLIZER:-}" llvm-symbolizer)"
  if [[ -n "${SYMBOLIZER}" ]]; then
    NEED_SYMBOLIZER=0
  elif [[ -x "${LLVM_BUILD_DIR}/bin/llvm-symbolizer" ]]; then
    SYMBOLIZER="${LLVM_BUILD_DIR}/bin/llvm-symbolizer"
    NEED_SYMBOLIZER=0
  else
    SYMBOLIZER=""
    NEED_SYMBOLIZER=1
  fi

  BOLT="${LLVM_BUILD_DIR}/bin/llvm-bolt"
  RUNTIME="${LLVM_BUILD_DIR}/lib/libbolt_rt_bray.a"
}

write_toolchain_file() {
  mkdir -p "${LLVM_ROOT_DIR}"
  {
    printf 'BRAY_CLANG_BIN=%q\n' "${CLANG}"
    printf 'BRAY_CLANGXX_BIN=%q\n' "${CLANGXX}"
    printf 'BRAY_LLD_BIN=%q\n' "${LLD}"
    printf 'BRAY_SYMBOLIZER_BIN=%q\n' "${SYMBOLIZER}"
    printf 'BRAY_BOLT_BIN=%q\n' "${BOLT}"
    printf 'BRAY_RUNTIME_LIB=%q\n' "${RUNTIME}"
  } >"${TOOLCHAIN_FILE}"
}

toolchain_ready() {
  local source_revision
  local built_revision
  source_revision="$(git -C "${LLVM_DIR}" rev-parse HEAD 2>/dev/null || true)"
  built_revision="$(cat "${SOURCE_REVISION_FILE}" 2>/dev/null || true)"
  [[ -n "${source_revision}" && "${source_revision}" == "${built_revision}" ]] &&
    [[ -n "${CLANG}" && -x "${CLANG}" ]] &&
    [[ -n "${CLANGXX}" && -x "${CLANGXX}" ]] &&
    [[ -n "${LLD}" && -x "${LLD}" ]] &&
    [[ -n "${SYMBOLIZER}" && -x "${SYMBOLIZER}" ]] &&
    [[ -x "${BOLT}" ]] &&
    [[ -f "${RUNTIME}" ]]
}

checkout_llvm() {
  require_command git

  if [[ -d "${LLVM_DIR}/.git" || -f "${LLVM_DIR}/.git" ]]; then
    if [[ -n "$(git -C "${LLVM_DIR}" status --porcelain)" ]]; then
      echo "error: LLVM checkout contains local changes: ${LLVM_DIR}" >&2
      exit 1
    fi
    echo "Updating ${LLVM_BRANCH}..."
    git -C "${LLVM_DIR}" fetch --depth 1 origin "${LLVM_BRANCH}"
    git -C "${LLVM_DIR}" checkout -B "${LLVM_BRANCH}" FETCH_HEAD
  else
    if [[ -e "${LLVM_DIR}" ]]; then
      echo "error: LLVM source path exists but is not a Git checkout:" >&2
      echo "  ${LLVM_DIR}" >&2
      echo "Remove it or set BRAY_LLVM_DIR to another path." >&2
      exit 1
    fi
    echo "Cloning ${LLVM_BRANCH}..."
    mkdir -p "$(dirname -- "${LLVM_DIR}")"
    git clone --depth 1 --branch "${LLVM_BRANCH}" "${LLVM_REPOSITORY}" \
      "${LLVM_DIR}"
  fi

  if [[ ! -d "${LLVM_DIR}/.git" && ! -f "${LLVM_DIR}/.git" ]]; then
    echo "error: failed to initialize LLVM checkout at ${LLVM_DIR}" >&2
    exit 1
  fi
  if [[ ! -f "${LLVM_DIR}/llvm/CMakeLists.txt" ||
        ! -f "${LLVM_DIR}/bolt/runtime/bray.cpp" ]]; then
    echo "error: ${LLVM_BRANCH} does not contain the BRay BOLT sources" >&2
    exit 1
  fi
}

require_command python3
NEED_CLANG=1
NEED_LLD=1
NEED_SYMBOLIZER=1
checkout_llvm
find_tools

if toolchain_ready; then
  write_toolchain_file
  echo "BRay toolchain is ready: ${LLVM_BUILD_DIR}"
  exit 0
fi

require_command cmake
require_command ninja

PROJECTS=(bolt)
TARGETS=(llvm-bolt bolt_rt)
if ((NEED_CLANG)); then
  PROJECTS+=(clang)
  TARGETS+=(clang)
fi
if ((NEED_LLD)); then
  PROJECTS+=(lld)
  TARGETS+=(lld)
fi
if ((NEED_SYMBOLIZER)); then
  TARGETS+=(llvm-symbolizer)
fi

PROJECT_LIST="$(IFS=';'; echo "${PROJECTS[*]}")"

CMAKE_ARGS=(
  -S "${LLVM_DIR}/llvm"
  -B "${LLVM_BUILD_DIR}"
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_ENABLE_ASSERTIONS=ON
  -DLLVM_ENABLE_PROJECTS="${PROJECT_LIST}"
  -DLLVM_TARGETS_TO_BUILD=X86\;AArch64
  -DLLVM_PARALLEL_LINK_JOBS=2
  -DLLVM_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DBOLT_ENABLE_RUNTIME=ON
)
if ((NEED_CLANG == 0)); then
  CMAKE_ARGS+=("-DBOLT_CLANG_EXE=${CLANG}")
fi
if ((NEED_LLD == 0)); then
  CMAKE_ARGS+=("-DBOLT_LLD_EXE=${LLD}")
fi

echo "Environment tools:"
echo "  clang:          ${CLANG:-build from source}"
echo "  clang++:        ${CLANGXX:-build from source}"
echo "  ld.lld:         ${LLD:-build from source}"
echo "  llvm-symbolizer:${SYMBOLIZER:-build from source}"
echo "LLVM projects to enable: ${PROJECT_LIST}"
echo "Build targets: ${TARGETS[*]}"

if [[ "${BRAY_BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
  exit 0
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "${LLVM_BUILD_DIR}" --parallel "${JOBS}" --target "${TARGETS[@]}"

find_tools
if [[ ! -x "${BOLT}" || ! -f "${RUNTIME}" || ! -x "${SYMBOLIZER}" ||
      ! -x "${CLANG}" || ! -x "${CLANGXX}" || ! -x "${LLD}" ]]; then
  echo "error: build completed without all required BRay tools" >&2
  exit 1
fi
git -C "${LLVM_DIR}" rev-parse HEAD >"${SOURCE_REVISION_FILE}"
write_toolchain_file

echo "BRay toolchain is ready: ${LLVM_BUILD_DIR}"
