#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLVM_REPOSITORY="https://github.com/Jinjie-Huang/llvm-project.git"
LLVM_BRANCH="bolt_BRay"
LLVM_DIR="${BRAY_LLVM_DIR:-${ROOT_DIR}/llvm}"
LLVM_BUILD_DIR="${BRAY_LLVM_BUILD_DIR:-${ROOT_DIR}/llvm-build}"
JOBS="${BRAY_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' was not found" >&2
    exit 1
  fi
}

toolchain_ready() {
  [[ -x "${LLVM_BUILD_DIR}/bin/clang" ]] &&
    [[ -x "${LLVM_BUILD_DIR}/bin/clang++" ]] &&
    [[ -x "${LLVM_BUILD_DIR}/bin/ld.lld" ]] &&
    [[ -x "${LLVM_BUILD_DIR}/bin/llvm-bolt" ]] &&
    [[ -f "${LLVM_BUILD_DIR}/lib/libbolt_rt_iwyn.a" ]]
}

checkout_llvm() {
  if [[ -f "${LLVM_DIR}/llvm/CMakeLists.txt" ]]; then
    return
  fi

  require_command git

  local git_root
  git_root="$(git -C "${ROOT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${git_root}" ]]; then
    echo "Initializing a Git worktree for the demo..."
    git -C "${ROOT_DIR}" init
    git_root="${ROOT_DIR}"
  fi

  if [[ "${LLVM_DIR}" != "${git_root}/"* ]]; then
    echo "error: BRAY_LLVM_DIR must be inside ${git_root} for submodule setup" >&2
    exit 1
  fi

  local relative_path="${LLVM_DIR#"${git_root}/"}"
  if git -C "${git_root}" ls-files --stage -- "${relative_path}" |
      grep -q '^160000 '; then
    echo "Initializing LLVM submodule ${relative_path}..."
    git -C "${git_root}" submodule update --init --depth 1 --recommend-shallow \
      -- "${relative_path}"
  else
    echo "Adding LLVM as a shallow submodule..."
    git -C "${git_root}" submodule add --depth 1 -b "${LLVM_BRANCH}" \
      "${LLVM_REPOSITORY}" "${relative_path}"
  fi
}

if toolchain_ready; then
  echo "BRay toolchain is ready: ${LLVM_BUILD_DIR}"
  exit 0
fi

checkout_llvm
require_command cmake
require_command ninja

echo "Configuring LLVM, Clang, LLD, and BOLT..."
cmake -S "${LLVM_DIR}/llvm" -B "${LLVM_BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_PROJECTS="clang;lld;bolt" \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DBOLT_ENABLE_RUNTIME=ON

echo "Building the BRay toolchain with ${JOBS} jobs..."
cmake --build "${LLVM_BUILD_DIR}" --parallel "${JOBS}" \
  --target clang lld llvm-bolt bolt_rt

if ! toolchain_ready; then
  echo "error: build completed without all required BRay tools" >&2
  exit 1
fi

echo "BRay toolchain is ready: ${LLVM_BUILD_DIR}"
