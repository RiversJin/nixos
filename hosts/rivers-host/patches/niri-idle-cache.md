# Render-independent GPU cache cleanup

Local fix for niri 26.04, layered after the existing blur and cursor patches.
It does not change monitor hotplug handling or the frame-callback policy.

## Failure and repair

`State::dmabuf_imported` imports buffers even when there is no rendered frame.
Smithay's GLES renderer caches those imports as EGLImages/textures. Destroying
the Wayland buffer invalidates its weak cache key, but the cache and deferred GL
destruction queue are normally drained by renderer cleanup associated with
rendering. DPMS off, no connected outputs, or an otherwise idle renderer can
therefore retain dead GPU resources indefinitely. Turning the monitors on
resumes rendering and releases the accumulation.

`niri-idle-cache-cleanup.patch` runs `Renderer::cleanup_texture_cache` from
niri's existing one-second fallback timer, independently of frame production.
The TTY backend visits **all** enumerated renderer devices, not just the primary
GPU, and continues if one device fails. Winit/headless use their renderer when
present. This removes dead cache entries and drains deferred GL destruction;
it does not invalidate live imports, force redraws, or suppress frame callbacks.

The cleanup cadence bounds retention of dead imports to the next maintenance
tick under a responsive event loop. It is not a memory quota for live client
buffers, and does not claim to fix unrelated driver or compositor leaks.

Upstream context:

- [niri #3295](https://github.com/niri-wm/niri/issues/3295): memory accumulation
  with screens off.
- [niri #3910](https://github.com/niri-wm/niri/pull/3910): closed, unmerged
  proposal to throttle/stop frame callbacks while screens are off. This local
  fix does not apply that proposal: the regression below creates no surface
  and never requests a frame callback, so stopping callbacks cannot fix it.
- [Smithay renderer API](https://smithay.github.io/smithay/smithay/backend/renderer/trait.Renderer.html):
  the existing cleanup operation retains live imports. No dependency update or
  unconditional cache invalidation is needed for this failure.

## Validation on RX 7900 XTX (2026-09-08)

The protocol client creates distinct 1024x1024 XRGB8888 GBM buffers, imports them
through linux-dmabuf, then destroys them. It never attaches a buffer to a
surface. The collector de-duplicates DRM client IDs and reads the compositor's
AMDGPU `drm-total-{vram,gtt,cpu}` statistics, not process RSS.

| Case | Before | After destruction + four seconds, still inactive |
| --- | ---: | ---: |
| Original live desktop, 128 buffers / 512 MiB | 1467.88 MiB | 1979.88 MiB (+512 MiB) |
| Patched nested instance, same workload | 69.35 MiB | 69.34 MiB |
| Patched real DRM / DPMS off, same workload | 64.39 MiB | 64.39 MiB |
| Patched real DRM / sole output disabled | 64.39 MiB | 64.39 MiB |
| Patched real DRM / 1024 buffers / 4096 MiB cumulative | 98.48 MiB | 98.49 MiB |
| Final build, restarted main desktop / 512 MiB | 438.84 MiB | 438.84 MiB |

In the original build, the retained 512 MiB disappeared only after power-on.
In each patched case a second workload kept 32 buffers alive for six seconds:
their 128 MiB remained allocated across three cleanup ticks, then disappeared
after destruction while the outputs were still inactive.

The real DRM test used a separate PAM/logind session on VT9, DP-1 at
3840x2160/120 Hz, and the hardware render node. The 4096 MiB run included two
real DP-1 disconnect/reconnect events (11:45:03 and 11:45:43). Its reclaimed
memory did not depend on removing that separate hotplug problem. The graphics
engine time counter remained unchanged during the DPMS-off regression.

204 regular tests and three actual EGL tests passed. The latter include the
existing blur crop and resize animation checks. The independent test session
was stopped and the original desktop on VT1 restored. Multi-GPU traversal is
implemented and compilation-checked; this host has only one GPU, so it is not
a multi-GPU runtime test.

Raw measurements from this run are in `/tmp/niri-dpms-fix/`: the
`baseline-regression`, `nested-regression`, `drm-dpms`, `drm-no-output`, and
`drm-stress` JSONL files, plus `egl-tests.log`. These are temporary artifacts;
the test sources and results above are retained here.

## Reproduce

From the repository root, build the standalone protocol client against the
same locked Nixpkgs as the host:

```sh
nix build --impure --expr '
  let f = builtins.getFlake ("path:" + toString ./.);
  in f.nixosConfigurations.rivers-host.pkgs.callPackage
    ./patches/niri-idle-cache/repro.nix {}
' --out-link /tmp/niri-dmabuf-churn
```

Run against a disposable niri instance with its outputs initially on. The
script temporarily powers off its monitors and restores them in `finally`:

```sh
python patches/niri-idle-cache/check.py \
  --socket "$NIRI_SOCKET" \
  --client /tmp/niri-dmabuf-churn/bin/niri-dmabuf-churn \
  --render-node /dev/dri/by-path/pci-0000:2d:00.0-render \
  --log /tmp/niri-cache-check.jsonl
```

Use `--expect-leak` for the unpatched baseline. Add `--output DP-1` to test
disabling the sole output, or `--count 1024` for the longer workload. An
isolated PAM session can restrict `/proc/PID/fdinfo` even for the same UID;
in that case run the collector with the required privilege and explicitly
preserve the test session's `XDG_RUNTIME_DIR` and socket argument.

The regression checks both reclamation and live-buffer retention, and fails
on compositor/client errors. It is intentionally AMD-specific because its
assertions depend on AMDGPU's domain accounting.

## Deployment and rollback

`nixos-rebuild switch` completed successfully on 2026-09-08 (system generation
486). The final package is
`/nix/store/phv2nddn5gr4ky5187xv5wzknkkm5czp-niri-26.04`; its 204 regular and
three EGL tests passed. The final source differs from the real-DRM-tested
build only in formatting of an error log statement.

After the approved session restart, the main `niri.service` ran PID 129515
from that exact final executable. The regression passed again in the main
desktop: destroyed buffers were reclaimed with DPMS still off, and 128 MiB of
live imports survived cleanup until destroyed. Desktop components were active
after restart. The final-session measurements and controller result are
`/tmp/niri-dpms-fix/live-final.jsonl` and `restart-result.json`.

`system/niri.nix` applies the patch declaratively. The build identifies itself
as `Nixpkgs-blur-crop-shake-idle-cache-fix`. A system switch updates the package,
but the running compositor cannot replace its code without ending the current
Wayland session; verify the running executable after the next login.

To roll back, remove only the idle-cache patch entry and restore the previous
build marker in `system/niri.nix`, then rebuild and log in again. Retain the
independent blur and cursor patches.
