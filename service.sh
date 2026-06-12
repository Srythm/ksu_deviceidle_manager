#!/system/bin/sh
# DeviceIdle Manager - service.sh
# Continuous protection + runtime sync for deviceidle.xml
# ColorOS/OxygenOS compatible: syncs via cmd deviceidle, cmd appops, am set-inactive

MODDIR=${0%/*}
TARGET_FILE="/data/system/deviceidle.xml"
ACTIVE_FILE="$MODDIR/active/deviceidle.xml"
LOG_FILE="$MODDIR/protection.log"
PID_FILE="$MODDIR/daemon.pid"
MANAGER="$MODDIR/manager.sh"
export MODDIR

# Store daemon PID
echo $$ > "$PID_FILE"

# Log function
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Restore function - applies our managed config (includes runtime_sync)
restore_config() {
    [ -x "$MANAGER" ] && sh "$MANAGER" apply
}

# Initial restore
[ -x "$MANAGER" ] && sh "$MANAGER" backup-once
restore_config

# Check if inotifywait is available
if command -v inotifywait >/dev/null 2>&1; then
    log_msg "Using inotifywait for real-time monitoring"
    
    # Use inotifywait for real-time monitoring
    while true; do
        # Monitor for any modifications
        inotifywait -e modify,attrib,move,create,delete "$TARGET_FILE" 2>/dev/null
        
        # Small delay to let the operation complete
        sleep 0.5
        
        # Check if file was actually modified
        if [ -f "$TARGET_FILE" ]; then
            CURRENT_HASH=$(md5sum "$TARGET_FILE" 2>/dev/null | awk '{print $1}')
            STORED_HASH=""
            [ -f "$MODDIR/.current_hash" ] && STORED_HASH=$(cat "$MODDIR/.current_hash")
            
            if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
                log_msg "Modification detected! Restoring..."
                restore_config
            fi
        else
            # File was deleted, recreate it
            log_msg "File deleted! Recreating..."
            restore_config
        fi
    done
else
    log_msg "inotifywait not available, using polling method"
    
    # Fallback: poll every 2 seconds
    while true; do
        sleep 2
        
        if [ -f "$TARGET_FILE" ]; then
            CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
            STORED_HASH=""
            [ -f "$MODDIR/.current_hash" ] && STORED_HASH=$(cat "$MODDIR/.current_hash")
            
            if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
                log_msg "Modification detected (polling)! Restoring..."
                restore_config
            fi
        else
            log_msg "File missing (polling)! Recreating..."
            restore_config
        fi
    done
fi
