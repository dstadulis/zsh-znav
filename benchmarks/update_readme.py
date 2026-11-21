#!/usr/bin/env python3
"""
Auto-inject and synchronize benchmark tables in README.md (and benchmarks/results.md)
from structured machine-readable benchmarks/results.json.

Splices a deterministic `## Performance Benchmarks` section into README.md strictly
between HTML sentinel comments:
  <!-- BEGIN ZNAV_BENCHMARKS -->
  ...
  <!-- END ZNAV_BENCHMARKS -->
preserving all content outside the sentinels byte-for-byte.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

BEGIN_MARKER = "<!-- BEGIN ZNAV_BENCHMARKS -->"
END_MARKER = "<!-- END ZNAV_BENCHMARKS -->"


def fmt_us(val: float | None) -> str:
    if val is None:
        return "N/A"
    return f"{float(val):.2f}"


def fmt_faster(ratio_str: str) -> str:
    if not ratio_str or ratio_str == "N/A":
        return "N/A"
    return f"**{ratio_str} faster**"


def _render_shared_tables(data: dict[str, Any], heading_prefix: str = "###") -> tuple[str, str, str]:
    env = data["environment"]
    chpwd = data["chpwd_latency_us"]
    jump = data["jump_latency_us"]
    info_meta = data["info_efficiency"]
    trees = info_meta["trees"]

    zo_avail = bool(env.get("zoxide_available"))
    zo_ver = env.get("zoxide_version") or "zoxide"
    zo_label = f"`{zo_ver}`" if zo_avail else "`zoxide` *(not installed)*"

    c50 = chpwd["50"]
    c500 = chpwd["500"]
    c2000 = chpwd["2000"]

    zo_base_col = "1.0x" if c2000.get("zoxide") is not None else "N/A"
    cdr_vs_zo = c2000.get("cdr_vs_zoxide", "N/A")
    if cdr_vs_zo == "N/A":
        cdr_vs_zo_cell = "—" if not zo_avail else "N/A"
    else:
        cdr_vs_zo_cell = cdr_vs_zo

    table1 = (
        f"{heading_prefix} 1. `chpwd` Hook Wall-Clock Latency (µs / op)\n\n"
        "| Engine / Mechanism | Complexity | Forks / `cd` | $N = 50$ (µs/op) | $N = 500$ (µs/op) | $N = 2000$ (µs/op) | Speedup vs `cdr` ($N=2000$) | Speedup vs `zoxide` ($N=2000$) |\n"
        "| :--- | :---: | :---: | ---: | ---: | ---: | ---: | ---: |\n"
        f"| **`znav` (`_znav_chpwd`)** | **$O(1)$ WAL** | **`0`** | **{fmt_us(c50['znav'])}** | **{fmt_us(c500['znav'])}** | **{fmt_us(c2000['znav'])}** | {fmt_faster(c2000['speedup_vs_cdr'])} | {fmt_faster(c2000['speedup_vs_zoxide'])} |\n"
        f"| Zsh `cdr` (`chpwd_recent_dirs`) | $O(N)$ rewrite | `0` | {fmt_us(c50['cdr'])} | {fmt_us(c500['cdr'])} | {fmt_us(c2000['cdr'])} | 1.0x | {cdr_vs_zo_cell} |\n"
        f"| Minimal External-Fork Floor (`/usr/bin/true`) | $O(1)$ no-op | `1` | {fmt_us(c50['fork_floor'])} | {fmt_us(c500['fork_floor'])} | {fmt_us(c2000['fork_floor'])} | — | — |\n"
        f"| {zo_label} (`__zoxide_hook`) | External DB | `2` + `1 exec` | {fmt_us(c50['zoxide'])} | {fmt_us(c500['zoxide'])} | {fmt_us(c2000['zoxide'])} | — | {zo_base_col} |"
    )

    n_jump = jump.get("n_dirs", 500)
    sp = jump["speedups_vs_external"]
    zo_jump_base = "1.0x" if jump.get("zoxide_jump") is not None else "N/A"
    ext_floor_base = "1.0x" if jump.get("zoxide_jump") is None else "—"

    table2 = (
        f"{heading_prefix} 2. Jump & Inline Path Expansion Latency (µs / op at $N = {n_jump}$)\n\n"
        "| Operation | Mechanism | Works in Arbitrary Path Args (`vim ...`)? | Forks / Op | Latency (µs/op) | Relative to External Jump |\n"
        "| :--- | :--- | :---: | :---: | ---: | ---: |\n"
        f"| **`~cr` (`znav` static named dir)** | **Zsh C `nameddirtab` hash lookup** | **Yes (`vim ~cr/f`)** | **`0`** | **{fmt_us(jump['tilde_static'])}** | {fmt_faster(sp['tilde_static'])} |\n"
        f"| **`~[cr]` (`znav` dynamic hook)** | **`_znav_directory_name n` hook** | **Yes (`vim ~[cr]/f`)** | **`0`** | **{fmt_us(jump['tilde_dynamic'])}** | {fmt_faster(sp['tilde_dynamic'])} |\n"
        f"| **`cd ~cr` (jump + `znav` `chpwd`)** | **C `nameddirtab` + `builtin cd` + WAL** | **Yes (bare `cr` w/ `AUTO_CD`)** | **`0`** | **{fmt_us(jump['cd_tilde'])}** | {fmt_faster(sp['cd_tilde'])} |\n"
        f"| **`j cr` (`znav` CLI jump + `chpwd`)** | **`resolve(cr)` + `builtin cd` + WAL** | `cd` jump (+ subpath `j cr sub`) | **`0`** | **{fmt_us(jump['jump_j'])}** | {fmt_faster(sp['jump_j'])} |\n"
        f"| `~[1]` (`zsh_directory_name_cdr`) | Re-reads & lexes `.chpwd-recent-dirs` | Yes (unstable index!) | `0` | {fmt_us(jump['cdr_dynamic'])} | — |\n"
        f"| `cdr 1` (jump + `cdr` `chpwd`) | $O(N)$ read + `cd` + $O(N)$ rewrite | `cd` jump | `0` | {fmt_us(jump['cdr_jump'])} | — |\n"
        f"| Minimal External-Fork Jump Floor | `$(/bin/echo $dir) && cd -q` | No | `1` | {fmt_us(jump['ext_jump_floor'])} | {ext_floor_base} |\n"
        f"| {zo_label} (`z <query>`) | 3 subshells + `zoxide query` + `zoxide add` | No | `5` + `2 exec` | {fmt_us(jump['zoxide_jump'])} | {zo_jump_base} |"
    )

    zipf_s = info_meta.get("zipf_s", 1.2)
    t3_lines = [
        f"{heading_prefix} 3. Empirical Information Efficiency & Recall Churn (`Zipf(s = {zipf_s})`)\n",
        "| Tree Size $N$ | Shannon $H_2(P)$ (bits) | Entropy Min Cmd $H_{36}(P)+1$ (keys) | **`znav` Bare `cr\\n` / `~cr` (keys)** | **`znav` `j cr\\n` (keys)** | `cd ~/...\\n` Full Path (keys) | Manual Top-10 Aliases + Tail (keys) | `cdr <k>\\n` Default Max-20 (keys) | **`znav` Recall Churn (%)** | **`cdr` Recall Churn (%)** |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in trees:
        t3_lines.append(
            f"| **{row['N']}** | {row['H_bits']:.2f} b | {row['H_36_bare_cmd_lb']:.2f} | "
            f"**{row['znav_exp_ks_bare']:.2f}** *(code: {row['znav_exp_code_len']:.2f} ch)* | "
            f"**{row['znav_exp_ks_j']:.2f}** | {row['full_cd_exp_ks']:.2f} | "
            f"{row['manual10_exp_ks']:.2f} *(tail: {row['manual10_tail_pct']:.1f}%)* | "
            f"{row['cdr_default20_exp_ks']:.2f} *(unb: {row['cdr_unbounded_exp_ks']:.2f})* | "
            f"**{row['znav_recall_churn_pct']:.2f}%** | **{row['cdr_recall_churn_pct']:.2f}%** |"
        )
    table3 = "\n".join(t3_lines)

    return table1, table2, table3


def render_readme_section(data: dict[str, Any]) -> str:
    env = data["environment"]
    hw = env["hardware"]
    arch = env["arch"]
    os_label = env["os"]
    zsh_ver = env["zsh_version"]
    iters = env["iterations"]
    zo_note = (
        f"; `{env['zoxide_version']}` isolated via `_ZO_DATA_DIR`"
        if env.get("zoxide_available")
        else "; `zoxide` not installed on runner"
    )

    table1, table2, table3 = _render_shared_tables(data, heading_prefix="###")

    return (
        "## Performance Benchmarks\n\n"
        f"Measured via `zsh/datetime` `$EPOCHREALTIME` in isolated `/tmp` sandboxes on "
        f"**{hw} (`{arch}`)**, **{os_label}**, **Zsh `{zsh_ver}`** "
        f"(**{iters} iterations** per data point after warm-up{zo_note}). "
        "Re-run locally via `make bench` (`zsh benchmarks/run_bench.zsh`).\n\n"
        f"{table1}\n\n"
        f"{table2}\n\n"
        f"{table3}\n\n"
        "Full methodology, baseline configurations, and ergonomic breakdown: "
        "[`benchmarks/results.md`](benchmarks/results.md) "
        "(machine-readable data: [`benchmarks/results.json`](benchmarks/results.json))."
    )


def render_results_md(data: dict[str, Any]) -> str:
    env = data["environment"]
    chpwd = data["chpwd_latency_us"]
    info_meta = data["info_efficiency"]
    trees = info_meta["trees"]

    hw = env["hardware"]
    arch = env["arch"]
    os_label = env["os"]
    zsh_bin = env.get("zsh_bin", "zsh")
    zsh_ver = env["zsh_version"]
    iters = env["iterations"]
    zo_avail = bool(env.get("zoxide_available"))
    zo_ver = env.get("zoxide_version") or "zoxide"

    table1, table2, table3 = _render_shared_tables(data, heading_prefix="##")

    zo_baseline_desc = (
        f"**`{zo_ver}` (Compiled Rust CLI)**: Real external frecency engine isolated via `_ZO_DATA_DIR`, paying subshell + `fork` + `execve` on every hook and query."
        if zo_avail
        else "**`zoxide` (Compiled Rust CLI)**: External frecency baseline (`N/A` on this host because `zoxide` was not installed)."
    )

    c2000 = chpwd["2000"]
    zo_takeaway = (
        f"—and outpaces compiled Rust `{zo_ver}` by **{c2000['speedup_vs_zoxide']}** on every `cd`."
        if zo_avail and c2000.get("speedup_vs_zoxide", "N/A") != "N/A"
        else "."
    )

    s30 = trees[0]
    s500 = trees[-1]
    top5_str = ", ".join(
        f"`{x['code']}` $\\to$ `{x['dir']}` ({x['prob_pct']}%)"
        for x in s30["sample_top5_codes"]
    )
    stability_500 = 100.0 - float(s500["znav_recall_churn_pct"])

    return (
        "# `znav` Quantitative Benchmark Results\n\n"
        "## Benchmark Environment & Methodology\n\n"
        f"- **Hardware**: {hw} (`{arch}`)\n"
        f"- **Operating System**: {os_label}\n"
        f"- **Shell**: `{zsh_bin}` `{zsh_ver}` (isolated `/tmp` sandboxes via `zsh -dfi +Z +m`, host state untouched)\n"
        f"- **Timing Source**: `zsh/datetime` `$EPOCHREALTIME` (nanosecond-resolution monotonic-scale clock) averaged over **{iters} iterations** per data point after warm-up.\n"
        "- **Baselines**:\n"
        "  - **`znav` (Pure Zsh)**: In-process IEEE-754 `zsh/mathfunc` Log-Epoch update + 1-line append-only WAL + C `nameddirtab` (`hash -d`) & `zsh_directory_name` projection (`0` forks, `0` subshells).\n"
        "  - **Zsh `cdr` / `chpwd_recent_dirs` (`zshcontrib`)**: Upstream Zsh MRU stack configured with `zstyle ':chpwd:*' recent-dirs-max 0` so all $N$ entries are retained (`0` forks via in-process `$(<$file)`, but $O(N)$ full-file slurp + `${(z)line}` shell lexer + non-atomic truncate-rewrite on every `cd`).\n"
        "  - **Minimal External-Fork Floor**: Irreducible OS `fork(2)` + `execve(2)` overhead executing `/usr/bin/true` (`chpwd`) or `$(/bin/echo ...)` (`jump`) with zero database work.\n"
        f"  - {zo_baseline_desc}\n\n"
        "---\n\n"
        f"{table1}\n\n"
        "**Key Takeaways**:\n"
        "1. **True $O(1)$ Scaling**: As the tracked workspace grows $40\\times$ from $N = 50 \\to 2000$, `cdr` degrades linearly due to re-slurping, `${(z)}`-lexing, and rewriting all $N$ lines on every directory change, whereas `znav` appends a single constant-size `V <t> <dir>` record to its WAL.\n"
        f"2. **Faster Than Empty `fork`+`exec`**: Pure-Zsh `znav` completes its entire IEEE-754 transcendental frecency update, shortcode check, and disk WAL append in a fraction of the time it takes the kernel merely to `fork` + `execve` `/usr/bin/true`{zo_takeaway}\n\n"
        "---\n\n"
        f"{table2.replace('### 2. Jump & Inline Path Expansion Latency', '## 2. Directory Jump & Path Expansion Latency')}\n\n"
        "---\n\n"
        f"{table3.splitlines()[0]}\n\n"
        f"Evaluated across realistic multi-repository developer directory trees ($N \\in \\{{30, 100, 500\\}}$) under a heavy-tailed $\\text{{Zipf}}(s = {info_meta['zipf_s']})$ visit distribution (${info_meta['warmup_steps']:,}$ warm-up transitions followed by ${info_meta['trace_steps']:,}$ measured transitions; alphabet $|\\Sigma| = {info_meta['alphabet_size']}$ `[a-z0-9]`).\n\n"
        "- **Shannon Entropy Lower Bound**: $H_2(P)$ bits/visit, yielding theoretical minimum expected code length $H_{36}(P) = H_2(P) / \\log_2(36)$ characters (plus `+1` `<Enter>` keystroke = $H_{36}(P) + 1$ minimum command keystrokes for any prefix/uniquely-resolvable static command mapping).\n"
        "- **Recall Churn Rate**: Percentage of repeat visits to a directory $d$ where $d$'s jump code **changed** since the user's immediately preceding visit to $d$ (`0%` = perfect muscle memory; high `%` = user cannot memorize codes and must inspect a list first).\n\n"
        + "\n".join(table3.splitlines()[2:])
        + "\n\n"
        "### Information-Theoretic & Ergonomic Synthesis\n\n"
        "1. **Near-Shannon Compression with Zero Human Maintenance**:\n"
        f"   - Across $N = 30 \\to 500$ directories, `znav` achieves an expected shortcode length of **{s30['znav_exp_code_len']:.2f}–{s500['znav_exp_code_len']:.2f} characters** (**{s30['znav_exp_ks_bare']:.2f}–{s500['znav_exp_ks_bare']:.2f} total keystrokes** with `<Enter>` under `AUTO_CD`+`CDABLE_VARS` or `~code` inline expansion)—cutting full-path keystrokes (`{s30['full_cd_exp_ks']:.2f}–{s500['full_cd_exp_ks']:.2f}` keys) by **~8x–10x** while requiring **0 manual `~/.zshrc` maintenance characters** (vs `{s30['manual10_maint_chars']}`+ hand-typed config chars for just 10 manual aliases).\n"
        f"   - Sample top-5 automatically assigned bindings: {top5_str}.\n"
        "2. **Why Partial Manual Aliases Collapse Under Heavy-Tailed `Zipf(1.2)`**:\n"
        f"   - Even if a developer dutifully curates aliases for their top 10 directories, under $\\text{{Zipf}}(1.2)$ the unaliased tail ($r > 10$) still accounts for **{s30['manual10_tail_pct']:.1f}% ($N=30$) to {s500['manual10_tail_pct']:.1f}% ($N=500$)** of all navigation events—inflating expected keystrokes to **{s30['manual10_exp_ks']:.2f}–{s500['manual10_exp_ks']:.2f} keys/jump** (nearly $5\\times–6\\times$ worse than `znav`).\n"
        "3. **Muscle-Memory Stability (`znav` No-Hijack Theorem vs `cdr` Positional Churn)**:\n"
        f"   - In Zsh's native `cdr`, every transition mutates stack indices (**{s500['cdr_step_mut_pct']:.1f}%** per-step code-table mutation), causing **{s30['cdr_recall_churn_pct']:.2f}%–{s500['cdr_recall_churn_pct']:.2f}%** of repeat directory visits to have a *different* numeric index than the previous visit to that exact same directory (plus heavy MRU eviction penalties beyond `recent-dirs-max=20`).\n"
        f"   - In `znav`, the formally proven **No-Hijack Theorem** locks top-ranked bindings (`cr`, `sr`, ...) against transient directory creation and exploration, achieving **{s30['znav_recall_churn_pct']:.2f}%–{s500['znav_recall_churn_pct']:.2f}%** recall churn (**{stability_500:.2f}%** muscle-memory stability even across $N=500$ directories!).\n"
    )


def splice_readme(readme_text: str, section_body: str) -> str:
    begin_count = readme_text.count(BEGIN_MARKER)
    end_count = readme_text.count(END_MARKER)
    if begin_count != 1 or end_count != 1:
        raise ValueError(
            f"Expected exactly 1 '{BEGIN_MARKER}' and 1 '{END_MARKER}' in README "
            f"(found begin={begin_count}, end={end_count})."
        )

    b_idx = readme_text.index(BEGIN_MARKER)
    e_idx = readme_text.index(END_MARKER)
    if b_idx >= e_idx:
        raise ValueError(f"'{BEGIN_MARKER}' must appear before '{END_MARKER}'.")

    prefix = readme_text[:b_idx]
    suffix = readme_text[e_idx + len(END_MARKER) :]
    return f"{prefix}{BEGIN_MARKER}\n{section_body.strip()}\n{END_MARKER}{suffix}"


def main() -> int:
    bench_dir = Path(__file__).resolve().parent
    repo_root = bench_dir.parent

    parser = argparse.ArgumentParser(
        description="Synchronize README.md benchmark section (and optional results.md) from results.json."
    )
    parser.add_argument(
        "--results",
        "-r",
        type=Path,
        default=None,
        help="Path to benchmarks/results.json",
    )
    parser.add_argument(
        "--readme",
        "-m",
        type=Path,
        default=None,
        help="Path to README.md containing ZNAV_BENCHMARKS sentinel comments",
    )
    parser.add_argument(
        "--results-md",
        type=Path,
        default=None,
        help="Optional path to write full benchmarks/results.md report",
    )
    parser.add_argument(
        "--no-readme",
        action="store_true",
        help="Skip updating README.md (useful with --results-md)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check that README.md is already synchronized without modifying files",
    )
    parser.add_argument("pos_args", nargs="*", help=argparse.SUPPRESS)
    args = parser.parse_args()

    results_path = args.results
    readme_path = args.readme
    if results_path is None:
        results_path = Path(args.pos_args[0]) if len(args.pos_args) >= 1 else (bench_dir / "results.json")
    if readme_path is None:
        readme_path = Path(args.pos_args[1]) if len(args.pos_args) >= 2 else (repo_root / "README.md")

    if not results_path.is_file():
        print(f"[FAIL] Benchmark JSON not found: {results_path}", file=sys.stderr)
        return 1

    try:
        data = json.loads(results_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[FAIL] Invalid JSON in {results_path}: {exc}", file=sys.stderr)
        return 1

    if args.results_md is not None and not args.check:
        args.results_md.parent.mkdir(parents=True, exist_ok=True)
        md_report = render_results_md(data)
        args.results_md.write_text(md_report, encoding="utf-8")
        print(f"[OK] Wrote benchmark report to {args.results_md}")

    if args.no_readme:
        return 0

    if not readme_path.is_file():
        print(f"[FAIL] README file not found: {readme_path}", file=sys.stderr)
        return 1

    old_bytes = readme_path.read_bytes()
    old_text = old_bytes.decode("utf-8")
    section = render_readme_section(data)
    try:
        new_text = splice_readme(old_text, section)
    except ValueError as exc:
        print(f"[FAIL] {readme_path}: {exc}", file=sys.stderr)
        return 1

    new_bytes = new_text.encode("utf-8")
    if args.check:
        if new_bytes != old_bytes:
            print(f"[FAIL] {readme_path} is out of sync with {results_path}.", file=sys.stderr)
            return 1
        print(f"[OK] {readme_path} is synchronized with {results_path}.")
        return 0

    if new_bytes != old_bytes:
        readme_path.write_bytes(new_bytes)
        print(f"[OK] Updated benchmark section in {readme_path}")
    else:
        print(f"[OK] Benchmark section in {readme_path} already up to date (0 diff)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
