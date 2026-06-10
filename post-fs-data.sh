#!/system/bin/sh
# DeviceIdle Manager - post-fs-data.sh
# Prepare file protection early in boot

MODDIR=${0%/*}
export MODDIR

[ -x "$MODDIR/manager.sh" ] && sh "$MODDIR/manager.sh" backup-once
[ -x "$MODDIR/manager.sh" ] && sh "$MODDIR/manager.sh" apply
