# Agent Guidance

- Reply in Chinese by default.
- Keep the tone direct, concise, and technically grounded.
- Avoid unnatural wording such as "如果你要" or "如果你愿意" when replying to the user.
- Prefer direct, natural phrasing over unnecessary optionality when the next step is already clear.
- Assume the user can evaluate technical tradeoffs and does not need oversimplified guidance.

# Execution Defaults

- Build context from the codebase or local environment first, then act.
- Prefer concrete edits and verification over long proposals when the next step is clear.
- Preserve user-owned edits and avoid reverting unrelated changes.
- After completing a discrete task in this repository, ask whether to commit the changes.

# NixOS And Ops

- For permanent behavioral changes on NixOS, edit declarative configuration and rebuild.
- For temporary service operations, use imperative commands such as `systemctl` directly instead of changing Nix config.
- `sudo -A` is a local-machine askpass pattern only; when operating over SSH, use the remote host's sudo/auth model and do not assume local graphical askpass applies there.
- Before using `sudo -A`, ask the user whether graphical askpass approval is currently possible.
- For privileged commands from Codex, prefer `sudo -A` so graphical askpass can be used instead of assuming an interactive TTY.
- If a tool is missing on NixOS, prefer `nix shell nixpkgs#<package>` for temporary access.
- When changing service or networking configuration and syntax is uncertain, verify against official docs or primary examples before editing.
- If `nix eval`, `nixos-rebuild`, or similar commands fail with `attempt to write a readonly database` under `/home/rivers/.cache/nix` while running from Codex, treat it as Codex sandbox filesystem isolation, not a host NixOS/cache problem. Re-run the needed Nix command with proper escalation outside the sandbox instead of diagnosing the machine state.

# JavaScript REPL (Node)

- Use `js_repl` for Node-backed JavaScript with top-level await in a persistent kernel.
- `js_repl` is a freeform/custom tool. Direct `js_repl` calls must send raw JavaScript tool input (optionally with first-line `// codex-js-repl: timeout_ms=15000`). Do not wrap code in JSON, quotes, or markdown code fences.
- Helpers: `codex.cwd`, `codex.homeDir`, `codex.tmpDir`, `codex.tool(name, args?)`, and `codex.emitImage(imageLike)`.
- Avoid direct access to `process.stdout` / `process.stderr` / `process.stdin`; it can corrupt the JSON line protocol. Use `console.log`, `codex.tool(...)`, and `codex.emitImage(...)`.
