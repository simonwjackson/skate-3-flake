# Skate 3 recomp built from source.
#
# Static recompilation turns the game's own PowerPC code into C++ at build
# time, so this build needs files from your Xbox 360 disc: default.xex and
# data/webkit/EAWebkit.xex. They are taken from the Nix store by hash
# (requireFile). The output contains code generated from EA's game: keep it
# out of any binary cache that other people can read.
#
# Upstream's submodule tree cannot be fetched as is: the Skate rexglue fork
# pins imgui commit cdda6234, which was never published. Every source is
# therefore pinned on its own in sources.json, imgui falls back to 1.92.5,
# and patches/imgui-rasterizer-gamma.patch rebuilds the one API the fork
# added on top of it.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  requireFile,
  runCommand,
  cmake,
  ninja,
  pkg-config,
  python3,
  autoPatchelfHook,
  wrapGAppsHook3,
  gtk3,
  glib,
  libx11,
  libxcb,
  libxext,
  libxrandr,
  libxcursor,
  libxi,
  libxfixes,
  libxscrnsaver,
  libxkbcommon,
  vulkan-headers,
  vulkan-loader,
  alsa-lib,
  libpulseaudio,
  pipewire,
  systemdLibs,
  libusb1,
  libunwind,
  liburing,
  dbus,
  gsettings-desktop-schemas,
  librsvg,
  shared-mime-info,
  adwaita-icon-theme,
  hicolor-icon-theme,
}:

let
  version = "2.0.2";

  pins = lib.importJSON ./sources.json;

  fetchPin =
    pin:
    fetchFromGitHub {
      inherit (pin)
        owner
        repo
        rev
        hash
        ;
    };

  # One writable tree with every submodule in place, like a recursive clone.
  src = runCommand "skate3recomp-src-${version}" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatMapStrings (pin: ''
      mkdir -p "$out/${pin.path}"
      cp -r --no-preserve=mode,ownership ${fetchPin pin}/. "$out/${pin.path}/"
    '') pins
  );

  gameFileMessage = name: path: ''
    Building Skate 3 from source needs ${name} from your own Xbox 360 copy of
    Skate 3 (Skate 3 (USA, Europe), title update not applied). After a normal
    install it is at:

      ~/.local/share/skate3/game/${path}

    Add it to the Nix store, then build again:

      nix-store --add-fixed sha256 ~/.local/share/skate3/game/${path}
  '';

  defaultXex = requireFile {
    name = "default.xex";
    sha256 = "1db39496585c521d17a2137804f42cf73ebed2b32cac166ec42dbf772f4dcf7f";
    message = gameFileMessage "default.xex" "default.xex";
  };

  eaWebkitXex = requireFile {
    name = "EAWebkit.xex";
    sha256 = "0ee66b9558c888147f4ffdfd748cfc28950e80e46a97321da2de2afdb068523f";
    message = gameFileMessage "EAWebkit.xex" "data/webkit/EAWebkit.xex";
  };

  # Title Update 3, from the same URL the game's own installer uses.
  titleUpdate = fetchurl {
    name = "TU_12K2276_000000C000000.00000000000O3";
    url = "https://xboxunity.net/Resources/Lib/TitleUpdate.php?tuid=21774";
    sha256 = "a3fcff1e0b6059d307e9877063e50a99aca8ac41c93ca054de653f7bf16bca0e";
  };

  runtimeLibs = [
    gtk3
    glib
    libx11
    libxcb
    alsa-lib
    libpulseaudio
    pipewire
    systemdLibs
    libusb1
    libunwind
    liburing
    dbus
    vulkan-loader
    stdenv.cc.cc.lib
  ];
in
stdenv.mkDerivation {
  pname = "skate3-source-unwrapped";
  inherit version src;

  postPatch = ''
    patch -p1 -d third_party/rexglue-sdk/thirdparty/imgui < ${./patches/imgui-rasterizer-gamma.patch}
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-codegen-quick-exit.patch}

    # Taller-than-16:9 displays (Vert+), next to upstream's ultrawide.
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-display-aspect.patch}
    patch -p1 < ${./patches/skate3-display-aspect.patch}

    # Free guest memory on any exit, not only a clean one (rexglue-sdk#445).
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-shm-unlink-early.patch}
  ''
  # ARM64 fixes the Skate rexglue fork predates. The first three are upstream
  # rexglue-sdk commits; the last is from Buku313's Android fork. They are
  # correct on x86_64 too, but are applied on ARM only so the verified x86_64
  # build stays byte-identical.
  + lib.optionalString stdenv.hostPlatform.isAarch64 ''
    # rexglue-sdk d82ec28: FFmpeg NEON assembly links only with hidden symbols.
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-ffmpeg-hidden-visibility.patch}
    # rexglue-sdk 85aa46b: overlapping memcpy corrupts the title update on aarch64.
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-xex-delta-memmove.patch}
    # rexglue-sdk 96bee61: lost wakeup for threads created suspended.
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-suspended-thread-race.patch}
    # Buku313/rexglue-skate3-android e99203e: skip draws with no pipeline.
    patch -p1 -d third_party/rexglue-sdk < ${./patches/rexglue-vulkan-null-pipeline-guard.patch}
  ''
  + ''

    # Submodules arrive without .git; check for the directory instead.
    substituteInPlace third_party/rexglue-sdk/thirdparty/CMakeLists.txt \
      --replace-fail '"''${CMAKE_CURRENT_SOURCE_DIR}/''${submodule}/.git"' '"''${CMAKE_CURRENT_SOURCE_DIR}/''${submodule}"'

    # No .git in the store: give the version string the release number.
    sed -i 's|^string(REGEX REPLACE "-\.\*\$" "" SKATE3_NUMERIC_VERSION|set(SKATE3_FULL_VERSION "${version}-nix")\n&|' CMakeLists.txt
    grep -q 'SKATE3_FULL_VERSION "${version}-nix"' CMakeLists.txt

    mkdir -p game/data/webkit
    cp ${defaultXex} game/default.xex
    cp ${eaWebkitXex} game/data/webkit/EAWebkit.xex
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    autoPatchelfHook
    wrapGAppsHook3
  ];

  buildInputs = runtimeLibs ++ [
    libxext
    libxrandr
    libxcursor
    libxi
    libxfixes
    libxscrnsaver
    libxkbcommon
    vulkan-headers
    gsettings-desktop-schemas
    librsvg
    shared-mime-info
    adwaita-icon-theme
    hicolor-icon-theme
  ];

  dontUseCmakeConfigure = true;

  # Upstream flow: configure, run codegen (generate-all), configure again so
  # CMake sees the generated source lists, then build. The codegen tool runs
  # from the build tree, before fixup sets its library paths.
  buildPhase = ''
    runHook preBuild
    # The codegen tool and librexruntime.so need every linked library; the
    # ld wrapper does not add an rpath for the implicit libstdc++.
    export LD_LIBRARY_PATH="${stdenv.cc.cc.lib}/lib:$(echo $NIX_LDFLAGS | tr " " "\n" | sed -n "s/^-L//p" | sort -u | paste -sd:)"
    conf() {
      cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DREXGLUE_USE_VULKAN=ON \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DFETCHCONTENT_SOURCE_DIR_FREETYPE="$PWD/fetchcontent/freetype" \
        -DSKATE3_GAME_DATA_ROOT="$PWD/game" \
        -DSKATE3_TITLE_UPDATE_PACKAGE=${titleUpdate}
    }
    conf
    cmake --build build --target generate-all --parallel $NIX_BUILD_CORES
    conf
    cmake --build build --parallel $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 build/skate3 $out/bin/skate3
    install -m644 build/librexruntime.so $out/bin/librexruntime.so
    runHook postInstall
  '';

  # Steam Input support is optional and only present under Steam.
  autoPatchelfIgnoreMissingDeps = [ "libsteam_api.so" ];

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ vulkan-loader ]}:/run/opengl-driver/lib"
    )
  '';

  meta = {
    description = "Native recompilation of the Xbox 360 version of Skate 3, built from source";
    homepage = "https://github.com/mchughalex/skate3recomp";
    license = lib.licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "skate3";
  };
}
