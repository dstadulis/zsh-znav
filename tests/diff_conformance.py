#!/usr/bin/env python3
"""
Differential Randomized Trace Conformance Verifier for znav (with Unicode & Collisions).

Executes 600+ randomized directory-navigation operations (`mkdir`, `seed`, `cd`,
`j` Unicode/shortcode jump, `clock-advance`, `clock-jitter-backward`, `delete+prune`,
`compact`, `reload`, `resolve` via `znav query` & `~[...]`) comparing 3 engines:
  1. Verifier's independent mathematical implementation (`VerifierModel`),
  2. Formal reference oracle (`proofs/znav_spec.py --trace`), and
  3. Live pure-Zsh engine (`znav.plugin.zsh`) spawned under an interactive UTF-8 locale.

Exercises and asserts at every checkpoint and end-of-trace:
  - Pure Unicode & CJK/Hangul/Cyrillic/Emoji directories (`日本`, `日本語`, `東京`, `京都`, `한국`, `Москва`, `🚀`),
  - Upfront sibling collision cluster (`日本`, `東京`, `한국`, `di`, `dir`, `dir_2`, `home_dir`, `home_dir_2`, `zzzzzz`)
    plus multi-parent identical Unicode basenames (`work/日本` vs `code/日本`, `日本/東京` vs `東京/日本`)
    and accented near-colliders (`café` vs `cafe` vs `caf`),
  - Zero naming collisions (`len(set(zsh_phi.values())) == len(zsh_phi)`) and strict identifier
    validity (`^[a-z_][a-z0-9_]+$`) across all projected shortcodes,
  - Exact `< 1e-9` float agreement and 1-to-1 `phi` bijection & `resolve(Q)` parity across all 3 engines,
  - Live Zsh `~code`, `~[code]`, `j 日本`, `~[日本]`, `~[東京:日本]`, and `znav query` verification.
"""

from __future__ import annotations

import functools
import itertools
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Sequence

DEFAULT_HALF_LIFE = 259200.0  # 72 hours
VALID_SHORTCODE_RE = re.compile(r"^[a-z_][a-z0-9_]+$")


def zsh_sq(s: str) -> str:
    """Single-quote an arbitrary UTF-8 string safely for Zsh without expansion."""
    return "'" + s.replace("'", "'\\''") + "'"


def detect_zsh_utf8_locale() -> str:
    """Select an installed UTF-8 locale (`en_US.UTF-8` on macOS, `C.UTF-8` on Linux,
    falling back to `C` if neither exists) verified directly against `/bin/zsh`.
    """
    if sys.platform == "darwin":
        candidates = ("en_US.UTF-8", "C.UTF-8", "UTF-8")
    else:
        candidates = ("C.UTF-8", "C.utf8", "en_US.UTF-8", "en_US.utf8")

    base_env = {"PATH": "/usr/bin:/bin", "TERM": "dumb"}
    for loc in candidates:
        env = dict(base_env, LC_ALL=loc, LANG=loc)
        try:
            proc = subprocess.run(
                ["/bin/zsh", "-fc", 'local _u="日本"; (( ${#_u} == 2 ))'],
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=5,
            )
            if proc.returncode == 0 and not proc.stderr.strip():
                return loc
        except OSError:
            continue
    return "C"


# ---------------------------------------------------------------------------
# Independent Verifier Reference Implementation of Formal Spec
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
    return len(d.encode("utf-8", errors="surrogateescape"))


def succ_cmp(a: tuple[str, float], b: tuple[str, float]) -> int:
    """Return -1 if a succ b (a comes BEFORE b in descending rank), +1 if b succ a, 0 if equal."""
    da, la = a
    db, lb = b
    if la != lb:
        return -1 if la > lb else 1
    dep_a, dep_b = path_depth(da), path_depth(db)
    if dep_a != dep_b:
        return -1 if dep_a < dep_b else 1
    ba = da.encode("utf-8", errors="surrogateescape")
    bb = db.encode("utf-8", errors="surrogateescape")
    if len(ba) != len(bb):
        return -1 if len(ba) < len(bb) else 1
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


def _ordered_substrings(haystack: str, needles: Sequence[str]) -> bool:
    pos = 0
    for needle in needles:
        idx = haystack.find(needle, pos)
        if idx < 0:
            return False
        pos = idx + len(needle)
    return True


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

    def assign_bijection(
        self, reserved: set[str], max_dirs: int | None = None, live_only: bool = False
    ) -> dict[str, str]:
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

    def resolve_query(
        self,
        query_tokens: Sequence[str],
        reserved: set[str],
        colon: bool = False,
    ) -> str | None:
        ranked = self.ranked_items(live_only=True)
        if not ranked or not query_tokens:
            return None
        q_clean = [q for q in query_tokens if q]
        if not q_clean:
            return None
        q_low = [q.lower() for q in q_clean]
        phi = self.assign_bijection(reserved, live_only=True)

        if not colon and len(q_clean) == 1:
            q0, q0_l = q_clean[0], q_low[0]
            for d, code in phi.items():
                if code == q0 or code == q0_l:
                    return d

        for d, _ in ranked:
            if len(q_low) == 1 and q_low[0] in candidate_tiers_1_to_4(d):
                return d
            base_low = ("" if d == "/" else os.path.basename(d)).lower()
            if q_low[-1] in base_low and _ordered_substrings(d.lower(), q_low):
                return d

        for d, _ in ranked:
            if _ordered_substrings(d.lower(), q_low):
                return d

        return None


# ---------------------------------------------------------------------------
# Cross-Check Against proofs/znav_spec.py --trace
# ---------------------------------------------------------------------------

def cross_check_theorist_trace(
    repo_root: Path,
    trace_ops: list[dict],
    model: VerifierModel,
    reserved: set[str],
    zsh_scores: dict[str, float],
    zsh_phi: dict[str, str],
    ver_resolutions: list[str | None],
    zsh_resolutions: list[str | None],
) -> None:
    spec_path = repo_root / "proofs" / "znav_spec.py"
    if not spec_path.is_file():
        raise FileNotFoundError(f"Required oracle {spec_path} not found!")

    payload = {
        "half_life": model.half_life,
        "reserved": sorted(reserved),
        "ops": trace_ops,
    }
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [sys.executable, "-B", str(spec_path), "--trace"],
        input=json.dumps(payload, ensure_ascii=False),
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        check=True,
    )
    theo = json.loads(proc.stdout)

    # 1. Exact ordered_dirs match against VerifierModel & Live Zsh
    ver_ordered = [d for d, _ in model.ranked_items(live_only=True)]
    assert theo["ordered_dirs"] == ver_ordered, (
        f"Spec --trace ordered_dirs != Verifier:\n  theo={theo['ordered_dirs'][:10]}\n  ver ={ver_ordered[:10]}"
    )

    # 2. Exact Lambda score match (< 1e-9) between Spec --trace and Live Zsh
    for d, s_theo in theo["scores"].items():
        s_zsh = zsh_scores[d]
        assert abs(s_theo - s_zsh) < 1e-9, (
            f"Spec vs Zsh Lambda drift on {d!r}: theo={s_theo:.17g}, zsh={s_zsh:.17g}"
        )

    # 3. Exact shortcode bijection phi match across all 3 engines + zero collisions
    assert len(set(theo["phi"].values())) == len(theo["phi"]), "Spec phi collision!"
    assert len(set(zsh_phi.values())) == len(zsh_phi), "Zsh phi collision!"
    n_proj = len(zsh_phi)
    for d in theo["ordered_dirs"][:n_proj]:
        assert zsh_phi.get(d) == theo["phi"][d], (
            f"Spec vs Zsh phi mismatch on {d!r}: theo={theo['phi'][d]!r}, zsh={zsh_phi.get(d)!r}"
        )

    # 4. Exact query resolution parity across all 3 engines (`znav_spec.py` == `VerifierModel` == Live Zsh)
    assert theo["resolutions"] == ver_resolutions, (
        f"Spec vs Verifier resolution mismatch:\n  theo={theo['resolutions']}\n  ver ={ver_resolutions}"
    )
    assert theo["resolutions"] == zsh_resolutions, (
        f"Spec vs Live Zsh resolution mismatch:\n  theo={theo['resolutions']}\n  zsh ={zsh_resolutions}"
    )

    print(
        f"  [PASS] 3-Way Differential Trace Equivalence (`znav_spec.py --trace` == Verifier == Live Zsh) "
        f"across {len(trace_ops)} ops, {len(theo['ordered_dirs'])} live dirs & {len(zsh_resolutions)} Unicode/code queries!"
    )


# ---------------------------------------------------------------------------
# Differential Randomized Trace Harness against Live Zsh (UTF-8 + Collisions)
# ---------------------------------------------------------------------------

UPFRONT_SIBLING_COLLISION_CLUSTER = [
    # Pure Unicode & CJK / Hangul / Cyrillic / Emoji siblings (T=["dir"] fallback cluster)
    "日本",
    "日本語",
    "東京",
    "京都",
    "한국",
    "Москва",
    "🚀",
    # Literal ASCII fallback-stem colliders
    "di",
    "dir",
    "dir_2",
    "home_dir",
    "home_dir_2",
    # Accented & prefix near-colliders + mixed ASCII/UTF-8 equal-6-byte tie-breaker
    "café",
    "cafe",
    "caf",
    "zzzzzz",
    # Parents for multi-parent Unicode basenames + classic developer dirs
    "work",
    "code",
    "CODE.REPOSITORIES",
    "SCRIPT.REPOS",
    "CACHE.REPOS",
]

UPFRONT_MULTIPARENT_UNICODE_SUBDIRS = [
    ("work", "日本"),
    ("code", "日本"),
    ("日本", "東京"),
    ("東京", "日本"),
]

PURE_UNICODE_DYNAMIC_STEMS = [
    "大阪",
    "札幌",
    "沖縄",
    "福岡",
    "名古屋",
    "横浜",
    "서울",
    "부산",
    "Киев",
    "🛰",
]

MIXED_UNICODE_SEGMENTS = [
    ["日本", "api"],
    ["東京", "core"],
    ["한국", "lab"],
    ["Москва", "ops"],
    ["café", "server"],
    ["🚀", "launch"],
]

DIR_VOCAB_SEGMENTS = [
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
    mode = rng.random()
    if mode < 0.28:
        # Pure Unicode basename (exercises degenerate fallback T=["dir"] dynamically!)
        stem = PURE_UNICODE_DYNAMIC_STEMS[idx % len(PURE_UNICODE_DYNAMIC_STEMS)]
        if idx >= len(PURE_UNICODE_DYNAMIC_STEMS):
            extra = PURE_UNICODE_DYNAMIC_STEMS[(idx // 3) % len(PURE_UNICODE_DYNAMIC_STEMS)]
            return f"{stem}_{extra}" if idx % 2 == 0 else stem
        return stem
    if mode < 0.52:
        # Mixed Unicode + ASCII segment directory
        u_seg, a_seg = rng.choice(MIXED_UNICODE_SEGMENTS)
        sep = rng.choice(["_", "-", "."])
        return f"{u_seg}{sep}{a_seg}{sep}{idx}"

    segs = rng.choice(DIR_VOCAB_SEGMENTS)
    sep = rng.choice([".", "-", "_", ""])
    if sep == "":
        base = segs[0].lower() + "".join(w.capitalize() for w in segs[1:])
    else:
        base = sep.join(segs)
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
    safe_pool = sorted(k for k in candidate_pool if VALID_SHORTCODE_RE.match(k) or k.isalnum())
    if not safe_pool:
        return set()
    lines = ["setopt localoptions no_nomatch; local _k _t _e; for _k in " + " ".join(safe_pool) + "; do"]
    lines.append(
        '  integer _is_res=0\n'
        '  if [[ $_k == znav || $_k == j ]]; then _is_res=1\n'
        '  elif (( ${+commands[$_k]} || ${+builtins[$_k]} || ${+functions[$_k]} || ${+aliases[$_k]} || ${reswords[(Ie)$_k]} )); then _is_res=1\n'
        '  elif (( ${+userdirs[$_k]} )); then _is_res=1\n'
        '  elif (( ${+nameddirs[$_k]} )) && (( ! ${+_ZNAV_OWNED_NAMEDDIRS[$_k]} )); then _is_res=1\n'
        '  elif (( ! ${+nameddirs[$_k]} )); then\n'
        '    _t="~$_k"; _e=${~_t}\n'
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

    zsh_locale = detect_zsh_utf8_locale()
    print(f"  [INFO] Spawning live Zsh conformance engine with LC_ALL={zsh_locale}")

    rng = random.Random(20261123)
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
            "LC_ALL": zsh_locale,
            "LANG": zsh_locale,
            "USER": os.environ.get("USER", "username"),
            "LOGNAME": os.environ.get("LOGNAME", "username"),
            "TERM": "dumb",
            "PATH": "/usr/bin:/bin",
        }

        def spawn_zsh() -> subprocess.Popen[str]:
            return subprocess.Popen(
                ["/bin/zsh", "-dfi", "+Z", "+m"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="surrogateescape",
                env=env,
                bufsize=1,
            )

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
            # Bootstrap shell with manual pre-existing nameddir to torture R preservation
            manual_pin = tmp / "manual_pin"
            manual_pin.mkdir()
            run_zsh(
                f'PROMPT="" RPROMPT="" PS1="" PS2=""; setopt NO_PROMPT_SP; '
                f'zmodload zsh/datetime zsh/mathfunc zsh/parameter; '
                f'hash -d manualpin={zsh_sq(str(manual_pin))}; '
                f'ZNAV_AUTO_SEED=0; '
                f'source {zsh_sq(str(plugin_path))}'
            )

            # Accumulate every candidate ever generated across the trace so `znav_spec.py --trace`
            # receives the complete reserved set R for intermediate `resolve` steps too.
            all_ever_candidates: set[str] = {
                "cr", "sr", "car", "tr", "pr", "ls", "cp", "cd", "do", "fi",
                "di", "dir", "hd", "wd", "co", "wo", "ca", "caf", "zz", "manualpin",
            }

            def register_dir_candidates(d: str) -> None:
                all_ever_candidates.update(itertools.islice(candidate_stream(d), 25))

            # 1. Create upfront sibling collision cluster in home_dir (depth-1)
            trace_ops: list[dict] = []
            ver_resolutions: list[str | None] = []
            zsh_resolutions: list[str | None] = []
            initial_dirs: list[Path] = []

            for name in UPFRONT_SIBLING_COLLISION_CLUSTER:
                p = home_dir / name
                p.mkdir(parents=True, exist_ok=True)
                initial_dirs.append(p)
                model.mkdir(str(p))
                register_dir_candidates(str(p))
                trace_ops.append({"op": "mkdir", "dir": str(p)})

            # Also create multi-parent identical Unicode basename directories (depth-2) upfront
            multiparent_dirs: list[Path] = []
            for par_name, child_name in UPFRONT_MULTIPARENT_UNICODE_SUBDIRS:
                mp = home_dir / par_name / child_name
                mp.mkdir(parents=True, exist_ok=True)
                multiparent_dirs.append(mp)
                model.mkdir(str(mp))
                register_dir_candidates(str(mp))
                trace_ops.append({"op": "mkdir", "dir": str(mp)})

            # Helper to read current _ZNAV_SCORE and owned $nameddirs from live Zsh with 17-digit precision
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
                seen_codes: set[str] = set()
                for line in out.splitlines():
                    if line.startswith("SCORE\t"):
                        _, val_s, d_s = line.split("\t", 2)
                        scores[d_s] = float(val_s)
                    elif line.startswith("NAMED\t"):
                        _, code_s, d_s = line.split("\t", 2)
                        assert VALID_SHORTCODE_RE.match(code_s), (
                            f"Invalid shortcode syntax in Zsh nameddirs: {code_s!r} -> {d_s!r}"
                        )
                        assert code_s not in seen_codes, (
                            f"Duplicate shortcode {code_s!r} in Zsh nameddirs!"
                        )
                        assert d_s not in dir_to_code, (
                            f"Duplicate nameddirs mapped to same path {d_s!r}: {dir_to_code[d_s]!r} and {code_s!r}"
                        )
                        seen_codes.add(code_s)
                        dir_to_code[d_s] = code_s
                all_ever_candidates.update(seen_codes)
                return scores, dir_to_code

            def verify_checkpoint(step_num: int, tag: str) -> None:
                zsh_scores, zsh_phi = fetch_zsh_state()

                # 1. Explicit zero-collision & valid identifier assertions on zsh_phi
                assert len(set(zsh_phi.values())) == len(zsh_phi), (
                    f"[Step {step_num} {tag}] Naming collision in zsh_phi: {zsh_phi}"
                )
                for d_chk, code_chk in zsh_phi.items():
                    assert VALID_SHORTCODE_RE.match(code_chk), (
                        f"[Step {step_num} {tag}] Invalid shortcode {code_chk!r} for {d_chk!r}"
                    )

                # 2. Exact directory set match
                spec_dirs = set(model.scores.keys())
                got_dirs = set(zsh_scores.keys())
                assert got_dirs == spec_dirs, (
                    f"[Step {step_num} {tag}] Tracked dir set mismatch!\n"
                    f"  Only in Zsh : {sorted(got_dirs - spec_dirs)}\n"
                    f"  Only in Spec: {sorted(spec_dirs - got_dirs)}"
                )

                # 3. Score match within 1e-9 for EVERY directory (ASCII & Unicode)
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

                # 4. Ranking & Shortcode Bijection match across ALL projected directories
                for d in spec_dirs:
                    register_dir_candidates(d)
                reserved = query_zsh_reserved_set(run_zsh, all_ever_candidates)
                assert "manualpin" in reserved, "manual hash -d 'manualpin' must remain in reserved set R"

                live_ranked = model.ranked_items(live_only=True)
                all_ranked = model.ranked_items(live_only=False)
                n_projected = len(zsh_phi)
                assert n_projected == min(len(spec_dirs), 256), (
                    f"[Step {step_num} {tag}] Expected {min(len(spec_dirs), 256)} projected nameddirs, got {n_projected}"
                )

                spec_phi_live = model.assign_bijection(reserved, max_dirs=len(live_ranked), live_only=True)
                spec_phi_all = model.assign_bijection(reserved, max_dirs=len(all_ranked), live_only=False)

                if set(zsh_phi.keys()) == set(list(spec_phi_live.keys())[:n_projected]):
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

                # 5. Verify ~code and ~[code] resolution in Zsh for top 12 + all Unicode dirs in target_phi
                check_items = list(target_phi.items())[:12]
                seen_chk = {d for d, _ in check_items}
                for d, code in target_phi.items():
                    if d not in seen_chk and any(ord(ch) > 127 for ch in d):
                        check_items.append((d, code))
                        seen_chk.add(d)

                if check_items:
                    checks = []
                    for d, code in check_items:
                        dq = zsh_sq(d)
                        checks.append(
                            f'[[ ~{code} == {dq} ]] || {{ print -r -- "FAIL_STATIC:{code}:~{code}!={d}"; return 1; }}; '
                            f'[[ ~[{code}] == {dq} ]] || {{ print -r -- "FAIL_DYN:{code}:~[{code}]!={d}"; return 1; }}'
                        )
                    run_zsh("() { " + "; ".join(checks) + "; }")

                # 6. Live Zsh Unicode resolution checks (`~[日本]`, `znav query 日本`, `j -p 日本`, `znav query café`)
                for u_tok in ("日本", "東京", "한국", "Москва", "🚀", "café"):
                    exp_u = model.resolve_query([u_tok], reserved, colon=False)
                    assert exp_u is not None, f"Expected live match for {u_tok!r}"
                    uq = zsh_sq(u_tok)
                    exp_q = zsh_sq(exp_u)
                    run_zsh(
                        f'() {{\n'
                        f'  local _qout _jout _dout\n'
                        f'  _qout=$(znav query -- {uq}) || return 1\n'
                        f'  _jout=$(j -p -- {uq}) || return 1\n'
                        f'  _dout=~[{u_tok}]\n'
                        f'  [[ $_qout == {exp_q} && $_jout == {exp_q} && $_dout == {exp_q} ]] || {{\n'
                        f'    print -r -- "UNICODE_RESOLVE_MISMATCH:{u_tok}:q=$_qout:j=$_jout:dyn=$_dout:exp=" {exp_q}\n'
                        f'    return 1\n'
                        f'  }}\n'
                        f'}}'
                    )

                print(
                    f"  [PASS] Checkpoint step={step_num:3d} ({tag:20s}) | "
                    f"dirs={len(spec_dirs):3d} | max |dLambda|={max_err:.3e} < 1e-9 | "
                    f"phi exact={len(target_phi):3d} (0 collisions)"
                )

            # Seed upfront sibling collision cluster via `znav seed "$HOME"`!
            # All 21 depth-1 siblings receive identical score t0 - H, immediately testing
            # equal-score UTF-8 byte-order tie-breaking (`京都` > `日本` > `東京` > `한국`, `zzzzzz` > `京都`, etc.)!
            run_zsh(f"znav seed {zsh_sq(str(home_dir))}")
            zsh_scores_after_seed, _ = fetch_zsh_state()
            assert len(zsh_scores_after_seed) == len(initial_dirs), (
                f"Expected {len(initial_dirs)} seeded dirs, got {len(zsh_scores_after_seed)}"
            )
            sample_seed_scores = set(zsh_scores_after_seed.values())
            assert len(sample_seed_scores) == 1, f"Expected uniform seed score, got {sample_seed_scores}"
            seed_lam = next(iter(sample_seed_scores))
            t0_seed = seed_lam + DEFAULT_HALF_LIFE
            model.seed([str(p) for p in initial_dirs], t0_seed)
            for p in initial_dirs:
                trace_ops.append({"op": "seed", "dir": str(p), "t": t0_seed})

            verify_checkpoint(1, "initial_unicode_seed")

            wal_file = data_dir / "wal.log"

            def extract_last_visit_timestamp(d: str, prev_score: float | None) -> float:
                """Recover exact visit timestamp t from WAL `V <t> <dir>` line (or invert LSE if auto-compacted)."""
                if wal_file.is_file():
                    lines = wal_file.read_text(encoding="utf-8", errors="replace").splitlines()
                    for ln in reversed(lines):
                        parts = ln.split(" ", 2)
                        if len(parts) >= 3 and parts[0] == "V":
                            try:
                                return float(parts[1])
                            except ValueError:
                                pass
                scores_now, _ = fetch_zsh_state()
                s_new = scores_now[d]
                if prev_score is None:
                    return s_new
                diff = (s_new - prev_score) / model.tau
                return prev_score + model.tau * math.log(math.expm1(diff))

            # Visit all 4 multi-parent identical-Unicode-basename directories (`work/日本`, `code/日本`,
            # `日本/東京`, `東京/日本`) + live `j 日本` jump check!
            t_last = t0_seed
            for mp in multiparent_dirs:
                mp_s = str(mp)
                prev_s = model.scores.get(mp_s)
                run_zsh(f"[[ $PWD == {zsh_sq(mp_s)} ]] && builtin cd -q /; cd -- {zsh_sq(mp_s)}")
                t_last = extract_last_visit_timestamp(mp_s, prev_s)
                model.visit(mp_s, t_last)
                trace_ops.append({"op": "visit", "dir": mp_s, "t": t_last})

            # Exercise real interactive `j 日本` jump (changes PWD to succ-winning `日本` dir and records visit!)
            reserved_cur = query_zsh_reserved_set(run_zsh, all_ever_candidates)
            exp_j_nihon = model.resolve_query(["日本"], reserved_cur, colon=False)
            assert exp_j_nihon is not None
            prev_j = model.scores.get(exp_j_nihon)
            j_pwd = run_zsh(
                f'[[ $PWD == {zsh_sq(exp_j_nihon)} ]] && builtin cd -q /; j 日本 && print -r -- "JPWD:$PWD"'
            )
            assert f"JPWD:{exp_j_nihon}" in j_pwd.splitlines(), (
                f"Live `j 日本` landed in wrong directory: got {j_pwd!r}, expected {exp_j_nihon!r}"
            )
            t_last = extract_last_visit_timestamp(exp_j_nihon, prev_j)
            model.visit(exp_j_nihon, t_last)
            trace_ops.append({"op": "visit", "dir": exp_j_nihon, "t": t_last})

            verify_checkpoint(2, "multiparent_and_j")

            # Protected core directories (upfront sibling cluster + multi-parent Unicode dirs) stay alive
            # throughout all 620 ops so collision clusters remain continuously active while dynamic
            # Unicode & ASCII directories are created, visited, compacted, deleted, and pruned!
            live_dirs: list[Path] = list(initial_dirs) + list(multiparent_dirs)
            n_protected = len(live_dirs)
            dir_counter = len(live_dirs)

            virtual_clock = t_last
            TOTAL_OPS = 620

            UNICODE_QUERY_POOL: list[tuple[list[str], bool]] = [
                (["日本"], False),
                (["日本語"], False),
                (["東京"], False),
                (["京都"], False),
                (["한국"], False),
                (["Москва"], False),
                (["🚀"], False),
                (["café"], False),
                (["cafe"], False),
                (["caf"], False),
                (["work", "日本"], False),
                (["code", "日本"], False),
                (["日本", "東京"], False),
                (["東京", "日本"], False),
                (["work", "日本"], True),
                (["code", "日本"], True),
                (["日本", "東京"], True),
                (["東京", "日本"], True),
                (["di"], False),
                (["dir"], False),
                (["hd"], False),
                (["cr"], False),
                (["sr"], False),
            ]

            for step in range(3, TOTAL_OPS + 3):
                r = rng.random()

                if r < 0.14 and len(live_dirs) < 105:
                    # OP 1: mkdir new directory (pure Unicode, mixed Unicode+ASCII, or ASCII/camelCase)
                    while True:
                        dir_counter += 1
                        if rng.random() < 0.30 and live_dirs:
                            parent = rng.choice(live_dirs[: min(len(live_dirs), 20)])
                            new_p = parent / make_dir_name(rng, dir_counter)
                        else:
                            new_p = home_dir / make_dir_name(rng, dir_counter)
                        if not new_p.exists():
                            break
                    new_p.mkdir(parents=True, exist_ok=False)
                    live_dirs.append(new_p)
                    model.mkdir(str(new_p))
                    register_dir_candidates(str(new_p))
                    trace_ops.append({"op": "mkdir", "dir": str(new_p)})

                elif r < 0.62 and live_dirs:
                    # OP 2: Zipf-skewed directory visit (`cd` with virtual-clock jumps/jitter,
                    # real EPOCHREALTIME `cd`, or live `j <unicode/code>` navigation!)
                    use_jump = rng.random() < 0.18
                    if use_jump:
                        reserved_step = query_zsh_reserved_set(run_zsh, all_ever_candidates)
                        jump_tok = rng.choice(["日本", "日本語", "東京", "京都", "한국", "Москва", "🚀", "café", "cafe", "di", "dir", "cr"])
                        exp_target = model.resolve_query([jump_tok], reserved_step, colon=False)
                        assert exp_target is not None
                        d_str = exp_target
                    else:
                        idx = min(len(live_dirs) - 1, int(rng.paretovariate(1.2) - 1))
                        d_str = str(live_dirs[idx])

                    prev_s = model.scores.get(d_str)

                    if rng.random() < 0.70:
                        # Deterministic virtual clock via ZNAV_NOW (including backward NTP jitter & multi-day jumps!)
                        if rng.random() < 0.10:
                            dt = -rng.uniform(0.5, 900.0)
                        elif rng.random() < 0.12:
                            dt = rng.uniform(3600.0, 86400.0 * 4.0)
                        else:
                            dt = rng.uniform(0.05, 120.0)
                        virtual_clock += dt
                        t_val = float(f"{virtual_clock:.9f}")
                        if use_jump:
                            out_j = run_zsh(
                                f'[[ $PWD == {zsh_sq(d_str)} ]] && builtin cd -q /; '
                                f'ZNAV_NOW={t_val:.9f} _ZNAV_NOW={t_val:.9f} j -- {zsh_sq(jump_tok)} && print -r -- "JPWD:$PWD"'
                            )
                            assert f"JPWD:{d_str}" in out_j.splitlines(), (
                                f"j {jump_tok!r} resolved to {out_j!r}, expected {d_str!r}"
                            )
                        else:
                            run_zsh(
                                f'[[ $PWD == {zsh_sq(d_str)} ]] && builtin cd -q /; '
                                f'ZNAV_NOW={t_val:.9f} _ZNAV_NOW={t_val:.9f} cd -- {zsh_sq(d_str)}'
                            )
                        model.visit(d_str, t_val)
                        trace_ops.append({"op": "visit", "dir": d_str, "t": t_val})
                    else:
                        # Real kernel EPOCHREALTIME visit
                        if use_jump:
                            out_j = run_zsh(
                                f'[[ $PWD == {zsh_sq(d_str)} ]] && builtin cd -q /; '
                                f'j -- {zsh_sq(jump_tok)} && print -r -- "JPWD:$PWD"'
                            )
                            assert f"JPWD:{d_str}" in out_j.splitlines()
                        else:
                            run_zsh(f'[[ $PWD == {zsh_sq(d_str)} ]] && builtin cd -q /; cd -- {zsh_sq(d_str)}')
                        t_recorded = extract_last_visit_timestamp(d_str, prev_s)
                        virtual_clock = max(virtual_clock, t_recorded)
                        model.visit(d_str, t_recorded)
                        trace_ops.append({"op": "visit", "dir": d_str, "t": t_recorded})

                elif r < 0.76 and live_dirs:
                    # OP 3: Concurrent external shell / synthetic clock-jump WAL append (ASCII & Unicode paths!)
                    idx = rng.randrange(len(live_dirs))
                    d_str = str(live_dirs[idx])
                    if rng.random() < 0.25:
                        t_synth = virtual_clock - rng.uniform(10.0, 5000.0)
                    else:
                        virtual_clock += rng.uniform(600.0, 86400.0 * 2.0)
                        t_synth = virtual_clock
                    t_synth = float(f"{t_synth:.9f}")
                    run_zsh(
                        f'() {{\n'
                        f'  emulate -L zsh; setopt no_multibyte; local LC_ALL=C\n'
                        f'  local _p={zsh_sq(d_str)}\n'
                        f'  print -r -- "V {t_synth:.9f} ${{(qqqq)_p}}" >> {zsh_sq(str(wal_file))}\n'
                        f'}}\n'
                        f'znav compact'
                    )
                    model.visit(d_str, t_synth)
                    trace_ops.append({"op": "visit", "dir": d_str, "t": t_synth})

                elif r < 0.88 and model.scores:
                    # OP 4: 3-Way Query Resolution (`znav query` + `~[...]` vs VerifierModel vs znav_spec.py --trace)
                    reserved_q = query_zsh_reserved_set(run_zsh, all_ever_candidates)
                    if rng.random() < 0.78:
                        q_toks, colon = rng.choice(UNICODE_QUERY_POOL)
                    else:
                        phi_cur = model.assign_bijection(reserved_q, live_only=True)
                        sample_code = rng.choice(list(phi_cur.values()))
                        q_toks, colon = [sample_code], False

                    exp_ans = model.resolve_query(q_toks, reserved_q, colon=colon)
                    q_args = " ".join(zsh_sq(tok) for tok in q_toks)
                    colon_flag = "--colon " if colon else ""
                    out_q = run_zsh(
                        f'() {{\n'
                        f'  local _ans=""\n'
                        f'  if _ans=$(znav query {colon_flag}-- {q_args} 2>/dev/null); then\n'
                        f'    print -r -- "HIT:$_ans"\n'
                        f'  else\n'
                        f'    print -r -- "MISS"\n'
                        f'  fi\n'
                        f'}}'
                    )
                    got_ans: str | None = None
                    for ln in out_q.splitlines():
                        if ln.startswith("HIT:"):
                            got_ans = ln[4:]
                            break
                        if ln == "MISS":
                            got_ans = None
                            break

                    assert got_ans == exp_ans, (
                        f"[Step {step}] `znav query` mismatch on {q_toks!r} (colon={colon}): "
                        f"zsh={got_ans!r}, ver={exp_ans!r}"
                    )

                    # Also verify live `~[...]` dynamic directory expansion whenever resolution hits!
                    if exp_ans is not None:
                        dyn_expr = ":".join(q_toks) if (colon or len(q_toks) > 1) else q_toks[0]
                        if all(ch not in dyn_expr for ch in ("]", "[", " ", "'", '"', "$", "`")):
                            out_dyn = run_zsh(f'() {{ local _d=~[{dyn_expr}]; print -r -- "DYN:$_d"; }}')
                            assert f"DYN:{exp_ans}" in out_dyn.splitlines(), (
                                f"[Step {step}] `~[{dyn_expr}]` mismatch: got {out_dyn!r}, expected {exp_ans!r}"
                            )

                    ver_resolutions.append(exp_ans)
                    zsh_resolutions.append(got_ans)
                    trace_ops.append({"op": "resolve", "query": list(q_toks), "colon": colon})

                elif r < 0.94 and len(live_dirs) > n_protected + 3:
                    # OP 5: Delete a dynamically created (Unicode or ASCII) directory + `znav prune`
                    victim_idx = rng.randrange(n_protected, len(live_dirs))
                    victim = live_dirs[victim_idx]
                    descendants = [p for p in live_dirs if p == victim or victim in p.parents]
                    run_zsh(f"builtin cd -q {zsh_sq(str(home_dir))}")
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

                elif r < 0.97:
                    # OP 6: Explicit atomic WAL compaction (`znav compact`)
                    run_zsh("znav compact")

                else:
                    # OP 7: Re-seed workspace (`znav seed` must ONLY initialize unseen depth-1 dirs!)
                    subdirs = sorted(str(p) for p in home_dir.iterdir() if p.is_dir())
                    before_scores = dict(model.scores)
                    run_zsh(f"znav seed {zsh_sq(str(home_dir))}")
                    zsh_after, _ = fetch_zsh_state()
                    for sd in subdirs:
                        if sd in before_scores:
                            assert abs(zsh_after[sd] - before_scores[sd]) < 1e-9, (
                                f"znav seed overwrote existing score for {sd!r}!"
                            )
                        elif sd in zsh_after:
                            model.mkdir(sd)
                            register_dir_candidates(sd)
                            model.scores[sd] = zsh_after[sd]
                            trace_ops.append({"op": "seed", "dir": sd, "t": zsh_after[sd] + DEFAULT_HALF_LIFE})

                if step % 100 == 0:
                    verify_checkpoint(step, "random_trace")

            # Final checkpoint in original UTF-8 Zsh session
            verify_checkpoint(TOTAL_OPS + 2, "trace_complete")

            # Compact, terminate shell, spawn a BRAND-NEW UTF-8 Zsh session, and verify full persistence!
            run_zsh("znav compact")
            proc.stdin.write("exit 0\n")
            proc.stdin.flush()
            proc.wait(timeout=5)

            proc = spawn_zsh()
            run_zsh(
                f'PROMPT="" RPROMPT="" PS1="" PS2=""; setopt NO_PROMPT_SP; '
                f'zmodload zsh/datetime zsh/mathfunc zsh/parameter; '
                f'hash -d manualpin={zsh_sq(str(manual_pin))}; '
                f'source {zsh_sq(str(plugin_path))}'
            )
            verify_checkpoint(TOTAL_OPS + 3, "fresh_shell_reload")

            # Cross-check full 620+ op trace against proofs/znav_spec.py --trace!
            final_zsh_scores, final_zsh_phi = fetch_zsh_state()
            for d in model.scores:
                register_dir_candidates(d)
            reserved_final = query_zsh_reserved_set(run_zsh, all_ever_candidates)
            cross_check_theorist_trace(
                repo_root,
                trace_ops,
                model,
                reserved_final,
                final_zsh_scores,
                final_zsh_phi,
                ver_resolutions,
                zsh_resolutions,
            )

            proc.stdin.write("exit 0\n")
            proc.stdin.flush()
            proc.wait(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()

    print(
        f"[OK] Differential Randomized Trace Conformance PASSED "
        f"({TOTAL_OPS}+ ops, LC_ALL={zsh_locale}, <1e-9 float precision, 0 collisions, 100% 3-way parity)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
