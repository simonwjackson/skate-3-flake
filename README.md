# skate-3-flake

A Nix flake that runs [skate3recomp](https://github.com/mchughalex/skate3recomp)
on NixOS. skate3recomp is an unofficial native recompilation of the Xbox 360
version of Skate 3.

The flake does not compile the game. It fetches the official prebuilt
`Skate3Recomp-Linux.zip` and patches it to use Nix libraries. The binary is
otherwise unchanged.

This flake contains no game files. You need an ISO of your own Xbox 360 copy
of Skate 3. The PS3 version does not work.

## Run

```sh
nix run github:simonwjackson/skate-3-flake
```

On the first run, the game opens in a window and asks for your ISO. It
extracts the ISO, then downloads Title Update 3 from Microsoft, so the first
run needs internet. Later runs start in fullscreen.

To install without the picker, for example over SSH, set two variables. The
game reads them itself:

```sh
SKATE3_INSTALL_ISO=/path/to/skate3.iso SKATE3_INSTALL_TU=download \
  nix run github:simonwjackson/skate-3-flake
```

`SKATE3_INSTALL_TU` also accepts a path to the title update package
(`TU_12K2276_000000C000000.00000000000O3`) if the download fails.

You need a working Vulkan driver at `/run/opengl-driver`. On NixOS, set
`hardware.graphics.enable = true;`.

## Install

```nix
{
  inputs.skate3.url = "github:simonwjackson/skate-3-flake";
}
```

```nix
environment.systemPackages = [ inputs.skate3.packages.x86_64-linux.default ];
```

The package carries an unfree license (upstream publishes none, and the
binary is generated from EA's game code). The flake allows it for its own
outputs, so you do not need `allowUnfree`.

## Files

| What | Where | Override |
|---|---|---|
| Game files | `$XDG_DATA_HOME/skate3/game` | `SKATE3_GAME_DATA_ROOT` |
| Settings and saves | `$XDG_DATA_HOME/skate3` | |
| Logs | `$XDG_STATE_HOME/skate3/logs` | |
| DLC | `dlc/` inside the game files folder | |

Arguments after `--` go to the game, for example
`nix run github:simonwjackson/skate-3-flake -- --fullscreen=false`.

## Outputs

| Output | What it is |
|---|---|
| `packages.x86_64-linux.default`, `.skate3` | The `skate3` launcher. It picks writable folders, then starts the game. |
| `packages.x86_64-linux.skate3-unwrapped` | The patched upstream binary and `librexruntime.so`. |
| `packages.x86_64-linux.skate3-source` | The same launcher around the source build. |
| `packages.x86_64-linux.skate3-source-unwrapped` | The source build. |
| `apps.x86_64-linux.default`, `.source` | `nix run` targets for the release and the source build. |

## Update to a new upstream release

Edit `version` and `hash` in `package.nix`. Get the hash from the release's
`sha256:` digest:

```sh
nix hash convert --hash-algo sha256 --to sri <hex digest>
```

## Build from source

`packages.x86_64-linux.skate3-source` builds the same v2.0.2 from source,
as a base for local patches. Static recompilation turns the game's own code
into C++ at build time, so the build needs two files from your Xbox 360 disc.
After a normal install they are in the game folder. Add them to the store by
hash, then build:

```sh
nix-store --add-fixed sha256 \
  ~/.local/share/skate3/game/default.xex \
  ~/.local/share/skate3/game/data/webkit/EAWebkit.xex
nix run github:simonwjackson/skate-3-flake#source
```

The build fetches Title Update 3 from the same URL the game's installer
uses. On a Ryzen 5 7600X it takes about 10 minutes.

The result contains code generated from EA's game. Do not push it to a
binary cache that other people can read.

Differences from the upstream release build:

| What | Why |
|---|---|
| imgui 1.92.5 plus `patches/imgui-rasterizer-gamma.patch` | The rexglue fork pins imgui commit `cdda6234`, which was never published. The patch rebuilds the one API the fork uses, `ImFontConfig::RasterizerGamma`. Other unpublished imgui changes, if any, are missing. Menu text may differ slightly. |
| `patches/rexglue-codegen-quick-exit.patch` | The codegen tool crashes in static destructors after it finishes, which fails the build step. The patch exits without running them. |
| Each submodule pinned in `sources.json` | Needed because of the broken imgui pin. |
| Version string `2.0.2-nix` | The store copy has no `.git`. |
| `patches/skate3-display-aspect.patch`, `patches/rexglue-display-aspect.patch` | Taller-than-16:9 displays. See below. |

### Taller screens (4:3, foldables)

Upstream's ultrawide mode only makes the picture wider. The source build
also makes it taller: on a screen narrower than 16:9 the game shows more
above and below (Vert+) and keeps the horizontal view, so the 3D scene fills
the screen. The HUD, menus and movies stay 16:9, centred, with bars above
and below.

On Linux the game cannot read the fullscreen monitor size, so set the
aspect yourself in `~/.local/share/skate3/settings.toml`. For a 2448x1848
screen:

```toml
skate3_ultrawide = true
skate3_ultrawide_target_aspect = 1.3246753
```

The setting accepts 1.0 to 8.0 and needs a restart. In the settings menu the
option is called Aspect Ratio, Match Display. It needs the native renderer,
which is the default.

The guest output keeps its width and grows in height, so a taller screen
costs more GPU time. At render scale 3 a 4:3 frame is 3840x2900. Render
scale 2 (2560x1932) is close to the size of a 2448x1848 screen.

Known limits: the edge snap for 2D art works only at the screen edge, so
art that reaches the edge of the 16:9 band can show a sub-pixel seam there.
Shadows and world streaming were tested only briefly, on one free-play
start position.

## Upstream known issues on Linux

- [#104](https://github.com/mchughalex/skate3recomp/issues/104): the native
  Linux build presents at 60 fps on some high refresh displays.
- [#151](https://github.com/mchughalex/skate3recomp/issues/151): controllers
  do not work for some users.

The Windows build under Proton avoids both.

## Credits

- [mchughalex/skate3recomp](https://github.com/mchughalex/skate3recomp), the
  recompilation and the release this flake fetches.
- [JuiceyDew/Skate3-Recomp-Nix](https://github.com/JuiceyDew/Skate3-Recomp-Nix),
  the first NixOS packaging. This flake follows its approach.
