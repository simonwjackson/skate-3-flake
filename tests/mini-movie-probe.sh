#!/usr/bin/env nix-shell
#! nix-shell -i bash -p coreutils gnugrep procps
# Run with the target's bash. This script never invokes Nix or builds software.
# Arguments: native|fallback|disabled, exact prebuilt launcher, evidence directory.
set -euo pipefail
mode=${1:?native|fallback|disabled}
out=${2:?prebuilt store path}
evidence=${3:?new evidence directory}
validation=${4:-}
observe_seconds=${5:-0}
[[ "$observe_seconds" =~ ^[0-9]+$ ]] && (( observe_seconds <= 180 ))
extra_env=()
if [[ -n "$validation" ]]; then
 [[ -f "$validation/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json" ]]
 extra_env+=(--setenv="VK_LAYER_PATH=$validation/share/vulkan/explicit_layer.d")
fi
case "$mode" in
 native) native=true; fallback=true ;;
 fallback) native=false; fallback=true ;;
 disabled) native=false; fallback=false ;;
 *) exit 64 ;;
esac
[[ "$out" == /nix/store/* && -x "$out/bin/skate3" ]]
if pgrep -x .skate3-wrapped >/dev/null; then echo 'Refusing: game already running'; exit 65; fi
mkdir -m 700 "$evidence"
settings=/home/korri/.local/share/skate3/settings.toml
log=/home/korri/.local/state/skate3/logs/skate3.log
cp -p "$settings" "$evidence/settings.before.toml"
cp -p "$log" "$evidence/log.before.txt"
cleanup() {
  systemctl stop skate3-movie-probe.service || true
  cp -p "$settings" "$evidence/settings.after.toml"
  cp -p "$evidence/settings.before.toml" "$settings"
  cp -p "$log" "$evidence/game.log"
  journalctl -u skate3-movie-probe.service --since "$started" --no-pager > "$evidence/unit.log"
  journalctl -k --since "$started" --no-pager > "$evidence/kernel.log"
  systemctl reset-failed skate3-movie-probe.service 2>/dev/null || true
}
trap cleanup EXIT
started=$(date --iso-8601=seconds)
cat /proc/sys/kernel/random/boot_id > "$evidence/boot-id"
# Explicit low settings avoid desktop defaults on this 6 GB device.
printf '%s\n' \
 'fullscreen = true' 'vsync = true' "input_backend = 'sdl'" \
 'show_fps_counter = true' 'resolution_scale = 1' \
 'draw_resolution_scale_x = 1' 'draw_resolution_scale_y = 1' \
 'skate3_native_render_scene = true' 'skate3_native_render_scene_msaa = 1' \
 'skate3_native_render_scene_ssao = false' 'skate3_native_render_scene_ssr = false' \
 'skate3_native_render_scene_hdr = false' 'skate3_native_render_scene_bloom = false' \
 'skate3_native_render_scene_shafts = false' 'skate3_native_render_scene_haze = false' \
 'skate3_native_render_scene_shadows = false' 'skate3_draw_distance_scale = 1.0' \
 'skate3_lod_distance_scale = 1.0' 'skate3_guest_fps_cap = 30.0' \
 'skate3_guest_fps_cap_auto = false' \
 "skate3_native_render_scene_fmv_native = $native" \
 "skate3_native_render_scene_fmv_yield = $fallback" > "$settings"
if [[ -n "$validation" ]]; then printf '%s\n' 'vulkan_validation_enabled = true' >> "$settings"; fi
chown korri:korri "$settings"
# New log excludes earlier failures. The previous log remains in evidence.
truncate -s 0 "$log"
systemd-run --unit=skate3-movie-probe --collect \
 -p User=korri -p Group=korri -p OOMScoreAdjust=1000 -p MemoryMax=3G \
 -p TimeoutStopSec=5 -p KillMode=mixed \
 --setenv=HOME=/home/korri --setenv=USER=korri \
 --setenv=XDG_RUNTIME_DIR=/run/user/1000 \
 --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
 --setenv=DISPLAY=:0 --setenv=GDK_BACKEND=x11 --setenv=SDL_VIDEODRIVER=x11 \
 "${extra_env[@]}" "$out/bin/skate3"
triggered=false
for ((i=0;i<60;i++)); do
 if ! systemctl is-active --quiet skate3-movie-probe.service; then
  echo 'FAIL: game exited before movie capture'; exit 1
 fi
 if grep -qE 'FMV rendering NATIVELY|FMV playing - yielding|video quad skipped' "$log"; then
  triggered=true; break
 fi
 sleep 1
done
if ! $triggered; then echo 'FAIL: movie path not reached'; exit 1; fi
grep -E 'FMV|video quad skipped' "$log" | tail -4
sleep 3
grim=$(find /nix/store -maxdepth 3 -path '*-grim-*/bin/grim' -print -quit)
[[ -n "$grim" ]]
for n in 1 2 3; do
 if ! systemctl is-active --quiet skate3-movie-probe.service; then echo 'FAIL: game exited during movie'; exit 1; fi
 runuser -u korri -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 "$grim" "/tmp/movie-probe-$n.png"
 cp "/tmp/movie-probe-$n.png" "$evidence/frame-$n.png"
 sha256sum "$evidence/frame-$n.png"
 sleep 2
done
if journalctl -k --since "$started" --no-pager | grep -qiE 'gpu fault|hangcheck'; then echo 'FAIL: GPU fault'; exit 1; fi
if journalctl -u skate3-movie-probe.service --since "$started" --no-pager | grep -q 'VUID-VkPipelineLayoutCreateInfo-setLayoutCount-00286'; then
 echo 'FAIL: descriptor layout exceeds device limit'; exit 1
fi
if cmp -s "$evidence/frame-1.png" "$evidence/frame-2.png" && cmp -s "$evidence/frame-2.png" "$evidence/frame-3.png"; then
 echo 'FAIL: frozen movie presentation'; exit 1
fi
echo 'PASS: changing presentation during movie; inspect captured frames to confirm movie content'
for ((elapsed=0;elapsed<observe_seconds;elapsed+=10)); do
 sleep 10
 if ! systemctl is-active --quiet skate3-movie-probe.service; then echo 'FAIL: game exited after movie'; exit 1; fi
 runuser -u korri -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 "$grim" /tmp/movie-probe-after.png
 cp /tmp/movie-probe-after.png "$evidence/after-$((elapsed+10)).png"
done
if journalctl -k --since "$started" --no-pager | grep -qiE 'gpu fault|hangcheck'; then echo 'FAIL: GPU fault after movie'; exit 1; fi
