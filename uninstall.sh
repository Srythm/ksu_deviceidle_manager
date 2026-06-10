#!/system/bin/sh
# DeviceIdle Manager - uninstall.sh
# Restore original configuration when module is removed

MODDIR=${0%/*}
TARGET_FILE="/data/system/deviceidle.xml"
BACKUP_FILE="$MODDIR/backup/original_deviceidle.xml"

# Remove immutable flag if set
chattr -i "$TARGET_FILE" 2>/dev/null

# Restore original configuration if available
if [ -f "$BACKUP_FILE" ]; then
    cp -f "$BACKUP_FILE" "$TARGET_FILE"
    chown system:system "$TARGET_FILE"
    chmod 644 "$TARGET_FILE"
fi

# Kill daemon if still running
if [ -f "$MODDIR/daemon.pid" ]; then
    PID=$(cat "$MODDIR/daemon.pid")
    kill "$PID" 2>/dev/null
fi

# Clean up runtime files
rm -f "$MODDIR/daemon.pid" 2>/dev/null
rm -f "$MODDIR/.current_hash" 2>/dev/null
