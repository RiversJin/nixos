{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
}:

stdenv.mkDerivation {
  pname = "nct6683-msi";
  version = "0.1.0";
  src = kernel.src;
  unpackPhase = ''
    runHook preUnpack
    tar -xf "$src" --strip-components=3 linux-${kernel.version}/drivers/hwmon/nct6683.c
    sourceRoot=.
    runHook postUnpack
  '';
  patches = [ ./nct6683-msi.patch ];
  postPatch = ''
    cp ${./Makefile} Makefile
  '';
  nativeBuildInputs = kernel.moduleBuildDependencies;
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
    description = "NCT6683 driver with board-scoped MSI MS-7C94 fan control";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
