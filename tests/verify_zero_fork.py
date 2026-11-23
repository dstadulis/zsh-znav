#!/usr/bin/env python3
"""
XNU Kernel-Level Zero-Fork & Zero-Subshell Verifier for znav.

Uses macOS libSystem `proc_pid_rusage(pid, RUSAGE_INFO_V4, &ri)` to read the
exact Mach-task child accounting counters (`ri_child_user_time`,
`ri_child_system_time`, `ri_child_elapsed_abstime`) of a live `/bin/zsh -df`
process before and after executing each `znav` operation with `PATH=""`.

Any `fork()`, `vfork()`, `posix_spawn()`, `$(...)` command substitution,
`( ... )` subshell, `<(...)` process substitution, pipeline `a | b`, or
external command (even invoked by absolute path like `/bin/mv` or `/bin/rm`)
causes the XNU kernel to increment `ri_child_elapsed_abstime` (> 0) when the
child exits. Pure in-process Zsh execution yields an exact `(0, 0, 0)` delta.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import tempfile
from pathlib import Path

RUSAGE_INFO_V4 = 4


class RUsageInfoV4(ctypes.Structure):
    # struct rusage_info_v4 on arm64/x86_64 macOS (<sys/resource.h>):
    # u64[0..1] : ri_uuid[16]
    # u64[2]    : ri_user_time
    # u64[3]    : ri_system_time
    # ...
    # u64[12]   : ri_child_user_time
    # u64[13]   : ri_child_system_time
    # u64[14]   : ri_child_pkg_idle_wkups
    # u64[15]   : ri_child_interrupt_wkups
    # u64[16]   : ri_child_pageins
    # u64[17]   : ri_child_elapsed_abstime
    _fields_ = [("u64", ctypes.c_uint64 * 48)]


def load_libsystem() -> ctypes.CDLL:
    return ctypes.CDLL("/usr/lib/libSystem.B.dylib")


def get_child_rusage(lib: ctypes.CDLL, pid: int) -> tuple[int, int, int]:
    ri = RUsageInfoV4()
    rc = lib.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(ri))
    if rc != 0:
        raise RuntimeError(f"proc_pid_rusage({pid}) failed with rc={rc}")
    return (int(ri.u64[12]), int(ri.u64[13]), int(ri.u64[17]))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    plugin_path = repo_root / "znav.plugin.zsh"
    if not plugin_path.is_file():
        print(f"[FAIL] Plugin not found at {plugin_path}", file=sys.stderr)
        return 1

    lib = load_libsystem()

    with tempfile.TemporaryDirectory(prefix="znav_zerofork_") as tmp_raw:
        tmp = Path(tmp_raw).resolve()
        home_dir = tmp / "home"
        data_dir = tmp / "data"
        home_dir.mkdir()
        data_dir.mkdir()

        # Create realistic developer directories inside sandbox HOME
        for d in [
            "CODE.REPOSITORIES/znav",
            "SCRIPT.REPOS/deploy",
            "DESIGN.AESTHETICS",
            "FORMAL.PROOFS",
            "GIT.STATUS",
            "My Spaces.Repo",
            "dir[1]*?(glob)",
        ]:
            (home_dir / d).mkdir(parents=True, exist_ok=True)

        cdr_file = tmp / "chpwd-recent-dirs"
        cdr_file.write_text(
            f"$'{home_dir}/CODE.REPOSITORIES'\n"
            f"$'{home_dir}/My Spaces.Repo'\n",
            encoding="utf-8",
        )

        env = {
            "HOME": str(home_dir),
            "ZNAV_DATA_DIR": str(data_dir),
            "USER": os.environ.get("USER", "username"),
            "LOGNAME": os.environ.get("LOGNAME", "username"),
            "TERM": "dumb",
            "PATH": "/usr/bin:/bin",
        }

        # Use interactive + stdin (+Z +m disables ZLE/job-control noise while
        # preserving interactive chpwd semantics if guarded on -o interactive).
        proc = subprocess.Popen(
            ["/bin/zsh", "-dfi", "+Z", "+m"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            bufsize=1,
        )
        assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None

        sentinel_idx = 0

        def run_step(label: str, zsh_cmd: str, expect_zero_fork: bool = True) -> str:
            nonlocal sentinel_idx
            sentinel_idx += 1
            marker = f"__ZNAV_SYNC_{sentinel_idx}__"
            before = get_child_rusage(lib, proc.pid)
            script = (
                f"{zsh_cmd}\n"
                f"integer _rc=$?\n"
                f"print -r -- \"{marker}:$_rc:$ZSH_SUBSHELL:${{sysparams[pid]:-0}}\"\n"
            )
            proc.stdin.write(script)
            proc.stdin.flush()

            lines: list[str] = []
            rc = -1
            subshell = -1
            while True:
                line = proc.stdout.readline()
                if not line:
                    err = proc.stderr.read()
                    raise RuntimeError(f"Unexpected EOF during step '{label}'. stderr:\n{err}")
                stripped = line.rstrip("\n")
                if marker in stripped:
                    tail = stripped.split(marker + ":", 1)[1]
                    parts = tail.split(":")
                    rc = int(parts[0])
                    subshell = int(parts[1])
                    break
                lines.append(stripped)

            after = get_child_rusage(lib, proc.pid)
            delta = (after[0] - before[0], after[1] - before[1], after[2] - before[2])

            if expect_zero_fork:
                if rc != 0:
                    err_hint = ""
                    raise AssertionError(
                        f"Step '{label}' exited non-zero (rc={rc}). Output: {lines}{err_hint}"
                    )
                if subshell != 0:
                    raise AssertionError(f"Step '{label}' left ZSH_SUBSHELL={subshell} != 0")
                if delta != (0, 0, 0):
                    raise AssertionError(
                        f"KERNEL FORK DETECTED in '{label}'! "
                        f"Mach child rusage delta (user, sys, elapsed) = {delta} != (0, 0, 0)"
                    )
                print(f"  [PASS] {label:42s} | rc=0 | Mach child ticks delta=(0, 0, 0)")
            else:
                if delta[2] == 0:
                    raise AssertionError(
                        f"Positive fork control '{label}' failed to register child ticks: {delta}"
                    )
                print(f"  [PASS] {label:42s} | control fork detected delta={delta}")
            return "\n".join(lines)

        try:
            # Initialize clean prompt & load zmodload zsh/system before locking down PATH=""
            run_step(
                "bootstrap_shell_and_plugin",
                f'PROMPT="" RPROMPT="" PS1="" PS2=""; setopt NO_PROMPT_SP; '
                f'zmodload zsh/system; '
                f'source {str(plugin_path)!r}; '
                f'PATH=""',
            )

            run_step("znav_seed_empty_PATH", f'znav seed {str(home_dir)!r}')
            run_step(
                "precmd_once_alias_guard_empty_PATH",
                'alias gs="git status"; '
                'add-zsh-hook precmd _znav_precmd_once; '
                '_znav_precmd_once && '
                '(( ! ${precmd_functions[(Ie)_znav_precmd_once]:-0} )) && '
                '(( ! $+nameddirs[gs] )) && '
                '[[ ~gis == */GIT.STATUS ]] && '
                'unalias gs',
            )
            run_step(
                "chpwd_20_transitions_empty_PATH",
                f'repeat 10 {{ cd {str(home_dir / "CODE.REPOSITORIES")!r}; cd {str(home_dir / "SCRIPT.REPOS")!r}; }}',
            )
            run_step(
                "chpwd_pathological_dirs_empty_PATH",
                f'cd {str(home_dir / "My Spaces.Repo")!r}; cd {str(home_dir / "dir[1]*?(glob)")!r}',
            )
            run_step(
                "static_tilde_hash_d_20x_empty_PATH",
                'local _p; repeat 20 { _p=~cr; _p=~sr } && [[ $_p == */SCRIPT.REPOS ]]',
            )
            run_step(
                "dynamic_tilde_bracket_20x_empty_PATH",
                'local _d; repeat 20 { _d=~[cr]; _d=~[sr]/deploy } && [[ $_d == */SCRIPT.REPOS/deploy ]]',
            )
            run_step(
                "dynamic_hook_mode_d_prompt_empty_PATH",
                f'cd {str(home_dir / "CODE.REPOSITORIES/znav")!r} && local _pr=${{(%):-%~}}',
            )
            run_step(
                "jump_j_cr_and_subpath_empty_PATH",
                'j sr && [[ $PWD == */SCRIPT.REPOS ]] && j cr znav && [[ $PWD == */CODE.REPOSITORIES/znav ]]',
            )
            run_step("znav_list_empty_PATH", "znav list >/dev/null")
            run_step("znav_explain_cr_empty_PATH", "znav explain cr >/dev/null")
            run_step("znav_stats_empty_PATH", "znav stats >/dev/null")
            run_step("znav_compact_atomic_empty_PATH", "znav compact")
            run_step("znav_import_cdr_empty_PATH", f"znav import --cdr --file {str(cdr_file)!r}")
            run_step("znav_prune_empty_PATH", "znav prune")

            run_step(
                "p10k_setup_and_reload_empty_PATH",
                'typeset -ga _P10K_SEGS=(); '
                'typeset -gi _p9k__force_must_init=0; '
                'typeset -gA _p9k__cache_ephemeral=(stale 1); '
                'p10k() { '
                '  if [[ $1 == reload ]]; then _p9k__force_must_init=1; return 0; fi; '
                '  if [[ $1 == segment ]]; then _P10K_SEGS+=("$*"); return 0; fi; '
                '}; '
                'prompt_dir() { typeset -g _LAST_P10K_DIR="${(%):-%~}"; }; '
                'typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char); '
                'hash -d userpin=/tmp; '
                '_znav_p10k_setup && '
                '[[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir znav vcs newline prompt_char" ]] && '
                'unset -m "POWERLEVEL9K_*" && '
                'typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs) && '
                'p10k reload && '
                '[[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir znav vcs" ]]',
            )
            run_step(
                "p10k_prompt_dir_and_znav_20x_empty_PATH",
                f'cd {str(home_dir / "CODE.REPOSITORIES")!r} && '
                '[[ $ZNAV_PWD_CODE == cr ]] && '
                'repeat 20 { _P10K_SEGS=(); prompt_dir; prompt_znav; instant_prompt_znav } && '
                '[[ $_LAST_P10K_DIR == "~/CODE.REPOSITORIES" ]] && '
                '(( ${#_P10K_SEGS} == 2 )) && '
                '[[ ${nameddirs[cr]} == */CODE.REPOSITORIES && ${nameddirs[userpin]} == /tmp ]] && '
                f'cd {str(home_dir)!r} && '
                '[[ -z $ZNAV_PWD_CODE ]] && '
                'prompt_dir && [[ $_LAST_P10K_DIR == "~" ]]',
            )

            # Positive control: prove that even a single empty command substitution `$(:)`
            # is immediately caught by the XNU Mach rusage_info_v4 oracle!
            run_step("positive_control_single_subshell", "local _fork_probe=$(:)", expect_zero_fork=False)

            proc.stdin.write("exit 0\n")
            proc.stdin.flush()
            proc.wait(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()

    print("[OK] XNU Kernel Zero-Fork & Zero-Subshell Proof PASSED (0 forks across all znav paths).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
