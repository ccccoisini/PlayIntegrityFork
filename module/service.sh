MODPATH="${0%/*}"
. "$MODPATH"/common_func.sh

# Conditional sensitive properties

# Magisk Recovery Mode
resetprop_if_match ro.boot.mode recovery unknown
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match vendor.boot.mode recovery unknown

# SELinux
resetprop_if_diff ro.boot.selinux enforcing
# use toybox to protect stat access time reading
if [ "$(toybox cat /sys/fs/selinux/enforce)" = "0" ]; then
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
fi

# Conditional late sensitive properties

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# SafetyNet/Play Integrity + OEM
# avoid bootloop on some Xiaomi devices
resetprop_if_diff ro.secureboot.lockstate locked
# avoid breaking Realme fingerprint scanners
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.realme.lockstate 1
# avoid breaking Oppo fingerprint scanners
resetprop_if_diff ro.boot.vbmeta.device_state locked
# avoid breaking OnePlus display modes/fingerprint scanners
resetprop_if_diff vendor.boot.verifiedbootstate green
# avoid breaking OnePlus/Oppo fingerprint scanners on OOS/ColorOS 12+
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff vendor.boot.vbmeta.device_state locked

# Other
resetprop_if_diff sys.oem_unlock_allowed 0

# ---- [install-and-use] Boot auto refresh (TEESimulator-RS companion) ----
# - No /data/adb/pif.prop, or a stale Pixel Canary fingerprint (older than 35
#   days; they expire in about 6 weeks) -> regenerate via autopif.sh.
# - autopif.sh then syncs the fingerprint's SECURITY_PATCH into
#   /data/adb/tricky_store/security_patch.txt (pif_auto_security_patch flag)
#   and restarts GMS/Play Store, so the new fingerprint takes effect at once.
# - Offline boots keep the existing config untouched.
PIF_LOG="$MODPATH/autopif_boot.log"

pif_fingerprint_stale() {
    local FP LINE YYMMDD BUILD_EPOCH NOW_EPOCH AGE
    FP="$(grep '^FINGERPRINT=' "$1" 2>/dev/null | head -n1 | cut -d= -f2)"
    [ -n "$FP" ] || return 1
    LINE="$(echo "$FP" | awk -F: '{print $4}')"                       # e.g. ZP11.260821.010
    YYMMDD="$(echo "$LINE" | sed 's/^[A-Za-z]*\([0-9]\{6\}\).*/\1/')" # 260821
    echo "$YYMMDD" | grep -qE '^[0-9]{6}$' || return 1
    BUILD_EPOCH="$(busybox date -u -D '%Y%m%d' -d "20$YYMMDD" '+%s' 2>/dev/null)" || return 1
    [ -n "$BUILD_EPOCH" ] || return 1
    NOW_EPOCH="$(date -u '+%s')"
    AGE=$(((NOW_EPOCH - BUILD_EPOCH) / 86400))
    [ "$AGE" -gt 35 ]
}

{
    echo "===== $(date) ====="
    if [ ! -s /data/adb/pif.prop ] || pif_fingerprint_stale /data/adb/pif.prop; then
        echo "[*] refreshing fingerprint (missing or stale)..."
        if sh "$MODPATH/autopif.sh"; then
            echo "[+] fingerprint refreshed: $(grep '^FINGERPRINT=' /data/adb/pif.prop 2>/dev/null | head -n1)"
        else
            echo "[!] autopif failed; keeping existing config"
        fi
    else
        echo "[=] fingerprint current: $(grep '^FINGERPRINT=' /data/adb/pif.prop 2>/dev/null | head -n1)"
    fi
    # Keep the TrickyStore sync flag alive (autopif.sh consults it).
    [ -d /data/adb/tricky_store ] && touch /data/adb/tricky_store/pif_auto_security_patch
} >> "$PIF_LOG" 2>&1
