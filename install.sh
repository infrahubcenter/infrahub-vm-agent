#!/usr/bin/env bash
#
# Native (non-Docker) install of the Infra Hub Center VM Agent as a
# systemd service. The alternative to the `docker run` command the console
# generates, for hosts that don't run Docker.
#
# Works on apt (Ubuntu, Debian), dnf (RHEL 8/9, Rocky, AlmaLinux, Fedora,
# Amazon Linux 2023), yum (CentOS 7, Amazon Linux 2) and zypper (SLES,
# openSUSE). On x86_64 it downloads the prebuilt release binary (built
# against glibc 2.28, runs on CentOS 7 and newer); on other CPUs, or with
# --from-source, it installs gcc/pkg-config/libsystemd headers and Go and
# builds the agent from this directory. Either way it installs:
#   /usr/local/bin/infrahub-vm-agent
#   /etc/infrahub/vm-agent.env          (backend URL + token, mode 0600)
#   /etc/systemd/system/infrahub-vm-agent.service
#
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/infrahubcenter/infrahub-vm-agent/main/install.sh \
#     | sudo bash -s -- --backend-url <INFRAHUB_BACKEND_URL> --token <INFRAHUB_AGENT_TOKEN>
#   sudo ./install.sh --backend-url <URL> --token <TOKEN> [--interval 15] [--from-source]
#   sudo ./install.sh --uninstall
#
# Take the backend URL and token from the console's VM Agent install
# command (the -e INFRAHUB_BACKEND_URL=... and -e INFRAHUB_AGENT_TOKEN=...
# values) -- the same token works for either install method.

set -euo pipefail

BIN_PATH=/usr/local/bin/infrahub-vm-agent
ENV_DIR=/etc/infrahub
ENV_FILE=$ENV_DIR/vm-agent.env
UNIT_FILE=/etc/systemd/system/infrahub-vm-agent.service
GO_VERSION=${GO_VERSION:-1.26.0}
RELEASE_URL=${INFRAHUB_AGENT_RELEASE_URL:-https://github.com/infrahubcenter/infrahub-vm-agent/releases/latest/download}

BACKEND_URL=""
TOKEN=""
INTERVAL=15
UNINSTALL=0
FROM_SOURCE=0

usage() {
    sed -n '17,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backend-url) BACKEND_URL="${2:-}"; shift 2 ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --from-source) FROM_SOURCE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run as root (sudo ./install.sh ...)."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required for the native install. Use the Docker install command instead."
    exit 1
fi

if [ "$UNINSTALL" -eq 1 ]; then
    systemctl disable --now infrahub-vm-agent 2>/dev/null || true
    rm -f "$UNIT_FILE" "$BIN_PATH" "$ENV_FILE"
    rmdir "$ENV_DIR" 2>/dev/null || true
    systemctl daemon-reload
    echo "Infra Hub Center VM Agent removed."
    exit 0
fi

if [ -z "$BACKEND_URL" ] || [ -z "$TOKEN" ]; then
    echo "Error: --backend-url and --token are both required."
    usage
fi
case "$INTERVAL" in
    ''|*[!0-9]*) echo "Error: --interval must be a whole number of seconds."; exit 1 ;;
esac

# Piped through `curl | bash`, $0 is "bash" -- there's no source directory.
SCRIPT_DIR=""
case "$0" in
    */*) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac

if [ "$FROM_SOURCE" -eq 0 ] && [ "$(uname -m)" != "x86_64" ]; then
    echo "==> No prebuilt binary for $(uname -m); building from source"
    FROM_SOURCE=1
fi
if [ "$FROM_SOURCE" -eq 1 ] && { [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/main.go" ]; }; then
    echo "Error: building from source needs the agent source -- run this script from a checkout:"
    echo "  git clone https://github.com/infrahubcenter/infrahub-vm-agent.git && cd infrahub-vm-agent"
    exit 1
fi

# --- Packages, per package manager ---
# curl only when missing: RHEL-family minimal images ship curl-minimal,
# which conflicts with installing the full curl package.
EXTRA=""
command -v curl >/dev/null 2>&1 || EXTRA="curl"
if [ "$FROM_SOURCE" -eq 1 ]; then
    echo "==> Installing build dependencies"
    APT_PKGS="gcc libc6-dev pkg-config libsystemd-dev ca-certificates tar gzip"
    DNF_PKGS="gcc glibc-devel pkgconf-pkg-config systemd-devel ca-certificates tar gzip"
    YUM_PKGS="gcc glibc-devel pkgconfig systemd-devel ca-certificates tar gzip"
    ZYP_PKGS="gcc glibc-devel pkg-config systemd-devel ca-certificates tar gzip"
else
    APT_PKGS="ca-certificates"; DNF_PKGS="ca-certificates"; YUM_PKGS="ca-certificates"; ZYP_PKGS="ca-certificates"
fi
if [ "$FROM_SOURCE" -eq 0 ] && [ -z "$EXTRA" ]; then
    # Download mode with curl already present: nothing to install. This
    # also keeps end-of-life distros (CentOS 7, whose mirrors are gone)
    # working, since the package manager is never touched.
    :
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends $APT_PKGS $EXTRA
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $DNF_PKGS $EXTRA
elif command -v yum >/dev/null 2>&1; then
    yum install -y $YUM_PKGS $EXTRA
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive --gpg-auto-import-keys install $ZYP_PKGS $EXTRA
else
    echo "Error: no supported package manager found (apt-get, dnf, yum, zypper)."
    exit 1
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

if [ "$FROM_SOURCE" -eq 0 ]; then
    echo "==> Downloading infrahub-vm-agent"
    curl -fsSL "$RELEASE_URL/infrahub-linux-os-agent-amd64" -o "$BUILD_DIR/infrahub-vm-agent"
else
    # --- Go toolchain: use an existing go >= 1.21 (it fetches the exact
    # toolchain go.mod requires via GOTOOLCHAIN=auto), else install one ---
    GO_BIN=""
    if command -v go >/dev/null 2>&1; then
        minor=$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')
        if [ "${minor:-0}" -ge 21 ] 2>/dev/null; then GO_BIN=$(command -v go); fi
    fi
    if [ -z "$GO_BIN" ]; then
        case "$(uname -m)" in
            x86_64) GOARCH=amd64 ;;
            aarch64|arm64) GOARCH=arm64 ;;
            *) echo "Error: unsupported CPU architecture $(uname -m)."; exit 1 ;;
        esac
        echo "==> Installing Go $GO_VERSION to /usr/local/go"
        curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tgz
        rm -f /tmp/go.tgz
        GO_BIN=/usr/local/go/bin/go
    fi

    echo "==> Building infrahub-vm-agent"
    (cd "$SCRIPT_DIR" && CGO_ENABLED=1 GOTOOLCHAIN=auto GOPATH="$BUILD_DIR/gopath" GOCACHE="$BUILD_DIR/cache" \
        "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$BUILD_DIR/infrahub-vm-agent" .)
fi
install -m 0755 "$BUILD_DIR/infrahub-vm-agent" "$BIN_PATH"

echo "==> Writing $ENV_FILE"
install -d -m 0700 "$ENV_DIR"
umask 077
cat > "$ENV_FILE" <<EOF
INFRAHUB_BACKEND_URL=$BACKEND_URL
INFRAHUB_AGENT_TOKEN=$TOKEN
INFRAHUB_METRICS_INTERVAL=$INTERVAL
EOF
chmod 0600 "$ENV_FILE"

echo "==> Installing systemd unit"
install -d /etc/systemd/system
# Runs as root for the same reason the container does: it reads host-
# owned logs whose ownership varies by distro (/var/log/messages is
# root-only on RHEL). Everything else is locked down read-only.
cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=Infra Hub Center VM Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/infrahub/vm-agent.env
ExecStart=/usr/local/bin/infrahub-vm-agent
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable infrahub-vm-agent >/dev/null
systemctl restart infrahub-vm-agent

sleep 2
if systemctl is-active --quiet infrahub-vm-agent; then
    echo "Infra Hub Center VM Agent is running. Logs: journalctl -u infrahub-vm-agent -f"
else
    echo "The agent did not start. Check: journalctl -u infrahub-vm-agent -n 50"
    exit 1
fi
