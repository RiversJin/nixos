{
  stdenv,
  pkg-config,
  wayland,
  wayland-scanner,
  wayland-protocols,
  libgbm,
}:
stdenv.mkDerivation {
  pname = "niri-dmabuf-churn";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [
    pkg-config
    wayland-scanner
  ];
  buildInputs = [
    wayland
    libgbm
  ];
  buildPhase = ''
    runHook preBuild
    protocol=${wayland-protocols}/share/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml
    wayland-scanner client-header "$protocol" linux-dmabuf-client.h
    wayland-scanner private-code "$protocol" linux-dmabuf-protocol.c
    $CC -Wall -Wextra -Werror -O2 -I. ${./dmabuf-churn.c} linux-dmabuf-protocol.c \
      $(pkg-config --cflags --libs wayland-client gbm) -o niri-dmabuf-churn
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 niri-dmabuf-churn $out/bin/niri-dmabuf-churn
    runHook postInstall
  '';
}
