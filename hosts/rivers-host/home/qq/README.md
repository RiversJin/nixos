# QQ clipboard compatibility

`../qq.nix` wraps both the `qq` command and its desktop entry. On Wayland,
`qq-wayland-clipboard` launches native Wayland QQ with a private Xvfb display,
isolating its legacy X11 clipboard. The bridge publishes standard MIME formats
to the real Wayland clipboard. X11 sessions use the original QQ launcher.

Upstream is pinned to `27ce5ac5c8ed9a2723160db4b8e8d8bc943d910a`.
`image-file-fallback.patch` additionally offers `image/png` when QQ copies a
local image as a type-4 file element. It retains the QQ format and file URI,
limits file reads to the upstream selection size limit, and ignores non-images.

Observed on 2026-09-08 with QQ 3.2.32 and Niri:

- Native QQ retained an old X11 image while Wayland held newer external text.
- XWayland QQ fixed incoming text, but copying the image still offered only
  `QQ_Unicode_RichEdit_Format` and `x-special/gnome-copied-files`.
- With this bridge and patch, the user verified QQ image to Codex paste and
  external text to QQ paste.
- Six Rust tests cover stale jobs, file URI parsing, image fallback and rejection
  of non-image files / remote URLs.

For updates, refresh both source and Cargo hashes and rerun those tests, then
verify the two paste directions in actual applications. The bridge has upstream
limitations around mixed rich text and simultaneous copies by multiple apps.

Rollback: remove the `./qq.nix` import in `../packages.nix`, restore `qq` in
`home.packages`, rebuild, then fully quit and relaunch QQ.
