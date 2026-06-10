#!/system/bin/sh
# DeviceIdle Manager - customize.sh
# First install/update: preserve original backup and seed managed config

TARGET_FILE="/data/system/deviceidle.xml"
BACKUP_DIR="$MODPATH/backup"
ACTIVE_DIR="$MODPATH/active"
OLD_MODDIR="/data/adb/modules/ksu_deviceidle_manager"

ui_print "[*] DeviceIdle Manager installing..."

# Create directories
mkdir -p "$BACKUP_DIR"
mkdir -p "$ACTIVE_DIR"

# Keep backup/active data across module updates when KernelSU stages a new MODPATH.
if [ -f "$OLD_MODDIR/backup/original_deviceidle.xml" ]; then
    ui_print "[*] Existing original backup found, preserving it..."
    cp -af "$OLD_MODDIR/backup/." "$BACKUP_DIR/" 2>/dev/null
    [ -d "$OLD_MODDIR/active" ] && cp -af "$OLD_MODDIR/active/." "$ACTIVE_DIR/" 2>/dev/null
fi

if [ -x "$MODPATH/manager.sh" ]; then
    if [ -f "$BACKUP_DIR/original_deviceidle.xml" ]; then
        ui_print "[*] Original backup already exists; not overwriting"
    elif [ -f "$TARGET_FILE" ]; then
        ui_print "[*] Backing up current /data/system/deviceidle.xml..."
    else
        ui_print "[!] /data/system/deviceidle.xml not found; creating empty managed config"
    fi
    MODDIR="$MODPATH" sh "$MODPATH/manager.sh" backup-once
else
    ui_print "[!] manager.sh missing, creating fallback empty config..."
    cat > "$ACTIVE_DIR/deviceidle.xml" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<config>
</config>
EOF
fi

# Set permissions for module files
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/manager.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print "[*] Installation complete!"
ui_print "[*] Use WebUI to manage battery optimization whitelist"
