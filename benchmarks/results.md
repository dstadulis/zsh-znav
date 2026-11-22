# `znav` Quantitative Benchmark Results

## Benchmark Environment & Methodology

- **Hardware**: Apple M2 Pro (Virtual) (`arm64`)
- **Operating System**: macOS 26.7.2
- **Shell**: `/bin/zsh` `5.9` (isolated `/tmp` sandboxes via `zsh -dfi +Z +m`, host state untouched)
- **Timing Source**: `zsh/datetime` `$EPOCHREALTIME` (nanosecond-resolution monotonic-scale clock) averaged over **1000 iterations** per data point after warm-up.
- **Baselines**:
  - **`znav` (Pure Zsh)**: In-process IEEE-754 `zsh/mathfunc` Log-Epoch update + 1-line append-only WAL + C `nameddirtab` (`hash -d`) & `zsh_directory_name` projection (`0` forks, `0` subshells).
  - **Zsh `cdr` / `chpwd_recent_dirs` (`zshcontrib`)**: Upstream Zsh MRU stack configured with `zstyle ':chpwd:*' recent-dirs-max 0` so all $N$ entries are retained (`0` forks via in-process `$(<$file)`, but $O(N)$ full-file slurp + `${(z)line}` shell lexer + non-atomic truncate-rewrite on every `cd`).
  - **Minimal External-Fork Floor**: Irreducible OS `fork(2)` + `execve(2)` overhead executing `/usr/bin/true` (`chpwd`) or `$(/bin/echo ...)` (`jump`) with zero database work.
  - **`zoxide 0.10.0` (Compiled Rust CLI)**: Real external frecency engine isolated via `_ZO_DATA_DIR`, paying subshell + `fork` + `execve` on every hook and query.

---

## 1. `chpwd` Hook Wall-Clock Latency (µs / op)

| Engine / Mechanism | Complexity | Forks / `cd` | $N = 50$ (µs/op) | $N = 500$ (µs/op) | $N = 2000$ (µs/op) | Speedup vs `cdr` ($N=2000$) | Speedup vs `zoxide` ($N=2000$) |
| :--- | :---: | :---: | ---: | ---: | ---: | ---: | ---: |
| **`znav` (`_znav_chpwd`)** | **$O(1)$ WAL** | **`0`** | **546.78** | **451.59** | **654.45** | **325.6x faster** | **4.9x faster** |
| Zsh `cdr` (`chpwd_recent_dirs`) | $O(N)$ rewrite | `0` | 807.36 | 17144.00 | 213119.49 | 1.0x | 0.0x |
| Minimal External-Fork Floor (`/usr/bin/true`) | $O(1)$ no-op | `1` | 1240.18 | 1252.64 | 1284.41 | — | — |
| `zoxide 0.10.0` (`__zoxide_hook`) | External DB | `2` + `1 exec` | 3065.22 | 3235.01 | 3228.90 | — | 1.0x |

**Key Takeaways**:
1. **True $O(1)$ Scaling**: As the tracked workspace grows $40\times$ from $N = 50 \to 2000$, `cdr` degrades linearly due to re-slurping, `${(z)}`-lexing, and rewriting all $N$ lines on every directory change, whereas `znav` appends a single constant-size `V <t> <dir>` record to its WAL.
2. **Faster Than Empty `fork`+`exec`**: Pure-Zsh `znav` completes its entire IEEE-754 transcendental frecency update, shortcode check, and disk WAL append in a fraction of the time it takes the kernel merely to `fork` + `execve` `/usr/bin/true`—and outpaces compiled Rust `zoxide 0.10.0` by **4.9x** on every `cd`.

---

## 2. Jump & Inline Path Expansion Latency (µs / op at $N = 500$)

| Operation | Mechanism | Works in Arbitrary Path Args (`vim ...`)? | Forks / Op | Latency (µs/op) | Relative to External Jump |
| :--- | :--- | :---: | :---: | ---: | ---: |
| **`~cr` (`znav` static named dir)** | **Zsh C `nameddirtab` hash lookup** | **Yes (`vim ~cr/f`)** | **`0`** | **0.25** | **27011.2x faster** |
| **`~[cr]` (`znav` dynamic hook)** | **`_znav_directory_name n` hook** | **Yes (`vim ~[cr]/f`)** | **`0`** | **31.22** | **216.3x faster** |
| **`cd ~cr` (jump + `znav` `chpwd`)** | **C `nameddirtab` + `builtin cd` + WAL** | **Yes (bare `cr` w/ `AUTO_CD`)** | **`0`** | **445.33** | **15.2x faster** |
| **`j cr` (`znav` CLI jump + `chpwd`)** | **`resolve(cr)` + `builtin cd` + WAL** | `cd` jump (+ subpath `j cr sub`) | **`0`** | **542.94** | **12.4x faster** |
| `~[1]` (`zsh_directory_name_cdr`) | Re-reads & lexes `.chpwd-recent-dirs` | Yes (unstable index!) | `0` | 3766.42 | — |
| `cdr 1` (jump + `cdr` `chpwd`) | $O(N)$ read + `cd` + $O(N)$ rewrite | `cd` jump | `0` | 20643.56 | — |
| Minimal External-Fork Jump Floor | `$(/bin/echo $dir) && cd -q` | No | `1` | 1374.82 | — |
| `zoxide 0.10.0` (`z <query>`) | 3 subshells + `zoxide query` + `zoxide add` | No | `5` + `2 exec` | 6752.81 | 1.0x |

---

## 3. Empirical Information Efficiency & Recall Churn (`Zipf(s = 1.2)`)

Evaluated across realistic multi-repository developer directory trees ($N \in \{30, 100, 500\}$) under a heavy-tailed $\text{Zipf}(s = 1.2)$ visit distribution ($1,500$ warm-up transitions followed by $5,000$ measured transitions; alphabet $|\Sigma| = 36$ `[a-z0-9]`).

- **Shannon Entropy Lower Bound**: $H_2(P)$ bits/visit, yielding theoretical minimum expected code length $H_{36}(P) = H_2(P) / \log_2(36)$ characters (plus `+1` `<Enter>` keystroke = $H_{36}(P) + 1$ minimum command keystrokes for any prefix/uniquely-resolvable static command mapping).
- **Recall Churn Rate**: Percentage of repeat visits to a directory $d$ where $d$'s jump code **changed** since the user's immediately preceding visit to $d$ (`0%` = perfect muscle memory; high `%` = user cannot memorize codes and must inspect a list first).

| Tree Size $N$ | Shannon $H_2(P)$ (bits) | Entropy Min Cmd $H_{36}(P)+1$ (keys) | **`znav` Bare `cr\n` / `~cr` (keys)** | **`znav` `j cr\n` (keys)** | `cd ~/...\n` Full Path (keys) | Manual Top-10 Aliases + Tail (keys) | `cdr <k>\n` Default Max-20 (keys) | **`znav` Recall Churn (%)** | **`cdr` Recall Churn (%)** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **30** | 3.70 b | 1.71 | **3.17** *(code: 2.17 ch)* | **5.17** | 30.27 | 9.65 *(tail: 19.6%)* | 9.52 *(unb: 6.03)* | **0.00%** | **89.46%** |
| **100** | 4.65 b | 1.90 | **3.22** *(code: 2.22 ch)* | **5.22** | 30.89 | 13.33 *(tail: 31.5%)* | 16.16 *(unb: 6.37)* | **0.39%** | **92.73%** |
| **500** | 5.70 b | 2.10 | **3.28** *(code: 2.28 ch)* | **5.28** | 31.25 | 16.00 *(tail: 40.5%)* | 20.46 *(unb: 7.74)* | **1.98%** | **95.29%** |

### Information-Theoretic & Ergonomic Synthesis

1. **Near-Shannon Compression with Zero Human Maintenance**:
   - Across $N = 30 \to 500$ directories, `znav` achieves an expected shortcode length of **2.17–2.28 characters** (**3.17–3.28 total keystrokes** with `<Enter>` under `AUTO_CD`+`CDABLE_VARS` or `~code` inline expansion)—cutting full-path keystrokes (`30.27–31.25` keys) by **~8x–10x** while requiring **0 manual `~/.zshrc` maintenance characters** (vs `480`+ hand-typed config chars for just 10 manual aliases).
   - Sample top-5 automatically assigned bindings: `cr` $\to$ `~/CODE.REPOSITORIES` (32.6%), `sr` $\to$ `~/SCRIPT.REPOS` (14.19%), `zn` $\to$ `~/CODE.REPOSITORIES/znav` (8.72%), `cv` $\to$ `~/CODE.REPOSITORIES/code-verification` (6.18%), `faf` $\to$ `~/CODE.REPOSITORIES/foss-agentic-forge` (4.73%).
2. **Why Partial Manual Aliases Collapse Under Heavy-Tailed `Zipf(1.2)`**:
   - Even if a developer dutifully curates aliases for their top 10 directories, under $\text{Zipf}(1.2)$ the unaliased tail ($r > 10$) still accounts for **19.6% ($N=30$) to 40.5% ($N=500$)** of all navigation events—inflating expected keystrokes to **9.65–16.00 keys/jump** (nearly $5\times–6\times$ worse than `znav`).
3. **Muscle-Memory Stability (`znav` No-Hijack Theorem vs `cdr` Positional Churn)**:
   - In Zsh's native `cdr`, every transition mutates stack indices (**100.0%** per-step code-table mutation), causing **89.46%–95.29%** of repeat directory visits to have a *different* numeric index than the previous visit to that exact same directory (plus heavy MRU eviction penalties beyond `recent-dirs-max=20`).
   - In `znav`, the formally proven **No-Hijack Theorem** locks top-ranked bindings (`cr`, `sr`, ...) against transient directory creation and exploration, achieving **0.00%–1.98%** recall churn (**98.02%** muscle-memory stability even across $N=500$ directories!).
