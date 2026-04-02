#!/bin/bash
# Remove all signal-bridge components
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo ""
echo "This will remove signal-bridge and all its data."
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
echo ""

# Stop and disable services
info "Stopping services..."
systemctl --user disable --now signal-listen.service 2>/dev/null || true
systemctl --user disable --now signal-daemon.service 2>/dev/null || true

# Remove service files
info "Removing service files..."
rm -f "$HOME/.config/systemd/user/signal-daemon.service"
rm -f "$HOME/.config/systemd/user/signal-listen.service"
systemctl --user daemon-reload

# Remove symlinks
info "Removing symlinks..."
rm -f "$HOME/.local/bin/signal-send"
rm -f "$HOME/.local/bin/signal-read"
rm -f "$HOME/.local/bin/signal-listen"
rm -f "$HOME/.local/bin/signal-cli"

# Remove downloaded binary from repo
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
info "Removing signal-cli binary..."
rm -rf "$SCRIPT_DIR/bin"

# Remove config
info "Removing config..."
rm -rf "$HOME/.config/signal-bridge"

# Remove data and logs
info "Removing Signal data and logs..."
rm -rf "$HOME/.local/share/signal-cli"
rm -rf "$HOME/.local/share/signal-bridge"

echo ""
info "Fully removed. No traces remain."
