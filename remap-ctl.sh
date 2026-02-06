#!/usr/bin/env bash
set -euo pipefail

# remap-ctl.sh — CLI management for remap-home-to-slash
# Manages config, compilation, installation, and the LaunchAgent daemon.

BUNDLE_ID="com.guerra.remap-home-to-slash"
APP_NAME="RemapHomeToSlash"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_BUNDLE}"
PLIST_PATH="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
CONFIG_DIR="$HOME/.config/remap-home-to-slash"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Common keycode names for pretty-printing (Bash 3.2 compatible)
keycode_name() {
    local kc="$1"
    case "$kc" in
        0) echo "A" ;; 1) echo "S" ;; 2) echo "D" ;; 3) echo "F" ;;
        4) echo "H" ;; 5) echo "G" ;; 6) echo "Z" ;; 7) echo "X" ;;
        8) echo "C" ;; 9) echo "V" ;; 11) echo "B" ;; 12) echo "Q" ;;
        13) echo "W" ;; 14) echo "E" ;; 15) echo "R" ;; 16) echo "Y" ;;
        17) echo "T" ;; 18) echo "1" ;; 19) echo "2" ;; 20) echo "3" ;;
        21) echo "4" ;; 22) echo "6" ;; 23) echo "5" ;; 24) echo "=" ;;
        25) echo "9" ;; 26) echo "7" ;; 27) echo "-" ;; 28) echo "8" ;;
        29) echo "0" ;; 30) echo "]" ;; 31) echo "O" ;; 32) echo "U" ;;
        33) echo "[" ;; 34) echo "I" ;; 35) echo "P" ;; 36) echo "Return" ;;
        37) echo "L" ;; 38) echo "J" ;; 39) echo "'" ;; 40) echo "K" ;;
        41) echo ";" ;; 42) echo "\\" ;; 43) echo "," ;; 44) echo "/" ;;
        45) echo "N" ;; 46) echo "M" ;; 47) echo "." ;; 48) echo "Tab" ;;
        49) echo "Space" ;; 50) echo "\`" ;; 51) echo "Delete" ;;
        53) echo "Escape" ;; 96) echo "F5" ;; 97) echo "F6" ;;
        98) echo "F7" ;; 99) echo "F3" ;; 100) echo "F8" ;; 101) echo "F9" ;;
        103) echo "F11" ;; 105) echo "F13" ;; 107) echo "F14" ;;
        109) echo "F10" ;; 111) echo "F12" ;; 113) echo "F15" ;;
        114) echo "Help/Insert" ;; 115) echo "Home" ;; 116) echo "PageUp" ;;
        117) echo "ForwardDelete" ;; 118) echo "F4" ;; 119) echo "End" ;;
        120) echo "F2" ;; 121) echo "PageDown" ;; 122) echo "F1" ;;
        123) echo "LeftArrow" ;; 124) echo "RightArrow" ;;
        125) echo "DownArrow" ;; 126) echo "UpArrow" ;;
        *) echo "keycode $kc" ;;
    esac
}

# --- Helpers ---

require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed."
        echo "Install it with: brew install jq"
        exit 1
    fi
}

ensure_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$CONFIG_DIR"
        echo '{"mappings":[]}' > "$CONFIG_FILE"
    fi
}

hex_to_char() {
    local hex="$1"
    local dec=$((16#$hex))
    if (( dec >= 32 && dec < 127 )); then
        printf "\\$(printf '%03o' "$dec")"
    else
        echo "U+${hex}"
    fi
}

daemon_is_loaded() {
    launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"
}

# --- Commands ---

cmd_set() {
    require_jq

    local keycode="" hex="" modifiers=()

    if [[ $# -lt 2 ]]; then
        echo "Usage: remap-ctl set <keycode> <hex> [--shift <hex>] [--option <hex>] [--ctrl <hex>] [--cmd <hex>] [--<combo> <hex>]"
        echo "Use 'passthrough' as hex value to skip remapping for that modifier."
        exit 1
    fi

    keycode="$1"; shift
    hex="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*)
                local mod="${1#--}"
                if [[ $# -lt 2 ]]; then
                    echo "Error: missing value for $1"
                    exit 1
                fi
                modifiers+=("$mod" "$2")
                shift 2
                ;;
            *)
                echo "Error: unexpected argument '$1'"
                exit 1
                ;;
        esac
    done

    ensure_config

    # Build modifier object
    local mod_json="{}"
    for (( i=0; i<${#modifiers[@]}; i+=2 )); do
        local mk="${modifiers[$i]}"
        local mv="${modifiers[$i+1]}"
        mod_json=$(echo "$mod_json" | jq --arg k "$mk" --arg v "$mv" '. + {($k): $v}')
    done

    # Build the new mapping entry
    local new_entry
    new_entry=$(jq -n --argjson from "$keycode" --arg to "$hex" --argjson mods "$mod_json" \
        '{from: $from, to: $to, modifiers: $mods}')

    # Remove existing mapping for this keycode, then add the new one
    local updated
    updated=$(jq --argjson kc "$keycode" --argjson entry "$new_entry" \
        '.mappings = [.mappings[] | select(.from == $kc | not)] + [$entry]' "$CONFIG_FILE")

    echo "$updated" > "$CONFIG_FILE"

    local name
    name=$(keycode_name "$keycode")
    local char
    char=$(hex_to_char "$hex")
    echo "Set: $name (keycode $keycode) → $char (U+$hex)"

    for (( i=0; i<${#modifiers[@]}; i+=2 )); do
        local mk="${modifiers[$i]}"
        local mv="${modifiers[$i+1]}"
        if [[ "$mv" == "passthrough" ]]; then
            echo "  $mk → passthrough"
        else
            local mc
            mc=$(hex_to_char "$mv")
            echo "  $mk → $mc (U+$mv)"
        fi
    done

    cmd_restart
}

cmd_remove() {
    require_jq

    if [[ $# -lt 1 ]]; then
        echo "Usage: remap-ctl remove <keycode>"
        exit 1
    fi

    local keycode="$1"
    ensure_config

    local count
    count=$(jq --argjson kc "$keycode" '[.mappings[] | select(.from == $kc)] | length' "$CONFIG_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "No mapping found for keycode $keycode."
        exit 1
    fi

    local updated
    updated=$(jq --argjson kc "$keycode" '.mappings = [.mappings[] | select(.from == $kc | not)]' "$CONFIG_FILE")
    echo "$updated" > "$CONFIG_FILE"

    local name
    name=$(keycode_name "$keycode")
    echo "Removed mapping for $name (keycode $keycode)."

    cmd_restart
}

cmd_list() {
    require_jq
    ensure_config

    local count
    count=$(jq '.mappings | length' "$CONFIG_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "No mappings configured."
        echo "Config: $CONFIG_FILE"
        return
    fi

    echo "Key mappings ($CONFIG_FILE):"
    echo ""

    jq -r '.mappings[] | "\(.from)\t\(.to)\t\(.modifiers // {} | to_entries | map("\(.key)=\(.value)") | join(","))"' "$CONFIG_FILE" | \
    while IFS=$'\t' read -r from to mods; do
        local name
        name=$(keycode_name "$from")
        local char
        char=$(hex_to_char "$to")
        printf "  %-20s → %s (U+%s)\n" "$name (keycode $from)" "$char" "$to"

        if [[ -n "$mods" ]]; then
            IFS=',' read -ra mod_pairs <<< "$mods"
            for pair in "${mod_pairs[@]}"; do
                local mk="${pair%%=*}"
                local mv="${pair#*=}"
                if [[ "$mv" == "passthrough" ]]; then
                    printf "    %-18s → passthrough\n" "$mk"
                else
                    local mc
                    mc=$(hex_to_char "$mv")
                    printf "    %-18s → %s (U+%s)\n" "$mk" "$mc" "$mv"
                fi
            done
        fi
    done

    echo ""
    if daemon_is_loaded; then
        echo "Daemon: running"
    else
        echo "Daemon: not loaded"
    fi
}

cmd_restart() {
    echo "Restarting daemon..."

    if daemon_is_loaded; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    if [[ ! -f "$PLIST_PATH" ]]; then
        echo "LaunchAgent plist not found at $PLIST_PATH"
        echo "Run 'remap-ctl install' first."
        exit 1
    fi

    launchctl load "$PLIST_PATH"

    # Brief wait to check status
    sleep 0.5
    if daemon_is_loaded; then
        echo "Daemon restarted successfully."
    else
        echo "Warning: daemon may not have started. Check /tmp/remap-home-to-slash.err for errors."
    fi
}

cmd_install() {
    require_jq

    echo "=== remap-home-to-slash installer ==="
    echo ""

    # Step 1: Compile
    echo "[1/6] Compiling..."
    cd "$SCRIPT_DIR"
    swiftc -O -o remap-home-to-slash remap-home-to-slash.swift
    echo "  Compiled successfully."

    # Step 2: Build .app bundle
    echo "[2/6] Building .app bundle..."
    mkdir -p "${APP_BUNDLE}/Contents/MacOS"
    cp remap-home-to-slash "${APP_BUNDLE}/Contents/MacOS/"
    echo "  Bundle ready."

    # Step 3: Sign
    echo "[3/6] Code signing..."
    codesign -s - -f "$APP_BUNDLE" 2>/dev/null
    echo "  Signed."

    # Step 4: Install to /Applications
    echo "[4/6] Installing to /Applications..."
    echo "  This requires sudo. You will be prompted for your password."
    sudo cp -R "$APP_BUNDLE" /Applications/
    echo "  Installed to $INSTALL_PATH"

    # Step 5: Create default config
    echo "[5/6] Creating default config..."
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << 'CONFIGEOF'
{
  "mappings": [
    {
      "from": 115,
      "to": "002F",
      "modifiers": {
        "shift": "003F",
        "cmd": "passthrough"
      }
    }
  ]
}
CONFIGEOF
        echo "  Created $CONFIG_FILE with default Home→/ mapping."
    else
        echo "  Config already exists at $CONFIG_FILE, keeping it."
    fi

    # Step 6: Create and load LaunchAgent
    echo "[6/6] Setting up LaunchAgent..."
    cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}/Contents/MacOS/remap-home-to-slash</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/remap-home-to-slash.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/remap-home-to-slash.err</string>
</dict>
</plist>
PLISTEOF

    if daemon_is_loaded; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi
    launchctl load "$PLIST_PATH"
    echo "  LaunchAgent loaded."

    echo ""
    echo "=== Installation complete ==="
    echo ""
    echo "IMPORTANT: Grant Accessibility permission to the app:"
    echo "  1. Open System Settings → Privacy & Security → Accessibility"
    echo "  2. Click + and navigate to /Applications"
    echo "  3. Select RemapHomeToSlash and enable it"
    echo ""
    echo "If you previously had the app installed, you may need to:"
    echo "  1. Remove the old entry from Accessibility"
    echo "  2. Run: tccutil reset Accessibility $BUNDLE_ID"
    echo "  3. Add it again"
    echo ""
    echo "Verify it's running: launchctl list | grep remap-home"
    echo "View logs: cat /tmp/remap-home-to-slash.log"
}

cmd_uninstall() {
    echo "=== remap-home-to-slash uninstaller ==="
    echo ""

    # Step 1: Unload agent
    echo "[1/5] Unloading LaunchAgent..."
    if daemon_is_loaded; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        echo "  Unloaded."
    else
        echo "  Not loaded, skipping."
    fi

    # Step 2: Remove plist
    echo "[2/5] Removing LaunchAgent plist..."
    if [[ -f "$PLIST_PATH" ]]; then
        rm "$PLIST_PATH"
        echo "  Removed $PLIST_PATH"
    else
        echo "  Not found, skipping."
    fi

    # Step 3: Remove app from /Applications
    echo "[3/5] Removing app from /Applications..."
    if [[ -d "$INSTALL_PATH" ]]; then
        echo "  This requires sudo. You will be prompted for your password."
        sudo rm -rf "$INSTALL_PATH"
        echo "  Removed $INSTALL_PATH"
    else
        echo "  Not found, skipping."
    fi

    # Step 4: Remove config
    echo "[4/5] Removing config directory..."
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        echo "  Removed $CONFIG_DIR"
    else
        echo "  Not found, skipping."
    fi

    # Step 5: Reset TCC
    echo "[5/5] Resetting Accessibility permission..."
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    echo "  TCC reset for $BUNDLE_ID"

    echo ""
    echo "=== Uninstall complete ==="
    echo "Log files at /tmp/remap-home-to-slash.{log,err} were left in place."
}

# --- Main ---

cmd="${1:-}"
shift || true

case "$cmd" in
    set)        cmd_set "$@" ;;
    remove)     cmd_remove "$@" ;;
    list)       cmd_list ;;
    restart)    cmd_restart ;;
    install)    cmd_install ;;
    uninstall)  cmd_uninstall ;;
    *)
        echo "remap-ctl — manage remap-home-to-slash key remapper"
        echo ""
        echo "Usage:"
        echo "  remap-ctl set <keycode> <hex> [--shift <hex>] [--option <hex>] [--cmd <hex>]"
        echo "  remap-ctl remove <keycode>"
        echo "  remap-ctl list"
        echo "  remap-ctl restart"
        echo "  remap-ctl install"
        echo "  remap-ctl uninstall"
        echo ""
        echo "Examples:"
        echo "  remap-ctl set 115 002F --shift 003F --cmd passthrough"
        echo "  remap-ctl remove 115"
        echo "  remap-ctl list"
        echo ""
        echo "Modifier flags: --shift, --option, --ctrl, --cmd"
        echo "Compound modifiers: --cmd+shift, --ctrl+option (alphabetically sorted)"
        echo "Use 'passthrough' to let the original key through for a modifier combo."
        exit 1
        ;;
esac
