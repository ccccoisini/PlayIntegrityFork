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
# - Missing /data/adb/pif.prop -> seed from the shipped stable pif.prop, or
#   fall back to autopif.sh when the shipped default is absent.
# - Stale *Pixel Canary* fingerprint (older than 35 days; canaries expire in
#   about 6 weeks) -> regenerate via autopif.sh. Stable fingerprints are never
#   auto-replaced, so a fresh install keeps passing MEETS_DEVICE_INTEGRITY.
# - autopif.sh syncs the fingerprint's SECURITY_PATCH into
#   /data/adb/tricky_store/security_patch.txt (pif_auto_security_patch flag)
#   and restarts GMS/Play Store, so the new fingerprint takes effect at once.
# - Offline boots keep the existing config untouched.
PIF_LOG="$MODPATH/autopif_boot.log"

pif_fingerprint_stale() {
    local FP LINE YYMMDD BUILD_EPOCH NOW_EPOCH AGE
    FP="$(grep '^FINGERPRINT=' "$1" 2>/dev/null | head -n1 | cut -d= -f2)"
    [ -n "$FP" ] || return 1
    # Fingerprint: brand/product:release/build-id/incremental:type/tags
    #   after the first colon: <release>/<build-id>/<incremental>
    #   build-id's 2nd dot field is the YYMMDD build date (ZP11.260821.010 -> 260821)
    LINE="$(echo "$FP" | awk -F: '{print $2}' | cut -d/ -f2)"
    YYMMDD="$(echo "$LINE" | cut -d. -f2)"
    echo "$YYMMDD" | grep -qE '^[0-9]{6}$' || return 1
    BUILD_EPOCH="$(busybox date -u -D '%Y%m%d' -d "20$YYMMDD" '+%s' 2>/dev/null)" || return 1
    [ -n "$BUILD_EPOCH" ] || return 1
    NOW_EPOCH="$(date -u '+%s')"
    AGE=$(((NOW_EPOCH - BUILD_EPOCH) / 86400))
    [ "$AGE" -gt 35 ]
}

pif_fingerprint_is_canary() {
    grep '^FINGERPRINT=' "$1" 2>/dev/null | head -n1 | grep -q ':CANARY/'
}

{
    echo "===== $(date) ====="
    # Seed from the shipped stable fingerprint when nothing is installed yet
    # (fresh install / wiped /data), so boot works without any network fetch.
    if [ ! -s /data/adb/pif.prop ] && [ -s "$MODPATH/pif.prop" ]; then
        cp -af "$MODPATH/pif.prop" /data/adb/pif.prop
        echo "[+] seeded /data/adb/pif.prop from shipped stable fingerprint"
    fi
    if [ ! -s /data/adb/pif.prop ]; then
        echo "[*] no pif.prop and no shipped default; fetching via autopif..."
        if sh "$MODPATH/autopif.sh"; then
            echo "[+] fingerprint refreshed: $(grep '^FINGERPRINT=' /data/adb/pif.prop 2>/dev/null | head -n1)"
        else
            echo "[!] autopif failed; keeping existing config"
        fi
    elif pif_fingerprint_is_canary /data/adb/pif.prop && pif_fingerprint_stale /data/adb/pif.prop; then
        # Only Pixel Canaries expire (~6 weeks) and need a refresh; a stable
        # fingerprint is left alone so installs keep passing out of the box.
        echo "[*] stale Pixel Canary fingerprint; refreshing..."
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
