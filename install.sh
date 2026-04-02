#!/bin/bash
# Signal Bridge — interactive installer
# Downloads signal-cli into the repo, registers, configures, starts services.
# Everything runs from the repo directory — no files copied elsewhere.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$REPO_DIR/bin"
CONFIG_DIR="$HOME/.config/signal-bridge"
LOG_DIR="$HOME/.local/share/signal-bridge"
SERVICE_DIR="$HOME/.config/systemd/user"
LINK_DIR="$HOME/.local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

echo ""
echo "=== Signal Bridge Installer ==="
echo ""

# Check dependencies
command -v curl >/dev/null || error "curl is required but not installed"
command -v jq >/dev/null || error "jq is required but not installed"
command -v python3 >/dev/null || error "python3 is required but not installed"
info "Dependencies OK (curl, jq, python3)"

# Create directories
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$SERVICE_DIR" "$LINK_DIR"

# Check if already installed
if [ -f "$CONFIG_DIR/config" ]; then
    warn "Existing config found at $CONFIG_DIR/config"
    read -rp "Reinstall? This will re-register. (yes/no): " REINSTALL
    [ "$REINSTALL" = "yes" ] || { echo "Aborted."; exit 0; }
    systemctl --user stop signal-listen.service 2>/dev/null || true
    systemctl --user stop signal-daemon.service 2>/dev/null || true
fi

# Download signal-cli into repo's bin/ directory
info "Fetching latest signal-cli release..."
LATEST=$(curl -sf https://api.github.com/repos/AsamK/signal-cli/releases/latest | jq -r '.tag_name' | sed 's/^v//')
[ -z "$LATEST" ] || [ "$LATEST" = "null" ] && error "Could not determine latest version. Check network."
info "Latest version: $LATEST"

NATIVE_URL="https://github.com/AsamK/signal-cli/releases/download/v${LATEST}/signal-cli-${LATEST}-Linux-native.tar.gz"
JAVA_URL="https://github.com/AsamK/signal-cli/releases/download/v${LATEST}/signal-cli-${LATEST}.tar.gz"
SIGNAL_CLI="$BIN_DIR/signal-cli"

if curl -sfL --head "$NATIVE_URL" >/dev/null 2>&1; then
    info "Downloading native binary (no Java required)..."
    TMP=$(mktemp -d)
    curl -sfL "$NATIVE_URL" | tar xz -C "$TMP"
    cp "$TMP"/signal-cli "$SIGNAL_CLI" 2>/dev/null || cp "$TMP"/signal-cli*/bin/signal-cli "$SIGNAL_CLI" 2>/dev/null || error "Could not find signal-cli in download"
    rm -rf "$TMP"
    info "Native binary downloaded"
elif command -v java >/dev/null; then
    JAVA_VER=$(java -version 2>&1 | head -1 | grep -oP '\d+' | head -1)
    [ "$JAVA_VER" -ge 21 ] 2>/dev/null || error "Java 21+ required, found Java $JAVA_VER"
    info "No native binary available. Downloading Java version..."
    TMP=$(mktemp -d)
    curl -sfL "$JAVA_URL" | tar xz -C "$TMP"
    EXTRACTED=$(ls -d "$TMP"/signal-cli*/ 2>/dev/null | head -1)
    [ -n "$EXTRACTED" ] || error "Could not find signal-cli in download"
    cp "$EXTRACTED/bin/signal-cli" "$SIGNAL_CLI"
    rm -rf "$TMP"
    info "Java version downloaded"
else
    error "No native binary available and Java not found. Install Java 21+ or try again later."
fi

chmod +x "$SIGNAL_CLI"

# Verify binary works
"$SIGNAL_CLI" --version || error "signal-cli binary failed to run"
echo ""

# Register phone number
read -rp "Enter your phone number with country code (e.g., +12125551234): " SIGNAL_NUMBER
[ -z "$SIGNAL_NUMBER" ] && error "Phone number is required"

echo ""
echo "How should Signal send the verification code?"
echo "  1) SMS (default for regular phone numbers)"
echo "  2) Voice call (recommended for Google Voice / VoIP numbers)"
read -rp "Choice [1/2]: " VERIFY_METHOD
VOICE_FLAG=""
[ "$VERIFY_METHOD" = "2" ] && VOICE_FLAG="--voice"

info "Registering $SIGNAL_NUMBER with Signal..."
echo ""

REG_OUTPUT=$("$SIGNAL_CLI" -a "$SIGNAL_NUMBER" register $VOICE_FLAG 2>&1) || {
    if echo "$REG_OUTPUT" | grep -qi "captcha"; then
        warn "Signal requires a captcha verification."
        echo ""
        echo "  1. Open this URL in a browser:"
        echo "     https://signalcaptchas.org/registration/generate.html"
        echo ""
        echo "  2. Complete the captcha"
        echo "  3. Right-click 'Open Signal' and copy the link"
        echo "     It starts with: signalcaptcha://"
        echo ""
        read -rp "Paste the captcha URL here: " CAPTCHA_URL
        CAPTCHA_TOKEN="${CAPTCHA_URL#signalcaptcha://}"
        CAPTCHA_TOKEN="${CAPTCHA_TOKEN#signal-captcha://}"
        "$SIGNAL_CLI" -a "$SIGNAL_NUMBER" register $VOICE_FLAG --captcha "$CAPTCHA_TOKEN" || error "Registration failed"
    else
        echo "$REG_OUTPUT"
        error "Registration failed"
    fi
}

echo ""
read -rp "Enter the verification code: " VERIFY_CODE
[ -z "$VERIFY_CODE" ] && error "Verification code is required"
"$SIGNAL_CLI" -a "$SIGNAL_NUMBER" verify "$VERIFY_CODE" || error "Verification failed"
info "Registration complete!"
echo ""

# Configure allowed senders — phone number used temporarily until UUID is discovered
echo "Who can send you messages through this bridge?"
echo "(Your main phone number — used only for initial setup, then auto-replaced with UUID)"
read -rp "Your phone number (e.g., +12125559999): " OWNER_NUMBER
[ -z "$OWNER_NUMBER" ] && error "Phone number is required"

# Write config — phone number is temporary, replaced by UUID after first message
cat > "$CONFIG_DIR/config" <<EOF
SIGNAL_NUMBER="$SIGNAL_NUMBER"
OWNER_UUID="pending"
SEND_TO="$OWNER_NUMBER"
HTTP_PORT="8080"
TCP_PORT="7583"
LOG_FILE="$LOG_DIR/messages.log"
ALLOWED_SENDERS="$OWNER_NUMBER"
BOOTSTRAP_NUMBER="$OWNER_NUMBER"
REPO_DIR="$REPO_DIR"
EOF
chmod 600 "$CONFIG_DIR/config"
info "Config written to $CONFIG_DIR/config (phone number is temporary — will be replaced with UUID)"

# Symlink scripts into PATH (points back to repo)
ln -sf "$REPO_DIR/signal-send" "$LINK_DIR/signal-send"
ln -sf "$REPO_DIR/signal-read" "$LINK_DIR/signal-read"
ln -sf "$REPO_DIR/signal-listen" "$LINK_DIR/signal-listen"
ln -sf "$SIGNAL_CLI" "$LINK_DIR/signal-cli"
info "Symlinks created in $LINK_DIR/ → repo"

# Generate systemd services with correct repo path
cat > "$SERVICE_DIR/signal-daemon.service" <<EOF
[Unit]
Description=Signal CLI daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
EnvironmentFile=%h/.config/signal-bridge/config
ExecStart=$SIGNAL_CLI -a \${SIGNAL_NUMBER} daemon \\
    --http localhost:\${HTTP_PORT} \\
    --tcp localhost:\${TCP_PORT} \\
    --receive-mode=on-connection \\
    --no-receive-stdout
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

cat > "$SERVICE_DIR/signal-listen.service" <<EOF
[Unit]
Description=Signal message listener
After=signal-daemon.service
Requires=signal-daemon.service

[Service]
ExecStart=$REPO_DIR/signal-listen
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
info "Starting daemon..."
systemctl --user enable --now signal-daemon.service
sleep 3
info "Starting listener..."
systemctl --user enable --now signal-listen.service
sleep 1

# Verify
if systemctl --user is-active --quiet signal-daemon.service; then
    info "Daemon running"
else
    warn "Daemon may still be starting. Check: systemctl --user status signal-daemon"
fi

if systemctl --user is-active --quiet signal-listen.service; then
    info "Listener running"
else
    warn "Listener may still be starting. Check: systemctl --user status signal-listen"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Send a message:   signal-send 'hello from the terminal'"
echo "  Read messages:     signal-read"
echo "  Wait for reply:    signal-read --wait"
echo "  Stop temporarily:  systemctl --user stop signal-daemon signal-listen"
echo "  Start again:       systemctl --user start signal-daemon signal-listen"
echo "  Remove everything: ./uninstall.sh"
echo ""
