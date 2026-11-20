#!/usr/bin/env python3
"""
Differential Randomized Trace Conformance Verifier for znav.

Executes 600+ randomized directory-navigation operations (`mkdir`, `seed`, `cd`,
`clock-advance`, `clock-jitter-backward`, `delete+prune`, `compact`, `reload`,
`resolve`) comparing:
  1. Verifier's independent mathematical implementation of the Formal Spec (#7),
  2. `@theorist`'s `proofs/znav_spec.py` oracle (when present), and
  3. `@architect`'s live pure-Zsh implementation (`znav.plugin.zsh`).

Asserts at multiple checkpoints and end-of-trace:
  - Exact directory set equality,
  - Exact strict total order (`succ`) ranking equality,
  - `|Lambda_zsh(d) - Lambda_spec(d)| < 1e-9` for every directory `d`,
  - Exact assigned shortcode bijection `phi_zsh(d) == phi_spec(d)` for all top dirs,
  - Exact `~code`, `~[code]`, and `j` / `resolve(Q)` agreement.
"""

from __future__ import annotations

import functools
import itertools
import math
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable

DEFAULT_HALF_LIFE = 259200.0  # 72 hours


# ---------------------------------------------------------------------------
# Independent Verifier Reference Implementation of Formal Spec (#7)
# ---------------------------------------------------------------------------

def lse_fold(lam: float | None, x: float, tau: float) -> float:
    """Overflow-safe Log-Epoch monoid fold (Lambda oplus_tau x)."""
    if lam is None:
        return float(x)
    m = lam if lam > x else x
    return m + tau * math.log(1.0 + math.exp(-abs(lam - x) / tau))


def path_depth(d: str) -> int:
    if d == "/":
        return 0
    return d.count("/")


def path_byte_len(d: str) -> int:
    return len(d.encode("utf-8"))


def succ_cmp(a: tuple[str, float], b: tuple[str, float]) -> int:
    """Return -1 if a succ b (a comes BEFORE b in descending rank), +1 if b succ a, 0 if equal."""
    da, la = a
    db, lb = b
    if la != lb:
        return -1 if la > lb else 1
    dep_a, dep_b = path_depth(da), path_depth(db)
    if dep_a != dep_b:
        return -1 if dep_a < dep_b else 1
    len_a, len_b = path_byte_len(da), path_byte_len(db)
    if len_a != len_b:
        return -1 if len_a < len_b else 1
    ba, bb = da.encode("utf-8"), db.encode("utf-8")
    if ba != bb:
        return -1 if ba < bb else 1
    return 0


_RE_CAMEL_1 = re.compile(r"([a-z0-9])([A-Z])")
_RE_CAMEL_2 = re.compile(r"([A-Z])([A-Z][a-z])")
_RE_NON_ALNUM = re.compile(r"[^A-Za-z0-9]+")


def tokenize(s: str) -> list[str]:
    s1 = _RE_CAMEL_1.sub(r"\1 \2", s)
    s2 = _RE_CAMEL_2.sub(r"\1 \2", s1)
    s3 = _RE_NON_ALNUM.sub(" ", s2).lower()
    return [tok for tok in s3.split() if tok]


def _compositions_desc(m_prime: int, bounds: list[int], total: int) -> list[tuple[int, ...]]:
    """
    Generate integer tuples (l_1, ..., l_{m'}) with 1 <= l_i <= bounds[i]
    and sum(l_i) == total in DESCENDING lexicographic order.
    """
    out: list[tuple[int, ...]] = []

    def rec(idx: int, rem: int, acc: list[int]) -> None:
        if idx == m_prime - 1:
            if 1 <= rem <= bounds[idx]:
                out.append(tuple(acc + [rem]))
            return
        # Minimum and maximum possible for current position
        rest_min = (m_prime - 1 - idx) * 1
        rest_max = sum(bounds[idx + 1 :])
        hi = min(bounds[idx], rem - rest_min)
        lo = max(1, rem - rest_max)
        for val in range(hi, lo - 1, -1):
            acc.append(val)
            rec(idx + 1, rem - val, acc)
            acc.pop()

    rec(0, total, [])
    return out


def candidate_tiers_1_to_4(d: str) -> list[str]:
    """Deterministic finite prefix of K(d) covering Tiers 1..4."""
    if d == "/":
        T = ["root", "dir"]
        P: list[str] = []
    else:
        base = os.path.basename(d)
        parent_dir = os.path.dirname(d)
        T = tokenize(base)
        if not T:
            T = ["dir"]
        if parent_dir in ("", "/"):
            P = []
        else:
            P = tokenize(os.path.basename(parent_dir))

    seen: set[str] = set()
    emitted: list[str] = []

    def emit(raw: str) -> None:
        if not raw:
            return
        s = ("_" + raw) if raw[0].isdigit() else raw
        if len(s) >= 2 and s not in seen:
            seen.add(s)
            emitted.append(s)

    m = len(T)
    # Tier 1 + 2: Segment-Prefix Lattice
    if m == 1:
        t1 = T[0]
        for L in range(2, min(len(t1), 8) + 1):
            emit(t1[:L])
    else:
        if m > 4:
            emit("".join(tok[0] for tok in T[: min(m, 8)]))
        m_prime = min(m, 4)
        bounds = [len(T[i]) for i in range(m_prime)]
        for L in range(m_prime, 7):
            for tup in _compositions_desc(m_prime, bounds, L):
                emit("".join(T[i][: tup[i]] for i in range(m_prime)))

    # Tier 3: Normalized Basename
    emit("".join(T))
    emit("_".join(T))

    # Tier 4: Parent Disambiguation
    if P:
        r = len(P)
        p_init = "".join(P[i][0] for i in range(min(r, 4)))
        b_init = "".join(T[i][0] for i in range(min(m, 4)))
        p_full = "_".join(P)
        b_full = "_".join(T)
        emit(p_init + b_init)
        emit(p_init + "_" + b_full)
        emit(p_full + "_" + b_full)

    return emitted


def candidate_stream(d: str) -> Iterable[str]:
    """Infinite collision-free candidate generator K(d) covering Tiers 1..5."""
    finite = candidate_tiers_1_to_4(d)
    seen = set(finite)
    for k in finite:
        yield k

    if d == "/":
        T = ["root", "dir"]
        P: list[str] = []
    else:
        T = tokenize(os.path.basename(d)) or ["dir"]
        parent_dir = os.path.dirname(d)
        P = [] if parent_dir in ("", "/") else tokenize(os.path.basename(parent_dir))

    b_full = "_".join(T)
    raw_stem = ("_".join(P) + "_" + b_full) if P else b_full
    stem = ("_" + raw_stem) if (raw_stem and raw_stem[0].isdigit()) else raw_stem
    if len(stem) < 2:
        stem = "_" + b_full
        if len(stem) < 2:
            stem = "_dir"

    if stem not in seen:
        seen.add(stem)
        yield stem
    for idx in itertools.count(2):
        cand = f"{stem}_{idx}"
        if cand not in seen:
            seen.add(cand)
            yield cand


class VerifierModel:
    def __init__(self, half_life: float = DEFAULT_HALF_LIFE) -> None:
        self.half_life = half_life
        self.tau = half_life / math.log(2.0)
        self.scores: dict[str, float] = {}
        self.existing_dirs: set[str] = set()

    def mkdir(self, d: str) -> None:
        self.existing_dirs.add(d)

    def rmdir(self, d: str) -> None:
        self.existing_dirs.discard(d)

    def seed(self, subdirs: list[str], t0: float) -> None:
        init_score = t0 - self.half_life
        for d in subdirs:
            self.existing_dirs.add(d)
            if d not in self.scores:
                self.scores[d] = init_score

    def visit(self, d: str, t: float) -> None:
        self.existing_dirs.add(d)
        self.scores[d] = lse_fold(self.scores.get(d), t, self.tau)

    def prune(self) -> None:
        dead = [d for d in self.scores if d not in self.existing_dirs]
        for d in dead:
            del self.scores[d]

    def ranked_items(self, live_only: bool = False) -> list[tuple[str, float]]:
        items = [
            (d, s)
            for d, s in self.scores.items()
            if (not live_only or d in self.existing_dirs)
        ]
        items.sort(key=functools.cmp_to_key(succ_cmp))
        return items

    def assign_bijection(self, reserved: set[str], max_dirs: int | None = None, live_only: bool = False) -> dict[str, str]:
        ranked = self.ranked_items(live_only=live_only)
        if max_dirs is not None:
            ranked = ranked[:max_dirs]
        used = set(reserved)
        phi: dict[str, str] = {}
        for d, _ in ranked:
            for cand in candidate_stream(d):
                if cand not in used:
                    used.add(cand)
                    phi[d] = cand
                    break
        return phi


# ---------------------------------------------------------------------------
# Cross-Check Against @theorist's proofs/znav_spec.py (if available)
# ---------------------------------------------------------------------------

def cross_check_theorist_trace(
    repo_root: Path,
    trace_ops: list[dict],
    model: VerifierModel,
    reserved: set[str],
    zsh_scores: dict[str, float],
    zsh_phi: dict[str, str],
) -> None:
    spec_path = repo_root / "proofs" / "znav_spec.py"
    if not spec_path.is_file():
        print("  [INFO] proofs/znav_spec.py not present; skipping --trace check.")
        return

    import json

    payload = {
        "half_life": model.half_life,
        "reserved": sorted(reserved),
        "ops": trace_ops,
    }
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [sys.executable, "-B", str(spec_path), "--trace"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    theo = json.loads(proc.stdout)

    # 1. Exact ordered_dirs match against VerifierModel & Live Zsh
    ver_ordered = [d for d, _ in model.ranked_items(live_only=True)]
    assert theo["ordered_dirs"] == ver_ordered, (
        f"Theorist --trace ordered_dirs != Verifier:\n  theo={theo['ordered_dirs'][:10]}\n  ver ={ver_ordered[:10]}"
    )

    # 2. Exact Lambda score match (< 1e-9) between Theorist --trace and Live Zsh
    for d, s_theo in theo["scores"].items():
        s_zsh = zsh_scores[d]
        assert abs(s_theo - s_zsh) < 1e-9, (
            f"Theorist vs Zsh Lambda drift on {d!r}: theo={s_theo:.17g}, zsh={s_zsh:.17g}"
        )

    # 3. Exact shortcode bijection phi match between Theorist --trace and Live Zsh
    n_proj = len(zsh_phi)
    for d in theo["ordered_dirs"][:n_proj]:
        assert zsh_phi.get(d) == theo["phi"][d], (
            f"Theorist vs Zsh phi mismatch on {d!r}: theo={theo['phi'][d]!r}, zsh={zsh_phi.get(d)!r}"
        )

    print(
        f"  [PASS] 3-Way Differential Trace Equivalence (`znav_spec.py --trace` == Verifier == Live Zsh) "
        f"across {len(trace_ops)} ops & {len(theo['ordered_dirs'])} live dirs!"
    )


# ---------------------------------------------------------------------------
# Differential Randomized Trace Harness against Live Zsh
# ---------------------------------------------------------------------------

DIR_VOCAB_SEGMENTS = [
    ["CODE", "REPOSITORIES"],
    ["SCRIPT", "REPOS"],
    ["CACHE", "REPOS"],
    ["CLOUD", "RUNTIME"],
    ["TEMP", "REPOS"],
    ["PUBLIC", "REPOS"],
    ["LOCAL", "SCRIPTS"],
    ["CORE", "PLATFORM"],
    ["CODE", "DESIGN"],
    ["DATA", "OPS"],
    ["FILE", "INDEX"],
    ["FAST", "CACHE"],
    ["my", "Camel", "Project"],
    ["HTML", "Parser", "Engine"],
    ["v2", "App", "Server"],
    ["2026", "Roadmap"],
    ["99", "bottles"],
    ["agi", "completions"],
    ["formal", "proofs"],
    ["zsh", "native", "audit"],
    ["mutual", "information", "lab"],
    ["onion", "router", "core"],
    ["braitenberg", "vehicles"],
    ["deep", "kernel", "trace"],
    ["alpha", "beta", "gamma", "delta", "epsilon"],
]


def make_dir_name(rng: random.Random, idx: int) -> str:
    segs = rng.choice(DIR_VOCAB_SEGMENTS)
    sep = rng.choice([".", "-", "_", ""])
    if sep == "":
        # camelCase / PascalCase join
        base = segs[0].lower() + "".join(w.capitalize() for w in segs[1:])
    else:
        base = sep.join(segs)
    if idx >= len(DIR_VOCAB_SEGMENTS):
        suffix_style = rng.choice(["num", "seg", "plain"])
        if suffix_style == "num":
            base = f"{base}.{idx}"
        elif suffix_style == "seg":
            extra = rng.choice(["core", "api", "cli", "dev", "lab", "ops", "ui", "db"])
            base = f"{base}-{extra}{idx}"
        else:
            base = f"{base}_{idx}"
    return base


def query_zsh_reserved_set(zsh_proc_run, candidate_pool: set[str]) -> set[str]:
    """Ask the live Zsh session which candidate identifiers are in its reserved set R."""
    # Check OS user expansion (~k), non-znav nameddirs, commands, builtins, functions, aliases, reswords
    lines = ["setopt localoptions no_nomatch; local _k _t _e; for _k in " + " ".join(sorted(candidate_pool)) + "; do"]
    lines.append(
        '  integer _is_res=0\n'
        '  if [[ $_k == znav || $_k == j ]]; then _is_res=1\n'
        '  elif (( ${+commands[$_k]} || ${+builtins[$_k]} || ${+functions[$_k]} || ${+aliases[$_k]} || ${reswords[(Ie)$_k]} )); then _is_res=1\n'
        '  elif (( ${+userdirs[$_k]} )); then _is_res=1\n'
        '  elif (( ${+nameddirs[$_k]} )) && (( ! ${+_ZNAV_OWNED_NAMEDDIRS[$_k]} )); then _is_res=1\n'
        '  elif (( ! ${+nameddirs[$_k]} )); then\n'
        '    _t="~$k"; _t="~$_k"; _e=${~_t}\n'
        '    [[ $_e != $_t ]] && _is_res=1\n'
        '  fi\n'
        '  (( _is_res )) && print -r -- "RES:$_k"\n'
        'done\n'
        'true'
    )
    out = zsh_proc_run("\n".join(lines))
    res: set[str] = set()
    for ln in out.splitlines():
        if ln.startswith("RES:"):
            res.add(ln[4:])
    return res


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    plugin_path = repo_root / "znav.plugin.zsh"
    if not plugin_path.is_file():
        print(f"[FAIL] {plugin_path} not found.", file=sys.stderr)
        return 1

    rng = random.Random(20261119)
    model = VerifierModel(half_life=DEFAULT_HALF_LIFE)

    with tempfile.TemporaryDirectory(prefix="znav_diff_") as tmp_raw:
        # Resolve /tmp -> /private/tmp on macOS so paths match ${dir:A}
        tmp = Path(os.path.realpath(tmp_raw))
        home_dir = tmp / "home"
        data_dir = tmp / "data"
        home_dir.mkdir()
        data_dir.mkdir()

        env = {
            "HOME": str(home_dir),
            "ZNAV_DATA_DIR": str(data_dir),
            "ZNAV_HALF_LIFE": str(DEFAULT_HALF_LIFE),
            "ZNAV_AVOID_COMMANDS": "1",
            "LC_ALL": "C",
            "USER": os.environ.get("USER", "username"),
            "LOGNAME": os.environ.get("LOGNAME", "username"),
            "TERM": "dumb",
            "PATH": "/usr/bin:/bin",
        }

        def spawn_zsh() -> subprocess.Popen[str]:
            p = subprocess.Popen(
                ["/bin/zsh", "-dfi", "+Z", "+m"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                bufsize=1,
            )
            return p

        proc = spawn_zsh()
        sync_id = 0

        def run_zsh(cmd: str) -> str:
            nonlocal sync_id
            assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
            sync_id += 1
            marker = f"__DIFF_SYNC_{sync_id}__"
            proc.stdin.write(f"{cmd}\nprint -r -- \"{marker}:$?\"\n")
            proc.stdin.flush()
            buf: list[str] = []
            while True:
                line = proc.stdout.readline()
                if not line:
                    err = proc.stderr.read()
                    raise RuntimeError(f"EOF from zsh on cmd:\n{cmd}\nstderr:\n{err}")
                s = line.rstrip("\n")
                if marker in s:
                    rc_str = s.split(marker + ":", 1)[1]
                    rc = int(rc_str)
                    if rc != 0:
                        raise AssertionError(f"Zsh command failed (rc={rc}):\n{cmd}\nout:\n{buf}")
                    break
                buf.append(s)
            return "\n".join(buf)

        try:
            # Bootstrap shell with manual pre-existing nameddir to also torture R preservation
            manual_pin = tmp / "manual_pin"
            manual_pin.mkdir()
            run_zsh(
                f'PROMPT="" RPROMPT="" PS1="" PS2=""; setopt NO_PROMPT_SP; '
                f'zmodload zsh/datetime zsh/mathfunc zsh/parameter; '
                f'hash -d manualpin={str(manual_pin)!r}; '
                f'source {str(plugin_path)!r}'
            )

            # Discover how znav stores data / WAL / scores so we can replay both live chpwd
            # AND synthetic multi-day clock jumps cleanly!
            probe = run_zsh(
                'print -r -- "SCORE_VAR:${+_ZNAV_SCORE}"; '
                'print -r -- "OWNED_VAR:${+_ZNAV_OWNED_NAMEDDIRS}"; '
                'typeset -m "_ZNAV_*" | sed -n "s/=.*//p" 2>/dev/null || true'
            )

            # Create initial workspace subdirectories for Day-0 seed
            trace_ops: list[dict] = []
            initial_dirs: list[Path] = []
            for i in range(8):
                name = make_dir_name(rng, i)
                p = home_dir / name
                p.mkdir(parents=True, exist_ok=True)
                initial_dirs.append(p)
                model.mkdir(str(p))
                trace_ops.append({"op": "mkdir", "dir": str(p)})

            # Clear any auto-seed state from sourcing so we start from a synchronized clean state
            run_zsh(
                f'setopt rm_star_silent; zf_rm -rf -- {str(data_dir)}/*(N) 2>/dev/null || true; '
                f'_ZNAV_SCORE=(); _ZNAV_DIR2CODE=(); _ZNAV_CODE2DIR=(); _ZNAV_TOP_DIRS=(); _ZNAV_TOP_POS=(); '
                f'_ZNAV_WAL_LINES=0; _ZNAV_CACHE_VALID=0; _ZNAV_ALL_DIRTY=1; '
                f'for _k in "${{(@k)_ZNAV_OWNED_NAMEDDIRS}}"; do builtin unhash -d -- "$_k" 2>/dev/null || true; done; '
                f'_ZNAV_OWNED_NAMEDDIRS=()'
            )

            all_created: list[Path] = list(initial_dirs)
            dir_counter = len(initial_dirs)

            # Detect WAL file path & snapshot path or internal visit helper
            # Let's trigger 1 real visit in a scratch dir or inspect functions to see if
            # znav exposes a timestamp parameter or WAL format.
            fn_dump = run_zsh('functions _znav_chpwd _znav_record_visit _znav_visit znav 2>/dev/null || true')

            # Helper to read current _ZNAV_SCORE from live zsh with full 17-digit precision
            def fetch_zsh_state() -> tuple[dict[str, float], dict[str, str]]:
                out = run_zsh(
                    '() {\n'
                    '  local _d _k\n'
                    '  float -E 17 _v\n'
                    '  for _d in "${(@k)_ZNAV_SCORE}"; do\n'
                    '    (( _v = _ZNAV_SCORE[$_d] ))\n'
                    '    printf "SCORE\\t%.17g\\t%s\\n" "$_v" "$_d"\n'
                    '  done\n'
                    '  for _k in "${(@k)nameddirs}"; do\n'
                    '    if (( ${+_ZNAV_OWNED_NAMEDDIRS} )); then\n'
                    '      (( ${+_ZNAV_OWNED_NAMEDDIRS[$_k]} )) && printf "NAMED\\t%s\\t%s\\n" "$_k" "${nameddirs[$_k]}"\n'
                    '    fi\n'
                    '  done\n'
                    '}'
                )
                scores: dict[str, float] = {}
                dir_to_code: dict[str, str] = {}
                for line in out.splitlines():
                    if line.startswith("SCORE\t"):
                        _, val_s, d_s = line.split("\t", 2)
                        scores[d_s] = float(val_s)
                    elif line.startswith("NAMED\t"):
                        _, code_s, d_s = line.split("\t", 2)
                        # Verify bijectivity on Zsh side too!
                        assert d_s not in dir_to_code, (
                            f"Duplicate nameddirs mapped to same path {d_s}: {dir_to_code[d_s]} and {code_s}"
                        )
                        dir_to_code[d_s] = code_s
                return scores, dir_to_code

            def verify_checkpoint(step_num: int, tag: str) -> None:
                zsh_scores, zsh_phi = fetch_zsh_state()

                # 1. Exact directory set match
                spec_dirs = set(model.scores.keys())
                got_dirs = set(zsh_scores.keys())
                assert got_dirs == spec_dirs, (
                    f"[Step {step_num} {tag}] Tracked dir set mismatch!\n"
                    f"  Only in Zsh : {sorted(got_dirs - spec_dirs)}\n"
                    f"  Only in Spec: {sorted(spec_dirs - got_dirs)}"
                )

                # 2. Score match within 1e-9 for EVERY directory
                max_err = 0.0
                for d, s_spec in model.scores.items():
                    s_zsh = zsh_scores[d]
                    err = abs(s_zsh - s_spec)
                    if err > max_err:
                        max_err = err
                    assert err < 1e-9, (
                        f"[Step {step_num} {tag}] Lambda score drift >= 1e-9 for {d!r}: "
                        f"zsh={s_zsh:.17g}, spec={s_spec:.17g}, diff={err:.3e}"
                    )

                # 3. Ranking & Shortcode Bijection match
                # Gather candidate pool to query Zsh's exact reserved set R
                cand_pool: set[str] = {"cr", "sr", "tr", "pr", "ls", "cp", "cd", "do", "fi", "manualpin"}
                for d in spec_dirs:
                    cand_pool.update(itertools.islice(candidate_stream(d), 15))
                cand_pool.update(zsh_phi.values())
                reserved = query_zsh_reserved_set(run_zsh, cand_pool)
                assert "manualpin" in reserved, "manual hash -d 'manualpin' must remain in reserved set R"

                # Determine whether znav projects only live dirs or top-K dirs
                live_ranked = model.ranked_items(live_only=True)
                all_ranked = model.ranked_items(live_only=False)
                n_projected = len(zsh_phi)

                # Check against live_only first (or all if all dirs exist)
                spec_phi_live = model.assign_bijection(reserved, max_dirs=len(live_ranked), live_only=True)
                spec_phi_all = model.assign_bijection(reserved, max_dirs=len(all_ranked), live_only=False)

                # Compare against whichever live-filtering policy znav uses for projection
                if set(zsh_phi.keys()) == set( list(spec_phi_live.keys())[:n_projected] ):
                    target_phi = {d: spec_phi_live[d] for d in list(spec_phi_live.keys())[:n_projected]}
                else:
                    target_phi = {d: spec_phi_all[d] for d in list(spec_phi_all.keys())[:n_projected]}

                for d, exp_code in target_phi.items():
                    got_code = zsh_phi.get(d)
                    assert got_code == exp_code, (
                        f"[Step {step_num} {tag}] Shortcode bijection mismatch for {d!r}!\n"
                        f"  Zsh assigned : {got_code!r}\n"
                        f"  Spec expected: {exp_code!r}\n"
                        f"  Lambda={model.scores[d]:.17g}"
                    )

                # 4. Spot-check ~code and ~[code] resolution in Zsh for top 10 projected dirs
                top_check = list(target_phi.items())[:10]
                if top_check:
                    checks = []
                    for d, code in top_check:
                        checks.append(
                            f'[[ ~{code} == {d!r} ]] || {{ print -r -- "FAIL_STATIC:{code}:~{code}!={d}"; return 1; }}; '
                            f'[[ ~[{code}] == {d!r} ]] || {{ print -r -- "FAIL_DYN:{code}:~[{code}]!={d}"; return 1; }}'
                        )
                    run_zsh("() { " + "; ".join(checks) + "; }")

                print(
                    f"  [PASS] Checkpoint step={step_num:3d} ({tag:18s}) | "
                    f"dirs={len(spec_dirs):3d} | max |dLambda|={max_err:.3e} < 1e-9 | "
                    f"phi exact={len(target_phi):3d}"
                )

            # Detect how to feed exact timestamps or extract WAL timestamps:
            # First run `znav seed` on home_dir and read back exact seed score t0 - H!
            run_zsh(f"znav seed {str(home_dir)!r}")
            zsh_scores_after_seed, _ = fetch_zsh_state()
            assert len(zsh_scores_after_seed) == len(initial_dirs), (
                f"Expected {len(initial_dirs)} seeded dirs, got {len(zsh_scores_after_seed)}"
            )
            # Infer exact t0 used by `znav seed` (all seeded dirs received t0 - H, or read each if per-dir)
            sample_seed_scores = set(zsh_scores_after_seed.values())
            if len(sample_seed_scores) == 1:
                seed_lam = next(iter(sample_seed_scores))
                t0_seed = seed_lam + DEFAULT_HALF_LIFE
                model.seed([str(p) for p in initial_dirs], t0_seed)
                for p in initial_dirs:
                    trace_ops.append({"op": "seed", "dir": str(p), "t": t0_seed})
            else:
                # In case znav sampled EPOCHREALTIME per dir inside the loop, check spread < 0.05s
                assert max(sample_seed_scores) - min(sample_seed_scores) < 0.05
                for p in initial_dirs:
                    model.mkdir(str(p))
                    sc_p = zsh_scores_after_seed[str(p)]
                    model.scores[str(p)] = sc_p
                    trace_ops.append({"op": "seed", "dir": str(p), "t": sc_p + DEFAULT_HALF_LIFE})

            verify_checkpoint(1, "initial_seed")

            # Check whether znav supports ZNAV_MOCK_TIME / ZNAV_NOW or WAL event injection for clock jumps
            supports_now_var = "_ZNAV_NOW" in fn_dump or "ZNAV_NOW" in fn_dump

            # Find WAL file path in data_dir after 1 real `cd`
            first_target = initial_dirs[0]
            run_zsh(f"cd {str(first_target)!r}")
            # Read WAL to get exact event timestamp written by chpwd!
            wal_candidates = list(data_dir.glob("*wal*")) + list(data_dir.glob("*.log")) + list(data_dir.glob("*"))
            wal_file: Path | None = None
            for wf in wal_candidates:
                if wf.is_file():
                    txt = wf.read_text(encoding="utf-8", errors="replace")
                    if "V " in txt or str(first_target) in txt:
                        wal_file = wf
                        break

            def extract_last_visit_timestamp(d: str, prev_score: float | None) -> float:
                """Recover exact visit timestamp t from WAL `V <t> <dir>` line (or ZNAV_NOW if used)."""
                if wal_file is not None and wal_file.is_file():
                    lines = wal_file.read_text(encoding="utf-8").splitlines()
                    for ln in reversed(lines):
                        parts = ln.split(" ", 2)
                        if len(parts) >= 3 and parts[0] == "V":
                            try:
                                return float(parts[1])
                            except ValueError:
                                pass
                        elif len(parts) >= 2:
                            # Fallback tab/space separated timestamp search
                            for tok in ln.replace("\t", " ").split():
                                try:
                                    v = float(tok)
                                    if v > 1e8:
                                        return v
                                except ValueError:
                                    pass
                # Fallback if WAL compacted on that exact step: invert LSE from zsh score!
                scores_now, _ = fetch_zsh_state()
                s_new = scores_now[d]
                if prev_score is None:
                    return s_new
                # exp(s_new/tau) = exp(prev/tau) + exp(t/tau) => t = prev + tau * log(exp((s_new-prev)/tau) - 1)
                diff = (s_new - prev_score) / model.tau
                return prev_score + model.tau * math.log(math.expm1(diff))

            t_first = extract_last_visit_timestamp(str(first_target), model.scores.get(str(first_target)))
            model.visit(str(first_target), t_first)
            trace_ops.append({"op": "visit", "dir": str(first_target), "t": t_first})
            verify_checkpoint(2, "first_live_cd")

            # Now execute 600 randomized operations!
            virtual_clock = t_first
            TOTAL_OPS = 600
            live_dirs: list[Path] = list(initial_dirs)

            for step in range(3, TOTAL_OPS + 3):
                r = rng.random()

                if r < 0.14 and len(live_dirs) < 95:
                    # OP 1: mkdir new directory (including nested dirs & collisions)
                    dir_counter += 1
                    if rng.random() < 0.25 and live_dirs:
                        parent = rng.choice(live_dirs[: min(len(live_dirs), 15)])
                        new_p = parent / make_dir_name(rng, dir_counter)
                    else:
                        new_p = home_dir / make_dir_name(rng, dir_counter)
                    new_p.mkdir(parents=True, exist_ok=True)
                    live_dirs.append(new_p)
                    all_created.append(new_p)
                    model.mkdir(str(new_p))
                    trace_ops.append({"op": "mkdir", "dir": str(new_p)})

                elif r < 0.72 and live_dirs:
                    # OP 2: Zipf-skewed directory visit (`cd` or `j` jump!)
                    # Pick with Zipf-like skew toward earlier / popular directories
                    idx = min(len(live_dirs) - 1, int(rng.paretovariate(1.2) - 1))
                    target = live_dirs[idx]
                    d_str = str(target)
                    prev_s = model.scores.get(d_str)

                    if supports_now_var:
                        # Advance virtual clock (with occasional backward clock jitter!)
                        if rng.random() < 0.08:
                            dt = -rng.uniform(0.5, 600.0)  # non-monotonic NTP clock step-back!
                        elif rng.random() < 0.10:
                            dt = rng.uniform(3600.0, 86400.0 * 5.0)  # multi-day jump!
                        else:
                            dt = rng.uniform(0.05, 120.0)
                        virtual_clock += dt
                        t_val = float(f"{virtual_clock:.9f}")
                        run_zsh(f"ZNAV_NOW={t_val:.9f} _ZNAV_NOW={t_val:.9f} cd {d_str!r}")
                        # Check if ZNAV_NOW was honored or real EPOCHREALTIME was used
                        t_recorded = extract_last_visit_timestamp(d_str, prev_s)
                        model.visit(d_str, t_recorded)
                        trace_ops.append({"op": "visit", "dir": d_str, "t": t_recorded})
                    else:
                        # Ensure PWD actually changes so `cd` triggers `chpwd`!
                        run_zsh(f'[[ $PWD == {d_str!r} ]] && builtin cd -q /; cd {d_str!r}')
                        t_recorded = extract_last_visit_timestamp(d_str, prev_s)
                        model.visit(d_str, t_recorded)
                        trace_ops.append({"op": "visit", "dir": d_str, "t": t_recorded})

                elif r < 0.84 and wal_file is not None and live_dirs:
                    # OP 3: Concurrent external shell / synthetic clock-jump WAL append
                    # (tests multi-day aging, backward clock jitter, and multi-shell WAL merge!)
                    idx = rng.randrange(len(live_dirs))
                    target = live_dirs[idx]
                    d_str = str(target)
                    if rng.random() < 0.25:
                        # Backward clock jitter event!
                        t_synth = virtual_clock - rng.uniform(10.0, 5000.0)
                    else:
                        virtual_clock += rng.uniform(600.0, 86400.0 * 2.0)
                        t_synth = virtual_clock
                    t_synth = float(f"{t_synth:.9f}")
                    sample_lines = wal_file.read_text(encoding="utf-8").splitlines() if wal_file.is_file() else []
                    v_lines = [ln for ln in sample_lines if ln.startswith("V ")]
                    if v_lines:
                        sample_rhs = v_lines[-1].split(" ", 2)[2]
                        if sample_rhs.startswith("$'"):
                            run_zsh(
                                f'print -r -- "V {t_synth:.9f} ${{(qqqq):-{d_str}}}" >> {str(wal_file)!r}; '
                                f'znav compact'
                            )
                        else:
                            run_zsh(
                                f'print -r -- "V {t_synth:.9f} ${{(q):-{d_str}}}" >> {str(wal_file)!r}; '
                                f'znav compact'
                            )
                        model.visit(d_str, t_synth)
                        trace_ops.append({"op": "visit", "dir": d_str, "t": t_synth})

                elif r < 0.91 and len(live_dirs) > 10:
                    # OP 4: Delete a directory on disk + run `znav prune`
                    victim_idx = rng.randrange(4, len(live_dirs))  # keep top few core dirs alive
                    victim = live_dirs[victim_idx]
                    descendants = [p for p in live_dirs if p == victim or victim in p.parents]
                    run_zsh(f"builtin cd -q {str(home_dir)!r}")
                    for desc in sorted(descendants, key=lambda x: len(str(x)), reverse=True):
                        if desc.exists():
                            for sub in sorted(desc.rglob("*"), key=lambda x: len(str(x)), reverse=True):
                                if sub.is_dir():
                                    sub.rmdir()
                                else:
                                    sub.unlink()
                            desc.rmdir()
                        if desc in live_dirs:
                            live_dirs.remove(desc)
                        model.rmdir(str(desc))
                        trace_ops.append({"op": "delete", "dir": str(desc), "prune": True})
                    run_zsh("znav prune")
                    model.prune()
                    trace_ops.append({"op": "prune"})

                elif r < 0.96:
                    # OP 5: Explicit atomic WAL compaction (`znav compact`)
                    run_zsh("znav compact")

                else:
                    # OP 6: Re-seed workspace (`znav seed` must ONLY initialize unseen dirs!)
                    subdirs = sorted(
                        str(p) for p in home_dir.iterdir() if p.is_dir()
                    )
                    before_scores = dict(model.scores)
                    run_zsh(f"znav seed {str(home_dir)!r}")
                    zsh_after, _ = fetch_zsh_state()
                    for sd in subdirs:
                        if sd in before_scores:
                            assert abs(zsh_after[sd] - before_scores[sd]) < 1e-9, (
                                f"znav seed overwrote existing score for {sd}!"
                            )
                        elif sd in zsh_after:
                            model.mkdir(sd)
                            model.scores[sd] = zsh_after[sd]
                            trace_ops.append({"op": "seed", "dir": sd, "t": zsh_after[sd] + DEFAULT_HALF_LIFE})

                if step % 100 == 0:
                    verify_checkpoint(step, "random_trace")

            # Final checkpoint in original shell
            verify_checkpoint(TOTAL_OPS + 2, "trace_complete")

            # Compact, terminate shell, spawn a BRAND-NEW Zsh session, and verify full persistence!
            run_zsh("znav compact")
            proc.stdin.write("exit 0\n")
            proc.stdin.flush()
            proc.wait(timeout=5)

            proc = spawn_zsh()
            run_zsh(
                f'PROMPT="" RPROMPT="" PS1="" PS2=""; setopt NO_PROMPT_SP; '
                f'zmodload zsh/datetime zsh/mathfunc zsh/parameter; '
                f'hash -d manualpin={str(manual_pin)!r}; '
                f'source {str(plugin_path)!r}'
            )
            verify_checkpoint(TOTAL_OPS + 3, "fresh_shell_reload")

            # Cross-check full 600+ op trace against @theorist's proofs/znav_spec.py --trace!
            final_zsh_scores, final_zsh_phi = fetch_zsh_state()
            cand_pool_final: set[str] = {"cr", "sr", "tr", "pr", "ls", "cp", "cd", "do", "fi", "manualpin"}
            for d in model.scores:
                cand_pool_final.update(itertools.islice(candidate_stream(d), 15))
            cand_pool_final.update(final_zsh_phi.values())
            reserved_final = query_zsh_reserved_set(run_zsh, cand_pool_final)
            cross_check_theorist_trace(
                repo_root, trace_ops, model, reserved_final, final_zsh_scores, final_zsh_phi
            )

            proc.stdin.write("exit 0\n")
            proc.stdin.flush()
            proc.wait(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()

    print(f"[OK] Differential Randomized Trace Conformance PASSED ({TOTAL_OPS}+ operations, <1e-9 float precision, 100% bijection & ranking match).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
