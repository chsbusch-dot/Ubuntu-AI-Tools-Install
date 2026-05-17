#!/bin/bash
#
# validate-uma-fit.sh — model-fit validation for the macOS port.
#
# Apple Silicon has unified memory, not a discrete VRAM pool. This
# script extracts get_model_recommendations() from macos-prep-setup.sh
# and checks, for every (backend × UMA-tier × category) combination
# the script would recommend, that:
#
#     model weights + KV cache (q4_0, 65 536 ctx) + runtime overhead
#         ≤ UMA-tier budget
#
# Mirrors the VRAM-fit section of the original Ubuntu test.sh so the
# two ports stay in lockstep. A tier "fits" if the estimate is ≤ the
# raw UMA number; the 10-15 % headroom that macOS wants for the
# window server / Metal drivers / Finder is NOT modelled here — this
# check is the "obviously-won't-run" tripwire, not a paging simulator.
#
# Run stand-alone, or as the "UMA fit" stage of check-macos.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SETUP_SCRIPT:-$SCRIPT_DIR/macos-prep-setup.sh}"

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    echo "❌ Cannot find macos-prep-setup.sh at $SETUP_SCRIPT" >&2
    exit 1
fi

# ─── Colors (disable if not a terminal) ────────────────────────────────
if [ -t 1 ]; then
    RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; RESET=""
fi

pass() { echo "  ${GREEN}✅ $1${RESET}"; }
fail() { echo "  ${RED}❌ $1${RESET}"; UMA_ERRORS=$((UMA_ERRORS + 1)); }
warn() { echo "  ${YELLOW}⚠️  $1${RESET}"; UMA_WARNINGS=$((UMA_WARNINGS + 1)); }

# ─── Import get_model_recommendations from macos-prep-setup.sh ─────────
# Extract by name so we don't have to source the whole setup script
# (which would trigger its check_os / sudo helpers).
eval "$(sed -n '/^get_model_recommendations() {/,/^}/p' "$SETUP_SCRIPT")"
eval "$(sed -n '/^qwopus_default_gguf_file() {/,/^}/p' "$SETUP_SCRIPT")"

# ─── Model weight lookup (Q4_K_M or tier-appropriate quant in GB) ──────
#
# Sizes are the on-disk GGUF file sizes for the default quant at each
# tier (rounded up to whole GB for fit-math headroom). Non-Qwopus entries
# match the Ubuntu test.sh weight table so the two scripts agree on
# shared model IDs.
get_model_weight() {
    local model="$1" tier="${2:-32}"
    case "$model" in
        # --- Small tiers (8/16 GB — VM / base configs) ---
        "bartowski/Qwen2.5-7B-Instruct-GGUF")        echo "5"  ;;
        "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF")  echo "5"  ;;
        "unsloth/Qwen2.5-VL-7B-Instruct-GGUF")       echo "5"  ;;
        "bartowski/Qwen2.5-14B-Instruct-GGUF")        echo "9"  ;;
        "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF")  echo "9"  ;;
        # --- Ollama small tiers (already covered by weight lookup above where names match) ---
        "qwen2.5:7b")              echo "5"  ;;
        "qwen2.5-coder:7b")        echo "5"  ;;
        "qwen2.5vl:7b")            echo "5"  ;;
        "qwen2.5:14b")             echo "9"  ;;
        "qwen2.5-coder:14b")       echo "9"  ;;
        # --- Qwopus3.5-27B (featured llama.cpp chat model) ---
        # Sizes scale with quant per qwopus_default_gguf_file(tier).
        "Jackrong/Qwopus3.5-27B-v3-GGUF")
            case "$tier" in
                24)  echo "13" ;;  # Q3_K_M
                32)  echo "16" ;;  # Q4_K_M
                48)  echo "19" ;;  # Q5_K_M
                64)  echo "22" ;;  # Q6_K
                96)  echo "29" ;;  # Q8_0
                128) echo "54" ;;  # BF16
                *)   echo "16" ;;  # Q4_K_M fallback
            esac ;;
        # --- Ollama models ---
        "qwen3:32b")             echo "20" ;;
        "qwen3:30b-a3b")         echo "19" ;;  # MoE, A3B = 3B active
        "qwen2.5:72b")           echo "47" ;;
        "qwen2.5-coder:32b")     echo "20" ;;
        "qwen2.5vl:32b")         echo "20" ;;
        "qwen2.5vl:72b")         echo "47" ;;
        "llama3.3:70b")          echo "43" ;;
        "mixtral:8x7b")          echo "26" ;;
        "mixtral:8x22b")         echo "86" ;;
        # --- HuggingFace GGUF repos (non-Qwopus) ---
        "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF")    echo "20" ;;
        "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF")     echo "19" ;;
        "unsloth/Qwen2.5-VL-32B-Instruct-GGUF")         echo "20" ;;
        "unsloth/Qwen2.5-VL-72B-Instruct-GGUF")         echo "47" ;;
        "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF")     echo "26" ;;
        "MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF")        echo "86" ;;
        *)  echo "0" ;;
    esac
}

# ─── KV-cache heuristic ────────────────────────────────────────────────
# Same formula as macos-prep-setup.sh's estimate_vram_usage():
#   KV ≈ (ctx/1024) * (bytes_per/2) * sqrt(model_gb/7) * 0.10
# sqrt scales sublinearly with model size (GQA + MoE reduce per-token KV).
compute_kv_gb() {
    local model_gb="$1" ctx_size="$2" cache_bytes="$3"
    awk "BEGIN { printf \"%.1f\", ($ctx_size / 1024.0) * ($cache_bytes / 2.0) * sqrt($model_gb / 7.0) * 0.10 }"
}

CTX_FLOOR=65536        # Minimum guaranteed context across all tiers
CACHE_BYTES_Q4=0.5     # q4_0 KV cache (0.5 B per element)
RUNTIME_OVERHEAD=0.5   # Metal + server + tokenizer buffers

UMA_ERRORS=0
UMA_WARNINGS=0
UMA_CHECKS=0

echo
echo "Validating model fit across Apple Silicon UMA tiers:"
echo "  ctx=${CTX_FLOOR} · kv=q4_0 · runtime=+${RUNTIME_OVERHEAD} GB"
echo

for backend in ollama llama; do
    label="Ollama"
    [[ "$backend" == "llama" ]] && label="llama.cpp"

    for tier in 8 16 24 32 48 64 96 128; do
        get_model_recommendations "$backend" "$tier"

        for pair in \
            "CHAT:$REC_MODEL_CHAT" \
            "CODE:$REC_MODEL_CODE" \
            "MOE:$REC_MODEL_MOE" \
            "VISION:$REC_MODEL_VISION"; do

            category="${pair%%:*}"
            model="${pair#*:}"
            [[ -z "$model" ]] && continue
            UMA_CHECKS=$((UMA_CHECKS + 1))

            weight_gb=$(get_model_weight "$model" "$tier")
            if [[ "$weight_gb" == "0" ]]; then
                warn "${label} ${tier}GB ${category}: $model — size unknown (add to lookup)"
                continue
            fi

            kv_gb=$(compute_kv_gb "$weight_gb" "$CTX_FLOOR" "$CACHE_BYTES_Q4")
            needed=$(awk -v w="$weight_gb" -v k="$kv_gb" -v r="$RUNTIME_OVERHEAD" \
                'BEGIN { printf "%.1f", w + k + r }')
            fits=$(awk -v n="$needed" -v t="$tier" 'BEGIN { print (n <= t) ? "yes" : "no" }')

            if [[ "$fits" == "no" ]]; then
                fail "${label} ${tier}GB ${category}: $model — needs ~${needed}GB (wt:${weight_gb}+kv:${kv_gb}+rt:${RUNTIME_OVERHEAD}) > ${tier}GB [ctx=${CTX_FLOOR} q4_0]"
            fi
        done
    done
done

echo
if [[ $UMA_ERRORS -eq 0 && $UMA_WARNINGS -eq 0 ]]; then
    pass "All $UMA_CHECKS model/tier combinations fit within their UMA budget"
    exit 0
elif [[ $UMA_ERRORS -eq 0 ]]; then
    warn "$UMA_WARNINGS model(s) have unknown sizes ($UMA_CHECKS checked, 0 over-budget)"
    exit 0
else
    fail "$UMA_ERRORS over-budget · $UMA_WARNINGS unknown · $UMA_CHECKS total"
    exit 1
fi
