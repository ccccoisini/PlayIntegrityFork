# Don't flash in recovery!
if ! $BOOTMODE; then
    ui_print "*********************************************************"
    ui_print "! Install from recovery is NOT supported"
    ui_print "! Recovery sucks"
    ui_print "! Please install from Magisk / KernelSU / APatch app"
    abort    "*********************************************************"
fi

# Error on < Android 8
if [ "$API" -lt 26 ]; then
    abort "! You can't use this module on Android < 8.0"
fi

check_zygisk() {
    local MAGISK_DIR="/data/adb/magisk"
    local ZYGISK_MSG="Zygisk is not enabled. Please either:
    - Enable Zygisk in Magisk settings
    - Install ZygiskNext or ReZygisk module"

    # Check if Zygisk module exists
    if find /data/adb/modules /data/adb/modules_update -name "libzygisk.so" | grep -q .; then
        return 0
    fi

    # If Magisk is installed, check Zygisk settings
    if [ -d "$MAGISK_DIR" ]; then
        # Query Zygisk status from Magisk database
        local ZYGISK_STATUS
        ZYGISK_STATUS=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk';")

        # Check if Zygisk is disabled
        if [ "$ZYGISK_STATUS" = "value=0" ]; then
            abort "$ZYGISK_MSG"
        fi
    else
        abort "$ZYGISK_MSG"
    fi
}

# Module requires Zygisk to work
check_zygisk

# safetynet-fix module is obsolete and it's incompatible with PIF
SNFix="/data/adb/modules/safetynet-fix"
if [ -d "$SNFix" ]; then
    ui_print "! safetynet-fix module is obsolete and it's incompatible with PIF, it will be removed on next reboot"
    ui_print "! Do not install it"
    touch "$SNFix"/remove
fi

# playcurl warn
if [ -d "/data/adb/modules/playcurl" ]; then
    ui_print "! playcurl may overwrite fingerprint with invalid one, be careful!"
fi

# MagiskHidePropsConf module is obsolete in Android 8+ but it shouldn't give issues
if [ -d "/data/adb/modules/MagiskHidePropsConf" ]; then
    ui_print "! WARNING, MagiskHidePropsConf module may cause issues with PIF."
fi

# Preserve previous setting
if [ -f "/data/adb/modules/playintegrityfix/system.prop" ]; then
    cp -af /data/adb/modules/playintegrityfix/system.prop "$MODPATH/system.prop"
fi

# give exec perm to autopif.sh
chmod +x "$MODPATH/autopif.sh"
chmod +x "$MODPATH/autopif_ota.sh"

# Clean up
for pkg in com.google.android.gms com.android.vending; do
    for dir in "/data/user_de/0/$pkg" "/data/data/$pkg"; do
        [ -d "$dir" ] || continue
        for artifact in libinject.so classes.dex pif.prop; do
            [ -f "$dir/$artifact" ] && rm -f "$dir/$artifact"
        done
    done
done

# ---- [install-and-use] Auto setup (TEESimulator-RS companion) ----
# 1) Enable the TrickyStore/TEESimulator security-patch auto-sync flag.
# 2) Install the SHIPPED stable fingerprint as /data/adb/pif.prop instead of
#    fetching a random Pixel Canary: public canaries get revoked by Google in
#    waves and come back all-red, while the shipped stable Pixel build is
#    verified to pass MEETS_DEVICE_INTEGRITY out of the box. An existing
#    non-canary pif.prop (a deliberate user choice) is left untouched;
#    autopif.sh remains available for a manual refresh (WebUI / shell).
if [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; then
    export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"
fi
if [ -d /data/adb/tricky_store ]; then
    touch /data/adb/tricky_store/pif_auto_security_patch
fi
pif_is_canary() {
    grep '^FINGERPRINT=' "$1" 2>/dev/null | head -n1 | grep -q ':CANARY/'
}
if [ -s "$MODPATH/pif.prop" ]; then
    if [ ! -s /data/adb/pif.prop ] || pif_is_canary /data/adb/pif.prop; then
        cp -af "$MODPATH/pif.prop" /data/adb/pif.prop
        ui_print "- Installed shipped stable fingerprint:"
    else
        ui_print "- Keeping existing pif.prop fingerprint:"
    fi
    ui_print "  $(grep '^FINGERPRINT=' /data/adb/pif.prop 2>/dev/null | head -n1 | cut -c1-70)"
fi
ui_print "- Syncing SECURITY_PATCH into TEESimulator/TrickyStore..."
if sh "$MODPATH/security_patch.sh" > "$MODPATH/autopif_install.log" 2>&1; then
    ui_print "  system/boot/vendor = $(grep '^SECURITY_PATCH=' /data/adb/pif.prop 2>/dev/null | cut -d= -f2)"
else
    ui_print "  sync skipped (see autopif_install.log); service.sh retries at boot."
fi
