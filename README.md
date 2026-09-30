# enable-hidpi-external-display

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/itsdezen)

Simulate HiDPI ("Retina") scaling on external displays that don't natively
report a HiDPI mode to macOS — with a "Looks like" resolution picker in
System Settings ▸ Displays, just like a real Retina panel.

Requires **macOS 26 (Tahoe) or later**. Older releases are not supported.

## Install

**Local** — clone the repo and double-click `enable-hidpi-external-display.command`, or run it
from a terminal:

```bash
git clone https://github.com/itsdezen/enable-hidpi-external-display.git
cd enable-hidpi-external-display
./enable-hidpi-external-display.sh
```

**Remote** — run directly without cloning:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/itsdezen/enable-hidpi-external-display/main/enable-hidpi-external-display.sh)"
```

## Usage

Run the script and follow the prompts:

1. **Enable HiDPI** — pick the external display, then choose how to derive
   the "Looks like" resolutions:
   - **Auto** — enable-hidpi-external-display reads the panel's native resolution
     and generates the same spread of scale steps macOS computes for a real
     Retina display ("Larger Text" down to "More Space"), all locked to the
     display's real aspect ratio.
   - **Manual** — type your own list of resolutions if you want full
     control.
2. **Disable HiDPI** — remove one display's override, or reset everything
   back to the macOS default.

Reboot after enabling or disabling for the change to take effect.

## Safety

- Only writes under `/Library/Displays/Contents/Resources/Overrides` — never
  touches `/System`, never requires disabling SIP, never installs a kernel
  extension.
- The built-in display is detected and excluded before any display list is
  ever shown — it cannot be selected, and nothing in this tool can write to
  its profile. Always double-check the display name printed before
  confirming, especially on unfamiliar hardware.
- Everything is reversible: use the in-app "Disable HiDPI" option, or delete
  `/Library/Displays/Contents/Resources/Overrides` entirely.
- If a change ever leaves a display unusable, boot into macOS Recovery,
  mount the "Macintosh HD - Data" volume in Disk Utility, then in Terminal run
  the helper generated at `~/.enable-hidpi-external-display-disable`:
  `bash "/Volumes/Macintosh HD - Data/Users/<you>/.enable-hidpi-external-display-disable"`
  (or manually delete the folder above from that Data volume).

## The EDID compatibility patch

Some monitors drop to a lower resolution after sleep/wake when using a
plain override. enable-hidpi-external-display can optionally patch a couple of feature-flag
bytes in the display's own EDID (embedded only in its override file — your
monitor's actual firmware is never touched) to work around this. It's only
offered on Intel Macs, since Apple Silicon has no real EDID to read in the
first place.

## License

MIT — see [LICENSE](LICENSE).
