#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 gcc spirv-tools git patch
"""Run: ./tests/packed-descriptors.py SDK_REPO SHADER_HEADER [--check-mutations]

Read the pinned SDK revision from its local git database and apply the package
patch. Extract and compile its actual RemapTableDescriptorSets function and
constants (Buku313 19050db). Test every uint32_t shader
array in the supplied skate3_native_shaders_spirv.h, then validate both original
and output modules with spirv-val for Vulkan 1.1, the header's compiler target.

Necessary but not sufficient: this host-only test does NOT verify Vulkan layout,
descriptor writes, command bindings, device limits, or actual movie playback.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def one(pattern, text):
    matches = re.findall(pattern, text, re.MULTILINE | re.DOTALL)
    require(len(matches) == 1, f"Expected one source match: {pattern!r}")
    return matches[0]


def extract(sdk):
    source = (sdk / "src/graphics/vulkan/native_rhi_vulkan.cpp").read_text()
    api = (sdk / "include/rex/graphics/native_rhi.h").read_text()
    size = one(r"^(\s*inline constexpr uint32_t kMaxTextureTableSize = [^;]+;)", api)
    constants = [one(rf"^(\s*static constexpr uint32_t {name} = [^;]+;)", source)
                 for name in ("kTableSetIndex", "kTableBindingStride")]
    # The closing brace has the same indentation as the declaration. Nested
    # braces cannot end the extraction. Fail closed if the source shape changes.
    function = one(r"^  (static bool RemapTableDescriptorSets\(.*?^  \})", source)
    return ("namespace nrhi {\n" + size + "\n}\n"
            "struct NrBindingLayoutVulkan {\n" + "\n".join(constants) + "\n};\n"
            + function + "\n")


def shaders(header):
    text = header.read_text()
    names = re.findall(r"\buint32_t\s+(\w+)\s*\[\s*\]\s*=", text)
    arrays = re.findall(r"\buint32_t\s+(\w+)\s*\[\s*\]\s*=\s*\{([^}]+)\};", text)
    require(names and names == [name for name, _ in arrays], "Did not extract every shader array")
    require(len(set(names)) == len(names), "Duplicate shader names")
    result = {}
    for name, body in arrays:
        tokens = [token.strip() for token in body.split(",") if token.strip()]
        require(all(re.fullmatch(r"0x[0-9a-fA-F]+", token) for token in tokens),
                f"Unexpected initializer in {name}")
        result[name] = tuple(int(token, 16) for token in tokens)
    require("k_overlay2d_ps_yuv2d" in result, "Missing real YUV shader")
    return result


def decorations(words):
    require(len(words) >= 5 and words[0] == 0x07230203, "Not SPIR-V")
    values, positions = {}, {}
    offset = 5
    while offset < len(words):
        length, opcode = words[offset] >> 16, words[offset] & 0xffff
        require(length and offset + length <= len(words), "Malformed instruction")
        if opcode == 71 and length >= 4 and words[offset + 2] in (33, 34):
            target, kind, value = words[offset + 1:offset + 4]
            key = (target, kind)
            require(key not in values, "Duplicate descriptor decoration")
            values[key], positions[key] = value, offset + 3
        offset += length
    ids = {target for target, _ in values}
    require(all((target, 33) in values and (target, 34) in values for target in ids),
            "Missing Binding/DescriptorSet pair")
    return {target: (values[target, 34], values[target, 33]) for target in ids}, positions


def check_mapping(name, before, after, returned):
    old, positions = decorations(before)
    new, new_positions = decorations(after)
    require(len(before) == len(after), f"{name}: module size changed")
    require(positions == new_positions, f"{name}: decoration structure changed")
    require(returned == any(s >= 1 for s, _ in old.values()), f"{name}: wrong return value")
    require(all(s <= 1 for s, _ in new.values()), f"{name}: old descriptor set survives (>=2)")
    require(len(set(new.values())) == len(new), f"{name}: descriptor mapping collision")
    permitted = set()
    for target, (old_set, old_binding) in old.items():
        require(0 <= old_set <= 6, f"{name}: unexpected original set {old_set}")
        require(old_set == 0 or old_binding < 8, f"{name}: table binding exceeds stride")
        # An independent expected-value oracle, never used to produce the output.
        expected = (old_set, old_binding) if old_set == 0 else (1, (old_set - 1) * 8 + old_binding)
        require(new[target] == expected,
                f"{name}: id {target} {(old_set, old_binding)} -> {new[target]}, expected {expected}")
        if old_set:
            permitted.update((positions[target, 33], positions[target, 34]))
    require(all(a == b for i, (a, b) in enumerate(zip(before, after)) if i not in permitted),
            f"{name}: modified words outside texture descriptor decorations (including set 0)")
    if name == "k_overlay2d_ps_yuv2d":
        v_ids = [target for target, pair in old.items() if pair == (4, 0)]
        require(len(v_ids) == 1 and new[v_ids[0]] == (1, 24), "YUV V plane must map (4,0) -> (1,24)")
    return {s for s, _ in old.values()}


def compile_test(tree, extracted):
    (tree / "packed-descriptors-extracted.inc").write_text(extracted)
    executable = tree / "packed-descriptors-test"
    run("g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2",
        "-I", str(tree), str(HERE / "packed-descriptors.cpp"), "-o", str(executable))
    return executable


def execute(executable, tree, name, words, validate=False):
    original = struct.pack(f"<{len(words)}I", *words)
    input_path, output_path = tree / f"{name}.original.spv", tree / f"{name}.packed.spv"
    input_path.write_bytes(original)
    result = run(str(executable), str(input_path), str(output_path), capture_output=True)
    require(input_path.read_bytes() == original, f"{name}: original file modified")
    output = output_path.read_bytes()
    require(len(output) % 4 == 0, f"{name}: unaligned output")
    require(result.stdout.strip() in ("true", "false"), f"{name}: invalid harness output")
    seen = check_mapping(name, words, struct.unpack(f"<{len(output) // 4}I", output),
                         result.stdout.strip() == "true")
    if validate:
        for path in (input_path, output_path):
            run("spirv-val", "--target-env", "vulkan1.1", str(path))
    return seen


def all_slots():
    # Exercise every legal slot, including slots not used by the real shaders.
    # Put Binding before DescriptorSet to verify the real two-pass behavior.
    words = [0x07230203, 0x00010300, 0, 100, 0]
    for set_ in range(7):
        for binding in range(8):
            target = set_ * 8 + binding + 1
            words.extend((0x00040047, target, 33, binding,
                          0x00040047, target, 34, set_))
    return tuple(words)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path, help="local upstream SDK git repository")
    parser.add_argument("header", type=Path, help="actual precompiled shader header")
    parser.add_argument("--check-mutations", action="store_true")
    args = parser.parse_args()
    require(sys.byteorder == "little", "C++ binary harness requires a little-endian host")
    require(shutil.which("spirv-val"), "spirv-val is required; run via the Nix shebang")
    root = HERE.parent
    pin = next(p for p in json.loads((root / "sources.json").read_text())
               if p["path"] == "third_party/rexglue-sdk")["rev"]
    blobs = shaders(args.header)
    with tempfile.TemporaryDirectory(prefix="packed-descriptors-test-") as tmp:
        tree = Path(tmp)
        for name in ("src/graphics/vulkan/native_rhi_vulkan.cpp",
                     "include/rex/ui/vulkan/device.h", "src/ui/vulkan/vulkan_device.cpp",
                     "include/rex/graphics/native_rhi.h"):
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(run("git", "-C", str(args.sdk), "show", f"{pin}:{name}",
                                capture_output=True).stdout)
        for name in ("rexglue-vulkan-null-pipeline-guard.patch",
                     "rexglue-vulkan-packed-tables.patch"):
            run("patch", "--batch", "--fuzz=0", "-p1", "-i", str(root / "patches" / name), cwd=tree)
        extracted = extract(tree)
        executable = compile_test(tree, extracted)
        run(str(executable))
        sets = set()
        for name, words in blobs.items():
            sets.update(execute(executable, tree, name, words, validate=True))
        require(sets == set(range(7)), f"Real shader set coverage changed: {sorted(sets)}")
        execute(executable, tree, "all-slots", all_slots())
        print(f"PASS: all {len(blobs)} real shader blobs; {len(blobs) * 2} spirv-val checks; "
              "sets 0..6; 56 synthetic slots; YUV V (4,0) -> (1,24)", flush=True)
        if args.check_mutations:
            mutations = (
                ("old set >=4 survives", "(*out)[i + 3] = NrBindingLayoutVulkan::kTableSetIndex;",
                 "(*out)[i + 3] = it->second >= 4 ? it->second : NrBindingLayoutVulkan::kTableSetIndex;",
                 "old descriptor set survives"),
                ("texture binding collision", "(it->second - 1) * NrBindingLayoutVulkan::kTableBindingStride",
                 "0u * NrBindingLayoutVulkan::kTableBindingStride", "descriptor mapping collision"),
            )
            for label, old, new, diagnostic in mutations:
                require(extracted.count(old) == 1, f"Mutation target changed: {label}")
                executable = compile_test(tree, extracted.replace(old, new))
                try:
                    execute(executable, tree, "k_overlay2d_ps_yuv2d", blobs["k_overlay2d_ps_yuv2d"])
                except RuntimeError as error:
                    require(diagnostic in str(error), f"Unexpected mutation failure: {error}")
                    print(f"CAUGHT {label}: {error}", flush=True)
                else:
                    raise RuntimeError(f"Mutation not caught: {label}")
        print("Host-only: Vulkan layouts, descriptor writes/binds and device playback remain unverified.")


if __name__ == "__main__":
    main()
