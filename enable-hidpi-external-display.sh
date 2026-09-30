#!/bin/bash
#
# enable-hidpi-external-display — enable simulated HiDPI ("Retina") scaling on external displays
# that don't natively report a HiDPI mode to macOS.
#
# Requires macOS 26 (Tahoe) or later. No backward compatibility is provided
# for earlier releases.

set -u

OVERRIDES_DIR="/Library/Displays/Contents/Resources/Overrides"
SYS_OVERRIDES_DIR="/System/Library/Displays/Contents/Resources/Overrides"
SYS_ICONS_PLIST="${SYS_OVERRIDES_DIR}/Icons.plist"
UNINSTALL_SCRIPT="${HOME}/.enable-hidpi-external-display-disable"
PLISTBUDDY="/usr/libexec/PlistBuddy"

WORKDIR=""
SUDO_KEEPALIVE_PID=""
DRY_RUN=""

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_PURPLE=$'\033[35m'
    C_BLUE=$'\033[34m'
    TTY=1
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_PURPLE=""; C_BLUE=""
    TTY=""
fi

print_banner() {
    printf "%s\n" "${C_CYAN}${C_BOLD}"
    printf "%s\n" "┌─────────────────────────────────┐"
    printf "%s\n" "│  enable-hidpi-external-display  │"
    printf "%s\n" "└─────────────────────────────────┘${C_RESET}"
    printf "\n"
}

log_info() { printf "%s\n" "${C_DIM}  $*${C_RESET}"; }
log_ok()   { printf "%s\n" "${C_GREEN}  ✓ $*${C_RESET}"; }
log_warn() { printf "%s\n" "${C_YELLOW}  ! $*${C_RESET}"; }
log_err()  { printf "%s\n" "${C_RED}  ✗ $*${C_RESET}" >&2; }
section()  { printf "\n%s\n\n" "${C_PURPLE}${C_BOLD}➤ $*${C_RESET}"; }
prompt()   { printf "%s" "${C_YELLOW}› $*${C_RESET}"; }

die() {
    spin_stop
    log_err "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Spinner — used around slow, non-interactive steps (display scans, sudo
# install/remove). Falls back to a plain log_info line on non-tty output.
# ---------------------------------------------------------------------------

SPIN_PID=""

spin() {
    if [[ -z "$TTY" ]]; then
        log_info "$1"
        return
    fi
    local msg="$1" i=0 frames='|/-\'
    ( while true; do
        printf "\r%s" "${C_BLUE}  ${frames:$i:1}${C_RESET} ${msg}"
        i=$(( (i + 1) % 4 ))
        sleep 0.1
    done ) &
    SPIN_PID=$!
    disown "$SPIN_PID" 2>/dev/null
}

spin_stop() {
    [[ -z "$SPIN_PID" ]] && return
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    printf "\r\033[2K"
}

spin_ok()   { spin_stop; log_ok "$*"; }
spin_warn() { spin_stop; log_warn "$*"; }

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

require_macos26() {
    local product major
    product="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    major="${product%%.*}"
    if ! [[ "$major" =~ ^[0-9]+$ ]] || (( major < 26 )); then
        die "enable-hidpi-external-display requires macOS 26 (Tahoe) or later. Detected: ${product:-unknown}."
    fi
}

is_apple_silicon() {
    [[ "$(uname -m)" == "arm64" ]]
}

start_sudo_keepalive() {
    if [[ -n "$DRY_RUN" ]]; then
        log_info "[dry-run] skipping sudo authentication."
        return
    fi
    sudo -v || die "Administrator privileges are required to continue."
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null
}

cleanup() {
    spin_stop
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null
    fi
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Display discovery
#
# Two independent detection paths feed the same candidate list:
#   - Intel: real EDID, read from ioreg.
#   - Apple Silicon: no real EDID: VendorID/ProductID recovered from the
#     IOKit "DisplayAttributes" block instead.
#
# Apple's own manufacturer id (0x0610) is always excluded. That covers both
# the built-in panel and Apple's own external displays (Studio Display, Pro
# Display XDR...), which already have proper native HiDPI and must never be
# touched by this tool.
# ---------------------------------------------------------------------------

DISP_VID=()
DISP_PID=()
DISP_NAME=()
DISP_EDID=()

APPLE_VENDOR_ID="610"

# Vendor/product ids are kept in the same non-zero-padded lowercase hex form
# Apple's own Overrides tree uses for folder names and Icons.plist keys
# (e.g. "610", "1e6d" — never "0610"), not the fixed-width form ioreg/EDID
# parsing naturally produces.
hex_norm() {
    printf '%x' "$((16#$1))"
}

discover_displays_intel() {
    local raw
    raw=($(ioreg -lw0 | grep -i "IODisplayEDID" | sed -e "/[^<]*</s///" -e "s/\>//"))

    local entry vid pid name
    for entry in "${raw[@]}"; do
        vid=$(hex_norm "${entry:16:4}")
        [[ "$vid" == "$APPLE_VENDOR_ID" ]] && continue

        pid=$(hex_norm "${entry:22:2}${entry:20:2}")
        name="$(echo "${entry:190:24}" | xxd -p -r 2>/dev/null | tr -d '\000')"
        [[ -z "$name" ]] && name="Unknown Display"

        DISP_VID+=("$vid")
        DISP_PID+=("$pid")
        DISP_NAME+=("$name")
        DISP_EDID+=("$entry")
    done
}

discover_displays_apple_silicon() {
    local vends prods names
    vends=($(ioreg -l | grep "DisplayAttributes" | sed -n 's/.*"LegacyManufacturerID"=\([0-9]*\).*/\1/p'))
    prods=($(ioreg -l | grep "DisplayAttributes" | sed -n 's/.*"ProductID"=\([0-9]*\).*/\1/p'))
    # IFS/noglob must be restored explicitly: an assignment-only command like
    # `IFS=x names=(...)` does NOT scope IFS temporarily the way it would
    # before a real command — it leaks into the rest of the script.
    local old_ifs="$IFS"
    IFS=$'\n'
    set -o noglob
    names=($(ioreg -l | grep "DisplayAttributes" | sed -n 's/.*"ProductName"="\([^"]*\)".*/\1/p'))
    set +o noglob
    IFS="$old_ifs"

    # vends[]/prods[] are decimal (from ioreg's LegacyManufacturerID/ProductID),
    # unlike the hex substrings discover_displays_intel deals with — hex_norm
    # would misinterpret them, so convert straight to hex here instead.
    local i vid pid name_index=0
    for ((i = 0; i < ${#prods[@]}; i++)); do
        vid=$(printf "%x" "${vends[$i]}")
        [[ "$vid" == "$APPLE_VENDOR_ID" ]] && continue

        pid=$(printf "%x" "${prods[$i]}")
        name="${names[$name_index]:-Unknown Display}"
        name_index=$((name_index + 1))

        DISP_VID+=("$vid")
        DISP_PID+=("$pid")
        DISP_NAME+=("$name")
        DISP_EDID+=("")
    done
}

# Best-effort corroboration only: if system_profiler reports this pair as
# the internal panel, drop it. Absence of a signal is not treated as proof
# of anything — the VendorID gate above is the real safety net.
looks_internal_per_system_profiler() {
    local vid_dec=$1 pid_dec=$2
    [[ -z "$SP_PLIST" ]] && return 1

    local i=0 j hit
    while true; do
        "$PLISTBUDDY" -c "Print :SPDisplaysDataType:${i}:_name" "$SP_PLIST" >/dev/null 2>&1 || break
        j=0
        while true; do
            hit="$("$PLISTBUDDY" -c "Print :SPDisplaysDataType:${i}:spdisplays_ndrvs:${j}:_spdisplays_display-vendor-id" "$SP_PLIST" 2>/dev/null)"
            [[ -z "$hit" ]] && break
            local pid_hit
            pid_hit="$("$PLISTBUDDY" -c "Print :SPDisplaysDataType:${i}:spdisplays_ndrvs:${j}:_spdisplays_display-product-id" "$SP_PLIST" 2>/dev/null)"
            if [[ "$((16#$hit))" == "$vid_dec" && "$((16#$pid_hit))" == "$pid_dec" ]]; then
                local raw
                raw="$("$PLISTBUDDY" -c "Print :SPDisplaysDataType:${i}:spdisplays_ndrvs:${j}" "$SP_PLIST" 2>/dev/null)"
                if grep -qi "internal\|built-in\|builtin" <<<"$raw"; then
                    return 0
                fi
                return 1
            fi
            j=$((j + 1))
        done
        i=$((i + 1))
    done
    return 1
}

SP_PLIST=""

load_system_profiler_snapshot() {
    WORKDIR="$(mktemp -d)"
    SP_PLIST="${WORKDIR}/displays.plist"
    if ! system_profiler SPDisplaysDataType -json 2>/dev/null | plutil -convert xml1 -o "$SP_PLIST" - 2>/dev/null; then
        SP_PLIST=""
    fi
}

discover_displays() {
    spin "Scanning connected displays..."
    load_system_profiler_snapshot

    if is_apple_silicon; then
        discover_displays_apple_silicon
    else
        discover_displays_intel
    fi

    local kept_vid=() kept_pid=() kept_name=() kept_edid=()
    local i vid_dec pid_dec
    for ((i = 0; i < ${#DISP_VID[@]}; i++)); do
        vid_dec=$((16#${DISP_VID[$i]}))
        pid_dec=$((16#${DISP_PID[$i]}))
        if looks_internal_per_system_profiler "$vid_dec" "$pid_dec"; then
            continue
        fi
        kept_vid+=("${DISP_VID[$i]}")
        kept_pid+=("${DISP_PID[$i]}")
        kept_name+=("${DISP_NAME[$i]}")
        kept_edid+=("${DISP_EDID[$i]}")
    done
    DISP_VID=("${kept_vid[@]}")
    DISP_PID=("${kept_pid[@]}")
    DISP_NAME=("${kept_name[@]}")
    DISP_EDID=("${kept_edid[@]}")
    spin_ok "Found ${#DISP_VID[@]} external display(s)."
}

select_display() {
    if [[ ${#DISP_VID[@]} -eq 0 ]]; then
        die "No external display found. The built-in display is never listed here — connect an external monitor and try again."
    fi

    section "Detected external displays (built-in excluded)"
    local i
    for ((i = 0; i < ${#DISP_VID[@]}; i++)); do
        printf "  %d) %-24s (%s:%s)\n" $((i + 1)) "${DISP_NAME[$i]}" "${DISP_VID[$i]}" "${DISP_PID[$i]}"
    done
    printf "\n"
    prompt "Select a display [1-${#DISP_VID[@]}]: "
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DISP_VID[@]} )); then
        die "Invalid selection."
    fi

    SEL_INDEX=$((choice - 1))
    VID="${DISP_VID[$SEL_INDEX]}"
    PID="${DISP_PID[$SEL_INDEX]}"
    NAME="${DISP_NAME[$SEL_INDEX]}"
    EDID="${DISP_EDID[$SEL_INDEX]}"

    log_ok "Selected: ${NAME} (${VID}:${PID})"
    log_warn "Double-check this is really the external monitor, not the built-in display, before continuing."
    prompt "Continue? [Y/n] (default: Yes): "
    read -r confirm
    [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
}

# ---------------------------------------------------------------------------
# Native resolution lookup (used by Auto mode)
# ---------------------------------------------------------------------------

# system_profiler's pixel fields report the current framebuffer, not the
# panel: run while a scaled/HiDPI mode is active and they return the scaled
# backing size. Read the panel's own native size instead:
#   - Intel: first EDID detailed timing descriptor (the preferred timing).
#   - Apple Silicon: NativeFormat*Pixels in the IOKit DisplayAttributes block.
get_native_resolution() {
    local vid_hex=$1 pid_hex=$2 edid=$3
    local w h

    if [[ -n "$edid" ]]; then
        [[ "${edid:108:4}" == "0000" ]] && return 1
        w=$((0x${edid:112:2} + ((0x${edid:116:2} >> 4) << 8)))
        h=$((0x${edid:118:2} + ((0x${edid:122:2} >> 4) << 8)))
    else
        local line
        line="$(ioreg -l | grep "DisplayAttributes" |
            grep "\"LegacyManufacturerID\"=$((16#$vid_hex))[,}]" |
            grep "\"ProductID\"=$((16#$pid_hex))[,}]" | head -n 1)"
        w="$(sed -n 's/.*"NativeFormatHorizontalPixels"=\([0-9]*\).*/\1/p' <<<"$line")"
        h="$(sed -n 's/.*"NativeFormatVerticalPixels"=\([0-9]*\).*/\1/p' <<<"$line")"
    fi

    [[ -z "$w" || -z "$h" || "$w" == 0 || "$h" == 0 ]] && return 1
    echo "${w}x${h}"
}

# ---------------------------------------------------------------------------
# Resolution ladder (Auto mode)
#
# macOS shows 5 "looks like" options on a real Retina display: three
# "Larger Text" steps, "Default" (native / 2 exactly), and one "More Space"
# step. These ratios (relative to Default) are taken directly from a real,
# verified macOS list — MacBook Pro 14" (native 3024x1964) shows exactly
# 1024x665, 1147x745, 1352x878, 1512x982 (Default), 1800x1169 — rather than
# an invented progression, so applying them to any other native resolution
# reproduces the same step spacing Apple actually uses, aspect-ratio-locked.
# ---------------------------------------------------------------------------

LADDER_RATIOS=(0.677248677 0.758597884 0.894179894 1.0 1.190476190)
LADDER_LABELS=("Larger Text" "Larger Text" "Larger Text" "Default" "More Space")
MIN_LOOKS_LIKE_SIDE=1000

RESOLUTIONS=()
RESOLUTION_LABELS=()
DEFAULT_RESOLUTION=""

compute_auto_ladder() {
    local native_w=$1 native_h=$2
    RESOLUTIONS=()
    RESOLUTION_LABELS=()
    DEFAULT_RESOLUTION=""
    local i f w h entry seen=""
    for ((i = 0; i < ${#LADDER_RATIOS[@]}; i++)); do
        f="${LADDER_RATIOS[$i]}"
        w=$(awk -v n="$native_w" -v f="$f" 'BEGIN{printf "%d", int(n*f/2 + 0.5)}')
        h=$(awk -v n="$native_h" -v f="$f" 'BEGIN{printf "%d", int(n*f/2 + 0.5)}')
        # "Looks like" sizes under 1000px on the long side are too cramped to
        # be useful on an external monitor. The long side, not the width, so
        # portrait panels are judged the same way. Default is exempt: it is
        # the pixel-exact 2x mode, so dropping it would leave nothing sharp
        # on small panels.
        (( (w > h ? w : h) < MIN_LOOKS_LIKE_SIDE )) && [[ "${LADDER_LABELS[$i]}" != "Default" ]] && continue
        entry="${w}x${h}"
        [[ "$seen" == *"|${entry}|"* ]] && continue
        seen="${seen}|${entry}|"
        RESOLUTIONS+=("$entry")
        RESOLUTION_LABELS+=("${LADDER_LABELS[$i]}")
        [[ "${LADDER_LABELS[$i]}" == "Default" ]] && DEFAULT_RESOLUTION="$entry"
    done
}

aspect_ratio_warning() {
    local native_w=$1 native_h=$2 w=$3 h=$4
    awk -v nw="$native_w" -v nh="$native_h" -v w="$w" -v h="$h" '
        BEGIN {
            na = nw / nh; wa = w / h;
            diff = na - wa; if (diff < 0) diff = -diff;
            if (diff / na > 0.002) exit 0; else exit 1;
        }'
}

# ---------------------------------------------------------------------------
# Override file generation
# ---------------------------------------------------------------------------

# Each entry is 9 bytes: 4-byte width, 4-byte height, 1 trailing flag byte
# (left at 0x00 here). Older HiDPI-injection scripts also emitted extra
# entries bundling additional non-zero flag bytes for "safe/TV/interlaced"
# variants; macOS 26's Displays UI no longer labels those compound entries
# as HiDPI, so only this plain single-entry form is used here.
emit_resolution() {
    local res=$1
    local width height hidpi
    width=$(cut -d x -f 1 <<<"$res")
    height=$(cut -d x -f 2 <<<"$res")
    hidpi=$(printf '%08x %08x' $((width * 2)) $((height * 2)) | xxd -r -p | base64)
    printf '                <data>%sA</data>\n' "${hidpi:0:11}" >>"$DPI_FILE"
}

build_override_file() {
    DPI_FILE="${WORKDIR}/DisplayVendorID-${VID}/DisplayProductID-${PID}"
    mkdir -p "$(dirname "$DPI_FILE")"

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n'
        printf '    <dict>\n'
        printf '        <key>DisplayProductID</key>\n'
        printf '            <integer>%d</integer>\n' "$((16#$PID))"
        printf '        <key>DisplayVendorID</key>\n'
        printf '            <integer>%d</integer>\n' "$((16#$VID))"
    } >"$DPI_FILE"

    if [[ -n "${PATCHED_EDID:-}" ]]; then
        printf '        <key>IODisplayEDID</key>\n            <data>%s</data>\n' "$PATCHED_EDID" >>"$DPI_FILE"
    fi

    printf '        <key>scale-resolutions</key>\n            <array>\n' >>"$DPI_FILE"
    local res
    for res in "${RESOLUTIONS[@]}"; do
        emit_resolution "$res"
    done
    {
        printf '            </array>\n'
        printf '        <key>target-default-ppmm</key>\n'
        printf '            <real>10.0699301</real>\n'
        printf '    </dict>\n'
        printf '</plist>\n'
    } >>"$DPI_FILE"
}

# Intel-only compatibility patch: some monitors fall back to a lower
# resolution after sleep/wake unless the injected EDID also advertises a
# preferred-timing/digital-input feature bitmap. This forges a copy of the
# real EDID with those bits set; it never touches the monitor's own
# firmware, only the copy macOS reads from the override file.
patch_edid() {
    local version basicparams checksum newchecksum newedid
    version=${EDID:38:2}
    basicparams=${EDID:40:2}
    checksum=${EDID:254:2}
    newchecksum=$(printf '%x' $((0x$checksum + 0x$version + 0x$basicparams - 0x04 - 0x90)) | tail -c 2)
    newedid=${EDID:0:38}0490${EDID:42:6}e6${EDID:50:204}${newchecksum}
    PATCHED_EDID=$(printf '%s' "$newedid" | xxd -r -p | base64)
}

# ---------------------------------------------------------------------------
# Icon selection + Icons.plist merge
#
# The Displays settings pane draws the display from the entry's
# display-resolution-preview-icon (a .tiff plus the resolution-preview-*
# frame geometry, with -90/-180/-270 variants for rotation); display-icon is
# a UTI resolved through CoreTypes. Rather than bundling copies that go stale
# with every macOS release, the chosen entry is copied verbatim from the
# system Icons.plist — Apple keeps a catalog of every device it draws under
# the pseudo-vendor 6161706c ("aapl"), keyed by UTI. Those catalog entries
# omit display-icon (the key itself is the UTI), so it is added back the way
# Apple's own per-product entries (e.g. vendors:610:products:ae2f) carry it.
# ---------------------------------------------------------------------------

ICON_LABELS=("Pro Display XDR" "Studio Display XDR" "Studio Display" "iMac" "MacBook Pro 14\"" "MacBook Pro 16\"" "LG UltraFine 5K" "Portable display (iPad Pro icon)" "Generic display")
ICON_SOURCES=(
    ":vendors:6161706c:products:com.apple.pro-display-xdr"
    ":vendors:6161706c:products:com.apple.studio-display-xdr-2026"
    ":vendors:6161706c:products:com.apple.studio-display-2026"
    ":vendors:6161706c:products:com.apple.imac-2024-silver"
    ":vendors:6161706c:products:com.apple.macbookpro-14-2026-space-black"
    ":vendors:6161706c:products:com.apple.macbookpro-16-2026-space-black"
    ":vendors:1e6d:products:5b11"
    ":vendors:6161706c:products:com.apple.ipad-pro-12point9-1"
    ":vendors:6161706c:products:public.generic-lcd"
)

choose_icon() {
    section "Display icon"
    local i
    for ((i = 0; i < ${#ICON_LABELS[@]}; i++)); do
        echo "  $((i + 1))) ${ICON_LABELS[$i]}"
    done
    echo "  $((i + 1))) Don't change"
    printf "\n"
    prompt "Choice [1-$((i + 1))]: "
    read -r icon_choice

    if ! [[ "$icon_choice" =~ ^[0-9]+$ ]] || (( icon_choice < 1 || icon_choice > i + 1 )); then
        die "Invalid selection."
    fi
    if (( icon_choice == i + 1 )); then
        SKIP_ICON=1
        return
    fi

    ICON_SOURCE="${ICON_SOURCES[$((icon_choice - 1))]}"
    if ! "$PLISTBUDDY" -c "Print ${ICON_SOURCE}" "$SYS_ICONS_PLIST" >/dev/null 2>&1; then
        log_warn "This macOS release has no \"${ICON_LABELS[$((icon_choice - 1))]}\" icon; leaving the icon unchanged."
        SKIP_ICON=1
    fi
}

merge_icons_plist() {
    [[ -n "${SKIP_ICON:-}" ]] && return

    local target="${WORKDIR}/Icons.plist"
    if [[ -f "${OVERRIDES_DIR}/Icons.plist" ]]; then
        cp "${OVERRIDES_DIR}/Icons.plist" "$target"
    else
        cp "$SYS_ICONS_PLIST" "$target"
    fi

    local entry="${WORKDIR}/icon-entry.plist"
    "$PLISTBUDDY" -x -c "Print ${ICON_SOURCE}" "$SYS_ICONS_PLIST" >"$entry"
    if ! "$PLISTBUDDY" -c "Print :display-icon" "$entry" >/dev/null 2>&1; then
        "$PLISTBUDDY" -c "Add :display-icon string ${ICON_SOURCE##*:}" "$entry"
    fi

    # Icons.plist keys are the plain lowercase hex id (e.g. "1e6d", "5b11"),
    # matching Apple's own entries — not the decimal form used for the
    # DisplayVendorID/DisplayProductID integer fields elsewhere.
    local dest=":vendors:${VID}:products:${PID}"
    "$PLISTBUDDY" -c "Delete ${dest}" "$target" >/dev/null 2>&1
    "$PLISTBUDDY" -c "Add :vendors:${VID} dict" "$target" >/dev/null 2>&1
    "$PLISTBUDDY" -c "Add :vendors:${VID}:products dict" "$target" >/dev/null 2>&1
    "$PLISTBUDDY" -c "Add ${dest} dict" "$target"
    "$PLISTBUDDY" -c "Merge ${entry} ${dest}" "$target"

    if ! plutil -lint -s "$target" >/dev/null 2>&1; then
        die "Generated Icons.plist failed validation; aborting before touching the system copy."
    fi
    MERGED_ICONS_PLIST="$target"
}

# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------

install_override() {
    if [[ -n "$DRY_RUN" ]]; then
        log_info "[dry-run] would install ${OVERRIDES_DIR}/DisplayVendorID-${VID}/DisplayProductID-${PID}"
        [[ -n "${MERGED_ICONS_PLIST:-}" ]] && log_info "[dry-run] would merge ${OVERRIDES_DIR}/Icons.plist"
        log_ok "[dry-run] HiDPI would be enabled for ${NAME}. No changes were made."
        return
    fi

    spin "Installing override for ${NAME}..."

    sudo mkdir -p "${OVERRIDES_DIR}/DisplayVendorID-${VID}"

    sudo cp -r "${WORKDIR}/DisplayVendorID-${VID}" "${OVERRIDES_DIR}/"
    sudo chown -R root:wheel "${OVERRIDES_DIR}/DisplayVendorID-${VID}"
    sudo chmod -R 0644 "${OVERRIDES_DIR}/DisplayVendorID-${VID}"/*
    sudo chmod 0755 "${OVERRIDES_DIR}/DisplayVendorID-${VID}"

    if [[ -n "${MERGED_ICONS_PLIST:-}" ]]; then
        # Left behind by older versions, which pointed display-icon at a bundled copy.
        sudo rm -f "${OVERRIDES_DIR}/DisplayVendorID-${VID}/DisplayProductID-${PID}.icns"
        sudo cp "$MERGED_ICONS_PLIST" "${OVERRIDES_DIR}/Icons.plist"
        sudo chown root:wheel "${OVERRIDES_DIR}/Icons.plist"
        sudo chmod 0644 "${OVERRIDES_DIR}/Icons.plist"
    fi

    spin_ok "HiDPI enabled for ${NAME}. Reboot to apply."
    log_info "The boot logo will look oversized on the very first reboot only."
}

# Scoped to one product: other displays from the same vendor share the
# DisplayVendorID-* folder and the vendors:<vid> Icons.plist entry.
remove_override() {
    local vid_hex=$1 pid_hex=$2
    local vendor_dir="${OVERRIDES_DIR}/DisplayVendorID-${vid_hex}"
    if [[ -n "$DRY_RUN" ]]; then
        log_info "[dry-run] would remove ${vendor_dir}/DisplayProductID-${pid_hex}"
        return
    fi
    if [[ -f "${OVERRIDES_DIR}/Icons.plist" ]]; then
        sudo "$PLISTBUDDY" -c "Delete :vendors:${vid_hex}:products:${pid_hex}" "${OVERRIDES_DIR}/Icons.plist" >/dev/null 2>&1
    fi
    sudo rm -f "${vendor_dir}/DisplayProductID-${pid_hex}" "${vendor_dir}/DisplayProductID-${pid_hex}.icns"
    sudo rmdir "$vendor_dir" 2>/dev/null
}

# Safety net: writing the override only takes effect after reboot, so it
# can't be tested live. Rather than leaving an unconfirmed change sitting
# there if the user got interrupted mid-run, silence for 10s is treated as
# "didn't mean to keep this" and the just-written override is undone before
# the script even exits — not a promise to catch problems that only show up
# after the next reboot (that's what Disable HiDPI / the recovery helper
# are for).
confirm_or_revert() {
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive session: skipping the confirm-or-revert safety window."
        return 0
    fi

    printf "\n"
    log_warn "If this display goes blank or wrong after rebooting, use \"Disable HiDPI\" or the recovery helper (~/.enable-hidpi-external-display-disable)."
    local secs=10
    while (( secs > 0 )); do
        printf "\r%s" "${C_YELLOW}› Press Enter to keep this change (auto-revert in ${secs}s)... ${C_RESET}"
        if read -r -t 1 _; then
            printf "\n"
            log_ok "Change kept."
            return 0
        fi
        secs=$((secs - 1))
    done
    printf "\n"
    log_warn "No response — reverting automatically."
    remove_override "$VID" "$PID"
    log_ok "Reverted. Nothing will change on next boot."
    return 1
}

write_uninstall_helper() {
    cat >"$UNINSTALL_SCRIPT" <<'EOS'
#!/bin/bash
# Emergency recovery helper for enable-hidpi-external-display.
#
# From macOS Recovery: open Disk Utility and mount the "<disk> - Data"
# volume (unlock it if FileVault is on), then in Terminal run:
#   bash "/Volumes/<disk> - Data/Users/<you>/.enable-hidpi-external-display-disable"
# From a normal boot, run it with sudo instead.
#
# /Library and /Users live on the Data volume, so paths are resolved from
# this script's own location rather than the current directory.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OVERRIDES="${ROOT}/Library/Displays/Contents/Resources/Overrides"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [[ ! -d "$OVERRIDES" ]]; then
    echo "No enable-hidpi-external-display overrides found at ${OVERRIDES}."
    exit 0
fi

echo "Installed display overrides:"
i=0
declare -a files
for f in "${OVERRIDES}"/DisplayVendorID-*/DisplayProductID-*; do
    [[ -f "$f" && "$(basename "$f")" != *.* ]] || continue
    i=$((i + 1))
    files[$i]="$f"
    echo "  ${i}) ${f#"${OVERRIDES}/"}"
done

if [[ $i -eq 0 ]]; then
    echo "Nothing to remove."
    exit 0
fi

echo ""
echo "(1-${i}) Remove one specific override"
echo "(a) Remove ALL overrides (reset to macOS default)"
read -p "Choice: " choice

if [[ "$choice" == "a" ]]; then
    rm -rf "$OVERRIDES"
    echo "All overrides removed."
    exit 0
fi

if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le $i ]]; then
    target="${files[$choice]}"
    vendor_dir="$(dirname "$target")"
    vid="${vendor_dir##*DisplayVendorID-}"
    pid="${target##*DisplayProductID-}"
    if [[ -f "${OVERRIDES}/Icons.plist" ]]; then
        if [[ -x "$PLISTBUDDY" ]]; then
            "$PLISTBUDDY" -c "Delete :vendors:${vid}:products:${pid}" "${OVERRIDES}/Icons.plist" 2>/dev/null
        else
            echo "PlistBuddy not available here; its Icons.plist entry was left in place (harmless)."
        fi
    fi
    rm -f "$target" "${target}.icns"
    rmdir "$vendor_dir" 2>/dev/null
    echo "Removed ${target#"${OVERRIDES}/"}."
else
    echo "Invalid choice."
    exit 1
fi
EOS
    chmod +x "$UNINSTALL_SCRIPT"
}

disable_flow() {
    if [[ ! -d "$OVERRIDES_DIR" ]]; then
        die "No enable-hidpi-external-display overrides are installed."
    fi

    section "Installed display overrides"
    local files=() i=0 f
    for f in "${OVERRIDES_DIR}"/DisplayVendorID-*/DisplayProductID-*; do
        [[ -f "$f" && "$(basename "$f")" != *.* ]] || continue
        i=$((i + 1))
        files[$i]="$f"
        printf "  %d) %s\n" "$i" "${f#"${OVERRIDES_DIR}/"}"
    done

    if [[ $i -eq 0 ]]; then
        die "No enable-hidpi-external-display overrides are installed."
    fi

    printf "\n"
    echo "  (a) Remove ALL overrides (reset to macOS default)"
    printf "\n"
    prompt "Choice [1-${i}, a]: "
    read -r choice

    if [[ "$choice" == "a" ]]; then
        log_warn "This deletes ${OVERRIDES_DIR} entirely, including anything there that wasn't installed by enable-hidpi-external-display."
        prompt "Remove ALL overrides? [Y/n] (default: Yes): "
        read -r confirm_all
        [[ -z "$confirm_all" || "$confirm_all" =~ ^[Yy]$ ]] || die "Aborted."
    fi

    start_sudo_keepalive

    if [[ "$choice" == "a" ]]; then
        if [[ -n "$DRY_RUN" ]]; then
            log_info "[dry-run] would remove ${OVERRIDES_DIR}"
        else
            spin "Removing all overrides..."
            sudo rm -rf "$OVERRIDES_DIR"
            spin_stop
        fi
        log_ok "All overrides removed. Reboot to apply."
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i )); then
        local target="${files[$choice]}"
        local label="${target#"${OVERRIDES_DIR}/"}"
        local vid_hex="${label%%/*}"
        vid_hex="${vid_hex#DisplayVendorID-}"
        local pid_hex="${target##*DisplayProductID-}"
        [[ -z "$DRY_RUN" ]] && spin "Removing ${label}..."
        remove_override "$vid_hex" "$pid_hex"
        [[ -z "$DRY_RUN" ]] && spin_stop
        log_ok "Removed ${label}. Reboot to apply."
    else
        die "Invalid choice."
    fi
}

# ---------------------------------------------------------------------------
# Enable flow
# ---------------------------------------------------------------------------

enable_flow() {
    discover_displays
    select_display

    local native=""
    native="$(get_native_resolution "$VID" "$PID" "$EDID")"

    section "Resolution setup for \"${NAME}\" (${VID}:${PID})"
    if [[ -n "$native" ]]; then
        log_info "Detected native resolution: ${native}"
    else
        log_warn "Could not auto-detect the native resolution."
    fi

    local native_w="" native_h=""
    local res_choice=""
    if [[ -n "$native" ]]; then
        native_w="${native%x*}"
        native_h="${native#*x}"
        compute_auto_ladder "$native_w" "$native_h"
        if [[ ${#RESOLUTIONS[@]} -eq 1 ]]; then
            log_warn "At ${native_w}x${native_h} every HiDPI size except ${DEFAULT_RESOLUTION} is under ${MIN_LOOKS_LIKE_SIDE}px — HiDPI gains little on a panel this small."
        fi

        echo "  1) Auto   — generate the same variant ladder macOS uses for real Retina displays"
        local i
        for ((i = 0; i < ${#RESOLUTIONS[@]}; i++)); do
            printf "       %-12s %s\n" "${RESOLUTION_LABELS[$i]}" "${RESOLUTIONS[$i]}"
        done
        echo "  2) Manual — type your own list of \"looks like\" resolutions"
        printf "\n"
        prompt "Choice [1-2]: "
        read -r res_choice
    else
        log_warn "Auto mode unavailable without a detected native resolution — falling back to manual."
        res_choice=2
    fi

    case "$res_choice" in
    1)
        log_ok "${#RESOLUTIONS[@]} HiDPI variants generated from ${native_w}x${native_h}. Default (${DEFAULT_RESOLUTION}) will be applied."
        ;;
    2)
        local prefill="${RESOLUTIONS[*]}"
        local list_prompt="Edit the \"looks like\" resolutions, space-separated"
        [[ -n "$prefill" ]] && list_prompt="${list_prompt} [${prefill}]"
        prompt "${list_prompt}: "
        read -r manual_list
        [[ -z "$manual_list" ]] && manual_list="$prefill"
        RESOLUTIONS=($manual_list)
        RESOLUTION_LABELS=()
        [[ ${#RESOLUTIONS[@]} -gt 0 ]] || die "No resolutions entered."
        if [[ -n "$native_w" ]]; then
            local r w h
            for r in "${RESOLUTIONS[@]}"; do
                w="${r%x*}"; h="${r#*x}"
                if aspect_ratio_warning "$native_w" "$native_h" "$w" "$h"; then
                    log_warn "${r} does not match the display's native aspect ratio — it may look blurry."
                fi
            done
        fi
        ;;
    *)
        die "Invalid selection."
        ;;
    esac

    PATCHED_EDID=""
    if ! is_apple_silicon && [[ -n "$EDID" ]]; then
        printf "\n"
        prompt "Apply the EDID sleep/wake compatibility patch? Only needed if the display drops to a lower resolution after sleep. [y/N] (default: No): "
        read -r patch_choice
        if [[ "$patch_choice" =~ ^[Yy]$ ]]; then
            patch_edid
        fi
    fi

    choose_icon

    start_sudo_keepalive
    build_override_file
    merge_icons_plist
    install_override

    if [[ -n "$DRY_RUN" ]]; then
        log_info "[dry-run] skipping confirm-or-revert window and uninstall helper."
        return
    fi

    if confirm_or_revert; then
        write_uninstall_helper
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
    done

    require_macos26
    print_banner

    if [[ -n "$DRY_RUN" ]]; then
        log_warn "DRY RUN — no sudo commands will run, no files will be written to the system."
    fi

    echo "  1) Enable HiDPI"
    echo "  2) Disable HiDPI"
    echo "  3) Exit"
    printf "\n"
    prompt "Select an option [1-3]: "
    read -r choice

    case "$choice" in
    1)
        enable_flow
        ;;
    2)
        disable_flow
        ;;
    3)
        exit 0
        ;;
    *)
        die "Invalid selection."
        ;;
    esac
}

# BASH_SOURCE is unset under `bash -c "$(curl ...)"`, which set -u would
# otherwise abort on before main ever runs.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
