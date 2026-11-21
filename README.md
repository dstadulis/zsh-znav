# `zsh-znav` — Formally Verified, Zero-Fork Directory Navigation for Zsh

`zsh-znav` (`znav` & `j`) replaces manually curated directory aliases (`alias cr='cd ~/CODE.REPOSITORIES'`, `alias sr='cd ~/SCRIPT.REPOS'`) with an **information-theoretically grounded, machine-checked, 100% pure-Zsh navigation engine** built directly atop Zsh's C hash tables and hook protocols.

Every hot path—startup, `chpwd` tracking, one-shot `precmd` alias protection, `~cr` C hash-table expansion, `~[cr]` dynamic resolution, `j cr` jumping, `~[<TAB>` completion, `cdr` import, and atomic WAL compaction—executes **100% in-process in pure Zsh (`0` `fork(2)` calls, `0` subshells, `0` external binaries, even under `PATH=""`)**.

---

## Why Manual Aliases Fail—and How `zsh-znav` Integrates Natively

Manual aliases (`alias cr='cd ~/CODE.REPOSITORIES'`) suffer from four structural defects:
1. **Lexical confinement to command position**: You cannot write `vim cr/foo`, `cp a sr/b`, or `git -C cr/zsh-znav status` (`alias -g` globally corrupts ordinary arguments across every command).
2. **$\Omega(N \cdot L_{\text{path}})$ human maintenance & silent staleness**: Every new, renamed, or deleted repository requires manual dotfile surgery.
3. **Silent command-table shadowing**: Two-letter initialisms like `tr` (`TEMP.REPOS`), `pr` (`PUBLIC.REPOS`), `ar`, `cc`, `ls`, or `cp` collide with POSIX `/usr/bin` utilities, shell builtins, or personal aliases (`gs`, `lg`).
4. **Zero prompt `%~` or completion awareness**.

| Capability / Complexity | Manual `alias` | Static `hash -d` | Zsh `cdr` (`zshcontrib`) | External (`zoxide`) | **`zsh-znav` (Pure Zsh)** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Human Maintenance Cost** | $\Omega(N)$ manual edits | $\Omega(N)$ manual edits | $0$ bits | $0$ bits | **$0$ bits (auto-seeded Day 0)** |
| **`chpwd` Compute & Disk I/O** | — | — | $O(N)$ slurp + full rewrite | $2$ forks + $1$ `exec` | **$O(1)$ RAM + $1$-line WAL append** |
| **Kernel Forks (`fork`/`exec`)** | $0$ | $0$ | $0$ (`1` fork on `~[<TAB>`) | $2\text{–}3$ forks per op | **$0$ forks everywhere (`PATH=""` safe)** |
| **Inline Path Args (`vim ~cr/f`)** | No | Yes (`~cr`) | Positional `~[1]` only | No | **Yes (`~cr`, `~[cr]`, `~[code:repo]`)** |
| **Bare Jump (`cr` + Enter)** | Command wrapper | With `AUTO_CD`+`CDABLE_VARS` | No (`cdr 1`) | No (`z cr`) | **Yes (`~cr` + `AUTO_CD`+`CDABLE_VARS`)** |
| **Ranking Model** | Static | Static | Pure MRU stack | Aging-rescaled frecency | **Exact Log-Epoch Frecency ($\oplus_\tau$)** |
| **Code Stability (No-Hijack)** | Manual | Manual | **0%** (`~[1]` shifts every `cd`) | Unstable prefix ties | **Proven No-Hijack Stability** |

For a deep line-by-line audit of Zsh 5.9's built-in mechanisms (`$nameddirs`, `CDABLE_VARS`, `zsh_directory_name`, `cdr`, `chpwd_recent_dirs`), see [docs/zsh_native_audit.md](docs/zsh_native_audit.md). For full formal proofs and executable verification certificates, see [proofs/formal_proofs.md](proofs/formal_proofs.md).

---

## Installation

### Local Clone + Symlink Installer (Recommended for Oh My Zsh)

```sh
git clone https://github.com/dstadulis/zsh-znav.git
cd zsh-znav
./install.sh          # Links into $ZSH_CUSTOM/plugins/zsh-znav (default with Oh My Zsh), compiles .zwc, and seeds $HOME depth-1
```

Then add `zsh-znav` to `plugins=(...)` in `~/.zshrc` (before `zsh-autosuggestions` if present) and reload your shell (`exec zsh`).

Installer flags (`./install.sh --help`):
- `--omz-plugin`: Link `$ZSH_CUSTOM/plugins/zsh-znav/{zsh-znav.plugin.zsh,_znav}` so Oh My Zsh's pre-`compinit` `$fpath` registers `_znav` in a single pass *(default when Oh My Zsh is present)*.
- `--omz-custom`: Link directly into `$ZSH_CUSTOM/zsh-znav.zsh` and `$ZSH_CUSTOM/completions/_znav`.
- `--zsh-dir <dir>`: Link autoload functions into `<dir>` (fallback default: `~/.local/share/zsh/site-functions`).
- `--import-zoxide`: Seed initial frecency scores from `zoxide query -ls` during installation.
- `--no-compile`: Skip compiling `.zwc` wordcode files.
- `--dry-run`: Preview actions without modifying the filesystem.

Run `./uninstall.sh` at any time to remove installed symlinks and `.zwc` wordcode cleanly (`--purge-data` to also remove `$ZNAV_DATA_DIR`).

### Zsh Plugin Managers

- **Oh My Zsh** (direct custom plugin clone):
  ```zsh
  git clone https://github.com/dstadulis/zsh-znav.git "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-znav"
  # Add `zsh-znav` to plugins=(...) in ~/.zshrc
  ```
- **Antidote** (`~/.zsh_plugins.txt`):
  ```text
  dstadulis/zsh-znav
  ```
- **Zinit** (`~/.zshrc`):
  ```zsh
  zinit light dstadulis/zsh-znav
  ```
- **Sheldon** (`~/.config/sheldon/plugins.toml`):
  ```toml
  [plugins.zsh-znav]
  github = "dstadulis/zsh-znav"
  ```
- **Znap** (`~/.zshrc`):
  ```zsh
  znap source dstadulis/zsh-znav
  ```
- **Direct Source** (no plugin manager):
  ```zsh
  source /path/to/zsh-znav/zsh-znav.plugin.zsh
  setopt AUTO_CD   # Oh My Zsh enables AUTO_CD automatically; CDABLE_VARS is enabled by default via ZNAV_CDABLE_VARS=1
  ```

---

## Quickstart

On **Day 0** (when the database is empty), `znav` automatically scans immediate subdirectories of `$HOME` at baseline Log-Epoch weight $0.5$ ($\Lambda_d = t_0 - H$). Without configuring a single alias:

```zsh
# 1. Static C Hash-Table Named Directories (`hash -d`) — works in EVERY argument!
vim ~cr/zsh-znav/README.md
diff -u ~cr/project/a.zsh ~sr/deploy/a.zsh
git -C ~cr/zsh-znav status

# 2. Bare Shortcode Navigation (`AUTO_CD` + default `ZNAV_CDABLE_VARS=1`)
cr                      # changes directly into ~/CODE.REPOSITORIES (0 wrapper overhead!)
sr                      # changes directly into ~/SCRIPT.REPOS

# 3. Dynamic Named Directories (`zsh_directory_name` protocol)
cd ~[cr]/zsh-znav       # exact shortcode + subpath
ls ~[code:repo]         # multi-token ordered substring resolution
cd ~[<TAB>              # live ranked completion with relative frecency weights

# 4. Ergonomic `j` / `znav` CLI + Subpath Jumping
j cr                    # jump to ~/CODE.REPOSITORIES
j cr zsh-znav           # jump directly to ~/CODE.REPOSITORIES/zsh-znav (or `j cr/zsh-znav`)
j -l                    # aligned table of ~codes, Λ scores, weights, P(d), paths
znav explain cr         # inspect candidate lattice K(d) & collision/reservation reasons
znav stats              # empirical Shannon entropy H(P) vs actual keystroke cost

# 5. Optional History Migration (from zoxide or Zsh built-in cdr)
znav import --zoxide    # exact Log-Epoch mapping Λ_d = t_now + τ ln(S_d)
znav import --cdr       # pure-Zsh import of ~/.chpwd-recent-dirs
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
- **Namespace, Command & Post-`.zshrc` Alias Safety**: `znav` tracks its own `hash -d` entries in `_ZNAV_OWNED_NAMEDDIRS`, probes macOS OpenDirectory users via zero-fork tilde expansion (`~root`, `~daemon`, `~$USER`), preserves manual `hash -d` entries, and reserves `$commands`, `$builtins`, `$functions`, `$aliases`, and `$reswords` (`TEMP.REPOS` skips `/usr/bin/tr` $\to$ receives `~ter`). Because plugin managers like Oh My Zsh load plugins *before* user aliases (`gs`, `lg`, etc.) at the bottom of `~/.zshrc`, a one-shot `precmd` guard (`_znav_precmd_once`) runs once before the first prompt, unregisters itself (`0` ongoing overhead), and re-projects any shortcode newly claimed by late `.zshrc` aliases or functions (`0` forks).

### 3. $O(1)$-in-$N$ Incremental `chpwd` & Commutative Multi-Shell WAL Compaction
- **$O(1)$ Top-$M$ Maintenance**: By Time-Translation Order Invariance, visiting directory $d$ can only increase $\Lambda_d$; relative order among all other $N - 1$ directories is invariant. `_znav_sync_visit` checks $d$ against its predecessor in `_ZNAV_TOP_DIRS` (or the $M$-th threshold guardian) in $O(1)$ time independent of total database size $N$, updating only affected ranks $\ge \text{new\_pos}$ by No-Hijack Prefix Stability.
- **Zero-Fork Atomic Persistence (`zsh/files`)**: `chpwd` appends a single ANSI-C quoted delta (`V <t_E17> $'...'`) to `wal.log`. When `wal.log` exceeds $2N + 64$ lines (or on `zshexit` / `znav compact`), `znav` acquires an atomic kernel directory mutex (`zf_mkdir compact.lock`), rotates `wal.log` via `zf_mv`, folds `db.tsv` + `wal.log` via commutative $\oplus_\tau$, and atomically renames `db.tsv.tmp.$$` $\to$ `db.tsv` via `zf_mv`—losing zero visits across concurrent shells and surviving arbitrary paths containing spaces, quotes, newlines, brackets `dir[1]*?(glob)`, `$()`, and leading hyphens.

---

<!-- BEGIN ZNAV_BENCHMARKS -->
## Performance Benchmarks

Measured via `zsh/datetime` `$EPOCHREALTIME` in isolated `/tmp` sandboxes on **Apple M5 Max (`arm64`)**, **macOS 26.5**, **Zsh `5.9`** (**1000 iterations** per data point after warm-up; `zoxide 0.10.0` isolated via `_ZO_DATA_DIR`). Re-run locally via `make bench` (`zsh benchmarks/run_bench.zsh`).

### 1. `chpwd` Hook Wall-Clock Latency (µs / op)

| Engine / Mechanism | Complexity | Forks / `cd` | $N = 50$ (µs/op) | $N = 500$ (µs/op) | $N = 2000$ (µs/op) | Speedup vs `cdr` ($N=2000$) | Speedup vs `zoxide` ($N=2000$) |
| :--- | :---: | :---: | ---: | ---: | ---: | ---: | ---: |
| **`znav` (`_znav_chpwd`)** | **$O(1)$ WAL** | **`0`** | **390.67** | **313.72** | **449.72** | **332.6x faster** | **16.6x faster** |
| Zsh `cdr` (`chpwd_recent_dirs`) | $O(N)$ rewrite | `0` | 523.74 | 12946.20 | 149591.11 | 1.0x | 0.0x |
| Minimal External-Fork Floor (`/usr/bin/true`) | $O(1)$ no-op | `1` | 1358.87 | 1256.58 | 1375.50 | — | — |
| `zoxide 0.10.0` (`__zoxide_hook`) | External DB | `2` + `1 exec` | 7256.80 | 7419.21 | 7472.95 | — | 1.0x |

### 2. Jump & Inline Path Expansion Latency (µs / op at $N = 500$)

| Operation | Mechanism | Works in Arbitrary Path Args (`vim ...`)? | Forks / Op | Latency (µs/op) | Relative to External Jump |
| :--- | :--- | :---: | :---: | ---: | ---: |
| **`~cr` (`znav` static named dir)** | **Zsh C `nameddirtab` hash lookup** | **Yes (`vim ~cr/f`)** | **`0`** | **0.17** | **89486.8x faster** |
| **`~[cr]` (`znav` dynamic hook)** | **`_znav_directory_name n` hook** | **Yes (`vim ~[cr]/f`)** | **`0`** | **24.83** | **612.7x faster** |
| **`cd ~cr` (jump + `znav` `chpwd`)** | **C `nameddirtab` + `builtin cd` + WAL** | **Yes (bare `cr` w/ `AUTO_CD`)** | **`0`** | **322.35** | **47.2x faster** |
| **`j cr` (`znav` CLI jump + `chpwd`)** | **`resolve(cr)` + `builtin cd` + WAL** | `cd` jump (+ subpath `j cr sub`) | **`0`** | **394.85** | **38.5x faster** |
| `~[1]` (`zsh_directory_name_cdr`) | Re-reads & lexes `.chpwd-recent-dirs` | Yes (unstable index!) | `0` | 2677.65 | — |
| `cdr 1` (jump + `cdr` `chpwd`) | $O(N)$ read + `cd` + $O(N)$ rewrite | `cd` jump | `0` | 15744.74 | — |
| Minimal External-Fork Jump Floor | `$(/bin/echo $dir) && cd -q` | No | `1` | 1308.16 | — |
| `zoxide 0.10.0` (`z <query>`) | 3 subshells + `zoxide query` + `zoxide add` | No | `5` + `2 exec` | 15212.76 | 1.0x |

### 3. Empirical Information Efficiency & Recall Churn (`Zipf(s = 1.2)`)

| Tree Size $N$ | Shannon $H_2(P)$ (bits) | Entropy Min Cmd $H_{36}(P)+1$ (keys) | **`znav` Bare `cr\n` / `~cr` (keys)** | **`znav` `j cr\n` (keys)** | `cd ~/...\n` Full Path (keys) | Manual Top-10 Aliases + Tail (keys) | `cdr <k>\n` Default Max-20 (keys) | **`znav` Recall Churn (%)** | **`cdr` Recall Churn (%)** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **30** | 3.70 b | 1.71 | **3.17** *(code: 2.17 ch)* | **5.17** | 30.27 | 9.65 *(tail: 19.6%)* | 9.52 *(unb: 6.03)* | **0.00%** | **89.46%** |
| **100** | 4.65 b | 1.90 | **3.22** *(code: 2.22 ch)* | **5.22** | 30.89 | 13.33 *(tail: 31.5%)* | 16.16 *(unb: 6.37)* | **0.39%** | **92.73%** |
| **500** | 5.70 b | 2.10 | **3.28** *(code: 2.28 ch)* | **5.28** | 31.25 | 16.00 *(tail: 40.5%)* | 20.46 *(unb: 7.74)* | **1.98%** | **95.29%** |

Full methodology, baseline configurations, and ergonomic breakdown: [`benchmarks/results.md`](benchmarks/results.md) (machine-readable data: [`benchmarks/results.json`](benchmarks/results.json)).
<!-- END ZNAV_BENCHMARKS -->

---

## CLI & Configuration Reference

### Commands ([functions/znav](functions/znav))
| Command | Description |
| :--- | :--- |
| `j <tokens...>` / `znav jump [-p] <tokens...>` | Jump to winning directory (supports subpaths: `j cr zsh-znav`, `j cr/zsh-znav`, `-p` to print path) |
| `znav query [--colon] <tokens...>` | Resolve query `resolve(Q)` to stdout without changing `$PWD` |
| `j -l` / `znav list [-n K] [--tsv]` | Display ranked table of `~code`, `~[code]`, $\Lambda$, decayed weight, $P(d)$, and path |
| `j -e <code\|dir>` / `znav explain [code\|dir]` | Inspect $K(d)$ candidate lattice and exact reason any earlier candidate was skipped |
| `j -s` / `znav stats` | Compute empirical Shannon entropy $H_2(P)$, $H_{37}(P)$ bound, and keystroke savings |
| `znav seed [root ...]` | Seed unseen depth-1 subdirectories (default: `$HOME`) at $\Lambda = t_0 - H$ |
| `znav import [--zoxide \| --cdr [--file <p>]]` | Import directory history from `zoxide query -ls` or Zsh `cdr` (`.chpwd-recent-dirs`) |
| `znav compact` | Force atomic multi-shell WAL compaction into `db.tsv` |
| `znav prune` | Prune deleted directories from database and unhash stale `hash -d` entries |
| `znav compile` | Bytecode-compile plugin files and `functions/*` into `.zwc` wordcode via `zcompile` |
| `znav init [--auto-cd] [--no-cmd]` | Enable `AUTO_CD` + `CDABLE_VARS` and/or disable the wrapper command |

### Environment / Shell Parameters
| Parameter | Default | Meaning |
| :--- | :--- | :--- |
| `ZNAV_DATA_DIR` | `${XDG_DATA_HOME:-~/.local/share}/znav` | Directory storing `db.tsv` snapshot and `wal.log` |
| `ZNAV_HALF_LIFE` | `259200.0` (72 hours) | Exponential frecency half-life $H$ in seconds ($\tau = H / \ln 2$) |
| `ZNAV_MAX_NAMEDDIRS` | `256` | Maximum top-ranked directories projected into static `hash -d` |
| `ZNAV_AVOID_COMMANDS` | `1` | Reserve `$commands`/`$builtins`/`$functions`/`$aliases`/`$reswords` for safe `AUTO_CD` |
| `ZNAV_CDABLE_VARS` | `1` | Enable `CDABLE_VARS` on plugin load (`0` to leave caller's `CDABLE_VARS` untouched) |
| `ZNAV_CMD` | `j` | Jump command name (`none` or `""` to disable wrapper function) |
| `ZNAV_PROMPT_DYNAMIC` | `0` | `%~` mode `d` contraction: `0` (clean / static `~cr`), `1` (`~[cr]`), `fallback` |
| `ZNAV_AUTO_SEED` | `1` | Automatically seed `$HOME` depth-1 subdirectories when database is empty |

---

## Verification & Benchmarks

- **Adversarial & XNU Mach Zero-Fork Test Suite** (`make test`):
  ```zsh
  zsh tests/run_tests.zsh
  python3 tests/verify_zero_fork.py
  python3 tests/diff_conformance.py
  ```
- **Machine-Checked Formal Proofs** (`make proof`):
  ```zsh
  python3 proofs/verify_all.py
  ```
- **Latency & Information-Efficiency Benchmarks + README Auto-Sync** (`make bench`):
  ```zsh
  zsh benchmarks/run_bench.zsh
  ```

---

## License

Released under the [MIT License](LICENSE).
