#!/bin/bash

set -e

REPO="acsandmann/aerospace-swipe"
INSTALL_DIR="$HOME/.local/share/aerospace-swipe"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ -f "makefile" && -f "src/main.m" ]]; then
    log_info "running in repository directory, using local code..."
    make install
    log_success "installation complete"
    exit 0
fi

log_info "downloading aerospace-swipe..."

mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    log_info "repository already exists, updating..."
    cd "$INSTALL_DIR"
    git pull
else
    git clone "https://github.com/${REPO}.git" "$INSTALL_DIR"
fi

SOURCE_DIR="$INSTALL_DIR"

if [[ ! -d "$SOURCE_DIR" || ! -f "$SOURCE_DIR/makefile" ]]; then
    log_error "could not find source directory with makefile"
    exit 1
fi

cd "$SOURCE_DIR"

log_info "installing aerospace-swipe..."
make install

log_success "installation complete"
echo
echo "aerospace-swipe has been installed and should start automatically upon being given accessibility permission (it will prompt you)"
