# `znav` — Formally Verified, Zero-Fork Directory Navigation for Zsh

`znav` replaces manually curated directory aliases (`alias cr='cd ~/CODE.REPOSITORIES'`, `alias sr='cd ~/SCRIPT.REPOS'`) with an **information-theoretically grounded, machine-checked, 100% pure-Zsh navigation engine** built directly atop Zsh's C hash tables and hook protocols.

Every hot path—startup, `chpwd` tracking, `~cr` C hash-table expansion, `~[cr]` dynamic resolution, `j cr` jumping, `~[<TAB>` completion, and atomic WAL compaction—executes **100% in-process in pure Zsh (`0` `fork(2)` calls, `0` subshells, `0` external binaries, even under `PATH=""`)**.

---

## Why Manual Aliases Fail—and How `znav` Integrates Natively

Manual aliases (`alias cr='cd ~/CODE.REPOSITORIES'`) suffer from four structural defects:
1. **Lexical confinement to command position**: You cannot write `vim cr/foo`, `cp a sr/b`, or `git -C cr/znav status` (`alias -g` globally corrupts ordinary arguments across every command).
2. **$\Omega(N \cdot L_{\text{path}})$ human maintenance & silent staleness**: Every new, renamed, or deleted repository requires manual dotfile surgery.
3. **Silent command-table shadowing**: Two-letter initialisms like `tr` (`TEMP.REPOS`), `pr` (`PUBLIC.REPOS`), `ar`, `cc`, `ls`, or `cp` collide with POSIX `/usr/bin` utilities and shell builtins.
4. **Zero prompt `%~` or completion awareness**.

| Capability / Complexity | Manual `alias` | Static `hash -d` | Zsh `cdr` (`zshcontrib`) | External (`zoxide`) | **`znav` (Pure Zsh)** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Human Maintenance Cost** | $\Omega(N)$ manual edits | $\Omega(N)$ manual edits | $0$ bits | $0$ bits | **$0$ bits (auto-seeded Day 0)** |
| **`chpwd` Compute & Disk I/O** | — | — | $O(N)$ slurp + full rewrite | $2$ forks + $1$ `exec` | **$O(1)$ RAM + $1$-line WAL append** |
| **Kernel Forks (`fork`/`exec`)** | $0$ | $0$ | $0$ (`1` fork on `~[<TAB>`) | $2\text{–}3$ forks per op | **$0$ forks everywhere (`PATH=""` safe)** |
| **Inline Path Args (`vim ~cr/f`)** | No | Yes (`~cr`) | Positional `~[1]` only | No | **Yes (`~cr`, `~[cr]`, `~[code:repo]`)** |
| **Bare Jump (`cr` + Enter)** | Command wrapper | With `AUTO_CD`+`CDABLE_VARS` | No (`cdr 1`) | No (`z cr`) | **Yes (`~cr` + `AUTO_CD`+`CDABLE_VARS`)** |
| **Ranking Model** | Static | Static | Pure MRU stack | Aging-rescaled frecency | **Exact Log-Epoch Frecency ($\oplus_\tau$)** |
| **Code Stability (No-Hijack)** | Manual | Manual | **0%** (`~[1]` shifts every `cd`) | Unstable prefix ties | **Proven No-Hijack Stability** |

For a deep line-by-line audit of Zsh 5.9's built-in mechanisms (`$nameddirs`, `CDABLE_VARS`, `zsh_directory_name`, `cdr`, `chpwd_recent_dirs`), see [zsh_native_audit.md](file:///Users/username/CODE.REPOSITORIES/znav/docs/zsh_native_audit.md). For full formal proofs and executable verification certificates, see [formal_proofs.md](file:///Users/username/CODE.REPOSITORIES/znav/proofs/formal_proofs.md).

---

## Quickstart

Source [znav.plugin.zsh](file:///Users/username/CODE.REPOSITORIES/znav/znav.plugin.zsh) in `~/.zshrc`:

```zsh
source /path/to/znav/znav.plugin.zsh

# Optional: enable zero-wrapper bare shortcode navigation (`cr` + Enter -> ~/CODE.REPOSITORIES)
znav init --auto-cd
```

On **Day 0** (when the database is empty), `znav` automatically scans immediate subdirectories of `$HOME` at baseline Log-Epoch weight $0.5$ ($\Lambda_d = t_0 - H$). Without configuring a single alias:

```zsh
# 1. Static C Hash-Table Named Directories (`hash -d`) — works in EVERY argument!
vim ~cr/znav/README.md
diff -u ~cr/project/a.zsh ~sr/deploy/a.zsh
git -C ~cr/znav status

# 2. Bare Shortcode Navigation (with `znav init --auto-cd` -> AUTO_CD + CDABLE_VARS)
cr                      # changes directly into ~/CODE.REPOSITORIES (0 wrapper overhead!)
sr                      # changes directly into ~/SCRIPT.REPOS

# 3. Dynamic Named Directories (`zsh_directory_name` protocol)
cd ~[cr]/znav           # exact shortcode + subpath
ls ~[code:repo]         # multi-token ordered substring resolution
cd ~[<TAB>              # live ranked completion with relative frecency weights

# 4. Ergonomic `j` / `znav` CLI + Subpath Jumping
j cr                    # jump to ~/CODE.REPOSITORIES
j cr znav               # jump directly to ~/CODE.REPOSITORIES/znav (or `j cr/znav`)
j -l                    # aligned table of ~codes, Λ scores, weights, P(d), paths
znav explain cr         # inspect candidate lattice K(d) & collision/reservation reasons
znav stats              # empirical Shannon entropy H(P) vs actual keystroke cost
```

---

## Pure-Zsh Architecture

### 1. Overflow-Safe Log-Epoch Frecency Monoid $(\mathbb{R} \cup \{-\infty\}, \oplus_\tau, -\infty)$
Conventional frecency tools periodically multiply all $N$ database entries by an aging factor ($O(N)$ maintenance) or risk `exp(t / tau)` IEEE-754 `double` overflow ($e^{1.79 \times 10^9 / \tau} = \infty$).

`znav` stores a single **Log-Epoch Score** $\Lambda_d \in \mathbb{R}$ (`float -E 17` for lossless 53-bit IEEE-754 round-trip) with time constant $\tau = H / \ln 2$ (default $H = 259200\text{ s} = 72\text{ h}$):

$$\Lambda_d \leftarrow \Lambda_d \oplus_\tau t = \max(\Lambda_d, t) + \tau \ln\!\Bigl(1 + \exp\bigl(-|\Lambda_d - t| / \tau\bigr)\Bigr)$$

- **Exact Decay Equivalence**: $\exp((\Lambda_d - t)/\tau) = \sum_{k=1}^{m} \exp(-(t - t_k)/\tau)$ for any visit timestamp sequence (even under non-monotonic NTP backward clock adjustments).
- **Time-Translation Order Invariance ($O(0)$ Aging)**: $\Lambda_a > \Lambda_b \iff S_a(t_1) > S_b(t_1) \iff S_a(t_2) > S_b(t_2)$ for all $t_1, t_2 \in \mathbb{R}$. Unvisited directories never require rescaling.
- **Zero Overflow**: Because $-|\Lambda_d - t|/\tau \le 0$, $\exp(\cdot) \in (0, 1]$ and $\ln(1 + \exp(\cdot)) \in (0, \ln 2]$ across arbitrary epochs.

### 2. Segment-Initialism Candidate Lattice $K(d)$ & No-Hijack Bijection $\phi$
Each canonical path $d$ (`${dir:A}`) is ranked under strict total order $\succ$ via $(\Lambda_d, -\text{depth}(d), -\text{bytes}(d), \text{lex}_{\text{ASCII}}(d))$. Basename segments are split on delimiters and `camelCase`/`ACRONYMWord` boundaries (`CODE.REPOSITORIES` $\to$ `["code", "repositories"]`, `HTMLParser` $\to$ `["html", "parser"]`) to generate a deterministic candidate sequence $K(d)$:
1. **Tier 1–2 (Segment-Prefix Lattice)**: Primary initialism (`cr`, `sr`), followed by bounded integer compositions $(\ell_1, \dots, \ell_{m'})$ of total length $L \le 6$ in descending lexicographic prefix order (`cor`, `cre`, `codr`, `core`, `crep`, …).
2. **Tier 3–4 (Normalized Basename & Parent Disambiguation)**: Full joined basename and parent-initialism compounds (`ucr`, `username_code_repositories`).
3. **Tier 5 (Unbounded Collision-Free Tail)**: Deterministic numeric suffixes guaranteeing total collision-free assignment for arbitrary directory sets.

Assigning each directory in descending $\succ$ order its earliest candidate outside reserved set $R$ yields a **priority-optimal injection** $\phi: \mathcal{D} \hookrightarrow \Sigma^+ \setminus R$:
- **No-Hijack Theorem**: Creating or visiting a lower-ranked colliding directory (`~/CACHE.REPOS`) **never** alters `~cr` (`~/CODE.REPOSITORIES`); `CACHE.REPOS` automatically receives `~car`.
- **Namespace & Command-Shadowing Safety**: `znav` tracks its own `hash -d` entries in `_ZNAV_OWNED_NAMEDDIRS`, probes macOS OpenDirectory users via zero-fork tilde expansion (`~root`, `~daemon`, `~$USER`—critical on macOS where `${#userdirs} == 0`), preserves manual `hash -d` entries, and reserves `$commands`, `$builtins`, `$functions`, `$aliases`, and `$reswords` (`TEMP.REPOS` skips `/usr/bin/tr` $\to$ receives `~ter`, so bare `ter` jumps cleanly while `tr` remains unshadowed!).

### 3. $O(1)$-in-$N$ Incremental `chpwd` & Commutative Multi-Shell WAL Compaction
- **$O(1)$ Top-$M$ Maintenance**: By Time-Translation Order Invariance, visiting directory $d$ can only increase $\Lambda_d$; relative order among all other $N - 1$ directories is invariant. `_znav_sync_visit` checks $d$ against its predecessor in `_ZNAV_TOP_DIRS` (or the $M$-th threshold guardian) in $O(1)$ time independent of total database size $N$, updating only affected ranks $\ge \text{new\_pos}$ by No-Hijack Prefix Stability.
- **Zero-Fork Atomic Persistence (`zsh/files`)**: `chpwd` appends a single ANSI-C quoted delta (`V <t_E17> $'...'`) to `wal.log`. When `wal.log` exceeds $2N + 64$ lines (or on `zshexit` / `znav compact`), `znav` acquires an atomic kernel directory mutex (`zf_mkdir compact.lock`), rotates `wal.log` via `zf_mv`, folds `db.tsv` + `wal.log` via commutative $\oplus_\tau$, and atomically renames `db.tsv.tmp.$$` $\to$ `db.tsv` via `zf_mv`—losing zero visits across concurrent shells and surviving arbitrary paths containing spaces, quotes, newlines, brackets `dir[1]*?(glob)`, `$()`, and leading hyphens.

---

## CLI & Configuration Reference

### Commands ([functions/znav](file:///Users/username/CODE.REPOSITORIES/znav/functions/znav))
| Command | Description |
| :--- | :--- |
| `j <tokens...>` / `znav jump [-p] <tokens...>` | Jump to winning directory (supports subpaths: `j cr znav`, `j cr/znav`, `-p` to print path) |
| `znav query [--colon] <tokens...>` | Resolve query `resolve(Q)` to stdout without changing `$PWD` |
| `j -l` / `znav list [-n K] [--tsv]` | Display ranked table of `~code`, `~[code]`, $\Lambda$, decayed weight, $P(d)$, and path |
| `j -e <code\|dir>` / `znav explain [code\|dir]` | Inspect $K(d)$ candidate lattice and exact reason any earlier candidate was skipped |
| `j -s` / `znav stats` | Compute empirical Shannon entropy $H_2(P)$, $H_{37}(P)$ bound, and keystroke savings |
| `znav seed [root ...]` | Seed unseen depth-1 subdirectories (default: `$HOME`) at $\Lambda = t_0 - H$ |
| `znav compact` | Force atomic multi-shell WAL compaction into `db.tsv` |
| `znav prune` | Prune deleted directories from database and unhash stale `hash -d` entries |
| `znav compile` | Bytecode-compile `znav.plugin.zsh` and `functions/*` into `.zwc` files via `zcompile` |
| `znav init [--auto-cd] [--no-cmd]` | Enable `AUTO_CD` + `CDABLE_VARS` and/or disable the wrapper command |

### Environment / Shell Parameters
| Parameter | Default | Meaning |
| :--- | :--- | :--- |
| `ZNAV_DATA_DIR` | `${XDG_DATA_HOME:-~/.local/share}/znav` | Directory storing `db.tsv` snapshot and `wal.log` |
| `ZNAV_HALF_LIFE` | `259200.0` (72 hours) | Exponential frecency half-life $H$ in seconds ($\tau = H / \ln 2$) |
| `ZNAV_MAX_NAMEDDIRS` | `256` | Maximum top-ranked directories projected into static `hash -d` |
| `ZNAV_AVOID_COMMANDS` | `1` | Reserve `$commands`/`$builtins`/`$functions`/`$aliases`/`$reswords` for safe `AUTO_CD` |
| `ZNAV_CMD` | `j` | Jump command name (`none` or `""` to disable wrapper function) |
| `ZNAV_PROMPT_DYNAMIC` | `0` | `%~` mode `d` contraction: `0` (clean / static `~cr`), `1` (`~[cr]`), `fallback` |
| `ZNAV_AUTO_SEED` | `1` | Automatically seed `$HOME` depth-1 subdirectories when database is empty |

---

## Verification & Benchmarks

- **Adversarial & XNU Mach Zero-Fork Test Suite**:
  ```zsh
  zsh tests/run_tests.zsh
  python3 tests/verify_zero_fork.py
  python3 tests/diff_conformance.py
  ```
- **Machine-Checked Formal Proofs**:
  ```zsh
  python3 proofs/verify_all.py
  ```
- **Latency & Information-Efficiency Benchmarks**:
  ```zsh
  zsh benchmarks/run_bench.zsh
  ```
