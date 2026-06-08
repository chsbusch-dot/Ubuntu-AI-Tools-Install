# Changelog

All notable changes to `ubuntu-prep-setup.sh` are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

## [1.9.0] — llama-reconfigure — 2026-06-08

### Added
- Sampler-parameter editors (server-side llama-server defaults):
  - `--temp` (temperature)
  - `--top-p` (nucleus)
  - `--top-k` (integer)
  - `--min-p` (`0.0` is a valid, serialized value — the Qwen3 recommendation)
  - `--repeat-penalty`
  New "Sampling" section in the main menu (items 15–19 on CUDA builds,
  14–18 on CPU builds). CLI jumps: `--temp`, `--top-p`, `--top-k`,
  `--min-p`, `--repeat-penalty`.
- Shared `_edit_sampler` helper. Because `0` is meaningful for these
  params (unlike other numeric flags), clearing uses `x` rather than `0`;
  blank keeps the current value.
- Menu prompts surface the Qwen3 recommendations
  (temp 0.7 / top-p 0.8 / top-k 20 / min-p 0.0 / repeat-penalty 1.05).
- 16 new bats tests (parse / serialize / round-trip for all 5 flags,
  incl. the `min-p 0.0` round-trip edge case and a full Qwen3 sampler-set
  round-trip). Total: 146.

### Changed
- `main_menu` now derives its `[1-N]` range and item dispatch from
  `menu_item_numbers` (single source of truth) instead of a duplicated
  local block.
- Completed the `parse_unit_file` doc header (spec + sampler vars).
- `llama-reconfigure` version: `1.8.0` → `1.9.0`.

## [1.8.0] — llama-reconfigure — 2026-06-08

### Added
- Context size editor now shows a numbered preset menu (8k / 16k / 32k /
  64k / 128k / 256k) with a `c` option for custom values. Blank keeps the
  current value. Current selection is marked `← current`.
- `detect_model_max_ctx`: pattern-matches the active repo/file slug to infer
  the model's advertised max context. When the inferred max is known, the
  context menu shows it and marks presets that exceed it with `⚠ may exceed
  model max`. Advisory only — user can still select any value.
- Model file picker (`_edit_model_file_picker`): shared helper that fetches
  the HF tree for a repo and lets the user pick a `.gguf` file. Used by:
  - Option 2 in `edit_model` when no `:file` suffix is given (previously
    left llama-server to auto-select; now always shows the file picker).
  - New option 4 in `edit_model`: "Pick a different file from current repo"
    (shown only when already in HF mode with a repo set).
  - `edit_model_search_flow` (refactored to call the helper instead of
    duplicating the logic).
- 9 new bats tests for `detect_model_max_ctx` (total: 130 in
  `reconfigure.bats`).

### Changed
- `llama-reconfigure` version: `1.7.0` → `1.8.0`.

## [1.7.0] — llama-reconfigure — 2026-05-26

### Added
- `--spec-type draft-mtp` toggle: enables the MTP speculative decoding engine.
  Menu item 13 (CUDA) / 12 (non-CUDA). CLI flag jump: `--spec-type`.
  Toggle: off → `draft-mtp`, `draft-mtp` → cleared.
- `--spec-draft-n-max N` editor: sets the maximum number of draft tokens
  (commonly 2 or 4). Blank keeps current; `0` clears.
  Menu item 14 (CUDA) / 13 (non-CUDA). CLI flag jump: `--spec-draft-n-max`.
- 10 new bats tests covering parse, serialize, and round-trip for both
  new flags (total: 121 in `reconfigure.bats`).

### Changed
- `llama-reconfigure` version: `1.6.0` → `1.7.0`.

## [1.6.0] — llama-reconfigure — 2026-05-25

### Added
- `--jinja` toggle (Jinja template processing)
- `--reasoning on/off` toggle
- `--parallel N` parallel request slots
- Model architecture compatibility warnings: GQA models warn when
  flash-attn is off + non-f16 KV; MoE models hint to set --n-cpu-moe
- `[u]` Update llama.cpp menu item: git pull + incremental CMake rebuild
  + cmake --install, runs git commands as service user to avoid ownership errors
- `llama-sync.sh`: sync .gguf model files between servers over SSH

### Fixed
- `edit_ubatch`: missing `local v` + set -e hazard on blank input
- Serializer silently dropped `--flash-attn off` / `--reasoning off` on round-trip
- `systemd-analyze verify` block was logically inverted (no-op); simplified
- `P_RAW_OVERRIDE` not cleared on re-parse (stale state after update_llama_cpp)
- hf_download: downloaded blobs owned by root (Permission denied for service user);
  now chowns entire repo_dir to service user after download
- Benchmark fa_list now respects P_FLASH=on (GQA models no longer sweep fa=0)

### Changed
- Item numbering logic extracted to `menu_item_numbers()` helper —
  show_current and main_menu no longer duplicate the CUDA/non-CUDA shift logic

### Added
- **`llama-reconfigure`: VRAM estimate for un-downloaded HF models.**
  Picking a too-big model from the search UI used to succeed silently;
  the OOM only surfaced during `apply_changes` after a 15-min
  download. Now:
  - `P_HF_FILE_BYTES` captures the picked file's size from the Hub
    tree listing (`edit_model_search_flow`) or a fresh `HEAD` probe
    (direct slug input, via new `hf_head_content_length`).
  - `detect_model_gb` falls back to `P_HF_FILE_BYTES` when the
    `.gguf` isn't on disk yet, so the main-menu "Model weights / KV
    cache / Runtime overhead / Estimated total" block (with ❌ OOM
    warning) appears immediately after the user picks a model —
    before they commit to the download. Lets a user back out of a
    70 B Q5_K_M on a 24 GB GPU the moment they pick it.
  - 5 new bats tests pinning the fallback, precedence, and curl-fail
    safety (total: 60 in `reconfigure.bats`, 280 repo-wide).
- **`llama-reconfigure`: benchmark optimizations (~50% faster).**
  Three improvements to the `[b]` sweep make it realistic to run on
  large models without sitting through 40+ minutes of silent GPU
  churn:
  - **Adaptive two-pass.** Pass 1 runs every candidate cache type
    at `-r 1` (fast triage). The winner is re-run alone at `-r 3`
    (confident number). Final table shows pass-2 numbers for the
    winner, pass-1 numbers for the losers. Saves ~40% vs. running
    every ctk at `-r 2`.
  - **VRAM pre-filter.** Before launching `llama-bench`, each ctk's
    estimated VRAM (`model_gb + kv_gb + overhead`) is compared
    against detected `hw_vram`. Cache types that wouldn't fit are
    skipped with a visible `⊘ ctk=f16 skipped (27 GB > 24 GB VRAM)`
    log line — no more 10-minute failed run to discover the OOM.
  - **Workload-aware ubatch default.** For `p ≤ 512` (`openclaw`,
    `chat`) the ubatch sweep is fixed at `512` (the llama.cpp default)
    since ub doesn't move the needle on short prompts. For `p > 512`
    (`coding`, `summarize`) ub sweeps `1024,2048`. Halves cell count
    on short-prompt presets.
  Env overrides still work: `BENCH_UBATCH`, `BENCH_CTK`, `BENCH_REPS`.
- **`llama-reconfigure`: `--n-cpu-moe` architecture hints.**
  The editor now prints a short table of typical values per
  architecture family (non-MoE → unset, Mixtral 8x7B → 2–4,
  Qwen-MoE → 4–8, DeepSeek-MoE → 8–16, GPT-OSS → 1–2) before
  prompting, so users pick a sensible starting number instead of
  guessing. Semantics also align with `edit_ubatch`: blank keeps
  the current value, `0` clears.
- **`llama-reconfigure`: benchmark & optimize.**
  New `[b]` menu entry (and `--benchmark [PRESET]` flag jump) sweeps
  `-ub × -ctk/-ctv × -fa` with `llama-bench` across four workload
  presets and ranks the combinations by predicted wall-clock time
  for that workload:
  - **`openclaw`** — p=64 n=256 (short system prompt, short reply;
    routing traffic from the OpenClaw coordinator)
  - **`chat`** — p=512 n=1024 (moderate prompt + reply)
  - **`coding`** — p=8192 n=2048 (large context in, medium out)
  - **`summarize`** — p=32768 n=512 (huge prompt, short output)

  Scoring formula `total_time = p/pp_toks_s + n/tg_toks_s` naturally
  picks different winners for different workload shapes: a short-reply
  workload favours tg throughput, a 32k-prompt summarisation workload
  is pp-dominated. K and V cache are locked to the same type (mixed
  types disable GPU offload), so we run one `llama-bench` invocation
  per cache type and merge results.

  The sweep automatically stops `llama-server` (if active) to free the
  GPU, writes raw JSON to `/var/lib/llama-reconfigure/bench-*.json`
  for history, restarts the service, then prints a ranked table with
  `★` on the winner. If the user accepts, `P_UBATCH`/`P_CACHE_K`/
  `P_CACHE_V`/`P_FLASH` are mutated and `apply_changes` runs. New
  path helpers (`detect_llama_cache`, `detect_user_from_unit`,
  `resolve_local_gguf`) locate the `.gguf` on disk from any user's
  unit file, replacing an earlier hard-coded `/home/chris/...`
  fallback. 12 new bats tests pin the path helpers, the preset
  table, and the scorer (total: 270).
- **`llama-reconfigure`: installer-style `Context & Memory` menu.**
  The interactive menu now mirrors the `configure_context_memory` UX from
  the main installer: a single numbered list with `[current value]` inline,
  a live VRAM estimate block (Model weights / KV cache / Runtime overhead /
  Estimated total) with ❌ OOM warning when the total exceeds detected GPU
  VRAM, and `[c]`/`[1-N]`/`[d]` shortcuts. Model and Listen address moved
  to `[m]`/`[l]` letter shortcuts to keep the numbered items focused on
  runtime tuning. Two new parameters added:
  - **`-ub N` (ubatch)** — controls prompt-processing batch size (`-ub`).
    Menu item 5. Flag jump: `--ubatch`. Clears with blank-then-0.
  - **`-dio` (Direct I/O)** — toggle for the `-dio` flag that prevents
    tensor hang on some configurations. Menu item 7 (CPU) / 8 (CUDA).
    Flag jump: `--dio`.
  Supporting infrastructure: `cache_type_bytes()`, `estimate_vram_usage()`,
  `detect_model_gb()` (stat on local path or cached HF file),
  `detect_hw_vram_gb()` (nvidia-smi). 7 new bats tests (total: 258).
- **`llama-reconfigure`: `--n-cpu-moe` support.**
  New menu option 9 (CPU MoE layers) and `--n-cpu-moe` flag jump let users
  set `--n-cpu-moe N` — the number of Mixture-of-Experts expert layers to
  evaluate on CPU instead of GPU. Useful for large MoE models (Mixtral,
  DeepSeek-MoE, Qwen-MoE) when VRAM is tight. Parsed from and serialized
  to the systemd ExecStart like all other flags; blank input clears the
  flag entirely. 5 new bats tests (total: 251).
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
- `llama-reconfigure` version: `1.4.0` → `1.5.0` (benchmark &
  optimize feature, SemVer minor).

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
