#!/bin/bash

set -e

REPO="acsandmann/aerospace-swipe"
INSTALL_DIR="$HOME/.local/share/aerospace-swipe"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  --keep-source   Keep the source directory after uninstalling"
    echo ""
    echo "this script will uninstall aerospace-swipe and optionally remove the source directory"
    exit 0
fi

echo "aerospace-swipe uninstaller"
echo "==========================="

if [[ -f "makefile" && -f "src/main.m" ]]; then
    log_info "running in repository directory, using local code..."
    if make uninstall; then
        log_success "uninstallation complete"
    else
        log_error "uninstallation failed"
        exit 1
    fi
    exit 0
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    log_warning "Installation directory not found at $INSTALL_DIR"
    log_info "aerospace-swipe may not be installed or was installed differently"
    exit 0
fi

if [[ ! -f "$INSTALL_DIR/makefile" ]]; then
    log_error "makefile not found in $INSTALL_DIR"
    log_info "the installation appears to be corrupted"
    read -p "remove the installation directory anyway? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        log_success "installation directory removed"
    fi
    exit 1
fi

cd "$INSTALL_DIR"

log_info "uninstalling aerospace-swipe..."
if make uninstall; then
    log_success "aerospace-swipe service uninstalled successfully"
else
    log_error "failed to run make uninstall"
    exit 1
fi

if [[ "$1" != "--keep-source" ]]; then
    echo
    read -p "remove source directory at $INSTALL_DIR? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$HOME"
        rm -rf "$INSTALL_DIR"
        log_success "source directory removed"
    else
        log_info "source directory kept at $INSTALL_DIR"
    fi
else
    log_info "source directory kept at $INSTALL_DIR (--keep-source flag used)"
fi

log_success "uninstallation complete"
echo
echo "aerospace-swipe has been removed from your system"
