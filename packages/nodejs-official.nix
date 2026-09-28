{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "nodejs-official";
  version = "24.21.0";

  src = fetchurl {
    url = "https://nodejs.org/dist/v${version}/node-v${version}-linux-x64.tar.xz";
    sha256 = "fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # DSH's require-builtin addon inspects Node internals. Preserve the upstream
  # executable and symbols; only adapt ELF interpreter and library paths.
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a bin include lib share "$out/"
    install -Dm644 LICENSE "$out/share/licenses/nodejs/LICENSE"

    # npm and npx must use this Node even when another version is on PATH.
    rm "$out/bin/npm" "$out/bin/npx"
    for command in npm npx; do
      makeWrapper "$out/bin/node" "$out/bin/$command" \
        --add-flags "$out/lib/node_modules/npm/bin/$command-cli.js" \
        --prefix PATH : "$out/bin"
    done
    runHook postInstall
  '';

  meta = {
    description = "Official Node.js binary with NixOS ELF paths for DSH";
    homepage = "https://nodejs.org/";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "node";
  };
}
