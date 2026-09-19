{ config, ... }:

let
  pypiMirror = "https://pypi.tuna.tsinghua.edu.cn/simple";
  cratesMirror = "sparse+https://rsproxy.cn/index/";
  npmMirror = "https://registry.npmmirror.com";
in
{
  home.sessionVariables = {
    GOPROXY = "https://goproxy.cn,direct";
    NPM_CONFIG_REGISTRY = npmMirror;
    PIP_INDEX_URL = pypiMirror;
    PNPM_HOME = "${config.home.homeDirectory}/.local/share/pnpm";
    RUSTUP_DIST_SERVER = "https://rsproxy.cn";
    RUSTUP_UPDATE_ROOT = "https://rsproxy.cn/rustup";
    UV_DEFAULT_INDEX = pypiMirror;
  };

  home.sessionPath = [
    "${config.home.homeDirectory}/.local/share/pnpm"
  ];

  home.file.".cargo/config.toml".text = ''
    [source.crates-io]
    replace-with = "rsproxy-sparse"

    [source.rsproxy-sparse]
    registry = "${cratesMirror}"

    [registries.rsproxy-sparse]
    index = "${cratesMirror}"

    [target.x86_64-unknown-linux-gnu]
    linker = "clang"
    ar = "llvm-ar"
    rustflags = ["-C", "link-arg=-fuse-ld=lld"]

    [env]
    CC = "clang"
  '';

  home.file.".config/pip/pip.conf".text = ''
    [global]
    index-url = ${pypiMirror}
  '';

  home.file.".config/uv/uv.toml".text = ''
    [[index]]
    url = "${pypiMirror}"
    default = true
  '';

  home.file.".npmrc".text = ''
    prefix=${config.home.homeDirectory}/.npm-global
    registry=${npmMirror}
  '';

  home.file.".yarnrc".text = ''
    registry "${npmMirror}"
  '';
}
