#!/usr/bin/env bash
###############################################################################
# fastbuild-core — Installation Script
# Version: 1.0.0
#
# Installs fastbuild-core and its optional dependencies.
# Supports: Linux (x86_64/AArch64), Android Termux
###############################################################################
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"
readonly INSTALL_DIR="${FASTBUILD_INSTALL_DIR:-${HOME}/.local/bin}"
readonly CONFIG_DIR="${HOME}/.fastbuild"
readonly CACHE_DIR="${CONFIG_DIR}/cache"
readonly LOG_DIR="${CONFIG_DIR}/logs"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
fatal()   { error "$@"; exit 1; }

# ─── Platform Detection ──────────────────────────────────────────────────────
detect_platform() {
    local os arch

    # Detect OS
    if [[ -n "${ANDROID_ROOT:-}" ]] || [[ "$(uname -o 2>/dev/null)" == *"Android"* ]]; then
        os="termux"
    elif [[ "$(uname -s)" == "Linux" ]]; then
        os="linux"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        os="macos"
    else
        os="unknown"
    fi

    # Detect architecture
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)   arch="x86_64" ;;
        aarch64|arm64)   arch="aarch64" ;;
        armv7l|armv8l)   arch="armv7l" ;;
        *)               arch="${arch}" ;;
    esac

    echo "${os}:${arch}"
}

# ─── Dependency Checker ──────────────────────────────────────────────────────
check_dependency() {
    local name="$1"
    local pkg="${2:-$1}"
    local required="${3:-false}"

    if command -v "${name}" &>/dev/null; then
        local ver
        ver=$("${name}" --version 2>/dev/null | head -1 || echo "installed")
        success "${name}: ${ver}"
        return 0
    else
        if [[ "${required}" == "true" ]]; then
            error "${name}: NOT FOUND (required) — install via: ${pkg}"
            return 1
        else
            warn "${name}: not found (optional) — install via: ${pkg}"
            return 0
        fi
    fi
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v apk &>/dev/null; then
        echo "apk"
    elif command -v pkg &>/dev/null; then
        echo "pkg"  # Termux
    elif command -v brew &>/dev/null; then
        echo "brew"
    else
        echo "unknown"
    fi
}

get_install_cmd() {
    local pkg_mgr="$1"
    local pkg="$2"

    case "${pkg_mgr}" in
        apt)   echo "sudo apt-get install -y ${pkg}" ;;
        dnf)   echo "sudo dnf install -y ${pkg}" ;;
        pacman) echo "sudo pacman -S --noconfirm ${pkg}" ;;
        apk)   echo "sudo apk add ${pkg}" ;;
        pkg)   echo "pkg install ${pkg}" ;;
        brew)  echo "brew install ${pkg}" ;;
        *)     echo "echo 'Please install ${pkg} manually'" ;;
    esac
}

# ─── Installation ─────────────────────────────────────────────────────────────
install_fastbuild() {
    local script_source="$1"

    info "Installing fastbuild-core v${VERSION}..."

    # Create directories
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${CACHE_DIR}"
    mkdir -p "${LOG_DIR}"

    # Determine source path
    local source_path=""
    if [[ -f "${script_source}" ]]; then
        source_path="${script_source}"
    elif [[ -f "./fastbuild.sh" ]]; then
        source_path="./fastbuild.sh"
    elif [[ -f "$(dirname "$0")/fastbuild.sh" ]]; then
        source_path="$(dirname "$0")/fastbuild.sh"
    else
        fatal "Cannot find fastbuild.sh. Please provide the path or run from the same directory."
    fi

    # Copy script
    cp "${source_path}" "${INSTALL_DIR}/fastbuild"
    chmod +x "${INSTALL_DIR}/fastbuild"

    success "Installed to: ${INSTALL_DIR}/fastbuild"

    # Create symlink in /usr/local/bin if we have permissions
    if [[ -w /usr/local/bin ]] || sudo -n true 2>/dev/null; then
        if [[ ! -f /usr/local/bin/fastbuild ]]; then
            ln -sf "${INSTALL_DIR}/fastbuild" /usr/local/bin/fastbuild 2>/dev/null || true
            success "Symlinked to: /usr/local/bin/fastbuild"
        fi
    fi

    # Check if INSTALL_DIR is in PATH
    if ! echo "${PATH}" | tr ':' '\n' | grep -q "^${INSTALL_DIR}$"; then
        warn "${INSTALL_DIR} is not in your PATH"
        echo ""
        echo "  Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        echo ""
        echo -e "    ${BOLD}export PATH=\"${INSTALL_DIR}:\${PATH}\"${RESET}"
        echo ""
    fi
}

install_optional_deps() {
    local auto_install="${1:-false}"
    local platform
    platform=$(detect_platform)
    local pkg_mgr
    pkg_mgr=$(detect_package_manager)

    echo ""
    info "Checking optional dependencies..."
    echo ""

    local missing_deps=()

    # Check each optional dependency
    check_dependency "zstd" "zstd" || missing_deps+=("zstd")
    check_dependency "sccache" "sccache" || missing_deps+=("sccache")
    check_dependency "rsync" "rsync" || missing_deps+=("rsync")

    echo ""

    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        success "All optional dependencies are installed!"
        return 0
    fi

    info "Missing optional dependencies: ${missing_deps[*]}"

    if [[ "${auto_install}" == "true" ]]; then
        info "Auto-installing dependencies..."
        for dep in "${missing_deps[@]}"; do
            local cmd
            cmd=$(get_install_cmd "${pkg_mgr}" "${dep}")
            info "Installing ${dep}: ${cmd}"
            eval "${cmd}" 2>/dev/null || warn "Failed to install ${dep} — install manually"
        done
    else
        echo "  Install commands for your platform (${pkg_mgr}):"
        echo ""
        for dep in "${missing_deps[@]}"; do
            local cmd
            cmd=$(get_install_cmd "${pkg_mgr}" "${dep}")
            echo -e "    ${BOLD}${cmd}${RESET}"
        done
        echo ""
        echo "  Or run: $0 --install-deps"
    fi
}

# ─── Post-Install Verification ───────────────────────────────────────────────
verify_installation() {
    echo ""
    info "Verifying installation..."

    if [[ -x "${INSTALL_DIR}/fastbuild" ]]; then
        success "Binary is executable"
    else
        fatal "Binary is not executable at ${INSTALL_DIR}/fastbuild"
    fi

    # Test basic execution
    if "${INSTALL_DIR}/fastbuild" --version &>/dev/null; then
        success "Version check passed"
    else
        fatal "Version check failed"
    fi

    # Show environment
    echo ""
    echo -e "${BOLD}${CYAN}Environment:${RESET}"
    echo "  Platform:    $(detect_platform)"
    echo "  CPU Threads: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 'unknown')"
    echo "  RAM:         $(awk '/MemAvailable/ {printf "%.0fMB", $2/1024}' /proc/meminfo 2>/dev/null || echo 'unknown')"
    echo "  Cache Dir:   ${CACHE_DIR}"
    echo "  Install Dir: ${INSTALL_DIR}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
show_help() {
    cat <<'HELP'
fastbuild-core Installer v1.0.0

USAGE:
    ./install.sh [OPTIONS] [PATH_TO_FASTBUILD.SH]

OPTIONS:
    --install-deps    Auto-install missing optional dependencies
    --prefix DIR      Installation directory (default: ~/.local/bin)
    --check-only      Only check dependencies, don't install
    -h, --help        Show this help

EXAMPLES:
    ./install.sh                          # Install from current directory
    ./install.sh ./fastbuild.sh           # Install specific file
    ./install.sh --install-deps           # Install + auto-install deps
    ./install.sh --prefix /usr/local/bin  # Custom install location

HELP
}

main() {
    local auto_install_deps=false
    local check_only=false
    local script_path=""

    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║     fastbuild-core v${VERSION} — Installer              ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}\n"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-deps)
                auto_install_deps=true
                shift
                ;;
            --prefix)
                export FASTBUILD_INSTALL_DIR="$2"
                shift 2
                ;;
            --check-only)
                check_only=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                fatal "Unknown option: $1"
                ;;
            *)
                script_path="$1"
                shift
                ;;
        esac
    done

    # Show platform info
    local platform
    platform=$(detect_platform)
    info "Platform: ${platform}"
    info "Package Manager: $(detect_package_manager)"
    echo ""

    # Check required dependencies
    info "Checking required dependencies..."
    local has_errors=false
    check_dependency "bash" "bash" "true" || has_errors=true
    check_dependency "tar" "tar" "true" || has_errors=true
    check_dependency "sha256sum" "coreutils" "true" || \
    check_dependency "shasum" "perl" "true" || \
    check_dependency "openssl" "openssl" "true" || {
        error "No SHA256 tool found (sha256sum, shasum, or openssl)"
        has_errors=true
    }

    if [[ "${has_errors}" == "true" ]]; then
        fatal "Missing required dependencies. Please install them first."
    fi

    echo ""
    success "All required dependencies satisfied!"

    if [[ "${check_only}" == "true" ]]; then
        install_optional_deps
        exit 0
    fi

    # Install
    install_fastbuild "${script_path}"

    # Optional deps
    install_optional_deps "${auto_install_deps}"

    # Verify
    verify_installation

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${GREEN}  Installation complete! Run 'fastbuild --help' to start.${RESET}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${RESET}"
    echo ""
}

main "$@"
