#!/usr/bin/env python3
"""Find short .com domains whose label ends in a fixed suffix such as "mx".

Designed for searches such as:
    oakmx.com    (5 letters before .com)
    homemx.com   (6 letters before .com)
    housemx.com  (7 letters before .com)

The prefix must be a familiar English word with no common pronunciation
collision in CMUdict. Results are ranked by familiarity and checked through
Verisign's .com RDAP service. A 404 means no current registry record was
returned; always confirm availability and premium pricing at a registrar.

Install:
    python -m pip install requests wordfreq cmudict

Example:
    python find_mx_coms.py --lengths 5,6,7 --suffix mx --include busch
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import requests

try:
    import cmudict
    from wordfreq import top_n_list, zipf_frequency
except ImportError as exc:
    raise SystemExit(
        "Missing dependencies. Run:\n"
        "  python -m pip install requests wordfreq cmudict"
    ) from exc

RDAP_URL = "https://rdap.verisign.com/com/v1/domain/{domain}"
USER_AGENT = "spoken-domain-finder/1.1 (personal availability research)"
WORD_RE = re.compile(r"^[a-z]+$")

# Words likely to create mistakes, security concerns, or an odd permanent identity.
EXCLUDED_WORDS = {
    "adult", "admin", "bank", "billing", "casino", "crypto", "domain",
    "email", "finance", "login", "medical", "money", "office", "online",
    "password", "secure", "support", "verify", "wallet", "webmail",
}

# Common spoken ambiguities. CMUdict catches additional same-pronunciation words.
EXCLUDED_HOMOPHONE_PRONE = {
    "air", "allowed", "ate", "be", "bee", "blue", "buy", "by", "cell",
    "cent", "dear", "die", "eight", "eye", "fair", "for", "four", "hear",
    "here", "hour", "know", "mail", "male", "meat", "meet", "new", "no",
    "one", "our", "pair", "peace", "piece", "plain", "plane", "right",
    "sea", "see", "son", "sun", "their", "there", "theyre", "to", "too",
    "two", "wait", "weight", "way", "we", "weak", "week", "weather",
    "whether", "which", "witch", "wood", "would", "write", "you", "your",
}

# Positive weighting for words that fit a private family/email domain.
PREFERRED_PREFIXES = {
    "all", "den", "home", "house", "inbox", "kin", "oak", "open", "post",
    "safe", "tree", "true",
}


@dataclass(frozen=True)
class Candidate:
    domain: str
    prefix: str
    spoken: str
    total_length: int
    score: float


def normalized_pronunciation(pron: list[str]) -> tuple[str, ...]:
    return tuple(re.sub(r"\d", "", phoneme) for phoneme in pron)


def parse_lengths(value: str) -> list[int]:
    try:
        lengths = sorted({int(part.strip()) for part in value.split(",") if part.strip()})
    except ValueError as exc:
        raise argparse.ArgumentTypeError("lengths must look like 5,6,7") from exc
    if not lengths or any(length < 3 or length > 20 for length in lengths):
        raise argparse.ArgumentTypeError("each total length must be between 3 and 20")
    return lengths


def load_clear_words(max_rank: int, min_zipf: float, max_prefix_length: int) -> dict[str, float]:
    pronunciations = cmudict.dict()
    raw_words = top_n_list("en", max_rank)

    words: dict[str, float] = {}
    for raw in raw_words:
        word = raw.lower()
        if not WORD_RE.fullmatch(word):
            continue
        if not (2 <= len(word) <= max_prefix_length):
            continue
        if word in EXCLUDED_WORDS or word in EXCLUDED_HOMOPHONE_PRONE:
            continue
        if word not in pronunciations:
            continue
        frequency = zipf_frequency(word, "en")
        if frequency < min_zipf and word not in PREFERRED_PREFIXES:
            continue
        words[word] = frequency

    pronunciation_map: dict[tuple[str, ...], set[str]] = defaultdict(set)
    for word in words:
        for pron in pronunciations[word]:
            pronunciation_map[normalized_pronunciation(pron)].add(word)

    clear: dict[str, float] = {}
    for word, frequency in words.items():
        if all(
            pronunciation_map[normalized_pronunciation(pron)] == {word}
            for pron in pronunciations[word]
        ):
            clear[word] = frequency
    return clear


def generate_candidates(
    words: dict[str, float], lengths: list[int], suffix: str, included: list[str]
) -> list[Candidate]:
    candidates: dict[str, Candidate] = {}
    suffix_spoken = " ".join(suffix.upper())

    pool = dict(words)
    for prefix in included:
        prefix = prefix.lower().strip()
        if WORD_RE.fullmatch(prefix):
            pool.setdefault(prefix, zipf_frequency(prefix, "en"))

    for prefix, frequency in pool.items():
        total_length = len(prefix) + len(suffix)
        if total_length not in lengths:
            continue
        joined = prefix + suffix
        score = frequency
        if prefix in PREFERRED_PREFIXES:
            score += 0.6
        # Prefer prefixes of at least four letters. Three-letter words are more
        # likely to be misheard or merged with the spoken M-X suffix.
        if len(prefix) == 3:
            score -= 0.4
        candidate = Candidate(
            domain=f"{joined}.com",
            prefix=prefix,
            spoken=f"{prefix} {suffix_spoken} dot com",
            total_length=total_length,
            score=round(score, 3),
        )
        candidates[candidate.domain] = candidate

    return sorted(candidates.values(), key=lambda item: (-item.score, item.domain))


def load_checked(path: Path) -> set[str]:
    if not path.exists():
        return set()
    with path.open(newline="", encoding="utf-8") as handle:
        return {row["domain"] for row in csv.DictReader(handle) if row.get("domain")}


def append_result(path: Path, row: dict[str, object]) -> None:
    new_file = not path.exists()
    fields = [
        "domain", "prefix", "spoken", "total_length", "score", "status",
        "http_status", "checked_at_utc", "note",
    ]
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        if new_file:
            writer.writeheader()
        writer.writerow(row)


def rdap_status(
    session: requests.Session, domain: str, timeout: float, attempts: int = 5
) -> tuple[str, int | None, str]:
    url = RDAP_URL.format(domain=domain)
    for attempt in range(attempts):
        try:
            response = session.get(url, timeout=timeout)
        except requests.RequestException as exc:
            if attempt == attempts - 1:
                return "error", None, str(exc)
            time.sleep(2 ** attempt)
            continue

        if response.status_code == 200:
            return "registered", 200, "RDAP record exists"
        if response.status_code == 404:
            return "no-rdap-record", 404, "Confirm availability and price at registrar"
        if response.status_code == 429 or 500 <= response.status_code < 600:
            if attempt == attempts - 1:
                return "error", response.status_code, "RDAP rate limit/server error"
            retry_after = response.headers.get("Retry-After")
            wait = float(retry_after) if retry_after and retry_after.isdigit() else 2 ** attempt
            time.sleep(wait)
            continue
        return "unknown", response.status_code, response.text[:160].replace("\n", " ")
    return "error", None, "Unexpected retry exit"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Find short spoken-clear .com domains ending in a fixed suffix."
    )
    parser.add_argument("--lengths", type=parse_lengths, default=parse_lengths("5,6,7"))
    parser.add_argument("--suffix", default="mx", help="Letter suffix before .com (default: mx).")
    parser.add_argument(
        "--include", action="append", default=[],
        help="Force-add a prefix such as busch. Repeat for multiple prefixes.",
    )
    parser.add_argument("--checks", type=int, default=500)
    parser.add_argument("--delay", type=float, default=1.0)
    parser.add_argument("--max-rank", type=int, default=50000)
    parser.add_argument("--min-zipf", type=float, default=4.2)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--results", type=Path, default=Path("mx_domain_checks.csv"))
    parser.add_argument("--candidates", type=Path, default=Path("mx_ranked_candidates.csv"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    suffix = args.suffix.lower().strip()
    if not WORD_RE.fullmatch(suffix):
        raise SystemExit("--suffix must contain letters only")
    max_prefix_length = max(args.lengths) - len(suffix)
    if max_prefix_length < 2:
        raise SystemExit("The suffix is too long for the requested total lengths")

    words = load_clear_words(args.max_rank, args.min_zipf, max_prefix_length)
    candidates = generate_candidates(words, args.lengths, suffix, args.include)

    with args.candidates.open("w", newline="", encoding="utf-8") as handle:
        fields = ["domain", "prefix", "spoken", "total_length", "score"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for candidate in candidates:
            writer.writerow(candidate.__dict__)

    checked = load_checked(args.results)
    pending = [candidate for candidate in candidates if candidate.domain not in checked]
    pending = pending[: args.checks]

    print(f"Generated {len(candidates):,} ranked candidates ending in {suffix}.com.")
    print(f"Previously checked: {len(checked):,}")
    print(f"Checking now: {len(pending):,}")
    print(f"Results: {args.results.resolve()}")

    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT, "Accept": "application/rdap+json"})

    available_count = 0
    for index, candidate in enumerate(pending, start=1):
        status, http_status, note = rdap_status(session, candidate.domain, args.timeout)
        append_result(
            args.results,
            {
                **candidate.__dict__,
                "status": status,
                "http_status": http_status or "",
                "checked_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "note": note,
            },
        )
        if status == "no-rdap-record":
            available_count += 1
            print(f"[{index:>4}/{len(pending)}] CANDIDATE  {candidate.domain:<18} {candidate.spoken}")
        elif index % 25 == 0 or status in {"error", "unknown"}:
            print(f"[{index:>4}/{len(pending)}] {status:<14} {candidate.domain}")
        if index < len(pending):
            time.sleep(max(args.delay, 0.25))

    print(f"\nNo-record candidates found this run: {available_count}")
    print("Confirm every candidate and any premium price at a registrar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
