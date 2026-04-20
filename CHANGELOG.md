# Changelog

All notable changes to `ubuntu-prep-setup.sh` are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- **`llama-reconfigure` model editor: HuggingFace search.**
  The model editor now offers three paths: (1) search the Hub by
  keyword → ranked list of GGUF repos by download count → pick repo
  → pick file from the top-level tree with human-readable sizes;
  (2) direct-input an `org/repo[:file.gguf]` slug; (3) a local `.gguf`
  path. Search uses the public `huggingface.co/api/models` endpoint
  (no token needed) filtered to `gguf`, sorted by downloads. Gated
  repos (meta-llama, google/gemma) work when `HF_TOKEN` is set in
  `~/.env.secrets`.
- 11 new bats tests pinning the JSON parsers (`hf_parse_search_results`,
  `hf_parse_tree_gguf`) with fixture JSON and the `human_size` formatter
  (total: 246).

### Changed
- `llama-reconfigure` now depends on `jq` for the search UX; direct
  input and local-path modes still work without it. A helpful error
  fires if `jq` is missing and the user tries to search.
- `llama-reconfigure` version: `1.1.0` → `1.2.0` (new feature,
  SemVer minor).

## [1.1.0] — 2026-04-20

Bundled scripts this release:
- `ubuntu-prep-setup.sh` — `1.0.1` (unchanged since last release)
- `llama-reconfigure.sh` — `1.1.0` (new this release)

### Added
- **`llama-reconfigure.sh`** — standalone, menu-driven editor for an
  installed `llama-server.service`. Parses the existing `ExecStart`
  in-place (preserves hand edits), lets the user change any of:
  model (HF slug `org/repo:file.gguf` or local path), context size,
  `-ngl`, KV cache quant, `--flash-attn`, listen host/port, `--mlock`,
  `--fit` / `--fit-ctx`, or raw args. On apply: downloads the new
  model (blocking, with curl progress bar), snapshots the current unit
  to `.bak`, writes the new unit, `daemon-reload`, restart, polls
  `is-active` for 10s, tails `journalctl` on failure, and offers
  `--rollback`. Flags (`--model`, `--context`, …) jump straight into
  specific editors for scripting. Does NOT modify `ubuntu-prep-setup.sh`
  — install `llama-reconfigure` independently once the base installer
  has set up llama.cpp.
- 15 new bats tests pinning the parser, serializer, round-trip, and
  the single-quote validator (total: 235).

### Changed
- Release workflow now accepts a tag that matches *any* bundled
  script's version (was: strict match against `UBUNTU_PREP_VERSION`).
  This lets us cut repo releases that bump only one script.

## [1.0.1] — 2026-04-19

Second-pass code review hardening. All 15 findings from an independent review
of the 6,000-line installer were applied. No behavioural changes to the golden
path — every fix is defence-in-depth against malformed inputs or unusual host
state.

### Added
- `UBUNTU_PREP_VERSION` constant and `--version` / `-V` flag so users can tell
  which release they are running.
- Release workflow (`.github/workflows/release.yml`): tag-triggered, runs
  `shellcheck --severity=warning` + the full bats suite, verifies the tag
  matches `UBUNTU_PREP_VERSION`, then attaches `ubuntu-prep-setup.sh` and a
  `SHA256SUMS` file to a GitHub Release built from the matching CHANGELOG
  entry. Users can now download a pinned, checksum-verified copy.

### Security
- **HuggingFace download** now passes `HF_TOKEN` via `env` + positional args
  to `bash -c` so a malicious token, repo slug, or filename can't inject shell
  metacharacters into the curl invocation.
- **`.env.secrets` writer** escapes `\ " $ \`` in user-supplied values before
  emitting `export NAME="VALUE"`, so a secret containing `"` can't break the
  file when it's later sourced.
- **NVIDIA/OLLAMA secret reads** use the same positional-arg pattern rather
  than interpolating `$TARGET_USER_HOME` into a `bash -c "…"` body.
- **`OLLAMA_ORIGINS`** is rejected (and falls back to `*`) if it contains `"`
  or a newline, so a malformed value can't corrupt the systemd override file.
- **Driver `.run`, cuDNN `.deb`, and cuda-keyring `.deb`** are staged in
  `mktemp -d` directories instead of predictable `/tmp/<name>` paths that a
  local attacker could pre-create as a symlink.
- **`TARGET_USER`** is validated against `^[a-z_][a-z0-9_-]{0,31}$` in both
  the "current user" and "new user" branches, before any sudo/systemd path
  interpolates it.
- **`TARGET_USER_HOME`** is resolved with `getent passwd` rather than
  `eval echo "~$TARGET_USER"`, eliminating the second shell pass.
- **llama-server systemd `ExecStart`** validates that `hf_args` and
  `llama_host_args` contain no single quote before the unit file is written
  (the `bash -c '…'` body would otherwise break).

### Fixed
- **OpenClaw provider auto-config** — jq filter corrected from `.providers`
  to `.models.providers` to match the actual schema.
- **Resume state round-trip** — every value persisted to
  `/var/lib/ubuntu-prep/resume.env` is shell-quoted via `printf %q`, so
  pathological values with spaces, quotes, backslashes, or `$` survive a
  `source`-back intact. Bare `NAME="$VAL"` interpolation broke on any `"`.
- **`ENABLE_UFW_AUTOMATICALLY`** is now persisted and restored across the
  post-reboot resume (was previously lost).
- **Gated/missing HuggingFace repos** are now detected by HTTP status
  (401/403/404) and produce an actionable message instead of the generic
  "llama.cpp will download on first start" fallback.
- **`openclaw onboard`** exit code is captured and surfaced when the config
  file write fails, instead of being swallowed by `|| true`.

### Changed
- Extracted `nvm_env_prelude()` helper; eight copies of the
  `export NVM_DIR=…; source "$NVM_DIR/nvm.sh"` literal now share one
  implementation.
- `--local-mirror` help text documents the trust-on-first-use model —
  `StrictHostKeyChecking=accept-new` means the first run trusts whatever
  host answers at that address.

### CI
- `check-nvidia-driver` workflow: replaced the single brittle grep with a
  fallback loop of four patterns (covers both the old and current
  nvidia.com page structures); pinned version `595.58.03` now matches the
  latest production release.
- All three scheduled workflows (`check-nvidia-driver`, `check-install-urls`,
  `check-openclaw`) now idempotently `gh label create … || true` before
  `gh issue create`, so a missing label no longer fails the job with
  exit 1.

### Earlier in-session fixes (pre-review)
- `CUDNN_VERSION` sanitised (`${var//[^0-9.]/}`) before interpolation into
  the download URL and keyring-copy path.
- cuDNN keyring copy wrapped in `sudo bash -c` so the glob expands as root;
  `wait_for_apt_lock` calls added around `dpkg -i` and `apt-get update`.
- TinyStories (`choice 5`) now starts with a minimal flag set to avoid a
  SEGV seen with production flags on the 656K model.
- LibreChat install falls back to GitHub when a `--local-mirror` clone fails.
- Added two bats tests pinning the exact `build_llama_hf_args` output for
  TinyStories (total: 220 tests).

## [1.0.0] — 2026-04-17

Initial public release. Full installer for Ubuntu 22.04/24.04 servers
targeting local LLM workloads:

- Interactive menu with dependency resolution across 15 components (Zsh,
  Docker, NVM, Homebrew, Gemini CLI, NVIDIA driver, CUDA, Container Toolkit,
  cuDNN, llama.cpp, Ollama, Open-WebUI, LibreChat, OpenClaw).
- Consumer GPU (`.run`) and vGPU driver paths, with ESXi passthrough detection.
- CUDA-aware llama.cpp build with flash-attn, KV-cache quantisation, `--fit`,
  `--mlock`, and `-dio` toggles.
- llama-server systemd unit with CUDA environment and auto-restart.
- LibreChat + Open-WebUI frontends, routable to either backend.
- `--dry-run`, `--resume`, `--local-mirror` flags.
- BATS test suite (220 unit tests) + `shellcheck` clean.
- Daily URL-liveness CI check for external install dependencies.
- PolyForm Noncommercial licence with a separate commercial licence path.
