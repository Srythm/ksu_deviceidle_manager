#!/system/bin/sh
# DeviceIdle Manager - service.sh
# Continuous protection + runtime sync for deviceidle.xml

MODDIR=${0%/*}
TARGET_FILE="/data/system/deviceidle.xml"
ACTIVE_FILE="$MODDIR/active/deviceidle.xml"
LIST_FILE="$MODDIR/active/packages.list"
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

# Restore function - applies our managed config
restore_config() {
    [ -x "$MANAGER" ] && sh "$MANAGER" apply
}

# Runtime sync: apply whitelist via cmd deviceidle + appops
# This is CRITICAL: the XML file alone is not enough; we must also
# tell the running DeviceIdleController and AppOpsManager to update.
runtime_sync() {
    if [ ! -f "$LIST_FILE" ]; then
        return 0
    fi

    log_msg "Runtime sync starting..."

    while read -r pkg; do
        [ -z "$pkg" ] && continue

        # 1. Add to DeviceIdleController runtime whitelist (battery optimization)
        if cmd deviceidle whitelist +"$pkg" >/dev/null 2>&1; then
            log_msg "Runtime whitelist: $pkg"
        elif dumpsys deviceidle whitelist +"$pkg" >/dev/null 2>&1; then
            log_msg "Runtime whitelist (dumpsys): $pkg"
        fi

        # 2. Allow app to run in background via AppOps
        if cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1; then
            log_msg "AppOps RUN_ANY_IN_BACKGROUND allow: $pkg"
        fi

        # 3. Also set RUN_IN_BACKGROUND for older Android versions
        if cmd appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1; then
            log_msg "AppOps RUN_IN_BACKGROUND allow: $pkg"
        fi
    done < "$LIST_FILE"

    log_msg "Runtime sync complete"
}

# Initial restore
[ -x "$MANAGER" ] && sh "$MANAGER" backup-once
restore_config

# Wait for system services to be ready before runtime sync
sleep 5
runtime_sync

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
                # Re-apply runtime sync after restore
                sleep 1
                runtime_sync
            fi
        else
            # File was deleted, recreate it
            log_msg "File deleted! Recreating..."
            restore_config
            sleep 1
            runtime_sync
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
                sleep 1
                runtime_sync
            fi
        else
            log_msg "File missing (polling)! Recreating..."
            restore_config
            sleep 1
            runtime_sync
        fi
    done
fi
