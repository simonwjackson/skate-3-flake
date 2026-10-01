# The upstream prebuilt Skate 3 recomp Linux release, re-homed onto Nix
# libraries. The binary itself is unchanged.
#
# Upstream links the GTK stack with only an $ORIGIN rpath and expects
# /lib64/ld-linux-x86-64.so.2. autoPatchelfHook fixes both. It also reads the
# ELF dlopen notes in librexruntime.so (SDL3's audio backends and D-Bus) and
# puts those libraries on the RUNPATH. The Vulkan loader is dlopen()ed without
# a note, so it goes on LD_LIBRARY_PATH.
# The approach follows github:JuiceyDew/Skate3-Recomp-Nix.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  wrapGAppsHook3,
  gtk3,
  glib,
  pango,
  cairo,
  harfbuzz,
  atk,
  gdk-pixbuf,
  libx11,
  libxcb,
  gsettings-desktop-schemas,
  librsvg,
  shared-mime-info,
  adwaita-icon-theme,
  hicolor-icon-theme,
  vulkan-loader,
  pipewire,
  libpulseaudio,
  alsa-lib,
  dbus,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "skate3-unwrapped";
  version = "2.0.2";

  src = fetchurl {
    url = "https://github.com/mchughalex/skate3recomp/releases/download/v${finalAttrs.version}/Skate3Recomp-Linux.zip";
    hash = "sha256-saVxDhRn09dQtzwQaAGBWo4ryLbqhgmA9tslLrH/wH8=";
  };

  sourceRoot = "Skate3Recomp-Linux";

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
    wrapGAppsHook3
  ];

  buildInputs = [
    gtk3
    glib
    pango
    cairo
    harfbuzz
    atk
    gdk-pixbuf
    stdenv.cc.cc.lib
    libx11
    libxcb
    # The first-run ISO picker is a GTK file chooser; these make it render.
    gsettings-desktop-schemas
    librsvg
    shared-mime-info
    adwaita-icon-theme
    hicolor-icon-theme
    # Named by the ELF dlopen notes in librexruntime.so.
    pipewire
    libpulseaudio
    alsa-lib
    dbus
  ];

  dontConfigure = true;
  dontBuild = true;

  # Optional Steam Input support. libsteam_api.so exists only under Steam, and
  # the reference is lazily bound, so the game runs without it.
  autoPatchelfIgnoreMissingDeps = [ "libsteam_api.so" ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    # Keep both files together so the $ORIGIN rpath still finds the runtime.
    install -m755 skate3 $out/bin/skate3
    # Upstream ships the library executable; without this, wrapGAppsHook
    # would wrap it like a program and shadow the real library.
    install -m644 librexruntime.so $out/bin/librexruntime.so
    runHook postInstall
  '';

  # The GPU driver, its Vulkan ICD and libnvidia-ml come from the host at
  # /run/opengl-driver (NixOS: hardware.graphics.enable).
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ vulkan-loader ]}:/run/opengl-driver/lib"
    )
  '';

  meta = {
    description = "Native recompilation of the Xbox 360 version of Skate 3 (upstream prebuilt Linux release)";
    homepage = "https://github.com/mchughalex/skate3recomp";
    # Upstream publishes no license, and the binary is generated from EA's
    # game code.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "skate3";
  };
})
