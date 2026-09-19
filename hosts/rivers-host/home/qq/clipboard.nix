{
  lib,
  rustPlatform,
  fetchzip,
  makeWrapper,
  xorg-server,
}:

rustPlatform.buildRustPackage {
  pname = "qq-wayland-clipboard";
  version = "0.1.0-27ce5ac";

  src = fetchzip {
    url = "https://github.com/w568w/qq-wayland-clipboard/archive/27ce5ac5c8ed9a2723160db4b8e8d8bc943d910a.tar.gz";
    hash = "sha256-H57ek2bpdufIZ9cWGW+bKq12o8qhUKyuQmJ6O56czuc=";
  };
  cargoHash = "sha256-+iNIffA+R//Dvy3NhYB0fw88ig+K+LsZOvTVbcz5Z2c=";
  patches = [ ./image-file-fallback.patch ];
  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/qq-wayland-clipboard \
      --prefix PATH : ${lib.makeBinPath [ xorg-server ]}
  '';
  meta = {
    description = "QQ Wayland clipboard compatibility with image file fallback";
    homepage = "https://github.com/w568w/qq-wayland-clipboard";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
}
