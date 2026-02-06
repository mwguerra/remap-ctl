# remap-ctl

A configurable CGEventTap key remapper for macOS, with a CLI for managing mappings.

By default, remaps **Home** to `/` (slash) and **Shift+Home** to `?` — designed for ThinkPad keyboards used via NoMachine remote desktop, where the Home key has no practical use on macOS.

## Why this exists

Tools like Karabiner-Elements, Ukelele, and `hidutil` don't work with NoMachine because it injects key events at the Quartz/CGEvent level, bypassing the HID device driver path. A **CGEventTap** intercepts events at the same level NoMachine injects them, so it can remap keys that other tools miss.

## Quick start

```bash
# Install (compiles, signs, copies to /Applications, creates LaunchAgent)
./remap-ctl.sh install

# Grant Accessibility permission (see instructions printed by install)

# Manage mappings
./remap-ctl.sh set 115 002F --shift 003F --cmd passthrough
./remap-ctl.sh list
./remap-ctl.sh remove 115
```

## CLI: remap-ctl.sh

Requires `jq` (`brew install jq`).

### Commands

| Command | Description |
|---------|-------------|
| `set <keycode> <hex> [--mod <hex>]` | Add or update a key mapping, then restart daemon |
| `remove <keycode>` | Remove a mapping by keycode, then restart daemon |
| `list` | Pretty-print all mappings with key names and Unicode chars |
| `restart` | Restart the daemon (unload + load LaunchAgent) |
| `install` | Full install: compile, bundle, sign, copy to /Applications, create config, load agent |
| `uninstall` | Full teardown: unload agent, remove plist, remove app, remove config, reset TCC |

### Modifier flags

Single modifiers: `--shift`, `--option`, `--ctrl`, `--cmd`

Compound modifiers (alphabetically sorted with `+`): `--cmd+shift`, `--ctrl+option`

Use `passthrough` as the hex value to let the original key through for that modifier combo:

```bash
# Home → /, Shift+Home → ?, Cmd+Home → pass through (normal Cmd+Home behavior)
./remap-ctl.sh set 115 002F --shift 003F --cmd passthrough
```

## Configuration

**File**: `~/.config/remap-ctl/config.json`

```json
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
```

### Schema

- `from` — CGEvent virtual keycode (integer)
- `to` — Default Unicode codepoint (hex string, e.g. `"002F"` for `/`)
- `modifiers` — Optional map of modifier combos to hex codepoints
  - `"passthrough"` — don't remap when this modifier is held
  - Absent modifier combos fall through to the `to` default

If the config file is missing or invalid, the program falls back to the default Home→/ mapping.

## Common keycodes

| Keycode | Key |
|---------|-----|
| 115 | Home |
| 119 | End |
| 116 | Page Up |
| 121 | Page Down |
| 114 | Help/Insert |
| 117 | Forward Delete |
| 51 | Delete (Backspace) |
| 36 | Return |
| 48 | Tab |
| 49 | Space |
| 53 | Escape |
| 122–126 | F1, F2, Arrow keys |

Full list: [Apple Technical Note TN2450](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)

## Common Unicode codepoints

| Hex | Character |
|-----|-----------|
| 002F | `/` |
| 003F | `?` |
| 005C | `\` |
| 007C | `\|` |
| 007E | `~` |
| 0060 | `` ` `` |
| 002D | `-` |
| 003D | `=` |

## How it works

The program creates a `CGEventTap` at `kCGSessionEventTap` that intercepts `keyDown` and `keyUp` events. When it sees a mapped keycode, it sets the Unicode character directly on the event (keyboard-layout-independent), then changes the keycode to a neutral value so the OS processes it as a character key.

Modifier-aware: the callback checks which modifiers are held and looks up the appropriate character (or passthrough) in the mapping table. An `activeRemaps` set tracks which keycodes were remapped on keyDown, so keyUp events are handled correctly even for passthrough cases.

The binary is wrapped in a `.app` bundle because macOS only reliably accepts `.app` bundles for Accessibility permissions.

## Migration from v1 (hardcoded)

If you had the old hardcoded version installed:

1. Run `./remap-ctl.sh install` — this will recompile and reinstall
2. The installer creates a default config with the same Home→/ mapping
3. **Re-grant Accessibility permission** (the binary signature changed):
   - System Settings → Privacy & Security → Accessibility
   - Remove the old RemapCtl entry, then add it again
   - Or run `tccutil reset Accessibility com.guerra.remap-ctl` then re-add

## Troubleshooting

- **"Could not create event tap"**: Grant Accessibility permission. If already listed, remove and re-add it.
- **Permission not sticking**: The code signature changed. Run `tccutil reset Accessibility com.guerra.remap-ctl`, then remove and re-add in System Settings.
- **Check if running**: `launchctl list | grep remap-ctl` — `0` in the second column = running, `1` = crashing.
- **View logs**: `cat /tmp/remap-ctl.log` and `cat /tmp/remap-ctl.err`
- **Wrong characters**: The code sets Unicode directly, so layout shouldn't matter. If wrong, verify config hex values.
- **jq not found**: `brew install jq` (required for CLI, not for the daemon itself)

## Uninstall

```bash
./remap-ctl.sh uninstall
```

This unloads the agent, removes the plist, removes the app from /Applications, deletes the config directory, and resets the TCC permission.
