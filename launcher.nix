# The `skate3` command: picks writable directories, then runs the game.
#
# - Game files live in SKATE3_GAME_DATA_ROOT
#   (default $XDG_DATA_HOME/skate3/game). On first run the game shows a
#   "Select ISO" picker and extracts your Xbox 360 ISO there.
# - Upstream writes logs beside the executable, which is the read-only Nix
#   store, and aborts at startup. --log_file moves them to
#   $XDG_STATE_HOME/skate3/logs.
# - The ISO picker is a modal GTK dialog. Over an X11 fullscreen window it
#   cannot be reached, so the first run (no default.xex yet) starts windowed.
#   Arguments you pass come last and win.
{ writeShellApplication, coreutils, skate3-unwrapped }:

writeShellApplication {
  name = "skate3";
  runtimeInputs = [ coreutils ];
  text = ''
    game="''${SKATE3_GAME_DATA_ROOT:-''${XDG_DATA_HOME:-$HOME/.local/share}/skate3/game}"
    logdir="''${XDG_STATE_HOME:-$HOME/.local/state}/skate3/logs"
    mkdir -p "$game" "$logdir"
    echo "skate3: game data: $game (override with SKATE3_GAME_DATA_ROOT)" >&2
    echo "skate3: logs: $logdir" >&2

    first_run_args=()
    if [ ! -f "$game/default.xex" ]; then
      echo "skate3: game not installed; starting windowed for the ISO picker" >&2
      first_run_args+=(--fullscreen=false)
    fi

    exec ${skate3-unwrapped}/bin/skate3 \
      --game_data_root="$game" \
      --log_file="$logdir/skate3.log" \
      "''${first_run_args[@]}" \
      "$@"
  '';
  meta = skate3-unwrapped.meta // {
    mainProgram = "skate3";
  };
}
