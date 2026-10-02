#!/usr/bin/env bash
###############################################################################
# fastbuild-core — Universal Build Acceleration CLI
# Version: 1.0.0
# License: MIT
#
# A production-grade build acceleration tool for Linux and Android Termux.
# Eliminates slow multi-minute compilations via smart caching, RAMDisk
# workspaces, compiler proxying, and Zstandard binary artifact archiving.
###############################################################################
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"
readonly PROGRAM_NAME="fastbuild-core"
readonly CACHE_DIR="${FASTBUILD_CACHE_DIR:-${HOME}/.fastbuild/cache}"
readonly RAMDISK_DIR="${FASTBUILD_RAMDISK_DIR:-/tmp/fastbuild-ramdisk}"
readonly LOG_FILE="${FASTBUILD_LOG_DIR:-${HOME}/.fastbuild/logs}/fastbuild.log"
readonly MAX_CACHE_SIZE_DEFAULT="5G"
readonly ZSTD_THREADS="${FASTBUILD_ZSTD_THREADS:-0}"  # 0 = auto-detect

# ─── Color Codes ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly MAGENTA='\033[0;35m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' RESET=''
fi

# ─── Global State ─────────────────────────────────────────────────────────────
RAMDISK_CREATED=false
TEMP_DIRS=()
BUILD_START_TIME=""
ECOSYSTEM=""
PROJECT_HASH=""

# ─── Logging Functions ────────────────────────────────────────────────────────
log_init() {
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    mkdir -p "${log_dir}" 2>/dev/null || true
    if [[ -f "${LOG_FILE}" ]]; then
        # Rotate log if > 10MB
        local size
        size=$(stat -f%z "${LOG_FILE}" 2>/dev/null || stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
        if [[ ${size} -gt 10485760 ]]; then
            mv "${LOG_FILE}" "${LOG_FILE}.old" 2>/dev/null || true
        fi
    fi
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local color=""
    local icon=""

    case "${level}" in
        INFO)    color="${BLUE}";    icon="ℹ" ;;
        WARN)    color="${YELLOW}";  icon="⚠" ;;
        ERROR)   color="${RED}";     icon="✗" ;;
        SUCCESS) color="${GREEN}";   icon="✓" ;;
        DEBUG)   color="${DIM}";     icon="→" ;;
        BUILD)   color="${CYAN}";    icon="⚙" ;;
        CACHE)   color="${MAGENTA}"; icon="◈" ;;
    esac

    echo -e "${color}${BOLD}[${icon} ${level}]${RESET} ${message}" >&2
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_fatal() {
    log ERROR "$@"
    cleanup_on_exit
    exit 1
}

# ─── Signal Traps & Cleanup ──────────────────────────────────────────────────
cleanup_on_exit() {
    local exit_code=$?

    if [[ "${RAMDISK_CREATED}" == "true" ]]; then
        log DEBUG "Cleaning up RAMDisk workspace..."
        # Sync before removal to ensure data integrity
        sync 2>/dev/null || true
        rm -rf "${RAMDISK_DIR}" 2>/dev/null || true
        RAMDISK_CREATED=false
    fi

    # Clean up any temp directories
    for dir in "${TEMP_DIRS[@]:-}"; do
        if [[ -n "${dir}" && -d "${dir}" ]]; then
            rm -rf "${dir}" 2>/dev/null || true
        fi
    done

    if [[ ${exit_code} -ne 0 ]]; then
        log WARN "Exited with code ${exit_code}"
    fi
}

trap cleanup_on_exit EXIT
trap 'log WARN "Interrupted by SIGINT"; exit 130' INT
trap 'log WARN "Terminated by SIGTERM"; exit 143' TERM
trap 'log ERROR "Pipeline failure at line $LINENO"; exit 1' ERR

# ─── Utility Functions ────────────────────────────────────────────────────────
get_nproc() {
    if command -v nproc &>/dev/null; then
        nproc
    elif [[ -f /proc/cpuinfo ]]; then
        grep -c ^processor /proc/cpuinfo
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.ncpu 2>/dev/null || echo 2
    else
        echo 2
    fi
}

get_available_ram_mb() {
    if [[ -f /proc/meminfo ]]; then
        awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo
    elif command -v sysctl &>/dev/null; then
        local bytes
        bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        echo $(( bytes / 1048576 ))
    else
        echo 512
    fi
}

get_tmpfs_available_mb() {
    local available=0
    if command -v df &>/dev/null; then
        # Check /tmp for tmpfs
        local tmp_info
        tmp_info=$(df -BM /tmp 2>/dev/null | tail -1)
        available=$(echo "${tmp_info}" | awk '{gsub("M",""); print $4}')
    fi
    echo "${available:-256}"
}

human_readable_size() {
    local bytes="$1"
    if [[ ${bytes} -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", ${bytes}/1073741824}")G"
    elif [[ ${bytes} -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", ${bytes}/1048576}")M"
    elif [[ ${bytes} -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", ${bytes}/1024}")K"
    else
        echo "${bytes}B"
    fi
}

parse_size_to_bytes() {
    local size_str="$1"
    local number unit
    number=$(echo "${size_str}" | sed 's/[^0-9.]//g')
    unit=$(echo "${size_str}" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

    case "${unit}" in
        G|GB) echo "$(awk "BEGIN {printf \"%.0f\", ${number}*1073741824}")" ;;
        M|MB) echo "$(awk "BEGIN {printf \"%.0f\", ${number}*1048576}")" ;;
        K|KB) echo "$(awk "BEGIN {printf \"%.0f\", ${number}*1024}")" ;;
        *)    echo "$(awk "BEGIN {printf \"%.0f\", ${number}}")" ;;
    esac
}

elapsed_time() {
    local start="$1"
    local end
    end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#end} -gt 12 ]]; then
        # Nanosecond precision available
        local diff=$(( (end - start) / 1000000 ))
        if [[ ${diff} -ge 1000 ]]; then
            echo "$(awk "BEGIN {printf \"%.2f\", ${diff}/1000}")s"
        else
            echo "${diff}ms"
        fi
    else
        echo "$(( end - start ))s"
    fi
}

check_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        return 1
    fi
    return 0
}

require_command() {
    local cmd="$1"
    local hint="${2:-}"
    if ! check_command "${cmd}"; then
        if [[ -n "${hint}" ]]; then
            log_fatal "Required command '${cmd}' not found. ${hint}"
        else
            log_fatal "Required command '${cmd}' not found. Please install it."
        fi
    fi
}

# ─── Hasher Engine ────────────────────────────────────────────────────────────
compute_dependency_hash() {
    local project_dir="$1"
    local hash_input=""
    local hash_files=(
        "CMakeLists.txt"
        "Cargo.toml"
        "Cargo.lock"
        "package.json"
        "package-lock.json"
        "pnpm-lock.yaml"
        "yarn.lock"
        "requirements.txt"
        "setup.py"
        "setup.cfg"
        "pyproject.toml"
        "Makefile"
        "GNUmakefile"
        "meson.build"
        "configure.ac"
        "configure"
        "*.cmake"
        "CMakePresets.json"
        ".cargo/config.toml"
        "rust-toolchain.toml"
    )

    local found_files=()
    for pattern in "${hash_files[@]}"; do
        while IFS= read -r -d '' file; do
            found_files+=("${file}")
        done < <(find "${project_dir}" -maxdepth 2 -name "${pattern}" -print0 2>/dev/null | sort -z)
    done

    if [[ ${#found_files[@]} -eq 0 ]]; then
        log WARN "No build configuration files found in ${project_dir}"
        # Fallback: hash all source files
        hash_input=$(find "${project_dir}" -maxdepth 3 \
            \( -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" \
            -o -name "*.rs" -o -name "*.py" -o -name "*.js" -o -name "*.ts" \) \
            -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null || echo "empty")
    else
        # Hash the content of all found config files
        hash_input=$(cat "${found_files[@]}" 2>/dev/null || echo "empty")
        # Also include compiler version in hash for cache invalidation
        if check_command gcc; then
            hash_input+="$(gcc --version 2>/dev/null | head -1)"
        fi
        if check_command clang; then
            hash_input+="$(clang --version 2>/dev/null | head -1)"
        fi
        if check_command rustc; then
            hash_input+="$(rustc --version 2>/dev/null)"
        fi
    fi

    # Compute SHA256 hash
    if check_command sha256sum; then
        echo -n "${hash_input}" | sha256sum | awk '{print $1}'
    elif check_command shasum; then
        echo -n "${hash_input}" | shasum -a 256 | awk '{print $1}'
    elif check_command openssl; then
        echo -n "${hash_input}" | openssl dgst -sha256 | awk '{print $NF}'
    else
        log_fatal "No SHA256 hashing tool found (sha256sum, shasum, or openssl)"
    fi
}

# ─── Cache Engine ─────────────────────────────────────────────────────────────
cache_init() {
    mkdir -p "${CACHE_DIR}" 2>/dev/null || log_fatal "Cannot create cache directory: ${CACHE_DIR}"
    log DEBUG "Cache directory: ${CACHE_DIR}"
}

cache_get_path() {
    local hash="$1"
    local ecosystem="$2"
    echo "${CACHE_DIR}/${ecosystem}/${hash:0:2}/${hash}.tar.zst"
}

cache_hit() {
    local hash="$1"
    local ecosystem="$2"
    local cache_path
    cache_path=$(cache_get_path "${hash}" "${ecosystem}")

    if [[ -f "${cache_path}" ]]; then
        # Validate archive integrity
        if validate_archive "${cache_path}"; then
            return 0
        else
            log WARN "Cache archive corrupted, removing: ${cache_path}"
            rm -f "${cache_path}"
            return 1
        fi
    fi
    return 1
}

cache_store() {
    local hash="$1"
    local ecosystem="$2"
    local source_dir="$3"
    local cache_path
    cache_path=$(cache_get_path "${hash}" "${ecosystem}")

    mkdir -p "$(dirname "${cache_path}")"

    log CACHE "Storing build artifacts to cache..."
    local zstd_args=(-T0 -19 --long --quiet)

    if check_command zstd; then
        tar -cf - -C "${source_dir}" . 2>/dev/null | \
            zstd "${zstd_args[@]}" -o "${cache_path}" 2>/dev/null || \
            log_fatal "Failed to create cache archive"
        log SUCCESS "Cached to: ${cache_path} ($(human_readable_size "$(stat -c%s "${cache_path}" 2>/dev/null || stat -f%z "${cache_path}" 2>/dev/null || echo 0)"))"
    else
        log WARN "zstd not available, falling back to gzip"
        tar -czf "${cache_path%.zst}.gz" -C "${source_dir}" . 2>/dev/null || \
            log_fatal "Failed to create cache archive"
    fi
}

cache_restore() {
    local hash="$1"
    local ecosystem="$2"
    local target_dir="$3"
    local cache_path
    cache_path=$(cache_get_path "${hash}" "${ecosystem}")

    log CACHE "Restoring from cache (parallel zstd decompression)..."

    if [[ "${cache_path}" == *.tar.zst ]]; then
        zstd -d -T0 --quiet --stdout "${cache_path}" 2>/dev/null | \
            tar -xf - -C "${target_dir}" 2>/dev/null || \
            log_fatal "Failed to extract cache archive"
    elif [[ "${cache_path%.zst}.gz" == *.gz && -f "${cache_path%.zst}.gz" ]]; then
        tar -xzf "${cache_path%.zst}.gz" -C "${target_dir}" 2>/dev/null || \
            log_fatal "Failed to extract cache archive"
    else
        log_fatal "No valid cache archive found"
    fi

    log SUCCESS "Cache restored successfully"
}

validate_archive() {
    local archive_path="$1"

    if [[ ! -f "${archive_path}" ]]; then
        return 1
    fi

    # Check file size > 0
    local size
    size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null || echo 0)
    if [[ ${size} -eq 0 ]]; then
        return 1
    fi

    # Validate zstd archive integrity
    if [[ "${archive_path}" == *.tar.zst ]] && check_command zstd; then
        if ! zstd -t "${archive_path}" &>/dev/null; then
            return 1
        fi
    elif [[ "${archive_path}" == *.gz ]] && check_command gzip; then
        if ! gzip -t "${archive_path}" &>/dev/null; then
            return 1
        fi
    fi

    return 0
}

cache_clean() {
    local max_size="${1:-${MAX_CACHE_SIZE_DEFAULT}}"
    local max_bytes
    max_bytes=$(parse_size_to_bytes "${max_size}")

    log INFO "Cleaning cache (max size: ${max_size})..."

    if [[ ! -d "${CACHE_DIR}" ]]; then
        log INFO "Cache directory does not exist, nothing to clean"
        return 0
    fi

    # Calculate current cache size
    local current_size
    current_size=$(du -sb "${CACHE_DIR}" 2>/dev/null | awk '{print $1}')
    current_size=${current_size:-0}

    if [[ ${current_size} -le ${max_bytes} ]]; then
        log INFO "Cache size ($(human_readable_size ${current_size})) within limit (${max_size})"
        return 0
    fi

    log INFO "Cache size (${current_size}) exceeds limit (${max_size}), performing LRU eviction..."

    # LRU eviction: sort files by access time, remove oldest first
    local files_to_remove=()
    while IFS= read -r -d '' file; do
        files_to_remove+=("${file}")
        current_size=$(du -sb "${CACHE_DIR}" 2>/dev/null | awk '{print $1}')
        current_size=${current_size:-0}
        if [[ ${current_size} -le ${max_bytes} ]]; then
            break
        fi
    done < <(find "${CACHE_DIR}" -type f \( -name "*.tar.zst" -o -name "*.gz" \) -printf '%T@ %p\0' 2>/dev/null | \
        sort -z -n | sed -z 's/^[^ ]* //')

    local removed_count=0
    for file in "${files_to_remove[@]:-}"; do
        if [[ -n "${file}" && -f "${file}" ]]; then
            rm -f "${file}"
            ((removed_count++)) || true
            # Clean empty parent directories
            local parent
            parent=$(dirname "${file}")
            rmdir "${parent}" 2>/dev/null || true
            parent=$(dirname "${parent}")
            rmdir "${parent}" 2>/dev/null || true
        fi
    done

    log SUCCESS "Removed ${removed_count} cached artifacts. New cache size: $(human_readable_size "$(du -sb "${CACHE_DIR}" 2>/dev/null | awk '{print $1}')")"
}

cache_purge() {
    log WARN "Purging entire cache directory..."
    rm -rf "${CACHE_DIR}"
    mkdir -p "${CACHE_DIR}"
    log SUCCESS "Cache purged successfully"
}

cache_stats() {
    if [[ ! -d "${CACHE_DIR}" ]]; then
        log INFO "No cache directory found"
        return 0
    fi

    local total_size
    total_size=$(du -sh "${CACHE_DIR}" 2>/dev/null | awk '{print $1}')
    local file_count
    file_count=$(find "${CACHE_DIR}" -type f \( -name "*.tar.zst" -o -name "*.gz" \) 2>/dev/null | wc -l)

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║      fastbuild-core Cache Statistics     ║${RESET}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET} Total Size:     ${BOLD}${total_size:-0}${RESET}"
    echo -e "${CYAN}║${RESET} Cached Items:   ${BOLD}${file_count}${RESET}"
    echo -e "${CYAN}║${RESET} Cache Dir:      ${BOLD}${CACHE_DIR}${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
}

# ─── RAMDisk Engine ───────────────────────────────────────────────────────────
ramdisk_init() {
    local available_ram
    available_ram=$(get_available_ram_mb)
    local available_tmpfs
    available_tmpfs=$(get_tmpfs_available_mb)

    log INFO "System RAM available: ${available_ram}MB"
    log INFO "tmpfs space available: ${available_tmpfs}MB"

    # Determine if we should use RAMDisk (need at least 256MB free)
    local use_ramdisk=false
    local ramdisk_target=""

    if [[ ${available_tmpfs} -ge 256 ]]; then
        ramdisk_target="${RAMDISK_DIR}"
        use_ramdisk=true
    elif [[ ${available_ram} -ge 512 ]]; then
        # Try to create a tmpfs mount
        ramdisk_target="${RAMDISK_DIR}"
        use_ramdisk=true
    fi

    if [[ "${use_ramdisk}" == "true" ]]; then
        # Create isolated build workspace
        mkdir -p "${ramdisk_target}" 2>/dev/null || {
            log WARN "Cannot create RAMDisk at ${ramdisk_target}, using /tmp"
            ramdisk_target="/tmp/fastbuild-$$"
            mkdir -p "${ramdisk_target}"
        }

        # If /tmp is already tmpfs, we're already in RAM
        if mountpoint -q /tmp 2>/dev/null || [[ "$(df -T /tmp 2>/dev/null | tail -1 | awk '{print $2}')" == "tmpfs" ]]; then
            log SUCCESS "Build workspace in tmpfs (RAM-backed): ${ramdisk_target}"
        else
            log INFO "Build workspace: ${ramdisk_target} (consider mounting tmpfs for better performance)"
        fi

        RAMDISK_CREATED=true
        echo "${ramdisk_target}"
    else
        log WARN "Insufficient memory for RAMDisk, using project directory"
        echo ""
    fi
}

ramdisk_sync_project() {
    local project_dir="$1"
    local ramdisk_dir="$2"

    if [[ -z "${ramdisk_dir}" ]]; then
        return 0
    fi

    log INFO "Syncing project to RAMDisk workspace..."
    # Use rsync if available for incremental sync, otherwise cp
    if check_command rsync; then
        rsync -a --exclude='.git' --exclude='node_modules' --exclude='target' \
            --exclude='build' --exclude='__pycache__' --exclude='.cache' \
            "${project_dir}/" "${ramdisk_dir}/" 2>/dev/null || \
            cp -a "${project_dir}/." "${ramdisk_dir}/" 2>/dev/null || \
            log_fatal "Failed to sync project to RAMDisk"
    else
        cp -a "${project_dir}/." "${ramdisk_dir}/" 2>/dev/null || \
            log_fatal "Failed to sync project to RAMDisk"
    fi

    log SUCCESS "Project synced to RAMDisk"
}

ramdisk_sync_back() {
    local project_dir="$1"
    local ramdisk_dir="$2"

    if [[ -z "${ramdisk_dir}" || ! -d "${ramdisk_dir}" ]]; then
        return 0
    fi

    log INFO "Syncing build artifacts back to project directory..."
    if check_command rsync; then
        rsync -a "${ramdisk_dir}/" "${project_dir}/" 2>/dev/null || true
    else
        cp -a "${ramdisk_dir}/." "${project_dir}/" 2>/dev/null || true
    fi
}

# ─── Compiler Proxy Engine ───────────────────────────────────────────────────
setup_compiler_proxy() {
    local nproc_count
    nproc_count=$(get_nproc)

    log INFO "Detected ${nproc_count} CPU threads"

    # Auto-detect and configure compiler caching proxy
    local proxy_found=false

    if check_command sccache; then
        log SUCCESS "Found sccache — enabling compiler proxy"
        export CC="sccache ${CC:-gcc}"
        export CXX="sccache ${CXX:-g++}"
        export RUSTC_WRAPPER="sccache"
        export SCCACHE_IDLE_TIMEOUT=0
        proxy_found=true
    elif check_command ccache; then
        log SUCCESS "Found ccache — enabling compiler proxy"
        export CC="ccache ${CC:-gcc}"
        export CXX="ccache ${CXX:-g++}"
        proxy_found=true
    else
        log WARN "No compiler cache proxy found (sccache/ccache). Install one for faster rebuilds."
        log DEBUG "  Install: sudo apt install sccache  OR  cargo install sccache"
    fi

    # Set parallel build flags
    export MAKEFLAGS="-j${nproc_count}"
    export CMAKE_BUILD_PARALLEL_LEVEL="${nproc_count}"
    export CARGO_BUILD_JOBS="${nproc_count}"

    if [[ "${proxy_found}" == "true" ]]; then
        log INFO "CC=${CC}"
        log INFO "CXX=${CXX}"
        if [[ -n "${RUSTC_WRAPPER:-}" ]]; then
            log INFO "RUSTC_WRAPPER=${RUSTC_WRAPPER}"
        fi
    fi
}

# ─── Ecosystem Detection ─────────────────────────────────────────────────────
detect_ecosystem() {
    local project_dir="$1"

    # Priority order for detection
    if [[ -f "${project_dir}/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "${project_dir}/CMakeLists.txt" ]]; then
        echo "cmake"
    elif [[ -f "${project_dir}/meson.build" ]]; then
        echo "meson"
    elif [[ -f "${project_dir}/setup.py" || -f "${project_dir}/pyproject.toml" ]]; then
        # Check if it has C extensions
        if grep -rq "Extension\|cython\|cffi\|setuptools_rust\|build_ext" "${project_dir}/setup.py" "${project_dir}/pyproject.toml" 2>/dev/null; then
            echo "python-c"
        else
            echo "python"
        fi
    elif [[ -f "${project_dir}/Makefile" || -f "${project_dir}/GNUmakefile" ]]; then
        echo "make"
    elif [[ -f "${project_dir}/package.json" ]]; then
        # Check for native addon indicators
        if grep -q '"gyp"\|"node-gyp"\|"native"\|"addon"' "${project_dir}/package.json" 2>/dev/null; then
            echo "node-native"
        else
            echo "node"
        fi
    elif [[ -f "${project_dir}/configure" || -f "${project_dir}/configure.ac" ]]; then
        echo "autotools"
    else
        echo "unknown"
    fi
}

# ─── Build Routines ──────────────────────────────────────────────────────────
build_rust() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    log BUILD "Building Rust project (release mode, ${nproc_count} jobs)..."

    cd "${work_dir}"
    if [[ "${FASTBUILD_DEBUG:-false}" == "true" ]]; then
        cargo build --jobs "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"
    else
        cargo build --release --jobs "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"
    fi

    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Rust build failed with exit code ${exit_code}"
    fi

    log SUCCESS "Rust build completed"
}

build_cmake() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    log BUILD "Building CMake project (${nproc_count} parallel jobs)..."

    cd "${work_dir}"

    # Configure
    local cmake_args=(-B build -DCMAKE_BUILD_TYPE=Release)

    if check_command sccache; then
        cmake_args+=(-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache)
    elif check_command ccache; then
        cmake_args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    fi

    cmake "${cmake_args[@]}" 2>&1 | tee -a "${LOG_FILE}"
    local config_exit=${PIPESTATUS[0]}
    if [[ ${config_exit} -ne 0 ]]; then
        log_fatal "CMake configuration failed"
    fi

    # Build
    cmake --build build -j "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"
    local build_exit=${PIPESTATUS[0]}
    if [[ ${build_exit} -ne 0 ]]; then
        log_fatal "CMake build failed"
    fi

    log SUCCESS "CMake build completed"
}

build_make() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    log BUILD "Building with Make (${nproc_count} parallel jobs)..."

    cd "${work_dir}"
    make -j "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"
    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Make build failed"
    fi

    log SUCCESS "Make build completed"
}

build_python() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    cd "${work_dir}"

    if [[ -f "setup.py" ]]; then
        log BUILD "Building Python C-extensions (${nproc_count} jobs)..."
        python3 setup.py build_ext --inplace -j "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"
    elif [[ -f "pyproject.toml" ]]; then
        log BUILD "Building Python project via pip..."
        python3 -m pip install --no-build-isolation -v . 2>&1 | tee -a "${LOG_FILE}"
    fi

    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Python build failed"
    fi

    log SUCCESS "Python build completed"
}

build_node() {
    local work_dir="$1"

    cd "${work_dir}"

    if check_command pnpm; then
        log BUILD "Installing Node.js dependencies via pnpm..."
        pnpm install --prefer-offline 2>&1 | tee -a "${LOG_FILE}"
    elif check_command npm; then
        log BUILD "Installing Node.js dependencies via npm..."
        npm install --prefer-offline 2>&1 | tee -a "${LOG_FILE}"
    else
        log_fatal "Neither pnpm nor npm found"
    fi

    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Node.js install failed"
    fi

    log SUCCESS "Node.js dependencies installed"
}

build_meson() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    log BUILD "Building Meson project (${nproc_count} jobs)..."

    cd "${work_dir}"
    meson setup build --buildtype=release 2>&1 | tee -a "${LOG_FILE}"
    ninja -C build -j "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"

    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Meson build failed"
    fi

    log SUCCESS "Meson build completed"
}

build_autotools() {
    local work_dir="$1"
    local nproc_count
    nproc_count=$(get_nproc)

    log BUILD "Building Autotools project (${nproc_count} jobs)..."

    cd "${work_dir}"

    if [[ ! -f "configure" ]]; then
        if [[ -f "configure.ac" ]] || [[ -f "configure.in" ]]; then
            autoreconf -fi 2>&1 | tee -a "${LOG_FILE}"
        fi
    fi

    if [[ -f "configure" ]]; then
        ./configure 2>&1 | tee -a "${LOG_FILE}"
    fi

    make -j "${nproc_count}" 2>&1 | tee -a "${LOG_FILE}"

    local exit_code=${PIPESTATUS[0]}
    if [[ ${exit_code} -ne 0 ]]; then
        log_fatal "Autotools build failed"
    fi

    log SUCCESS "Autotools build completed"
}

# ─── Main Build Orchestrator ─────────────────────────────────────────────────
do_build() {
    local project_dir="$1"
    local skip_cache="${2:-false}"
    local force_rebuild="${3:-false}"

    BUILD_START_TIME=$(date +%s%N 2>/dev/null || date +%s)

    # Banner
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║          ${GREEN}fastbuild-core${CYAN} v${VERSION}                      ║${RESET}"
    echo -e "${BOLD}${CYAN}║    Universal Build Acceleration Engine              ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}\n"

    # Initialize subsystems
    log_init
    cache_init

    log INFO "Project directory: ${project_dir}"

    # Detect ecosystem
    ECOSYSTEM=$(detect_ecosystem "${project_dir}")
    log INFO "Detected ecosystem: ${BOLD}${ECOSYSTEM}${RESET}"

    if [[ "${ECOSYSTEM}" == "unknown" ]]; then
        log_fatal "Cannot detect project ecosystem. No recognized build files found."
    fi

    # Compute dependency hash
    log INFO "Computing dependency hash..."
    PROJECT_HASH=$(compute_dependency_hash "${project_dir}")
    log INFO "Project hash: ${PROJECT_HASH:0:16}..."

    # Check cache (unless force rebuild)
    if [[ "${force_rebuild}" != "true" && "${skip_cache}" != "true" ]]; then
        if cache_hit "${PROJECT_HASH}" "${ECOSYSTEM}"; then
            log CACHE "Cache HIT! Restoring pre-built artifacts..."

            local restore_start
            restore_start=$(date +%s%N 2>/dev/null || date +%s)

            cache_restore "${PROJECT_HASH}" "${ECOSYSTEM}" "${project_dir}"

            local restore_time
            restore_time=$(elapsed_time "${restore_start}")
            log SUCCESS "Build restored from cache in ${restore_time} (skipped compilation)"

            echo -e "\n${BOLD}${GREEN}═══ BUILD COMPLETE (from cache) in ${restore_time} ═══${RESET}\n"
            return 0
        else
            log CACHE "Cache MISS — proceeding with fresh build"
        fi
    fi

    # Setup compiler proxy
    setup_compiler_proxy

    # Initialize RAMDisk workspace
    local ramdisk_dir
    ramdisk_dir=$(ramdisk_init)

    local work_dir="${project_dir}"
    if [[ -n "${ramdisk_dir}" ]]; then
        ramdisk_sync_project "${project_dir}" "${ramdisk_dir}"
        work_dir="${ramdisk_dir}"
    fi

    # Execute build
    log BUILD "Starting build..."
    local build_start
    build_start=$(date +%s%N 2>/dev/null || date +%s)

    case "${ECOSYSTEM}" in
        rust)        build_rust "${work_dir}" ;;
        cmake)       build_cmake "${work_dir}" ;;
        make)        build_make "${work_dir}" ;;
        python|python-c) build_python "${work_dir}" ;;
        node|node-native) build_node "${work_dir}" ;;
        meson)       build_meson "${work_dir}" ;;
        autotools)   build_autotools "${work_dir}" ;;
        *)           log_fatal "No build routine for ecosystem: ${ECOSYSTEM}" ;;
    esac

    local build_time
    build_time=$(elapsed_time "${build_start}")
    log INFO "Build completed in ${build_time}"

    # Sync back from RAMDisk
    if [[ -n "${ramdisk_dir}" ]]; then
        ramdisk_sync_back "${project_dir}" "${ramdisk_dir}"
    fi

    # Store in cache
    if [[ "${skip_cache}" != "true" ]]; then
        cache_store "${PROJECT_HASH}" "${ECOSYSTEM}" "${work_dir}"
    fi

    local total_time
    total_time=$(elapsed_time "${BUILD_START_TIME}")
    echo -e "\n${BOLD}${GREEN}═══ BUILD COMPLETE in ${total_time} ═══${RESET}\n"
}

# ─── CLI Argument Parser ─────────────────────────────────────────────────────
show_help() {
    cat <<'HELP'
fastbuild-core — Universal Build Acceleration CLI v1.0.0

USAGE:
    fastbuild [COMMAND] [OPTIONS] [PROJECT_DIR]

COMMANDS:
    build           Build the project with acceleration (default)
    clean           Clean build cache (LRU eviction)
    purge           Purge entire build cache
    stats           Show cache statistics
    hash            Compute and display project hash
    detect          Detect and display project ecosystem
    version         Show version information
    help            Show this help message

OPTIONS:
    --no-cache          Skip cache lookup/store for this build
    --force             Force rebuild even if cache exists
    --debug             Build in debug mode
    --max-cache-size N  Set maximum cache size (e.g., 5G, 500M)
    --clean             Clean cache with default max size (5G)
    --ramdisk-dir PATH  Override RAMDisk directory location
    --cache-dir PATH    Override cache directory location
    -h, --help          Show this help message
    -v, --version       Show version

EXAMPLES:
    fastbuild                       # Build current directory
    fastbuild build ./my-project    # Build specific project
    fastbuild --force build         # Force rebuild, ignore cache
    fastbuild clean --max-cache-size 2G
    fastbuild stats
    fastbuild hash ./my-project

ENVIRONMENT VARIABLES:
    FASTBUILD_CACHE_DIR     Cache directory (default: ~/.fastbuild/cache)
    FASTBUILD_RAMDISK_DIR   RAMDisk directory (default: /tmp/fastbuild-ramdisk)
    FASTBUILD_LOG_DIR       Log directory (default: ~/.fastbuild/logs)
    FASTBUILD_ZSTD_THREADS  Zstd compression threads (default: auto)

HELP
}

show_version() {
    echo "fastbuild-core v${VERSION}"
    echo "Build Acceleration Engine for Linux & Termux"
    echo ""
    echo "Components:"
    echo "  Shell:      ${BASH_VERSION}"
    echo "  CPU Threads: $(get_nproc)"
    echo "  RAM:        $(get_available_ram_mb)MB available"
    echo "  Cache Dir:  ${CACHE_DIR}"
    echo ""
    echo "Optional tools detected:"
    for tool in sccache ccache zstd sha256sum rsync cargo cmake make ninja; do
        if check_command "${tool}"; then
            echo -e "  ${GREEN}✓${RESET} ${tool}"
        else
            echo -e "  ${DIM}✗ ${tool}${RESET}"
        fi
    done
}

main() {
    local command="build"
    local project_dir="."
    local skip_cache=false
    local force_rebuild=false
    local max_cache_size="${MAX_CACHE_SIZE_DEFAULT}"
    local debug_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            build|clean|purge|stats|hash|detect|version|help)
                command="$1"
                shift
                ;;
            --no-cache)
                skip_cache=true
                shift
                ;;
            --force)
                force_rebuild=true
                shift
                ;;
            --debug)
                debug_mode=true
                export FASTBUILD_DEBUG=true
                shift
                ;;
            --max-cache-size)
                max_cache_size="$2"
                shift 2
                ;;
            --clean)
                command="clean"
                shift
                ;;
            --ramdisk-dir)
                export FASTBUILD_RAMDISK_DIR="$2"
                shift 2
                ;;
            --cache-dir)
                export FASTBUILD_CACHE_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -*)
                log_fatal "Unknown option: $1. Use --help for usage."
                ;;
            *)
                project_dir="$1"
                shift
                ;;
        esac
    done

    # Resolve project directory
    if [[ ! -d "${project_dir}" ]]; then
        log_fatal "Project directory does not exist: ${project_dir}"
    fi
    project_dir="$(cd "${project_dir}" && pwd)"

    # Execute command
    case "${command}" in
        build)
            do_build "${project_dir}" "${skip_cache}" "${force_rebuild}"
            ;;
        clean)
            log_init
            cache_init
            cache_clean "${max_cache_size}"
            ;;
        purge)
            log_init
            cache_init
            cache_purge
            ;;
        stats)
            log_init
            cache_stats
            ;;
        hash)
            log_init
            local hash
            hash=$(compute_dependency_hash "${project_dir}")
            echo "Project: ${project_dir}"
            echo "Ecosystem: $(detect_ecosystem "${project_dir}")"
            echo "Hash: ${hash}"
            ;;
        detect)
            local eco
            eco=$(detect_ecosystem "${project_dir}")
            echo "Project: ${project_dir}"
            echo "Ecosystem: ${eco}"
            ;;
        version)
            show_version
            ;;
        help)
            show_help
            ;;
        *)
            log_fatal "Unknown command: ${command}"
            ;;
    esac
}

# ─── Entry Point ──────────────────────────────────────────────────────────────
main "$@"
