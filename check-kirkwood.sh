#!/system/bin/sh
# check-kirkwood.sh -- read-only compatibility check for
# ghostlock-kirkwood-oneclick.sh (Google TV Streamer / kirkwood / MT8696).
#
# Usage:
#   adb push check-kirkwood.sh /data/local/tmp/
#   adb shell sh /data/local/tmp/check-kirkwood.sh
#
# This script does not exploit anything and does not modify the device.
# Exit code 0 = compatible with the published bundle, 1 = not compatible.

fail=0
chk() {
  name="$1"; want="$2"; got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS  $name = $got"
  else
    echo "FAIL  $name  want='$want' got='$got'"
    fail=1
  fi
}

echo "== kernel / build"
chk kernel "5.15.180-android14-11-gf55c0c36ffcd-ab13512086" "$(uname -r)"
chk device "kirkwood" "$(getprop ro.product.device)"
chk fingerprint "google/kirkwood/kirkwood:14/UTTK.260317.003/15205007:user/release-keys" \
    "$(getprop ro.build.fingerprint)"
chk security_patch "2026-04-01" "$(getprop ro.build.version.security_patch)"
chk sdk "34" "$(getprop ro.build.version.sdk)"

echo "== boot chain / userspace"
chk verifiedboot "green" "$(getprop ro.boot.verifiedbootstate)"
chk vbmeta_state "locked" "$(getprop ro.boot.vbmeta.device_state)"
case "$(getprop ro.product.cpu.abilist)" in
  *armeabi-v7a*) echo "PASS  abilist = $(getprop ro.product.cpu.abilist)" ;;
  *) echo "FAIL  abilist missing armeabi-v7a: $(getprop ro.product.cpu.abilist)"; fail=1 ;;
esac
echo "     selinux now = $(getenforce 2>/dev/null) (bundle requires enforcing before the run)"
echo "     slot_suffix = $(getprop ro.boot.slot_suffix)"

echo "== memory / perf knobs"
mem_kb=$(grep MemTotal /proc/meminfo | tr -dc '0-9')
if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 3500000 ] 2>/dev/null; then
  echo "PASS  MemTotal = ${mem_kb} kB (4 GB class)"
else
  echo "FAIL  MemTotal = ${mem_kb:-unknown} kB (expected ~4 GB)"; fail=1
fi
pep=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
if [ "$pep" = "-1" ] || [ "$pep" = "0" ] || [ "$pep" = "1" ]; then
  echo "PASS  perf_event_paranoid = $pep"
else
  echo "WARN  perf_event_paranoid = ${pep:-unknown} (shell perf may be restricted)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "VERDICT: COMPATIBLE with ghostlock-kirkwood-oneclick.sh"
  echo "         sha256 a4968b9bb9fc451066e060d66739a2af5e05640827df8ddcd1ed46b32beb1150"
  exit 0
else
  echo "VERDICT: NOT COMPATIBLE -- do not run the bundle."
  echo "         See README.md section \"If the chain does not work / 适配指南\"."
  exit 1
fi
