#!/system/bin/sh
# DeviceIdle Manager - action.sh
# Quick status check when action button is pressed

MODDIR=${0%/*}
TARGET_FILE="/data/system/deviceidle.xml"
ACTIVE_FILE="$MODDIR/active/deviceidle.xml"
BACKUP_FILE="$MODDIR/backup/original_deviceidle.xml"
MANAGER="$MODDIR/manager.sh"

echo "========================================"
echo "   DeviceIdle Manager Status"
echo "========================================"
echo ""

if [ -f "$TARGET_FILE" ]; then
    echo "[✓] Target file exists: $TARGET_FILE"
    ls -laZ "$TARGET_FILE"
    echo ""
    
    # Check if protected by immutable flag
    if lsattr "$TARGET_FILE" 2>/dev/null | grep -q 'i'; then
        echo "[✓] File is protected (immutable flag set)"
    else
        echo "[!] File is NOT protected (immutable flag not set)"
    fi
    echo ""
    
    # Show count of whitelisted apps
    if [ -x "$MANAGER" ]; then
        COUNT=$(sh "$MANAGER" list 2>/dev/null | wc -l)
    else
        COUNT=$(grep -oE '(<wl[^>]* n=|package(Name)?=)"[^"]+"' "$TARGET_FILE" 2>/dev/null | wc -l)
    fi
    echo "[i] Whitelisted apps: $COUNT"
else
    echo "[✗] Target file NOT found!"
fi

echo ""

if [ -f "$BACKUP_FILE" ]; then
    echo "[✓] Original backup exists"
else
    echo "[!] Original backup not found"
fi

if [ -f "$ACTIVE_FILE" ]; then
    echo "[✓] Active config exists"
else
    echo "[✗] Active config missing!"
fi

if [ -f "$MODDIR/daemon.pid" ]; then
    PID=$(cat "$MODDIR/daemon.pid")
    if kill -0 "$PID" 2>/dev/null; then
        echo "[✓] Protection daemon running (PID: $PID)"
    else
        echo "[!] Daemon PID file exists but process not running"
    fi
else
    echo "[!] Daemon PID file not found"
fi

if [ -x "$MANAGER" ]; then
    echo ""
    echo "[i] Manager status:"
    sh "$MANAGER" status 2>/dev/null
fi

echo ""
echo "========================================"

# Pause to show output
sleep 3
