# ARM64 movie verification

## Cause and changes

On 2026-10-02, the Retroid Pocket Mini V2 reproduced a GPU fault on the first native movie draw. Vulkan validation reported `VUID-VkPipelineLayoutCreateInfo-setLayoutCount-00286`: the layout requested seven sets, but Turnip Adreno 650 permits four. The native YUV shader sampled V from set 4. Valid set indices were 0 through 3.

`rexglue-vulkan-packed-tables.patch` ports only descriptor packing from Buku313 SDK `19050db`. Buffers and samplers stay in set 0. Image tables share set 1, with the matching SPIR-V binding remap. The scene now uses two sets and ten image slots. Existing resource retirement and the null-pipeline guard stay in place.

`skate3-movie-fallback.patch` ports the 1.5-second heartbeat and session latch from `5ae21ad`, plus the optional timeout from `d047216`. The timeout remains disabled by default on Linux. These are game changes, not SDK changes.

The independent GTK repaint fix, `3720dca`, is also required in the tested package base. It makes repaint requests on the UI thread. The movie work does not duplicate that patch.

## Evidence so far

| Check | Result |
|---|---|
| Original native path | GPU null-address read after `FMV rendering NATIVELY`, then graphics-device loss. |
| Original fallback | Three identical captures. Logs alternated between emulated and native output every half second. |
| Packed native diagnostic | Full EA and Black Box movie frames in sequence. No new GPU fault or descriptor-count validation error. |
| Native diagnostic with GTK fix | A 156-second run passed. Captures over 90 seconds show complete skateboarding movie scenes, not only an updating overlay. |
| Latched fallback before GTK fix | Path switching stopped, but the display stayed black with a frozen overlay. |
| Latched fallback with GTK fix | Presentation updates, but the movie contains incomplete image strips. Not accepted as correct playback. |
| Host fallback tests | 18 scenario/platform runs pass. Three deliberate regressions are detected. |
| Host descriptor tests | All 75 real shader blobs pass mapping checks and 150 original/remapped `spirv-val` checks. Two deliberate regressions are detected. |
| Full sandboxed ARM64 package | Build passed, including the real GTK check over 20 cycles. The signed closure verified on the Mini. A 227-second native run passed, with complete movie frames through the final 180-second capture and no new GPU fault. |

The verified release launcher is `/nix/store/n378x2v9crqrahzk6v6965nzvwnak5xi-skate3`. Its native package is `/nix/store/k41yg113gmzas8g29g4k3d8gqppjwhjp-skate3-source-unwrapped-2.0.2`. Fuji built it in the Nix sandbox and signed it with the existing `korri-cache-fuji-1` key. Private delivery preserved signature checks, and `nix store verify --recursive` passed on the Mini. The owner reported no audio/video issues.

The signed diagnostic outputs are private. The initial packed build was `/nix/store/hd0i3jbcymm9m0l8m4cgz9fijgd7qw6b-skate3`; adding the GTK fix produced `/nix/store/i3d8dp7gj23vij51sm0fmh4glbylc8yh-skate3`. Fuji built both. The Mini imported them with signature checks enabled. Recursive store verification passed for the initial output.

Private evidence is under `/tmp/s3arm/` on the development host and `/root/movie-*` on the Mini. Important directories are `movie-baseline-native`, `movie-baseline-fallback`, `movie-native-validation`, `movie-native-packed`, `movie-fallback-latched`, `movie-fallback-gtk`, `movie-native-gtk-long`, and `movie-release-native`. Each contains settings, logs, and captures when the process survived. No game data or generated game code belongs in this repository or a public cache.

## Limits and follow-up

- Forced emulated fallback has a separate image-corruption problem. The timing port does not fix emulated texture/resolve correctness. Native FMV stays enabled by default.
- Validation still reports `VUID-vkDestroySwapchainKHR-swapchain-01282` at startup in both original and patched runs. This is an existing lifetime error, not a clean validation result.
- These tests do not prove gameplay, long-term performance, natural movie completion, all in-game movies, or Odin compatibility. An updating overlay alone is not proof of movie playback.
- Manual launch does not activate Korri controller routing. Plugin integration and controller acceptance belong to the separate ARM64 plugin task.
- Packing complete image tuples increases each descriptor-cache key and can create more cached combinations. Gameplay performance has not been measured.

Run the checks in [tests/README.md](../tests/README.md). The exact sandboxed output passed movie-content and GPU-fault checks. Movie completion, skipping, and controller acceptance still need the normal plugin launch route.
