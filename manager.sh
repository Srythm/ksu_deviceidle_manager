#!/system/bin/sh
# DeviceIdle Manager - single control point for backup, apply and WebUI writes.

MODDIR=${MODDIR:-/data/adb/modules/ksu_deviceidle_manager}
TARGET_FILE="/data/system/deviceidle.xml"
BACKUP_DIR="$MODDIR/backup"
ACTIVE_DIR="$MODDIR/active"
BACKUP_FILE="$BACKUP_DIR/original_deviceidle.xml"
ACTIVE_FILE="$ACTIVE_DIR/deviceidle.xml"
LIST_FILE="$ACTIVE_DIR/packages.list"
HASH_FILE="$MODDIR/.current_hash"
LOG_FILE="$MODDIR/protection.log"

log_msg() {
    mkdir -p "$MODDIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR" "$ACTIVE_DIR"
}

empty_config() {
    cat <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<config>
</config>
EOF
}

normalize_pkg() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._'
}

extract_packages() {
    sed -n \
        -e 's/.*<whitelist[^>]* n="\([^"]*\)".*/\1/p' \
        -e 's/.*<app[^>]* n="\([^"]*\)".*/\1/p' \
        -e 's/.*<wl[^>]* n="\([^"]*\)".*/\1/p' \
        -e 's/.*packageName="\([^"]*\)".*/\1/p' \
        -e 's/.*package="\([^"]*\)".*/\1/p' \
        "$1" 2>/dev/null | while read -r pkg; do
            pkg="$(normalize_pkg "$pkg")"
            case "$pkg" in
                *.*) echo "$pkg" ;;
            esac
        done | sort -u
}

write_xml_from_list() {
    list="$1"
    out="$2"
    tmp="$out.tmp.$$"

    {
        echo '<?xml version="1.0" encoding="utf-8"?>'
        echo '<config>'
        if [ -f "$list" ]; then
            sort -u "$list" | while read -r pkg; do
                pkg="$(normalize_pkg "$pkg")"
                case "$pkg" in
                    *.*) echo "    <wl n=\"$pkg\" />" ;;
                esac
            done
        fi
        echo '</config>'
    } > "$tmp"

    mv -f "$tmp" "$out"
}

# Runtime sync: apply whitelist to running system services
# This is critical for ColorOS/OxygenOS and Android 14+
runtime_sync() {
    if [ ! -f "$LIST_FILE" ]; then
        return 0
    fi

    log_msg "Runtime sync starting..."

    while read -r pkg; do
        [ -z "$pkg" ] && continue

        # 1. DeviceIdleController runtime whitelist
        if cmd deviceidle whitelist +"$pkg" >/dev/null 2>&1; then
            log_msg "deviceidle whitelist: $pkg"
        elif dumpsys deviceidle whitelist +"$pkg" >/dev/null 2>&1; then
            log_msg "dumpsys deviceidle whitelist: $pkg"
        fi

        # 2. AppOps: allow background running
        if cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1; then
            log_msg "appops RUN_ANY_IN_BACKGROUND allow: $pkg"
        fi
        if cmd appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1; then
            log_msg "appops RUN_IN_BACKGROUND allow: $pkg"
        fi

        # 3. ActivityManager: ensure app is not marked inactive
        if am set-inactive "$pkg" false >/dev/null 2>&1; then
            log_msg "am set-inactive false: $pkg"
        fi
    done < "$LIST_FILE"

    log_msg "Runtime sync complete"
}

sync_list_from_active() {
    ensure_dirs
    if [ -f "$ACTIVE_FILE" ]; then
        extract_packages "$ACTIVE_FILE" > "$LIST_FILE"
    else
        : > "$LIST_FILE"
    fi
}

backup_once() {
    ensure_dirs

    if [ -f "$BACKUP_FILE" ]; then
        [ -f "$ACTIVE_FILE" ] || cp -f "$BACKUP_FILE" "$ACTIVE_FILE"
        sync_list_from_active
        return 0
    fi

    if [ -f "$TARGET_FILE" ]; then
        cp -f "$TARGET_FILE" "$BACKUP_FILE"
        cp -f "$TARGET_FILE" "$ACTIVE_FILE"
        md5sum "$TARGET_FILE" 2>/dev/null | awk '{print $1}' > "$BACKUP_DIR/original_hash"
        log_msg "Original deviceidle.xml backed up"
    else
        empty_config > "$BACKUP_FILE"
        empty_config > "$ACTIVE_FILE"
        touch "$BACKUP_DIR/original_not_found"
        log_msg "Original deviceidle.xml missing, empty config created"
    fi

    sync_list_from_active
}

apply_active() {
    ensure_dirs

    if [ ! -f "$ACTIVE_FILE" ]; then
        if [ -f "$BACKUP_FILE" ]; then
            cp -f "$BACKUP_FILE" "$ACTIVE_FILE"
        else
            empty_config > "$ACTIVE_FILE"
        fi
    fi

    chattr -i "$TARGET_FILE" 2>/dev/null
    cp -f "$ACTIVE_FILE" "$TARGET_FILE"
    chown system:system "$TARGET_FILE" 2>/dev/null
    chmod 644 "$TARGET_FILE" 2>/dev/null
    restorecon "$TARGET_FILE" 2>/dev/null
    chattr +i "$TARGET_FILE" 2>/dev/null
    md5sum "$TARGET_FILE" 2>/dev/null | awk '{print $1}' > "$HASH_FILE"
    log_msg "Active config applied"

    # Runtime sync to running system services
    sync_list_from_active
    runtime_sync
}

set_list_csv() {
    ensure_dirs
    csv="$1"
    tmp="$LIST_FILE.tmp.$$"
    : > "$tmp"

    old_ifs="$IFS"
    IFS=','
    for raw in $csv; do
        pkg="$(normalize_pkg "$raw")"
        case "$pkg" in
            *.*) echo "$pkg" >> "$tmp" ;;
        esac
    done
    IFS="$old_ifs"

    sort -u "$tmp" > "$LIST_FILE"
    rm -f "$tmp"
    write_xml_from_list "$LIST_FILE" "$ACTIVE_FILE"
    apply_active
}

status() {
    count=0
    [ -f "$LIST_FILE" ] && count="$(wc -l < "$LIST_FILE" 2>/dev/null | tr -d ' ')"

    protected=0
    lsattr "$TARGET_FILE" 2>/dev/null | grep -q 'i' && protected=1

    daemon=0
    if [ -f "$MODDIR/daemon.pid" ]; then
        pid="$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && daemon=1
    fi

    target_match=0
    [ -f "$TARGET_FILE" ] && [ -f "$ACTIVE_FILE" ] && cmp -s "$TARGET_FILE" "$ACTIVE_FILE" && target_match=1

    echo "count=$count"
    echo "protected=$protected"
    echo "daemon=$daemon"
    echo "target_match=$target_match"
}

case "$1" in
    backup-once)
        backup_once
        ;;
    apply)
        apply_active
        ;;
    set-list)
        set_list_csv "$2"
        ;;
    list)
        sync_list_from_active
        cat "$LIST_FILE" 2>/dev/null
        ;;
    original-list)
        [ -f "$BACKUP_FILE" ] && extract_packages "$BACKUP_FILE"
        ;;
    status)
        sync_list_from_active
        status
        ;;
    restore-original)
        ensure_dirs
        [ -f "$BACKUP_FILE" ] || exit 1
        cp -f "$BACKUP_FILE" "$ACTIVE_FILE"
        sync_list_from_active
        apply_active
        ;;
    *)
        echo "Usage: $0 {backup-once|apply|set-list|list|original-list|status|restore-original}" >&2
        exit 2
        ;;
esac
