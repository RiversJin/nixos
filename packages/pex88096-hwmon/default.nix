{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
}:

stdenv.mkDerivation {
  pname = "pex88096-hwmon";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = kernel.moduleBuildDependencies;
  # Kbuild interprets M relative to the kernel directory; use an absolute path.
  preBuild = ''
    export sourceRoot="$PWD"
  '';
  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(sourceRoot)"
  ];
  buildFlags = [ "modules" ];
  installFlags = [ "INSTALL_MOD_PATH=${placeholder "out"}" ];
  installTargets = [ "modules_install" ];
  meta = {
    description = "PEX88096 B0 internal temperature via its idle MPT management endpoint";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
