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

Outputs JSON or Markdown summary tables consumed by `benchmarks/run_bench.zsh`.
"""

from __future__ import annotations

import json
import math
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ZIPF_S = 1.2
TRACE_STEPS = 5000
WARMUP_STEPS = 1500
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


def query_live_znav_codes(plugin_path: Path, home_dir: Path, data_dir: Path, abs_dirs_ranked: list[str]) -> dict[str, str]:
    """
    Create all N directories in sandbox, assign strictly decreasing Lambda scores in live Zsh
    matching their exact Zipf rank order, trigger znav's real shortcode projection, and return
    the exact `dir -> code` map produced by `@architect`'s Zsh implementation!
    """
    # Ensure ZNAV_MAX_NAMEDDIRS (if capped by default) covers all N dirs so we measure full tree
    tau = 259200.0 / math.log(2.0)
    t_base = 1795126400.0

    # Write a snapshot/WAL or feed scores in descending rank order and invoke znav projection
    # First discover znav's snapshot/WAL/projection mechanism by inspecting znav in a subprocess:
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
        "PATH": "/usr/bin:/bin",
    }

    dir_list_file = data_dir / "_bench_dirs.txt"
    dir_list_file.write_text("\n".join(abs_dirs_ranked) + "\n", encoding="utf-8")

    zsh_script = f"""
PROMPT="" RPROMPT=""
zmodload zsh/mathfunc zsh/parameter
integer rank=0
float -E 17 base_t={t_base}
mkdir -p -- {str(data_dir)!r}
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
        ["/bin/zsh", "-dfi", "+Z", "+m", "-c", zsh_script],
        env=env,
        text=True,
    )
    dir_to_code: dict[str, str] = {}
    for ln in out.splitlines():
        if ln.startswith("MAP\t"):
            _, code, d = ln.split("\t", 2)
            dir_to_code[d] = code

    # If znav caps static `hash -d` projection at some default K < N and uses another variable name,
    # also check `_ZNAV_DIR_TO_CODE` / `_ZNAV_CODE` if needed:
    if len(dir_to_code) < len(abs_dirs_ranked):
        zsh_fallback = zsh_script + '\nfor k in "${(@k)_ZNAV_CODE_TO_DIR}"; do printf "ALT\\t%s\\t%s\\n" "$k" "${_ZNAV_CODE_TO_DIR[$k]}"; done 2>/dev/null || true\n'
        out2 = subprocess.check_output(["/bin/zsh", "-dfi", "+Z", "+m", "-c", zsh_fallback], env=env, text=True)
        for ln in out2.splitlines():
            if ln.startswith("ALT\t"):
                _, code, d = ln.split("\t", 2)
                dir_to_code.setdefault(d, code)

    return dir_to_code


def simulate_workload(n: int, plugin_path: Path) -> dict[str, object]:
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

        dir_to_code = query_live_znav_codes(plugin_path, home_dir, data_dir, abs_dirs)
        assert len(dir_to_code) == n, (
            f"Expected {n} codes from live znav, got {len(dir_to_code)}"
        )

    # 1. Shannon Entropy Lower Bounds
    h_bits = -sum(p * math.log2(p) for p in probs)
    h_chars_36 = h_bits / math.log2(ALPHABET_SIZE)

    # 2. Expected keystrokes under stationary Zipf(1.2) distribution
    # (a) znav bare shortcode (`cr\n` = len(code) + 1; inline `~cr` = len(code) + 1; `j cr\n` = len(code) + 3)
    exp_code_len = sum(probs[r] * len(dir_to_code[abs_dirs[r]]) for r in range(n))
    exp_ks_znav_bare = exp_code_len + 1.0
    exp_ks_znav_j = exp_code_len + 3.0

    # (b) Full path (`cd ~/<relpath>\n` = 5 + len(relpath) + 1 = 6 + len(relpath))
    exp_ks_full_cd = sum(probs[r] * (len(f"cd ~/{relpaths[r]}\n")) for r in range(n))

    # (c) Partial manual aliases: user hand-curates top K=10 aliases (2-3 chars), unaliased tail uses `cd ~/...\n`
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

    # 3. Empirical Trace Simulation (WARMUP_STEPS + TRACE_STEPS) for `cdr` vs `znav` Code Churn!
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

    # Simulate both:
    # - `cdr` (default recent-dirs-max=20 AND unbounded MRU stack)
    # - `znav` dynamic Log-Epoch frecency ranking over time (dt ~ Exp(mean=180s), half-life=72h)
    tau = 259200.0 / math.log(2.0)
    znav_lam: dict[int, float] = {}
    cdr_stack_unbounded: list[int] = []  # index 0 is current PWD; cdr 1 is index 1
    cdr_stack_20: list[int] = []

    t_sim = 1795126400.0
    # Pre-seed znav at t_sim - H just like `znav seed`
    for r in range(n):
        znav_lam[r] = t_sim - 259200.0

    # Precompute candidate prefixes for fast greedy bijection during trace simulation
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))
    import diff_conformance as dc  # reuse exact candidate_stream

    cand_lists = [list(dc._islice_cands(d, 25)) if hasattr(dc, "_islice_cands") else [] for d in abs_dirs]
    import itertools
    cand_lists = [list(itertools.islice(dc.candidate_stream(d), 25)) for d in abs_dirs]

    def compute_sim_phi() -> dict[int, str]:
        order = sorted(range(n), key=lambda r: (-znav_lam[r], abs_dirs[r].count("/"), len(abs_dirs[r]), abs_dirs[r]))
        used: set[str] = {"tr", "pr", "ls", "cp", "cd", "fc", "do", "fi", "znav", "j"}
        phi: dict[int, str] = {}
        for r in order:
            for c in cand_lists[r]:
                if c not in used:
                    used.add(c)
                    phi[r] = c
                    break
        return phi

    # Warmup phase
    cur_dir = 0
    cdr_stack_unbounded = [0]
    cdr_stack_20 = [0]
    for _ in range(WARMUP_STEPS):
        t_sim += rng.expovariate(1.0 / 180.0)
        nxt = sample_rank()
        if nxt == cur_dir:
            continue
        znav_lam[nxt] = dc.lse_fold(znav_lam[nxt], t_sim, tau)
        if nxt in cdr_stack_unbounded:
            cdr_stack_unbounded.remove(nxt)
        cdr_stack_unbounded.insert(0, nxt)
        if nxt in cdr_stack_20:
            cdr_stack_20.remove(nxt)
        cdr_stack_20.insert(0, nxt)
        if len(cdr_stack_20) > 20:
            cdr_stack_20.pop()
        cur_dir = nxt

    # Measurement phase over TRACE_STEPS transitions
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

        # Current code to jump to `nxt` BEFORE `cd`:
        z_code_now = prev_phi[nxt]
        if nxt in last_used_znav_code:
            znav_repeat_visits += 1
            if last_used_znav_code[nxt] == z_code_now:
                znav_same_code_hits += 1
        last_used_znav_code[nxt] = z_code_now

        # `cdr` code BEFORE `cd`: index in stack[1:] (1-based)
        if nxt in cdr_stack_unbounded[1:]:
            idx_unb = cdr_stack_unbounded.index(nxt)  # 1-based because index 0 is cur_dir!
            cdr_code_now = str(idx_unb)
            # `cdr <idx>\n` keystrokes (or `cdr\n` = 4 when idx == 1)
            cdr_unbounded_ks_total += 4 if idx_unb == 1 else (4 + len(cdr_code_now) + 1)
        else:
            cdr_code_now = f"MISS_{nxt}"
            cdr_unbounded_ks_total += len(f"cd ~/{relpaths[nxt]}\n")

        if nxt in cdr_stack_20[1:]:
            idx_20 = cdr_stack_20.index(nxt)
            cdr20_ks_total += 4 if idx_20 == 1 else (4 + len(str(idx_20)) + 1)
        else:
            # Evicted from recent-dirs-max=20! Must type full path:
            cdr20_ks_total += len(f"cd ~/{relpaths[nxt]}\n")

        if nxt in last_used_cdr_code:
            cdr_repeat_visits += 1
            if last_used_cdr_code[nxt] == cdr_code_now and not cdr_code_now.startswith("MISS_"):
                cdr_same_code_hits += 1
        last_used_cdr_code[nxt] = cdr_code_now

        # Apply transition
        # In cdr, any transition to nxt shifts old cur_dir from 0 -> 1 (mutating codes!)
        cdr_step_mutations += 1
        if nxt in cdr_stack_unbounded:
            cdr_stack_unbounded.remove(nxt)
        cdr_stack_unbounded.insert(0, nxt)

        if nxt in cdr_stack_20:
            cdr_stack_20.remove(nxt)
        cdr_stack_20.insert(0, nxt)
        if len(cdr_stack_20) > 20:
            cdr_stack_20.pop()

        znav_lam[nxt] = dc.lse_fold(znav_lam[nxt], t_sim, tau)
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
        "H_bits": round(h_bits, 3),
        "H_36_chars": round(h_chars_36, 3),
        "H_36_bare_cmd_lb": round(h_chars_36 + 1.0, 3),
        "znav_exp_code_len": round(exp_code_len, 3),
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
            {"dir": "~/" + relpaths[r], "code": dir_to_code[abs_dirs[r]], "prob_pct": round(100.0 * probs[r], 2)}
            for r in range(min(5, n))
        ],
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    plugin_path = repo_root / "znav.plugin.zsh"
    if not plugin_path.is_file():
        print(f"[FAIL] {plugin_path} not found.", file=sys.stderr)
        return 1

    results = [simulate_workload(n, plugin_path) for n in (30, 100, 500)]
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
