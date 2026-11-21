#!/usr/bin/env python3
"""
Empirical Information-Efficiency & Code-Churn Benchmark for znav.

Evaluates realistic Zipf(s=1.2) developer directory trees of size N in {30, 100, 500}
against the live pure-Zsh `znav.plugin.zsh` engine, comparing:
  1. Shannon Entropy Lower Bound H_2(P) (bits) and H_36(P) (chars over [a-z0-9])
  2. Live `znav` expected shortcode length, expected keystrokes (`cr\n`, `~cr`, `j cr\n`),
     0-maintenance cost, and steady-state code-churn / muscle-memory recall stability
  3. Full path `cd ~/...\n` expected keystrokes
  4. Partial manual aliases (top K=10 hand-maintained in ~/.zshrc + unaliased Zipf tail)
  5. Zsh native `cdr` (`cdr <idx>\n` / `~[<idx>]`, both max=20 default and unbounded),
     quantifying MRU code-churn rate and muscle-memory recall failure rate!

Outputs JSON consumed by `benchmarks/run_bench.zsh` and `benchmarks/update_readme.py`.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterator

ZIPF_S = 1.2
TRACE_STEPS = int(os.environ.get("ZNAV_BENCH_TRACE_STEPS", "5000"))
WARMUP_STEPS = int(os.environ.get("ZNAV_BENCH_WARMUP_STEPS", "1500"))
ALPHABET_SIZE = 36  # [a-z0-9]

# Grounded in real developer workspace naming conventions (including actual repo names
# observed in ~/CODE.REPOSITORIES plus realistic multi-repo trees)
REALISTIC_TOP_DIRS = [
    "CODE.REPOSITORIES",
    "SCRIPT.REPOS",
    "CODE.REPOSITORIES/znav",
    "CODE.REPOSITORIES/code-verification",
    "CODE.REPOSITORIES/foss-agentic-forge",
    "CODE.REPOSITORIES/mutual-information-education",
    "CODE.REPOSITORIES/design-aesthetics",
    "CODE.REPOSITORIES/agy-completions",
    "CODE.REPOSITORIES/agy-ios-handoff",
    "CODE.REPOSITORIES/Braitenberg-Vehicles",
    "CODE.REPOSITORIES/confidential-gemini-proofs",
    "CODE.REPOSITORIES/eigenym",
    "CODE.REPOSITORIES/forgejo",
    "CODE.REPOSITORIES/irc_onion",
    "CODE.REPOSITORIES/layertree",
    "CODE.REPOSITORIES/mergiraf",
    "CODE.REPOSITORIES/mpv-grid",
    "CODE.REPOSITORIES/onion-mail",
    "CODE.REPOSITORIES/sound-switch",
    "CODE.REPOSITORIES/terminal_O1_invocation",
    "CODE.REPOSITORIES/transport-covertness",
    "CODE.REPOSITORIES/visual_gap",
    "CODE.REPOSITORIES/web-service-bootstrap",
    "CODE.REPOSITORIES/zsh-mkrepo",
    "CODE.REPOSITORIES/zsh-rl",
    "SCRIPT.REPOS/backup-automation",
    "SCRIPT.REPOS/macos-diagnostics",
    "SCRIPT.REPOS/network-monitors",
    "WORK.PROJECTS/distributed-consensus",
    "WORK.PROJECTS/compiler-backend",
]

ADJECTIVES = [
    "async", "atomic", "binary", "cache", "cloud", "crypto", "cyber", "data",
    "delta", "edge", "fast", "formal", "graph", "hyper", "kernel", "latent",
    "lean", "local", "matrix", "mesh", "micro", "modern", "native", "neural",
    "open", "packet", "proto", "pure", "quantum", "reactive", "rust", "secure",
    "signal", "smart", "sparse", "static", "stream", "symbolic", "tensor", "zero",
]

NOUNS = [
    "agent", "algebra", "analyzer", "archive", "audit", "bench", "bridge", "broker",
    "builder", "canvas", "checker", "client", "cluster", "codec", "compiler", "config",
    "console", "core", "daemon", "debugger", "driver", "engine", "explorer", "fabric",
    "filter", "forge", "gateway", "gateway", "harness", "index", "inspector", "kernel",
    "lab", "ledger", "linter", "loader", "logger", "mapper", "monitor", "navigator",
    "node", "oracle", "parser", "pipeline", "planner", "plugin", "portal", "prover",
    "proxy", "queue", "relay", "repo", "router", "runner", "runtime", "sandbox",
    "scanner", "scheduler", "schema", "server", "service", "shell", "solver", "store",
    "studio", "sync", "system", "toolkit", "tracer", "tracker", "tunnel", "verifier",
    "viewer", "vm", "wal", "watcher", "worker",
]

ROOT_BUCKETS = [
    "CODE.REPOSITORIES",
    "SCRIPT.REPOS",
    "WORK.PROJECTS",
    "RESEARCH.LABS",
    "INFRA.SYSTEMS",
    "ARCHIVE.REPOS",
]

_RE_CAMEL_1 = re.compile(r"([a-z0-9])([A-Z])")
_RE_CAMEL_2 = re.compile(r"([A-Z])([A-Z][a-z])")
_RE_NON_ALNUM = re.compile(r"[^A-Za-z0-9]+")


def _fallback_lse_fold(lam: float | None, x: float, tau: float) -> float:
    if lam is None or lam == -math.inf:
        return float(x)
    m = lam if lam >= x else x
    return m + tau * math.log(1.0 + math.exp(-abs(lam - x) / tau))


def _fallback_tokenize(s: str) -> list[str]:
    s1 = _RE_CAMEL_1.sub(r"\1 \2", s)
    s2 = _RE_CAMEL_2.sub(r"\1 \2", s1)
    s3 = _RE_NON_ALNUM.sub(" ", s2).lower()
    return [tok for tok in s3.split() if tok]


def _fallback_compositions_desc(total: int, caps: list[int]) -> Iterator[tuple[int, ...]]:
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
        for tail in _fallback_compositions_desc(total - l1, caps[1:]):
            yield (l1,) + tail


def _fallback_candidate_stream(d: str) -> Iterator[str]:
    d = "/" if d == "/" else (d.rstrip("/") or "/")
    if d == "/":
        t_list, p_list = ["root", "dir"], []
    else:
        base = d[d.rfind("/") + 1 :]
        parent = "/" if d.rfind("/") == 0 else d[: d.rfind("/")]
        t_list = _fallback_tokenize(base) or ["dir"]
        p_list = [] if parent == "/" else _fallback_tokenize(parent[parent.rfind("/") + 1 :])

    seen: set[str] = set()
    erg: list[str] = []

    def norm_id(raw: str) -> str | None:
        if not raw:
            return None
        if "0" <= raw[0] <= "9":
            raw = "_" + raw
        return raw if len(raw) >= 2 else None

    def emit(raw: str) -> None:
        cid = norm_id(raw)
        if cid is not None and cid not in seen:
            seen.add(cid)
            erg.append(cid)

    m = len(t_list)
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
            for lengths in _fallback_compositions_desc(total_len, caps):
                emit("".join(tok[:l] for tok, l in zip(sub_toks, lengths)))

    emit("".join(t_list))
    b_full = "_".join(t_list)
    emit(b_full)
    if p_list:
        p_init = "".join(tok[0] for tok in p_list[: min(len(p_list), 4)])
        b_init = "".join(tok[0] for tok in t_list[: min(m, 4)])
        p_full = "_".join(p_list)
        emit(p_init + b_init)
        emit(p_init + "_" + b_full)
        emit(p_full + "_" + b_full)

    for cid in erg:
        yield cid

    raw_stem = ("_".join(p_list) + "_" + b_full) if p_list else b_full
    stem = norm_id(raw_stem) or ("_" + raw_stem)
    if len(stem) < 2:
        stem = "_dir"
    if stem not in seen:
        seen.add(stem)
        yield stem
    idx = 2
    while True:
        cand = f"{stem}_{idx}"
        idx += 1
        if cand not in seen:
            seen.add(cand)
            yield cand


def load_spec_primitives(repo_root: Path):
    """Load canonical (lse_fold, candidate_stream) from proofs/znav_spec.py if present."""
    proofs_dir = repo_root / "proofs"
    if (proofs_dir / "znav_spec.py").is_file():
        sys.path.insert(0, str(proofs_dir))
        import znav_spec as zs  # type: ignore
        return zs.log_epoch_fold, zs.candidate_stream

    tests_dir = repo_root / "tests"
    if (tests_dir / "diff_conformance.py").is_file():
        sys.path.insert(0, str(tests_dir))
        import diff_conformance as dc  # type: ignore
        return dc.lse_fold, dc.candidate_stream

    return _fallback_lse_fold, _fallback_candidate_stream


def resolve_zsh_bin() -> str:
    override = os.environ.get("ZNAV_BENCH_ZSH")
    if override:
        return override
    found = shutil.which("zsh")
    if found:
        return found
    return "/bin/zsh"


def generate_tree_relpaths(n: int, seed: int = 42) -> list[str]:
    rng = random.Random(seed + n)
    paths: list[str] = []
    seen: set[str] = set()
    for p in REALISTIC_TOP_DIRS:
        if len(paths) >= n:
            break
        seen.add(p)
        paths.append(p)

    idx = 0
    while len(paths) < n:
        idx += 1
        bucket = ROOT_BUCKETS[idx % len(ROOT_BUCKETS)]
        a = rng.choice(ADJECTIVES)
        b = rng.choice(NOUNS)
        sep = rng.choice(["-", "_", "."])
        if rng.random() < 0.25:
            c = rng.choice(["v2", "core", "cli", "api", "lib", "ops", "ui", "sdk"])
            rel = f"{bucket}/{a}{sep}{b}{sep}{c}"
        else:
            rel = f"{bucket}/{a}{sep}{b}"
        if rel not in seen:
            seen.add(rel)
            paths.append(rel)
    return paths


def zipf_probs(n: int, s: float = ZIPF_S) -> list[float]:
    weights = [1.0 / ((r + 1) ** s) for r in range(n)]
    total = sum(weights)
    return [w / total for w in weights]


def query_live_znav_codes(
    plugin_path: Path,
    home_dir: Path,
    data_dir: Path,
    abs_dirs_ranked: list[str],
    zsh_bin: str,
) -> dict[str, str]:
    """
    Create all N directories in sandbox, assign strictly decreasing Lambda scores in live Zsh
    matching their exact Zipf rank order, trigger znav's real shortcode projection, and return
    the exact `dir -> code` map produced by the pure-Zsh implementation.
    """
    t_base = 1795126400.0
    env = {
        "HOME": str(home_dir),
        "ZNAV_DATA_DIR": str(data_dir),
        "ZNAV_MAX_NAMEDDIRS": str(max(1000, len(abs_dirs_ranked) + 50)),
        "ZNAV_TOP_K": str(max(1000, len(abs_dirs_ranked) + 50)),
        "ZNAV_AVOID_COMMANDS": "1",
        "LC_ALL": "C",
        "USER": os.environ.get("USER", "username"),
        "LOGNAME": os.environ.get("LOGNAME", "username"),
        "TERM": "dumb",
        "PATH": "/usr/local/bin:/usr/bin:/bin",
    }

    dir_list_file = data_dir / "_bench_dirs.txt"
    dir_list_file.write_text("\n".join(abs_dirs_ranked) + "\n", encoding="utf-8")

    zsh_script = f"""
PROMPT="" RPROMPT=""
zmodload zsh/mathfunc zsh/parameter
zmodload -F zsh/files b:zf_mkdir
integer rank=0
float -E 17 base_t={t_base}
zf_mkdir -p -- {str(data_dir)!r}
local -a db_lines=()
while IFS= read -r d; do
  [[ -z $d ]] && continue
  (( rank++ ))
  float -E 17 sc=$(( base_t - rank * 100.0 ))
  local sc_s
  printf -v sc_s '%.17g' $sc
  db_lines+=("S ${{sc_s}} ${{(qqqq)d}}")
done < {str(dir_list_file)!r}
print -rl -- "${{db_lines[@]}}" > {str(data_dir / "db.tsv")!r}

source {str(plugin_path)!r} || exit 1

for k in "${{(@k)nameddirs}}"; do
  if (( ${{+_ZNAV_OWNED_NAMEDDIRS[$k]}} )); then
    printf "MAP\\t%s\\t%s\\n" "$k" "${{nameddirs[$k]}}"
  fi
done
"""
    out = subprocess.check_output(
        [zsh_bin, "-dfi", "+Z", "+m", "-c", zsh_script],
        env=env,
        text=True,
    )
    dir_to_code: dict[str, str] = {}
    for ln in out.splitlines():
        if ln.startswith("MAP\t"):
            _, code, d = ln.split("\t", 2)
            dir_to_code[d] = code

    if len(dir_to_code) < len(abs_dirs_ranked):
        zsh_fallback = (
            zsh_script
            + '\nfor k in "${(@k)_ZNAV_CODE2DIR}"; do printf "ALT\\t%s\\t%s\\n" "$k" "${_ZNAV_CODE2DIR[$k]}"; done 2>/dev/null || true\n'
        )
        out2 = subprocess.check_output(
            [zsh_bin, "-dfi", "+Z", "+m", "-c", zsh_fallback],
            env=env,
            text=True,
        )
        for ln in out2.splitlines():
            if ln.startswith("ALT\t"):
                _, code, d = ln.split("\t", 2)
                dir_to_code.setdefault(d, code)

    return dir_to_code


def simulate_workload(
    n: int,
    plugin_path: Path,
    zsh_bin: str,
    lse_fold_fn,
    candidate_stream_fn,
) -> dict[str, object]:
    relpaths = generate_tree_relpaths(n, seed=1000 + n)
    probs = zipf_probs(n, ZIPF_S)

    with tempfile.TemporaryDirectory(prefix=f"znav_info_{n}_") as tmp_raw:
        tmp = Path(os.path.realpath(tmp_raw))
        home_dir = tmp / "home"
        data_dir = tmp / "data"
        home_dir.mkdir()
        data_dir.mkdir()

        abs_dirs: list[str] = []
        for rel in relpaths:
            p = home_dir / rel
            p.mkdir(parents=True, exist_ok=True)
            abs_dirs.append(str(p))

        dir_to_code = query_live_znav_codes(plugin_path, home_dir, data_dir, abs_dirs, zsh_bin)
        assert len(dir_to_code) == n, (
            f"Expected {n} codes from live znav, got {len(dir_to_code)}"
        )

    # 1. Shannon Entropy Lower Bounds
    h_bits = -sum(p * math.log2(p) for p in probs)
    h_chars_36 = h_bits / math.log2(ALPHABET_SIZE)

    # 2. Expected keystrokes under stationary Zipf(1.2) distribution
    exp_code_len = sum(probs[r] * len(dir_to_code[abs_dirs[r]]) for r in range(n))
    exp_ks_znav_bare = exp_code_len + 1.0
    exp_ks_znav_j = exp_code_len + 3.0
    exp_ks_full_cd = sum(probs[r] * (len(f"cd ~/{relpaths[r]}\n")) for r in range(n))

    manual_k = min(10, n)
    exp_ks_manual = 0.0
    maint_chars_manual = 0
    for r in range(n):
        if r < manual_k:
            code_r = dir_to_code[abs_dirs[r]]
            exp_ks_manual += probs[r] * (len(code_r) + 1)
            maint_chars_manual += len(f"alias {code_r}='cd ~/{relpaths[r]}'\n")
        else:
            exp_ks_manual += probs[r] * len(f"cd ~/{relpaths[r]}\n")
    unaliased_tail_mass = sum(probs[manual_k:])

    # 3. Empirical Trace Simulation (WARMUP_STEPS + TRACE_STEPS) for `cdr` vs `znav` Code Churn
    rng = random.Random(9001 + n)
    cum_probs: list[float] = []
    acc = 0.0
    for p in probs:
        acc += p
        cum_probs.append(acc)

    def sample_rank() -> int:
        u = rng.random()
        lo, hi = 0, n - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if cum_probs[mid] < u:
                lo = mid + 1
            else:
                hi = mid
        return lo

    tau = 259200.0 / math.log(2.0)
    znav_lam: dict[int, float] = {}
    t_sim = 1795126400.0
    for r in range(n):
        znav_lam[r] = t_sim - 259200.0

    cand_lists = [list(itertools.islice(candidate_stream_fn(d), 25)) for d in abs_dirs]

    def compute_sim_phi() -> dict[int, str]:
        order = sorted(
            range(n),
            key=lambda r: (-znav_lam[r], abs_dirs[r].count("/"), len(abs_dirs[r]), abs_dirs[r]),
        )
        used: set[str] = {"tr", "pr", "ls", "cp", "cd", "fc", "do", "fi", "znav", "j"}
        phi: dict[int, str] = {}
        for r in order:
            for c in cand_lists[r]:
                if c not in used:
                    used.add(c)
                    phi[r] = c
                    break
        return phi

    cur_dir = 0
    cdr_stack_unbounded: list[int] = [0]
    cdr_stack_20: list[int] = [0]
    for _ in range(WARMUP_STEPS):
        t_sim += rng.expovariate(1.0 / 180.0)
        nxt = sample_rank()
        if nxt == cur_dir:
            continue
        znav_lam[nxt] = lse_fold_fn(znav_lam[nxt], t_sim, tau)
        if nxt in cdr_stack_unbounded:
            cdr_stack_unbounded.remove(nxt)
        cdr_stack_unbounded.insert(0, nxt)
        if nxt in cdr_stack_20:
            cdr_stack_20.remove(nxt)
        cdr_stack_20.insert(0, nxt)
        if len(cdr_stack_20) > 20:
            cdr_stack_20.pop()
        cur_dir = nxt

    prev_phi = compute_sim_phi()
    last_used_znav_code: dict[int, str] = {}
    last_used_cdr_code: dict[int, str] = {}

    znav_repeat_visits = 0
    znav_same_code_hits = 0
    znav_top10_step_mutations = 0

    cdr_repeat_visits = 0
    cdr_same_code_hits = 0
    cdr_step_mutations = 0
    cdr20_ks_total = 0.0
    cdr_unbounded_ks_total = 0.0
    measured_transitions = 0

    for _ in range(TRACE_STEPS):
        t_sim += rng.expovariate(1.0 / 180.0)
        nxt = sample_rank()
        if nxt == cur_dir:
            continue
        measured_transitions += 1

        z_code_now = prev_phi[nxt]
        if nxt in last_used_znav_code:
            znav_repeat_visits += 1
            if last_used_znav_code[nxt] == z_code_now:
                znav_same_code_hits += 1
        last_used_znav_code[nxt] = z_code_now

        if nxt in cdr_stack_unbounded[1:]:
            idx_unb = cdr_stack_unbounded.index(nxt)
            cdr_code_now = str(idx_unb)
            cdr_unbounded_ks_total += 4 if idx_unb == 1 else (4 + len(cdr_code_now) + 1)
        else:
            cdr_code_now = f"MISS_{nxt}"
            cdr_unbounded_ks_total += len(f"cd ~/{relpaths[nxt]}\n")

        if nxt in cdr_stack_20[1:]:
            idx_20 = cdr_stack_20.index(nxt)
            cdr20_ks_total += 4 if idx_20 == 1 else (4 + len(str(idx_20)) + 1)
        else:
            cdr20_ks_total += len(f"cd ~/{relpaths[nxt]}\n")

        if nxt in last_used_cdr_code:
            cdr_repeat_visits += 1
            if last_used_cdr_code[nxt] == cdr_code_now and not cdr_code_now.startswith("MISS_"):
                cdr_same_code_hits += 1
        last_used_cdr_code[nxt] = cdr_code_now

        cdr_step_mutations += 1
        if nxt in cdr_stack_unbounded:
            cdr_stack_unbounded.remove(nxt)
        cdr_stack_unbounded.insert(0, nxt)

        if nxt in cdr_stack_20:
            cdr_stack_20.remove(nxt)
        cdr_stack_20.insert(0, nxt)
        if len(cdr_stack_20) > 20:
            cdr_stack_20.pop()

        znav_lam[nxt] = lse_fold_fn(znav_lam[nxt], t_sim, tau)
        new_phi = compute_sim_phi()
        if any(new_phi[r] != prev_phi[r] for r in range(min(10, n))):
            znav_top10_step_mutations += 1
        prev_phi = new_phi
        cur_dir = nxt

    znav_churn_pct = 100.0 * (1.0 - (znav_same_code_hits / max(1, znav_repeat_visits)))
    znav_top10_mut_pct = 100.0 * (znav_top10_step_mutations / max(1, measured_transitions))
    cdr_churn_pct = 100.0 * (1.0 - (cdr_same_code_hits / max(1, cdr_repeat_visits)))
    cdr_step_mut_pct = 100.0 * (cdr_step_mutations / max(1, measured_transitions))

    return {
        "N": n,
        "H_bits": round(h_bits, 2),
        "H_36_chars": round(h_chars_36, 2),
        "H_36_bare_cmd_lb": round(h_chars_36 + 1.0, 2),
        "znav_exp_code_len": round(exp_code_len, 2),
        "znav_exp_ks_bare": round(exp_ks_znav_bare, 2),
        "znav_exp_ks_tilde": round(exp_ks_znav_bare, 2),
        "znav_exp_ks_j": round(exp_ks_znav_j, 2),
        "znav_recall_churn_pct": round(znav_churn_pct, 2),
        "znav_top10_step_churn_pct": round(znav_top10_mut_pct, 2),
        "full_cd_exp_ks": round(exp_ks_full_cd, 2),
        "manual10_exp_ks": round(exp_ks_manual, 2),
        "manual10_tail_pct": round(100.0 * unaliased_tail_mass, 1),
        "manual10_maint_chars": maint_chars_manual,
        "cdr_default20_exp_ks": round(cdr20_ks_total / max(1, measured_transitions), 2),
        "cdr_unbounded_exp_ks": round(cdr_unbounded_ks_total / max(1, measured_transitions), 2),
        "cdr_recall_churn_pct": round(cdr_churn_pct, 2),
        "cdr_step_mut_pct": round(cdr_step_mut_pct, 1),
        "sample_top5_codes": [
            {
                "dir": "~/" + relpaths[r],
                "code": dir_to_code[abs_dirs[r]],
                "prob_pct": round(100.0 * probs[r], 2),
            }
            for r in range(min(5, n))
        ],
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Run Zipf(1.2) information-efficiency benchmark.")
    parser.add_argument(
        "--plugin",
        type=Path,
        default=repo_root / "znav.plugin.zsh",
        help="Path to znav.plugin.zsh",
    )
    args = parser.parse_args()

    plugin_path = args.plugin.resolve()
    if not plugin_path.is_file():
        print(f"[FAIL] {plugin_path} not found.", file=sys.stderr)
        return 1

    zsh_bin = resolve_zsh_bin()
    lse_fold_fn, candidate_stream_fn = load_spec_primitives(plugin_path.parent)
    results = [
        simulate_workload(n, plugin_path, zsh_bin, lse_fold_fn, candidate_stream_fn)
        for n in (30, 100, 500)
    ]
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
