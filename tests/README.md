# Movie regression checks

Run these on a build machine. They need local upstream Git repositories, but no game files.

```sh
./tests/movie-fallback.py /path/to/skate3recomp --check-mutations
./tests/packed-descriptors.py /path/to/rexglue-skate3 \
  /path/to/skate3recomp/src/native/shaders/spirv/skate3_native_shaders_spirv.h \
  --check-mutations
```

The scripts read pinned SDK/game source from the local Git object database and apply the package patches in temporary directories. They compile extracted production functions, not copies of their algorithms. Each script uses its Nix shebang to obtain host tools.

| Check | What it proves | What it does not prove |
|---|---|---|
| `movie-fallback.py` | The actual `YieldForMovie` holds across slow heartbeat and stale-quad intervals, releases after a genuine end, and handles the optional timeout and next session. It checks Linux and Android defaults. | GPU presentation, decoder throughput, or input routing. |
| `packed-descriptors.py` | All supplied native shader blobs map texture sets into set 1 without changing buffers, samplers, or other instructions. It validates original and remapped SPIR-V with `spirv-val`. | Vulkan layout construction, descriptor writes, resource lifetime, or device playback. |

Mutation checks deliberately restore the old 500 ms heartbeat, cancel the latch, permit timeout re-entry, retain unsupported descriptor sets, or create binding collisions. The corresponding checks must fail.

## Mini V2 runtime check

Host tests cannot replace this check. Build on an ARM64 builder, then deliver the exact output privately with trusted Nix signatures. Do not build on the Mini or publish the game output.

The runtime probe starts the supplied prebuilt launcher as the `korri` user in its existing Xwayland session. It temporarily replaces Skate 3 settings with low settings, captures movie frames and logs, stops the game, and restores the previous settings. It refuses an already-running game and an existing evidence directory. Its transient service has a 3 GiB memory limit and an OOM preference that protects the portal.

Copy `mini-movie-probe.sh` to the Mini, then invoke it with the target's existing `bash`. Do not execute its Nix shebang on the target.

```sh
# On the Mini, after copying the script and signed prebuilt output:
bash /root/mini-movie-probe.sh native /nix/store/EXACT-skate3 /root/movie-native-run
bash /root/mini-movie-probe.sh fallback /nix/store/EXACT-skate3 /root/movie-fallback-run
```

An optional fourth argument names a prebuilt `vulkan-validation-layers` store path. Deliver that package from a build machine too. A fifth argument adds up to 180 seconds of observation, with captures every ten seconds. Pass an empty fourth argument to observe without validation.

The probe fails if movie entry does not occur, the game exits, a new GPU fault appears, or three successive captures are identical. Changing pixels alone do not prove correct movies: inspect the captures for actual movie content, not merely an updating FPS overlay. Also check movie completion, return to native output, and a repeat launch.

Manual launch does not enable Korri controller routing. Use a korrid/plugin launch for controller and skip acceptance. Do not change input permissions to make this probe interactive.

The probe is specific to the existing Mini installation: `korri` UID 1000, `DISPLAY=:0`, and `WAYLAND_DISPLAY=wayland-1`. It writes only application settings, logs, screenshots, and its named transient service. It does not change firmware, partitions, plugins, or publisher trust.
