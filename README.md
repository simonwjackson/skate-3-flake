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
| `apps.x86_64-linux.default` | `nix run` target. |

## Update to a new upstream release

Edit `version` and `hash` in `package.nix`. Get the hash from the release's
`sha256:` digest:

```sh
nix hash convert --hash-algo sha256 --to sri <hex digest>
```

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
