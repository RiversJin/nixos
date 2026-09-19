# Shake-to-locate trial for Niri 26.04

Upstream proposal: https://github.com/niri-wm/niri/pull/2797 (still unmerged when fetched on 2026-09-06).

`niri-shake-2797.diff` is the fetched proposal, SHA-256 `36c94c0fccc62d6791ccb64b723c0c337089c04693a2a6e982b2447a4900319f`.
`niri-shake-fixes.patch` adapts it for this desktop:

- Preserve the original integer cursor buffer scale on 1.5x displays.
- Scale against the image size actually supplied by the cursor theme, including themes without large frames.
- Keep scheduling frames until an enlarged cursor can start shrinking.
- Restore normal size when the feature is disabled and handle stopping immediately after a shake in intensity mode.
- Add five regression tests for detection, recovery, disabling and fractional scaling.

This local package enables the feature by default: maximum 3x size, hold-while-moving behavior, 100 ms stopped threshold, 500 ms post-expand delay, 300 ms shrink animation. Enabling through package defaults keeps the current configuration compatible with the older Niri process during deployment. A new login is required to run the patched compositor.

After logging into this build, `cursor { shake { off; }; }` disables it. The patched compositor also accepts explicit overrides under `cursor.shake`, such as `max-multiplier 2.5`. Removing these two shake patches and rebuilding restores the previous compositor; retain the independent blur patch.

This is a local trial of an unmerged feature, not an upstream release. Validation and screenshots are retained in `/home/rivers/Documents/ChatGPT/desktop/niri-shake-trial`.
