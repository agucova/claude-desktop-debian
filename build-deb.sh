#!/bin/bash
set -euo pipefail

# Update this URL when a new version of Claude Desktop is released
CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"

# Function to check if we need sudo for a command
need_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "This operation requires sudo privileges. Please enter your password."
        return 0
    fi
    return 1
}

# Function to run a command with sudo if needed
run_with_sudo() {
    if [ "$EUID" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# Check for Debian-based system
if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

# Print system information
echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
for cmd in p7zip wget wrestool icotool convert unzip dpkg-deb; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }p7zip-full"
                ;;
            "wget")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }wget"
                ;;
            "wrestool"|"icotool")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }imagemagick"
                ;;
            "unzip")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }unzip"
                ;;
            "dpkg-deb")
                DEPS_TO_INSTALL="${DEPS_TO_INSTALL:+$DEPS_TO_INSTALL }dpkg-dev"
                ;;
        esac
    fi
done

# Install system dependencies if any
if [ -n "${DEPS_TO_INSTALL:-}" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    if ! run_with_sudo apt-get update; then
        echo "❌ Failed to update package lists"
        exit 1
    fi
    if ! run_with_sudo apt-get install -y $DEPS_TO_INSTALL; then
        echo "❌ Failed to install dependencies"
        exit 1
    fi
    echo "✓ System dependencies installed successfully"
fi

# Install bun if not present
if ! check_command "bun"; then
    echo "Installing bun..."
    # Check for Linuxbrew bun first
    LINUXBREW_BUN="/home/linuxbrew/.linuxbrew/bin/bun"
    if [ -f "$LINUXBREW_BUN" ]; then
        export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
        echo "Using existing bun installation from Linuxbrew"
    else
        # Install for current user
        if ! curl -fsSL https://bun.sh/install | bash; then
            echo "❌ Failed to download/install bun"
            exit 1
        fi
        export PATH="$HOME/.bun/bin:$PATH"
    fi

    if ! check_command "bun"; then
        echo "❌ Failed to install/find bun"
        exit 1
    fi
    echo "✓ Bun installed/found successfully"
fi

# Extract version from the installer filename
# NOTE: Adjust logic as needed if you want to parse from the .exe or nupkg more dynamically
VERSION=$(basename "$CLAUDE_DOWNLOAD_URL" | grep -oP 'Claude-Setup-x64\.exe' | sed 's/Claude-Setup-x64\.exe/0.7.8/')
PACKAGE_NAME="claude-desktop"
ARCHITECTURE="amd64"
MAINTAINER="Agustín Covarrubias <gh@agucova.dev>"
DESCRIPTION="Claude Desktop for Linux (Unofficial)"

# Create working directories in home directory
WORK_DIR="$HOME/.cache/claude-desktop-build"
DEB_ROOT="$WORK_DIR/deb-package"
INSTALL_DIR="$DEB_ROOT/usr"

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$DEB_ROOT/DEBIAN"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# Install electron as a package dependency (using 33.3.1 per the Claude Desktop version)
echo "Installing electron..."
cd "$WORK_DIR"
cat > package.json << EOF
{
  "name": "claude-desktop-runner",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "electron": "^33.3.1"
  }
}
EOF

if ! bun install; then
    echo "❌ Failed to install electron"
    exit 1
fi

# Download Claude Windows installer
echo "📥 Downloading Claude Desktop installer..."
CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
if ! wget --show-progress --progress=bar:force:noscroll -O "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer"
    exit 1
fi
echo "✓ Download complete"

# Extract resources
echo "📦 Extracting resources..."
cd "$WORK_DIR" || exit 1
if ! 7z x -y "$CLAUDE_EXE"; then
    echo "❌ Failed to extract installer"
    exit 1
fi

if ! 7z x -y "AnthropicClaude-$VERSION-full.nupkg"; then
    echo "❌ Failed to extract nupkg"
    exit 1
fi
echo "✓ Resources extracted"

# Extract and convert icons
echo "🎨 Processing icons..."
if ! wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    exit 1
fi
echo "✓ Icons processed"

# Map icon sizes to their corresponding extracted files
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

# Install icons
for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    if [ -f "${icon_files[$size]}" ]; then
        echo "Installing ${size}x${size} icon..."
        if ! install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"; then
            echo "❌ Failed to install ${size}x${size} icon"
            exit 1
        fi
    else
        echo "Warning: Missing ${size}x${size} icon"
    fi
done

# Process app.asar
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd electron-app || exit 1
bunx asar extract app.asar app.asar.contents

# Replace native module with stub implementation
echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << 'EOF'
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
cp ../lib/net45/resources/Tray* app.asar.contents/resources/ || {
    echo "❌ Failed to copy tray icons"
    exit 1
}

# Repackage app.asar
if ! bunx asar pack app.asar.contents app.asar; then
    echo "❌ Failed to repack app.asar"
    exit 1
fi

# Copy app files and electron
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r "$WORK_DIR/node_modules" "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Create desktop entry
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
EOF

# Create launcher script
cat > "$INSTALL_DIR/bin/claude-desktop" << EOF
#!/bin/bash
ELECTRON_ENABLE_LOGGING=true
/usr/lib/claude-desktop/node_modules/.bin/electron \
    --no-sandbox \
    --enable-logging \
    --v=1 \
    /usr/lib/claude-desktop/app.asar "\$@" 2>&1 | tee /tmp/claude-desktop.log
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# Create control file (with improved metadata)
cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Homepage: https://www.anthropic.com/
License: Proprietary
Depends: unzip, p7zip-full
Description: Claude Desktop for Linux (Unofficial)
 Claude is an AI assistant from Anthropic. This package provides the desktop
 interface for using Claude on a Debian-based system via an Electron wrapper.
EOF

# Create postinst script to update icon cache and desktop database
cat > "$DEB_ROOT/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e

if [ -x /usr/bin/update-icon-caches ]; then
  update-icon-caches /usr/share/icons/hicolor || true
elif [ -x /usr/bin/gtk-update-icon-cache ]; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi

if [ -x /usr/bin/update-desktop-database ]; then
  update-desktop-database /usr/share/applications || true
fi

exit 0
EOF
chmod +x "$DEB_ROOT/DEBIAN/postinst"

# Build .deb package
echo "📦 Building .deb package..."
DEB_FILE="$WORK_DIR/claude-desktop_${VERSION}_${ARCHITECTURE}.deb"
if ! run_with_sudo dpkg-deb --build "$DEB_ROOT" "$DEB_FILE"; then
    echo "❌ Failed to build .deb package"
    exit 1
fi

if [ -f "$DEB_FILE" ]; then
    echo "🎉 Package built successfully at: $DEB_FILE"
    echo -n "Would you like to install the package now? [y/N] "
    read -r install_now
    if [[ "$install_now" =~ ^[Yy]$ ]]; then
        if run_with_sudo dpkg -i "$DEB_FILE"; then
            echo "Package installed successfully."
        else
            echo "Package installation failed."
        fi
    else
        echo "You can install it manually with: sudo dpkg -i $DEB_FILE"
    fi
    # Copy the .deb file to the current directory
    cp "$DEB_FILE" .
    echo "The .deb file has been copied to the current directory"
else
    echo "❌ Package file not found at expected location: $DEB_FILE"
    exit 1
fi
