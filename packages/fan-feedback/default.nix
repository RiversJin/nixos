{ lib, rustPlatform, pkg-config, dbus }:
rustPlatform.buildRustPackage {
  pname = "fan-feedback";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ dbus ];
  meta = {
    description = "PEX88096 temperature feedback for the Haicon BLE fan controller";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "fan-feedback";
  };
}
