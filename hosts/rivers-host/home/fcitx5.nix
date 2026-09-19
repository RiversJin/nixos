{
  pkgs,
  lib,
  rime-ice,
  ...
}:

{
  # Keep native Wayland apps on the compositor text-input path.
  # Apps that need the fcitx Qt IM module, such as WeChat, get QT_IM_MODULE per app.

  # Fcitx5 with Rime
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [
        fcitx5-rime
        qt6Packages.fcitx5-chinese-addons
      ];
    };
  };

  # Fcitx5 profile managed via activation (must be writable at runtime)
  home.activation.fcitx5Profile = ''
        PROFILE="$HOME/.config/fcitx5/profile"
        mkdir -p "$(dirname "$PROFILE")"
        if [ ! -f "$PROFILE" ] || [ -L "$PROFILE" ]; then
          rm -f "$PROFILE"
          cat > "$PROFILE" << 'EOF'
    [Groups/0]
    Name=Default
    Default Layout=us
    DefaultIM=rime

    [Groups/0/Items/0]
    Name=keyboard-us
    Layout=

    [Groups/0/Items/1]
    Name=rime
    Layout=

    [GroupOrder]
    0=Default
    EOF
        fi
  '';

  # Rime configuration: copy rime-ice base + custom overrides into a writable directory
  # (Rime needs write access to create build/ and userdb/)
  home.activation.rimeConfig = ''
    RIME_DIR="$HOME/.local/share/fcitx5/rime"
    mkdir -p "$RIME_DIR"

    # Only rsync when rime-ice source has changed
    RIME_STAMP="$RIME_DIR/.nix-source-stamp"
    if [ ! -f "$RIME_STAMP" ] || [ "$(cat "$RIME_STAMP")" != "${rime-ice}" ]; then
      ${pkgs.rsync}/bin/rsync -a --chmod=u+w --delete \
        --exclude='build/' \
        --exclude='*.userdb/' \
        --exclude='sync/' \
        --exclude='*.custom.yaml' \
        --exclude='.git/' \
        --exclude='installation.yaml' \
        --exclude='user.yaml' \
        --exclude='.nix-source-stamp' \
        "${rime-ice}/" "$RIME_DIR/"
      echo -n "${rime-ice}" > "$RIME_STAMP"
      RIME_CHANGED=1
    fi

    # Write custom overrides
    cat > "$RIME_DIR/default.custom.yaml" << 'YAML'
    patch:
      schema_list:
        - schema: double_pinyin_flypy

      "ascii_composer/good_old_caps_lock": true
      "ascii_composer/switch_key/Shift_L": noop
      "ascii_composer/switch_key/Shift_R": commit_code
      "ascii_composer/switch_key/Control_L": noop
      "ascii_composer/switch_key/Control_R": noop
      "menu/page_size": 7
      "switcher/hotkeys":
        - F4
    YAML

    cat > "$RIME_DIR/double_pinyin_flypy.custom.yaml" << 'YAML'
    patch:
      # 默认中文模式
      "switches/@0/reset": 0

      # 双拼不要自动展开（显示原来的字母，而不是拼音）
      translator/preedit_format: []

      # 中文模式下使用英文标点
      punctuator/half_shape:
        ",": ","
        ".": "."
        "!": "!"
        "?": "?"
        ":": ":"
        ";": ";"
        "~": "~"
        "@": "@"
        "#": "#"
        "%": "%"
        "^": "^"
        "&": "&"
        "*": "*"
        "(": "("
        ")": ")"
        "_": "_"
        "+": "+"
        "=": "="
        "[": "["
        "]": "]"
        "{": "{"
        "}": "}"
        "|": "|"
        "\\": "\\"
        "/": "/"
        "<": "<"
        ">": ">"
        "`": "`"
        "'": "'"
        "\"": "\""
    YAML

    # Restart fcitx5 only when rime data changed
    if [ "''${RIME_CHANGED:-}" = "1" ] && ${pkgs.systemd}/bin/systemctl --user is-active fcitx5-daemon.service > /dev/null 2>&1; then
      ${pkgs.systemd}/bin/systemctl --user restart fcitx5-daemon.service || true
    fi
  '';

  # KWin manages fcitx5 via wayland-launcher, so disable the systemd service
  # to avoid D-Bus name conflicts and restart loops
  systemd.user.services.fcitx5-daemon.Install.WantedBy = lib.mkForce [ ];
}
