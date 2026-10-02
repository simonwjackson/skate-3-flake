#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 gcc git patch
"""Run: ./tests/movie-fallback.py /path/to/pristine/skate3recomp [--check-mutations]

Read the pinned revision from that local git object database, not its working
files. Apply the packaging patch in a temporary tree. Compile the actual
YieldForMovie body with synthetic clock/cvar/global inputs; no algorithm copy.
This is a host-only unit test, not a renderer, ARM64 build, or device test.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = (
    "defaults", "disabled", "heartbeat-gap", "quad-latch", "end-next-session",
    "entry-guards", "native-served", "timeout-next-session", "unbounded",
)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def one(pattern, text):
    matches = re.findall(pattern, text, re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one source match: {pattern!r}")
    return matches[0]


def extract(tree):
    gpu = (tree / "src/skate3_native_scene_gpu.cpp").read_text()
    scene = (tree / "src/skate3_native_scene.cpp").read_text()
    state = (tree / "src/skate3_native_scene_state.h").read_text()
    declarations = []
    definitions = []
    for kind, name in (("BOOL", "skate3_native_render_scene_fmv_yield"),
                       ("INT32", "skate3_native_render_scene_fmv_yield_max_ms")):
        declarations.append(one(rf"^(REXCVAR_DECLARE\([^\n]*\b{name}\);)$", gpu))
        definitions.append(one(
            rf"^(REXCVAR_DEFINE_{kind}\(\s*{name},.*?"
            r"\.lifecycle\(rex::cvar::Lifecycle::kHotReload\);)", scene))
    globals_ = [one(rf"^(inline std::atomic<int64_t> {name}[^\n]*;)$", state)
                for name in ("g_movie_decode_last_ns", "g_movie_native_last_ns",
                             "g_movie_quad_last_ns")]
    function = one(r"^(bool YieldForMovie\(\) \{\n.*?^\})", gpu)
    return "\n".join(declarations + definitions + globals_ + [function]) + "\n"


def compile_test(tree, android):
    executable = tree / "movie-fallback-test"
    run("g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2",
        f"-DREX_PLATFORM_ANDROID={android}", "-I", str(tree),
        str(ROOT / "tests/movie-fallback.cpp"), "-o", str(executable))
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="local upstream git repository")
    parser.add_argument("--check-mutations", action="store_true")
    args = parser.parse_args()
    pin = next(p for p in json.loads((ROOT / "sources.json").read_text())
               if p["path"] == ".")["rev"]
    with tempfile.TemporaryDirectory(prefix="movie-fallback-test-") as tmp:
        tree = Path(tmp)
        (tree / "src").mkdir()
        for name in ("skate3_native_scene.cpp", "skate3_native_scene_gpu.cpp",
                     "skate3_native_scene_state.h"):
            content = run("git", "-C", str(args.source), "show",
                          f"{pin}:src/{name}", capture_output=True).stdout
            (tree / "src" / name).write_text(content)
        run("patch", "--batch", "--fuzz=0", "-p1", "-i",
            str(ROOT / "patches/skate3-movie-fallback.patch"), cwd=tree)
        extracted = extract(tree)
        include = tree / "movie-fallback-extracted.inc"
        include.write_text(extracted)
        for android in (0, 1):
            executable = compile_test(tree, android)
            print(f"REX_PLATFORM_ANDROID={android}", flush=True)
            # Separate processes reset the function's real local static state.
            for scenario in SCENARIOS:
                run(str(executable), scenario)
        if args.check_mutations:
            mutations = (
                ("500 ms heartbeat", "constexpr int64_t kDecoderHoldNs = 1'500'000'000;",
                 "constexpr int64_t kDecoderHoldNs = 500'000'000;", "heartbeat-gap"),
                ("quad cancels latch", "if (s_yielding) {\n    const int32_t max_ms",
                 "if (s_yielding && now_ns - g_movie_quad_last_ns.load() < 500'000'000) {\n"
                 "    const int32_t max_ms", "quad-latch"),
                ("timeout re-entry", "if (s_yield_timed_out) {",
                 "if (s_yield_timed_out && false) {", "timeout-next-session"),
            )
            # Make the old self-cancelling behavior explicit in the latch mutant:
            # if stale, clear the latch before the normal entry test.
            for label, old, new, scenario in mutations:
                if extracted.count(old) != 1:
                    raise RuntimeError(f"Mutation target changed: {label}")
                mutated = extracted.replace(old, new)
                if label == "quad cancels latch":
                    mutated = mutated.replace(
                        "  const int64_t native_ns =",
                        "  s_yielding = false;\n  const int64_t native_ns =")
                include.write_text(mutated)
                executable = compile_test(tree, 0)
                result = subprocess.run([str(executable), scenario], text=True,
                                        capture_output=True)
                if result.returncode != 1 or "FAIL:" not in result.stderr:
                    raise RuntimeError(f"Mutation not caught: {label}\n{result.stderr}")
                print(f"CAUGHT {label}: {result.stderr.strip()}")
        print(f"PASS: {len(SCENARIOS) * 2} scenario/platform runs against {pin}")


if __name__ == "__main__":
    main()
