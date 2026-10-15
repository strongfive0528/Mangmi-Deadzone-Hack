#!/system/bin/sh

# Non-interactive root script for aggressively reducing joystick deadzone/offset
# behavior to zero on Mangmi/Handheld MQ66-style firmware, while also handling
# MQ86/MQ87-style dead_zone sysfs nodes if present.

set +e

AXIS_DIR="/mnt/vendor/persist/axis"
MCU_DIR="/sys/devices/platform/soc/0.mcu"
SPI_DIR="/sys/bus/spi/devices/spi0.0"

log() {
    echo "[deadzone-zero] $*"
}

section() {
    echo ""
    echo "========== $* =========="
}

read_file() {
    p="$1"
    if [ -e "$p" ]; then
        v="$(cat "$p" 2>/dev/null)"
        echo "$p = $v"
    else
        echo "$p = <missing>"
    fi
}

try_chmod() {
    p="$1"
    [ -e "$p" ] || return 1
    chmod 666 "$p" 2>/dev/null
    return 0
}

try_write() {
    p="$1"
    v="$2"
    label="$3"

    if [ ! -e "$p" ]; then
        log "skip missing $label: $p"
        return 1
    fi

    try_chmod "$p"
    old="$(cat "$p" 2>/dev/null)"
    echo "$v" > "$p" 2>/dev/null
    rc=$?
    new="$(cat "$p" 2>/dev/null)"

    if [ "$rc" = "0" ]; then
        log "wrote $label: $p"
        log "  old: $old"
        log "  new: $new"
        return 0
    fi

    log "ERROR writing $label: $p"
    log "  old: $old"
    log "  attempted: $v"
    log "  after: $new"
    return 1
}

find_nodes() {
    name="$1"
    for base in /sys/bus/spi/devices /sys/devices/platform /sys/devices /sys/module; do
        [ -d "$base" ] || continue
        find "$base" -type f -name "$name" 2>/dev/null
    done
}

backup_axis_file() {
    p="$1"
    [ -f "$p" ] || return 1

    mkdir -p "$AXIS_DIR/deadzone_zero_backup" 2>/dev/null
    b="$AXIS_DIR/deadzone_zero_backup/$(basename "$p").bak"

    if [ ! -f "$b" ]; then
        cp "$p" "$b" 2>/dev/null
        if [ "$?" = "0" ]; then
            log "backup: $p -> $b"
        else
            log "WARN backup failed: $p -> $b"
        fi
    else
        log "backup exists: $b"
    fi
}

zero_axisdata_center_offset() {
    p="$1"
    [ -f "$p" ] || return 1

    backup_axis_file "$p"

    old="$(cat "$p" 2>/dev/null)"
    set -- $old
    if [ "$#" -lt 4 ]; then
        log "skip AxisData without 4 fields: $p = $old"
        return 1
    fi

    new="$1 $2 $3 0"
    try_write "$p" "$new" "AxisData centerOffset=0"
}

section "environment"
id
uname -a 2>/dev/null
getprop ro.product.model 2>/dev/null | sed 's/^/ro.product.model = /'
getprop ro.product.device 2>/dev/null | sed 's/^/ro.product.device = /'
getprop ro.build.fingerprint 2>/dev/null | sed 's/^/ro.build.fingerprint = /'

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    log "ERROR: run this script as root"
    exit 1
fi

section "before: known MQ66 nodes"
read_file "$MCU_DIR/joystick_L_X_cali"
read_file "$MCU_DIR/joystick_L_Y_cali"
read_file "$MCU_DIR/joystick_R_Z_cali"
read_file "$MCU_DIR/joystick_R_RZ_cali"
read_file "$MCU_DIR/joystick_L_offset"
read_file "$MCU_DIR/joystick_R_offset"
read_file "$MCU_DIR/mcu_stick_val"

section "before: known MQ86/MQ87 nodes"
read_file "$SPI_DIR/joystick_L_dead_zone"
read_file "$SPI_DIR/joystick_R_dead_zone"
read_file "$SPI_DIR/joystick_L_sensitivity"
read_file "$SPI_DIR/joystick_R_sensitivity"

section "before: persist axis"
find "$AXIS_DIR" -maxdepth 1 -type f 2>/dev/null | sort | while read p; do
    read_file "$p"
done

section "step 1: write real dead_zone sysfs nodes if present"
dz_count=0
find_nodes "joystick_L_dead_zone" | while read p; do
    try_write "$p" "0" "left dead_zone"
done
find_nodes "joystick_R_dead_zone" | while read p; do
    try_write "$p" "0" "right dead_zone"
done

section "step 2: MQ66 runtime offset nodes to zero"
try_write "$MCU_DIR/joystick_L_offset" "0 0" "MQ66 left runtime offset"
try_write "$MCU_DIR/joystick_R_offset" "0 0" "MQ66 right runtime offset"

section "step 3: MQ66 persisted incOffset to zero"
mkdir -p "$AXIS_DIR" 2>/dev/null
try_write "$AXIS_DIR/inc_offset_l" "0" "MQ66 left incOffset"
try_write "$AXIS_DIR/inc_offset_r" "0" "MQ66 right incOffset"

if [ ! -e "$AXIS_DIR/inc_offset_l" ]; then
    echo "0" > "$AXIS_DIR/inc_offset_l" 2>/dev/null
    log "created $AXIS_DIR/inc_offset_l = $(cat "$AXIS_DIR/inc_offset_l" 2>/dev/null)"
fi
if [ ! -e "$AXIS_DIR/inc_offset_r" ]; then
    echo "0" > "$AXIS_DIR/inc_offset_r" 2>/dev/null
    log "created $AXIS_DIR/inc_offset_r = $(cat "$AXIS_DIR/inc_offset_r" 2>/dev/null)"
fi

section "step 4: MQ66 AxisData centerOffset field to zero"
for axis in 0 1 11 14; do
    zero_axisdata_center_offset "$AXIS_DIR/data_$axis"
done

section "step 5: default AxisData centerOffset field to zero"
for axis in 0 1 11 14; do
    zero_axisdata_center_offset "$AXIS_DIR/def_$axis"
done

section "step 6: re-apply runtime offsets after persist edits"
try_write "$MCU_DIR/joystick_L_offset" "0 0" "MQ66 left runtime offset final"
try_write "$MCU_DIR/joystick_R_offset" "0 0" "MQ66 right runtime offset final"

section "after: known MQ66 nodes"
read_file "$MCU_DIR/joystick_L_X_cali"
read_file "$MCU_DIR/joystick_L_Y_cali"
read_file "$MCU_DIR/joystick_R_Z_cali"
read_file "$MCU_DIR/joystick_R_RZ_cali"
read_file "$MCU_DIR/joystick_L_offset"
read_file "$MCU_DIR/joystick_R_offset"
read_file "$MCU_DIR/mcu_stick_val"

section "after: known MQ86/MQ87 nodes"
read_file "$SPI_DIR/joystick_L_dead_zone"
read_file "$SPI_DIR/joystick_R_dead_zone"
read_file "$SPI_DIR/joystick_L_sensitivity"
read_file "$SPI_DIR/joystick_R_sensitivity"

section "after: persist axis"
find "$AXIS_DIR" -maxdepth 1 -type f 2>/dev/null | sort | while read p; do
    read_file "$p"
done

section "diagnostic search"
echo "deadzone candidates:"
find /sys -type f \( -name '*dead*zone*' -o -name '*deadzone*' -o -name '*joystick*dead*' -o -name '*stick*dead*' \) 2>/dev/null
echo "joystick/stick candidates:"
find /sys -type f \( -name '*joystick*' -o -name '*stick*' -o -name '*mcu*stick*' \) 2>/dev/null
echo "xpad parameters:"
find /sys/module/xpad/parameters -type f 2>/dev/null | while read p; do
    read_file "$p"
done

section "summary"
log "finished"
log "For MQ66, zeroing was attempted through runtime offsets, inc_offset_l/r, and AxisData centerOffset fields."
log "If offsets later return to nonzero values, SystemService or kernel/MCU firmware rewrote them after this script."
