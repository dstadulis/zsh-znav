#!/usr/bin/env python3
"""Canonical Executable Mathematical Specification for znav.

This module implements the exact proven mathematical core of `znav`:
  1. Primitive 1: Overflow-Safe Log-Epoch Frecency Monoid (R u {-inf}, (+)_tau, -inf)
  2. Strict Total Order (>) on canonical directory paths
  3. Deterministic ASCII Segment Tokenizer & Candidate Lattice Stream K(d)
  4. Greedy Priority-Optimal Collision-Free Shortcode Bijection phi: D -> Sigma^+ \\ R
  5. Monotone Multi-Token Query Resolver resolve(Q)

It also serves as a differential-testing CLI oracle (`znav_spec.py --trace`) so
`tests/` can verify 1-to-1 conformance between formal proofs and live Zsh code.
"""

from __future__ import annotations

import itertools
import json
import math
import os
import re
import sys
from typing import (
    AbstractSet,
    Dict,
    Iterable,
    Iterator,
    List,
    Mapping,
    Optional,
    Sequence,
    Tuple,
)

ZNAV_HALF_LIFE_DEFAULT: float = 259200.0  # 72 hours (3 days) in seconds

_CAMEL_LOWER_UPPER_RE = re.compile(r"([a-z0-9])([A-Z])")
_CAMEL_ACRONYM_WORD_RE = re.compile(r"([A-Z])([A-Z][a-z])")
_NON_ALNUM_ASCII_RE = re.compile(r"[^A-Za-z0-9]+")


def tau_from_half_life(half_life: float = ZNAV_HALF_LIFE_DEFAULT) -> float:
    """Return decay time constant tau = H / ln(2) > 0."""
    if half_life <= 0.0 or not math.isfinite(half_life):
        raise ValueError(f"half_life must be finite and positive, got {half_life!r}")
    return half_life / math.log(2.0)


def log_epoch_fold(lam: Optional[float], x: float, tau: float) -> float:
    """Overflow-safe Log-Epoch monoid operation lam (+)_tau x.

    First visit (lam is None or -inf): returns x.
    Subsequent visit: max(lam, x) + tau * ln(1 + exp(-|lam - x| / tau)).
    """
    if tau <= 0.0 or not math.isfinite(tau):
        raise ValueError(f"tau must be finite and positive, got {tau!r}")
    if not math.isfinite(x):
        raise ValueError(f"event timestamp x must be finite, got {x!r}")
    if lam is None or lam == -math.inf:
        return float(x)
    if not math.isfinite(lam):
        raise ValueError(f"existing score lam must be finite or -inf, got {lam!r}")
    mx = lam if lam >= x else x
    diff = math.fabs(lam - x)
    return mx + tau * math.log(1.0 + math.exp(-diff / tau))


def seed_initial_score(
    t0: float, half_life: float = ZNAV_HALF_LIFE_DEFAULT
) -> float:
    """Baseline Log-Epoch score t0 - H (weight 0.5 at t0) for unseen seeded dirs."""
    return float(t0 - half_life)


def effective_weight(lam: float, t_ref: float, tau: float) -> float:
    """Exact decayed frecency weight S_d(t_ref) = exp((lam - t_ref) / tau)."""
    return math.exp((lam - t_ref) / tau)


def visit_probabilities(
    scores: Mapping[str, float], tau: float
) -> Dict[str, float]:
    """Scale-free, time-translation-invariant empirical distribution P(d).

    Uses max-shifted softmax exp((lam_d - lam_max)/tau) / Z so it never overflows
    regardless of epoch magnitude and is strictly independent of reference time t.
    """
    if not scores:
        return {}
    lam_max = max(scores.values())
    unnorm = {d: math.exp((lam - lam_max) / tau) for d, lam in scores.items()}
    total = sum(unnorm.values())
    return {d: w / total for d, w in unnorm.items()}


def canonicalize_path_string(d: str) -> str:
    """Normalize an already-resolved absolute path string (strip trailing '/' except '/')."""
    if not d or not d.startswith("/"):
        raise ValueError(f"canonical path must start with '/', got {d!r}")
    if d == "/":
        return "/"
    stripped = d.rstrip("/")
    return stripped if stripped else "/"


def path_depth(d: str) -> int:
    """Slash depth of canonical path d: 0 for '/', count('/') otherwise."""
    d = canonicalize_path_string(d)
    if d == "/":
        return 0
    return d.count("/")


def path_byte_len(d: str) -> int:
    """UTF-8 / ASCII byte length of canonical path d (matches Zsh no_multibyte ${#d})."""
    return len(d.encode("utf-8", errors="surrogateescape"))


def path_basename(d: str) -> str:
    """Basename of canonical path d (matches Zsh ${d:t}; '' for '/')."""
    d = canonicalize_path_string(d)
    if d == "/":
        return ""
    idx = d.rfind("/")
    return d[idx + 1 :]


def path_parent(d: str) -> str:
    """Parent directory of canonical path d (matches Zsh ${d:h}; '/' for '/foo' or '/')."""
    d = canonicalize_path_string(d)
    if d == "/":
        return "/"
    idx = d.rfind("/")
    return "/" if idx == 0 else d[:idx]


def strictly_precedes(a: str, lam_a: float, b: str, lam_b: float) -> bool:
    """Strict total order a > b on canonical directories.

    a > b iff:
      1. lam_a > lam_b, OR
      2. lam_a == lam_b and depth(a) < depth(b), OR
      3. lam_a == lam_b and depth(a) == depth(b) and byte_len(a) < byte_len(b), OR
      4. lam_a == lam_b and depth(a) == depth(b) and byte_len(a) == byte_len(b)
         and a_bytes < b_bytes (LC_ALL=C ASCII/byte lexicographic order).
    """
    if lam_a != lam_b:
        return lam_a > lam_b
    da, db = path_depth(a), path_depth(b)
    if da != db:
        return da < db
    ba = a.encode("utf-8", errors="surrogateescape")
    bb = b.encode("utf-8", errors="surrogateescape")
    if len(ba) != len(bb):
        return len(ba) < len(bb)
    return ba < bb


def sort_directories_desc(scores: Mapping[str, float]) -> List[str]:
    """Return canonical directories sorted in strictly descending (>) order."""
    return sorted(
        scores.keys(),
        key=lambda d: (
            -scores[d],
            path_depth(d),
            path_byte_len(d),
            d.encode("utf-8", errors="surrogateescape"),
        ),
    )


def tokenize(s: str) -> List[str]:
    """Deterministic ASCII segment tokenizer matching pure-Zsh extended_glob rules.

    1. Split [a-z0-9][A-Z] -> '\\1 \\2'
    2. Split [A-Z][A-Z][a-z] -> '\\1 \\2'
    3. Replace [^A-Za-z0-9] with space, lowercase, split into non-empty tokens.
    """
    s1 = _CAMEL_LOWER_UPPER_RE.sub(r"\1 \2", s)
    s2 = _CAMEL_ACRONYM_WORD_RE.sub(r"\1 \2", s1)
    s3 = _NON_ALNUM_ASCII_RE.sub(" ", s2).lower()
    return [tok for tok in s3.split(" ") if tok]


def norm_id(s: str) -> Optional[str]:
    """Normalize raw candidate string into valid Zsh identifier of length >= 2."""
    if not s:
        return None
    if "0" <= s[0] <= "9":
        s = "_" + s
    if len(s) < 2:
        return None
    return s


def _bounded_compositions_desc(
    total: int, caps: Sequence[int]
) -> Iterator[Tuple[int, ...]]:
    """Yield tuples (l_1, ..., l_k) with 1 <= l_i <= caps[i-1], sum == total,
    in strictly descending lexicographic order of (l_1, ..., l_k).
    """
    k = len(caps)
    if k == 1:
        if 1 <= total <= caps[0]:
            yield (total,)
        return
    min_rest = k - 1
    max_rest = sum(caps[1:])
    hi = min(caps[0], total - min_rest)
    lo = max(1, total - max_rest)
    for l1 in range(hi, lo - 1, -1):
        for tail in _bounded_compositions_desc(total - l1, caps[1:]):
            yield (l1,) + tail


def _directory_tokens(d: str) -> Tuple[List[str], List[str]]:
    """Return (basename_tokens T, parent_tokens P) for canonical path d."""
    d = canonicalize_path_string(d)
    if d == "/":
        return ["root", "dir"], []
    t_list = tokenize(path_basename(d))
    if not t_list:
        t_list = ["dir"]
    parent = path_parent(d)
    p_list = [] if parent == "/" else tokenize(path_basename(parent))
    return t_list, p_list


def candidate_finite_prefix(d: str) -> List[str]:
    """Return deduplicated ergonomic candidates (Tiers 1..4) of K(d)."""
    t_list, p_list = _directory_tokens(d)
    m = len(t_list)
    seen = set()
    out: List[str] = []

    def emit(raw: str) -> None:
        cid = norm_id(raw)
        if cid is not None and cid not in seen:
            seen.add(cid)
            out.append(cid)

    # Tier 1 + 2: Segment-Prefix Lattice
    if m == 1:
        t1 = t_list[0]
        for length in range(2, min(len(t1), 8) + 1):
            emit(t1[:length])
    else:
        if m > 4:
            emit("".join(tok[0] for tok in t_list[: min(m, 8)]))
        m_eff = min(m, 4)
        sub_toks = t_list[:m_eff]
        caps = [len(tok) for tok in sub_toks]
        for total_len in range(m_eff, 7):
            for lengths in _bounded_compositions_desc(total_len, caps):
                emit("".join(tok[:l] for tok, l in zip(sub_toks, lengths)))

    # Tier 3: Normalized Basename
    emit("".join(t_list))
    b_full = "_".join(t_list)
    emit(b_full)

    # Tier 4: Parent Disambiguation (when P is non-empty)
    if p_list:
        p_init = "".join(tok[0] for tok in p_list[: min(len(p_list), 4)])
        b_init = "".join(tok[0] for tok in t_list[: min(m, 4)])
        p_full = "_".join(p_list)
        emit(p_init + b_init)
        emit(p_init + "_" + b_full)
        emit(p_full + "_" + b_full)

    return out


def candidate_stream(d: str) -> Iterator[str]:
    """Infinite deterministic collision-free stream K(d) (Tiers 1..5)."""
    erg = candidate_finite_prefix(d)
    seen = set(erg)
    for cid in erg:
        yield cid

    # Tier 5: Unbounded Collision-Free Tail
    t_list, p_list = _directory_tokens(d)
    b_full = "_".join(t_list)
    if p_list:
        raw_stem = "_".join(p_list) + "_" + b_full
    else:
        raw_stem = b_full
    stem = norm_id(raw_stem)
    if stem is None:
        stem = "_" + raw_stem
    if stem not in seen:
        seen.add(stem)
        yield stem
    for idx in itertools.count(2):
        cand = f"{stem}_{idx}"
        if cand not in seen:
            seen.add(cand)
            yield cand


def assign_shortcodes(
    scores: Mapping[str, float],
    reserved: AbstractSet[str] = frozenset(),
) -> Dict[str, str]:
    """Greedy descending-(>) collision-free bijection phi: D -> Sigma^+ \\ R."""
    ordered = sort_directories_desc(scores)
    used = set(reserved)
    phi: Dict[str, str] = {}
    for d in ordered:
        for cand in candidate_stream(d):
            if cand not in used:
                phi[d] = cand
                used.add(cand)
                break
    return phi


def _ordered_substrings_match(haystack: str, needles: Sequence[str]) -> bool:
    """True iff needles appear in order (non-overlapping) inside haystack."""
    pos = 0
    for needle in needles:
        idx = haystack.find(needle, pos)
        if idx < 0:
            return False
        pos = idx + len(needle)
    return True


def matches_primary(d: str, query_tokens: Sequence[str]) -> bool:
    """Intrinsic primary match predicate between canonical path d and query tokens Q.

    Depends ONLY on (d, Q) — strictly independent of peer directories D!
    True iff:
      - |Q| == 1 and lower(q_1) is in Tiers 1..4 of K(d), OR
      - lower(q_1..q_r) match as ordered substrings along lower(d) AND lower(q_r)
        is a substring of lower(basename(d)).
    """
    if not query_tokens:
        return False
    q_low = [q.lower() for q in query_tokens if q]
    if not q_low:
        return False
    if len(q_low) == 1 and q_low[0] in candidate_finite_prefix(d):
        return True
    d_low = canonicalize_path_string(d).lower()
    base_low = path_basename(d).lower()
    if q_low[-1] not in base_low:
        return False
    return _ordered_substrings_match(d_low, q_low)


def matches_fallback(d: str, query_tokens: Sequence[str]) -> bool:
    """Intrinsic fallback match predicate: ordered substrings anywhere along lower(d)."""
    q_low = [q.lower() for q in query_tokens if q]
    if not q_low:
        return False
    return _ordered_substrings_match(canonicalize_path_string(d).lower(), q_low)


def resolve_query(
    query_tokens: Sequence[str],
    scores: Mapping[str, float],
    phi: Optional[Mapping[str, str]] = None,
    existing_dirs: Optional[AbstractSet[str]] = None,
    reserved: AbstractSet[str] = frozenset(),
    single_token_shortcode: bool = True,
) -> Optional[str]:
    """Resolve interactive query Q = (q_1, ..., q_r) to winning canonical directory."""
    active_scores = (
        {d: s for d, s in scores.items() if d in existing_dirs}
        if existing_dirs is not None
        else dict(scores)
    )
    if not active_scores or not query_tokens:
        return None
    if phi is None:
        phi = assign_shortcodes(active_scores, reserved)

    # 1. Exact Shortcode Lookup (for single-token non-colon queries)
    if single_token_shortcode and len(query_tokens) == 1:
        q0 = query_tokens[0]
        q0_low = q0.lower()
        for d, code in phi.items():
            if d in active_scores and (code == q0 or code == q0_low):
                return d

    ordered = sort_directories_desc(active_scores)

    # 2. Primary (>)-maximal intrinsic match
    for d in ordered:
        if matches_primary(d, query_tokens):
            return d

    # 3. Fallback (>)-maximal full-path match
    for d in ordered:
        if matches_fallback(d, query_tokens):
            return d

    return None


def run_trace_json(payload: dict) -> dict:
    """Execute a trace of operations for differential conformance verification.

    Input JSON schema:
      {
        "half_life": 259200.0,
        "reserved": ["root", "tr", "pr", ...],
        "ops": [
          {"op": "seed", "dir": "/path", "t": 1700000000.0},
          {"op": "visit", "dir": "/path", "t": 1700000010.0},
          {"op": "delete", "dir": "/path"},
          {"op": "resolve", "query": ["cr"], "colon": false}
        ]
      }
    """
    hl = float(payload.get("half_life", ZNAV_HALF_LIFE_DEFAULT))
    tau = tau_from_half_life(hl)
    reserved = frozenset(payload.get("reserved", []))
    scores: Dict[str, float] = {}
    existing: set[str] = set()
    resolutions: List[Optional[str]] = []

    for item in payload.get("ops", []):
        kind = item["op"]
        if kind == "seed":
            d = canonicalize_path_string(item["dir"])
            existing.add(d)
            if d not in scores:
                scores[d] = seed_initial_score(float(item["t"]), hl)
        elif kind == "visit":
            d = canonicalize_path_string(item["dir"])
            existing.add(d)
            scores[d] = log_epoch_fold(scores.get(d), float(item["t"]), tau)
        elif kind == "mkdir":
            existing.add(canonicalize_path_string(item["dir"]))
        elif kind == "delete":
            d = canonicalize_path_string(item["dir"])
            existing.discard(d)
            if item.get("prune", False):
                scores.pop(d, None)
        elif kind == "prune":
            scores = {d: s for d, s in scores.items() if d in existing}
        elif kind == "resolve":
            active = {d: s for d, s in scores.items() if d in existing}
            phi_cur = assign_shortcodes(active, reserved)
            ans = resolve_query(
                item["query"],
                active,
                phi=phi_cur,
                existing_dirs=existing,
                reserved=reserved,
                single_token_shortcode=not bool(item.get("colon", False)),
            )
            resolutions.append(ans)
        else:
            raise ValueError(f"unknown trace op: {kind!r}")

    active_scores = {d: s for d, s in scores.items() if d in existing}
    ordered = sort_directories_desc(active_scores)
    phi = assign_shortcodes(active_scores, reserved)
    return {
        "ordered_dirs": ordered,
        "scores": {d: active_scores[d] for d in ordered},
        "phi": phi,
        "resolutions": resolutions,
    }


def _cli() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--trace":
        data = json.load(sys.stdin)
        out = run_trace_json(data)
        json.dump(out, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    # Quick self-smoke check
    hl = ZNAV_HALF_LIFE_DEFAULT
    tau = tau_from_half_life(hl)
    assert candidate_finite_prefix("/Users/username/CODE.REPOSITORIES")[:6] == [
        "cr",
        "cor",
        "cre",
        "codr",
        "core",
        "crep",
    ]
    assert candidate_finite_prefix("/Users/username/SCRIPT.REPOS")[:3] == [
        "sr",
        "scr",
        "sre",
    ]
    t0 = 1700000000.0
    s_code = None
    for i in range(5):
        s_code = log_epoch_fold(s_code, t0 + i, tau)
    s_cache = log_epoch_fold(None, t0 + 10.0, tau)
    phi = assign_shortcodes(
        {
            "/Users/username/CODE.REPOSITORIES": s_code,
            "/Users/username/SCRIPT.REPOS": seed_initial_score(t0, hl),
            "/Users/username/CACHE.REPOS": s_cache,
        },
        reserved=frozenset({"root", "tr", "pr"}),
    )
    assert phi["/Users/username/CODE.REPOSITORIES"] == "cr"
    assert phi["/Users/username/CACHE.REPOS"] == "car"
    assert phi["/Users/username/SCRIPT.REPOS"] == "sr"
    print("znav_spec.py: self-test OK", phi)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
