# remap-home-to-slash

Remaps the **Home** key to `/` (slash) and **Shift+Home** to `?` on macOS, using a CGEventTap.

## Why this exists

When using a ThinkPad keyboard via **NoMachine** remote desktop, the Home key has no practical use on macOS. Tools like Karabiner-Elements, Ukelele, and `hidutil` don't work because NoMachine injects key events at the Quartz/CGEvent level, bypassing the HID device driver path those tools intercept.

A **CGEventTap** intercepts events at the Quartz event stream level — the same level NoMachine injects them — so it can remap keys that other tools miss.

## How it works

The program creates a `CGEventTap` at `kCGSessionEventTap` that intercepts `keyDown` and `keyUp` events. When it sees virtual keycode **115** (Home), it sets the Unicode character directly on the event (`/` or `?` depending on Shift). This is keyboard-layout-independent — remapping to a different keycode would produce wrong characters on non-US layouts (e.g. `;` instead of `/` on Brazilian Portuguese).

If macOS disables the tap due to a processing timeout, the callback automatically re-enables it.

The binary is wrapped in a minimal `.app` bundle because macOS Input Monitoring only reliably accepts `.app` bundles — bare command-line binaries are silently rejected by the permission file picker.

## Install

### 1. Compile

```bash
cd ~/projects/remap-home-to-slash
swiftc -O -o remap-home-to-slash remap-home-to-slash.swift
```

### 2. Build the .app bundle

```bash
mkdir -p RemapHomeToSlash.app/Contents/MacOS
cp remap-home-to-slash RemapHomeToSlash.app/Contents/MacOS/
```

The `Info.plist` is already included in the repo at `RemapHomeToSlash.app/Contents/Info.plist`.

### 3. Sign the app bundle

macOS requires code-signed apps for permissions. Ad-hoc sign it:

```bash
codesign -s - -f RemapHomeToSlash.app
```

### 4. Install the app

```bash
sudo cp -R RemapHomeToSlash.app /Applications/
```

### 5. Grant Accessibility permission

The app needs **Accessibility** permission (not Input Monitoring) for CGEventTap to work when launched via `launchd`.

Go to **System Settings → Privacy & Security → Accessibility**, click **+**, navigate to `/Applications`, select **RemapHomeToSlash**, and enable it.

> **Why Accessibility and not Input Monitoring?** When `launchd` spawns the binary, macOS TCC does not associate the process with the `.app` bundle's Input Monitoring entry. Accessibility permission works correctly for `launchd`-spawned processes.

### 6. Create LaunchAgent

```bash
cat > ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.guerra.remap-home-to-slash</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/RemapHomeToSlash.app/Contents/MacOS/remap-home-to-slash</string>
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
EOF
```

### 7. Load

```bash
launchctl load ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist
```

Verify it's running:

```bash
launchctl list | grep remap-home
```

A `0` in the second column means it's running successfully.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist
rm ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist
sudo rm -rf /Applications/RemapHomeToSlash.app
```

Then remove **RemapHomeToSlash** from System Settings → Privacy & Security → Accessibility.

## Updating after recompilation

After recompiling the binary, the code signature changes and macOS invalidates the Accessibility permission. To restore it:

1. Rebuild, sign, and reinstall:
   ```bash
   cd ~/projects/remap-home-to-slash
   swiftc -O -o remap-home-to-slash remap-home-to-slash.swift
   cp remap-home-to-slash RemapHomeToSlash.app/Contents/MacOS/
   codesign -s - -f RemapHomeToSlash.app
   sudo cp -R RemapHomeToSlash.app /Applications/
   ```

2. Reset the TCC permission (so macOS prompts fresh):
   ```bash
   tccutil reset Accessibility com.guerra.remap-home-to-slash
   ```

3. Re-grant Accessibility permission:
   - Go to **System Settings → Privacy & Security → Accessibility**
   - **Remove** RemapHomeToSlash (click `-`), then **add** it again (click `+`)
   - Simply toggling off/on is not enough when the signature changed

4. Restart the agent:
   ```bash
   launchctl unload ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist
   launchctl load ~/Library/LaunchAgents/com.guerra.remap-home-to-slash.plist
   ```

## Troubleshooting

- **"Could not create event tap"**: The app needs Accessibility permission. Check System Settings → Privacy & Security → Accessibility. If it's listed but not working, remove and re-add it.
- **Tap stops working**: macOS disables taps that take too long to process events. The callback re-enables it automatically, but check `/tmp/remap-home-to-slash.err` for errors.
- **Permission not sticking after recompilation**: The code signature changed. Follow the "Updating after recompilation" section above. Use `tccutil reset Accessibility com.guerra.remap-home-to-slash` then remove and re-add in System Settings.
- **Bare binary rejected by permission file picker**: macOS silently ignores command-line binaries. This is why the binary is wrapped in a `.app` bundle.
- **Check if running**: `launchctl list | grep remap-home` — a `0` in the second column means it's running; `1` means it's crashing (likely a permission issue).
- **View logs**: `cat /tmp/remap-home-to-slash.log` and `cat /tmp/remap-home-to-slash.err`.
- **Wrong characters (e.g. `;` instead of `/`)**: The code uses Unicode characters directly, not keycodes, so this should not happen. If it does, check that you're running the latest compiled version.
