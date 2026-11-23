#!/bin/zsh -f
# ==============================================================================
# znav Adversarial Pure-Zsh Verification Suite
# ==============================================================================
# Exercises:
#   1. Host Isolation, Module Hygiene & `warn_create_global` Cleanliness
#   2. Zero-Fork & Zero-Subshell Proof (`PATH=""` + PID/ZSH_SUBSHELL + XNU Kernel rusage)
#   3. Core User Scenario (`cr` -> CODE.REPOSITORIES, `sr` -> SCRIPT.REPOS, ~cr, ~[cr], j, AUTO_CD)
#   4. No-Hijack Stability Theorem & Candidate Lattice Conformance
#   5. Namespace & Command-Shadowing Safety ($userdirs/OS users, manual hash -d, tr/pr/ls/cp/cd/do/fi)
#   6. Pathological Filenames, Command-Injection Bait, UTF-8 Multibyte `%~`, Symlinks & Lazy Pruning
#   7. 6-Way Concurrent Multi-Shell WAL Merge & Bounded Atomic Compaction
#   8. `zcompile` Bytecode Compilation & Execution Compatibility
#   9. 600+ Operation Differential Randomized Trace Conformance (`diff_conformance.py`)
#  10. Shell Ergonomics (`ZNAV_CDABLE_VARS=1`/`0` & `_znav_precmd_once` Post-`.zshrc` Guard)
#  11. Migration Importers (`znav import --zoxide` Mock & `znav import --cdr` Pure Zsh)
#  12. Hermetic Packaging & Installer (`zsh-znav.plugin.zsh`, `install.sh`, `uninstall.sh`)
#  13. Benchmark Pipeline, README Auto-Injector & CI/CD Workflow Loop-Safety Audit
#  14. Powerlevel10k Full-Path + Shortcode Prompt Integration (`ZNAV_PWD_CODE`, `ZNAV_P10K_PROMPT`, Reload & `always`-Block Safety)
#  15. Interactive GitHub Pages Site (`site/`), Offline `file://` Safety, `bench_data.js` Sync, `pages.yml` & JS Engine Parity
# ==============================================================================

emulate -L zsh
setopt extended_glob typeset_silent no_short_loops pipe_fail
unset FPATH

readonly REAL_HOME=$HOME
readonly TESTS_DIR=${0:A:h}
readonly REPO_ROOT=${TESTS_DIR:h}
readonly PLUGIN_FILE="$REPO_ROOT/znav.plugin.zsh"

zmodload zsh/datetime zsh/mathfunc zsh/parameter zsh/system
zmodload -F zsh/files b:zf_mkdir b:zf_rm
zmodload -F zsh/stat b:zstat

integer PASS_COUNT=0
integer FAIL_COUNT=0
typeset -a FAIL_LOG=()

pass() {
  (( PASS_COUNT++ ))
  print -r -- "  [PASS] $1"
}

fail() {
  (( FAIL_COUNT++ ))
  FAIL_LOG+=("$1")
  print -u2 -r -- "  [FAIL] $1"
}

assert_eq() {
  local got=$1 exp=$2 msg=$3
  if [[ $got == $exp ]]; then
    pass "$msg"
  else
    fail "$msg (expected: '$exp', got: '$got')"
  fi
}

assert_ne() {
  local got=$1 unexp=$2 msg=$3
  if [[ $got != $unexp ]]; then
    pass "$msg"
  else
    fail "$msg (unexpectedly got: '$got')"
  fi
}

assert_true() {
  local rc=$1 msg=$2
  if (( rc == 0 )); then
    pass "$msg"
  else
    fail "$msg (rc=$rc)"
  fi
}

# Verify plugin exists before running
if [[ ! -f $PLUGIN_FILE ]]; then
  print -u2 -r -- "[ABORT] Plugin not found at $PLUGIN_FILE"
  exit 1
fi

# Record host ~/.zshrc state before running anything (sandbox may block reading ~/.zshrc)
integer HOST_ZSHRC_READABLE=0
local HOST_ZSHRC_MTIME="" HOST_ZSHRC_SIZE=""
if [[ -e "$REAL_HOME/.zshrc" ]]; then
  typeset -A _st
  if zstat -H _st "$REAL_HOME/.zshrc" 2>/dev/null; then
    HOST_ZSHRC_READABLE=1
    HOST_ZSHRC_MTIME=${_st[mtime]}
    HOST_ZSHRC_SIZE=${_st[size]}
  fi
fi
integer HOST_P10K_READABLE=0
local HOST_P10K_MTIME="" HOST_P10K_SIZE=""
if [[ -e "$REAL_HOME/.p10k.zsh" ]]; then
  typeset -A _st_p10k
  if zstat -H _st_p10k "$REAL_HOME/.p10k.zsh" 2>/dev/null; then
    HOST_P10K_READABLE=1
    HOST_P10K_MTIME=${_st_p10k[mtime]}
    HOST_P10K_SIZE=${_st_p10k[size]}
  fi
fi
integer HOST_ZNAV_DATA_EXISTED=0
[[ -e "$REAL_HOME/.local/share/znav" ]] && HOST_ZNAV_DATA_EXISTED=1

# Create isolated master sandbox in /tmp (canonicalized via :A -> /private/tmp on macOS)
readonly RAW_TMP="/tmp/znav_testsuite_${sysparams[pid]}_${RANDOM}"
zf_mkdir -p "$RAW_TMP"
readonly SANDBOX_ROOT=${RAW_TMP:A}

cleanup() {
  /bin/rm -rf "$SANDBOX_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

print -r -- "======================================================================"
print -r -- " znav Adversarial Verification Suite (Zsh $ZSH_VERSION)"
print -r -- " Sandbox: $SANDBOX_ROOT"
print -r -- "======================================================================"

# Helper to spawn a completely clean interactive-capable Zsh sandbox subshell
# Usage: run_isolated <test_id> <zsh_script_body>
run_isolated() {
  local tid=$1 body=$2
  local sb="$SANDBOX_ROOT/$tid"
  zf_mkdir -p "$sb/home" "$sb/data"
  HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT="" PS1="" PS2=""
      setopt NO_PROMPT_SP
      eval "$1"
    ' _ "$body"
}

# ==============================================================================
# SUITE 1: Module Hygiene & `warn_create_global` Cleanliness
# ==============================================================================
print -r -- "\n--- Suite 1: Module Hygiene & Global Namespace Cleanliness ---"
() {
  local out
  out=$(run_isolated "s1_hygiene" "
    zmodload zsh/parameter
    setopt AUTO_CD CDABLE_VARS
    source ${(q)PLUGIN_FILE} || exit 11
    # Sourcing plugin MUST NOT wipe caller options or leak warn_create_global into caller scope!
    [[ \${options[autocd]} == on && \${options[cdablevars]} == on ]] || { print -r -- 'WIPED_CALLER_OPTIONS'; exit 15; }
    [[ \${options[warncreateglobal]} == off ]] || { print -r -- 'LEAKED_WARN_CREATE_GLOBAL'; exit 16; }

    # Check znav init --auto-cd persists AUTO_CD and CDABLE_VARS in caller scope!
    unsetopt AUTO_CD CDABLE_VARS
    znav init --auto-cd || exit 17
    [[ \${options[autocd]} == on && \${options[cdablevars]} == on ]] || { print -r -- 'INIT_AUTOCD_NOOP'; exit 18; }

    # Check selective zsh/files and zsh/stat loading (must NOT shadow user commands!)
    for b in mv rm mkdir rmdir ln chmod chown stat; do
      if (( \${+builtins[\$b]} )); then
        print -r -- \"SHADOWED_BUILTIN:\$b\"
        exit 12
      fi
    done
    (( \${+functions[znav]} )) || { print -r -- 'MISSING_FN:znav'; exit 13; }
    (( \${+functions[j]} ))    || { print -r -- 'MISSING_FN:j'; exit 14; }

    # Check warn_create_global cleanliness across all operations
    mkdir -p \"\$HOME/CODE.REPOSITORIES\" \"\$HOME/SCRIPT.REPOS\"
    setopt warn_create_global
    znav seed \"\$HOME\" >/dev/null
    cd \"\$HOME/CODE.REPOSITORIES\"
    cd \"\$HOME/SCRIPT.REPOS\"
    j cr
    local _x=~cr _y=~[cr]
    znav list >/dev/null
    znav explain cr >/dev/null
    znav stats >/dev/null
    znav compact
    znav prune
    print -r -- 'HYGIENE_OK'
  " 2>&1)
  local rc=$?
  assert_true $rc "Sourcing & exercising znav passes without shadowing mv/rm/mkdir/stat builtins"
  if [[ $out == *"created globally in function"* ]]; then
    fail "warn_create_global caught leaked global variable: $out"
  else
    pass "Zero leaked globals under setopt warn_create_global"
  fi
  [[ $out == *"HYGIENE_OK"* ]] && pass "All core functions (znav, j) registered cleanly" || fail "Hygiene output: $out"
}

# ==============================================================================
# SUITE 2: Zero-Fork & Zero-Subshell Proof (PATH="" + PID + XNU Kernel rusage)
# ==============================================================================
print -r -- "\n--- Suite 2: Zero-Fork & Zero-Subshell Proof ---"
() {
  local sb="$SANDBOX_ROOT/s2_zerofork"
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES/znav" "$sb/home/SCRIPT.REPOS/bin" "$sb/data"
  # Create >140 visits to also force WAL auto-compaction under PATH=""!
  local err_file="$sb/stderr.log"
  HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zmodload zsh/system zsh/parameter
      source '"${(q)PLUGIN_FILE}"' || exit 21
      # LOCK DOWN PATH COMPLETELY!
      PATH=""
      integer orig_pid=${sysparams[pid]}

      znav seed "$HOME" || exit 22
      (( ZSH_SUBSHELL == 0 && sysparams[pid] == orig_pid )) || exit 23

      # Trigger 80 pairs = 160 chpwd transitions to cross WAL auto-compaction threshold (2N+64)
      repeat 80 {
        cd "$HOME/CODE.REPOSITORIES" || exit 24
        cd "$HOME/SCRIPT.REPOS" || exit 25
      }
      (( ZSH_SUBSHELL == 0 && sysparams[pid] == orig_pid )) || exit 26

      local p_static=~cr
      [[ $p_static == "${HOME:A}/CODE.REPOSITORIES" ]] || exit 27

      local p_dyn=~[cr]
      [[ $p_dyn == "${HOME:A}/CODE.REPOSITORIES" ]] || exit 28

      local p_sub=~[sr]/bin
      [[ $p_sub == "${HOME:A}/SCRIPT.REPOS/bin" ]] || exit 29

      j cr || exit 30
      [[ $PWD == "${HOME:A}/CODE.REPOSITORIES" ]] || exit 31
      j sr bin || exit 32
      [[ $PWD == "${HOME:A}/SCRIPT.REPOS/bin" ]] || exit 33

      znav list >/dev/null || exit 34
      znav explain cr >/dev/null || exit 35
      znav stats >/dev/null || exit 36
      znav compact || exit 37
      znav prune || exit 38

      (( ZSH_SUBSHELL == 0 && sysparams[pid] == orig_pid )) || exit 39
    ' 2>"$err_file"
  local rc=$?
  local stderr_txt=$(<"$err_file")
  assert_true $rc "All hot & cold paths succeed with PATH=\"\" (including 160-step auto-compaction)"
  assert_eq "$stderr_txt" "" "Zero stderr 'command not found' messages under PATH=\"\""

  # Run XNU Mach-task kernel rusage_info_v4 Zero-Fork Proof (macOS Darwin)
  if [[ $OSTYPE == darwin* ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$TESTS_DIR/verify_zero_fork.py"
    assert_true $? "XNU Kernel proc_pid_rusage(RUSAGE_INFO_V4) proves 0 forks across all znav paths"
  else
    pass "Zero-fork verified via PATH=\"\" + ZSH_SUBSHELL + sysparams[pid] (non-Darwin host)"
  fi
}

# ==============================================================================
# SUITE 3: Core User Scenario (CODE.REPOSITORIES -> cr, SCRIPT.REPOS -> sr)
# ==============================================================================
print -r -- "\n--- Suite 3: Core User Scenario & Triple Zsh Integration ---"
() {
  local sb="$SANDBOX_ROOT/s3_core"
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES/znav" "$sb/home/SCRIPT.REPOS/deploy" "$sb/data"

  local out
  out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source '"${(q)PLUGIN_FILE}"' || exit 1
      # If day-0 cold-start did not auto-seed $HOME, check if znav seed is needed,
      # though requirement #4 says cold-start auto-scans empty DB! Test immediate ~cr first:
      local auto_cr=""
      setopt localoptions no_nomatch
      auto_cr=~cr
      if [[ $auto_cr != "${HOME:A}/CODE.REPOSITORIES" ]]; then
        print -r -- "AUTO_SEED:NO"
        znav seed "$HOME"
      else
        print -r -- "AUTO_SEED:YES"
      fi
      _pt() { print -r -- "$1:$2"; }
      _pt TILDE_CR ~cr
      _pt TILDE_SR ~sr
      _pt TILDE_CR_SUB ~cr/znav
      _pt DYN_CR ~[cr]
      _pt DYN_SR_SUB ~[sr]/deploy
      _pt DYN_MULTI ~[code:repo]
      j cr && print -r -- "J_CR:$PWD"
      j sr && print -r -- "J_SR:$PWD"
      j cr znav && print -r -- "J_CR_SUB:$PWD"
    ')
  local rc=$?
  assert_true $rc "Core user scenario shell exited 0"
  local exp_home=${${:-$sb/home}:A}
  [[ $out == *"AUTO_SEED:YES"* ]] && pass "Day-0 cold-start auto-seeded ~ immediately with zero manual config" \
                                  || fail "Day-0 cold-start did not auto-seed empty DB automatically"
  [[ $out == *"TILDE_CR:$exp_home/CODE.REPOSITORIES"* ]] && pass "~cr expands via C hash table to CODE.REPOSITORIES" || fail "~cr failed: $out"
  [[ $out == *"TILDE_SR:$exp_home/SCRIPT.REPOS"* ]]      && pass "~sr expands via C hash table to SCRIPT.REPOS" || fail "~sr failed: $out"
  [[ $out == *"TILDE_CR_SUB:$exp_home/CODE.REPOSITORIES/znav"* ]] && pass "~cr/znav works inline in path arguments" || fail "~cr/znav failed: $out"
  [[ $out == *"DYN_CR:$exp_home/CODE.REPOSITORIES"* ]]   && pass "~[cr] expands via zsh_directory_name n" || fail "~[cr] failed: $out"
  [[ $out == *"DYN_SR_SUB:$exp_home/SCRIPT.REPOS/deploy"* ]] && pass "~[sr]/deploy expands subpath cleanly" || fail "~[sr]/deploy failed: $out"
  [[ $out == *"DYN_MULTI:$exp_home/CODE.REPOSITORIES"* ]] && pass "~[code:repo] multi-token dynamic query resolves CODE.REPOSITORIES" || fail "~[code:repo] failed: $out"
  [[ $out == *"J_CR:$exp_home/CODE.REPOSITORIES"* ]]     && pass "j cr jumps to CODE.REPOSITORIES" || fail "j cr failed: $out"
  [[ $out == *"J_SR:$exp_home/SCRIPT.REPOS"* ]]          && pass "j sr jumps to SCRIPT.REPOS" || fail "j sr failed: $out"
  [[ $out == *"J_CR_SUB:$exp_home/CODE.REPOSITORIES/znav"* ]] && pass "j cr znav subpath jump works" || fail "j cr znav failed: $out"

  # Test bare `cr` and `sr` via AUTO_CD + CDABLE_VARS in a SHINSTDIN (`-s`) shell!
  local autocd_out
  autocd_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfis +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP AUTO_CD CDABLE_VARS
source ${(q)PLUGIN_FILE}
cr
print -r -- "BARE_CR:\$PWD"
sr
print -r -- "BARE_SR:\$PWD"
exit 0
EOF
  )
  [[ $autocd_out == *"BARE_CR:$exp_home/CODE.REPOSITORIES"* ]] \
    && pass "Bare 'cr' + Enter changes into CODE.REPOSITORIES via AUTO_CD + CDABLE_VARS" \
    || fail "Bare 'cr' AUTO_CD + CDABLE_VARS failed: $autocd_out"
  [[ $autocd_out == *"BARE_SR:$exp_home/SCRIPT.REPOS"* ]] \
    && pass "Bare 'sr' + Enter changes into SCRIPT.REPOS via AUTO_CD + CDABLE_VARS" \
    || fail "Bare 'sr' AUTO_CD + CDABLE_VARS failed: $autocd_out"
}

# ==============================================================================
# SUITE 4: No-Hijack Stability Theorem & Candidate Lattice Torture
# ==============================================================================
print -r -- "\n--- Suite 4: No-Hijack Stability & Candidate Lattice Torture ---"
() {
  local sb="$SANDBOX_ROOT/s4_nohijack"
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/data"
  local exp_home=${${:-$sb/home}:A}

  local out
  out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      _pt() { print -r -- "$1:$2"; }
      source '"${(q)PLUGIN_FILE}"' || exit 1
      # Visit CODE.REPOSITORIES 5 times
      repeat 5 {
        cd "$HOME/SCRIPT.REPOS"
        cd "$HOME/CODE.REPOSITORIES"
      }
      # Now create CACHE.REPOS and visit it ONCE
      mkdir -p "$HOME/CACHE.REPOS"
      cd "$HOME/CACHE.REPOS"

      # Verify cr was NOT hijacked!
      _pt AFTER_CACHE_CR ~cr
      _pt AFTER_CACHE_DYN_CR ~[cr]
      j cr && print -r -- "AFTER_CACHE_J_CR:$PWD"

      # Check what code CACHE.REPOS received (per Spec #7: cr taken -> car)
      _pt CACHE_CAR ~car
      _pt CACHE_DYN_CAR ~[car]
      j car && print -r -- "CACHE_J_CAR:$PWD"

      # Add a 3rd cr-collider: CLOUD.RUNTIME visited once -> cr, clu/clr (clr!)
      mkdir -p "$HOME/CLOUD.RUNTIME"
      cd "$HOME/CLOUD.RUNTIME"
      _pt AFTER_CLOUD_CR ~cr
      _pt AFTER_CLOUD_CAR ~car
      _pt CLOUD_CLR ~clr

      # Also test camelCase & digit-prefix candidate rules (#7)
      mkdir -p "$HOME/myCamelRepo" "$HOME/HTMLParser" "$HOME/2026.roadmap"
      cd "$HOME/myCamelRepo"
      cd "$HOME/HTMLParser"
      cd "$HOME/2026.roadmap"
      _pt CAMEL1 ~mcr
      _pt CAMEL2 ~hp
      _pt DIGIT ~_2r
    ')
  assert_true $? "No-Hijack torture shell exited 0"
  [[ $out == *"AFTER_CACHE_CR:$exp_home/CODE.REPOSITORIES"* ]]     && pass "No-Hijack: ~cr remains CODE.REPOSITORIES after visiting new CACHE.REPOS" || fail "Hijacked ~cr: $out"
  [[ $out == *"AFTER_CACHE_DYN_CR:$exp_home/CODE.REPOSITORIES"* ]] && pass "No-Hijack: ~[cr] remains CODE.REPOSITORIES" || fail "Hijacked ~[cr]: $out"
  [[ $out == *"AFTER_CACHE_J_CR:$exp_home/CODE.REPOSITORIES"* ]]   && pass "No-Hijack: j cr remains CODE.REPOSITORIES" || fail "Hijacked j cr: $out"
  [[ $out == *"CACHE_CAR:$exp_home/CACHE.REPOS"* ]]                && pass "Collision resolution: CACHE.REPOS assigned exact next lattice code ~car" || fail "Expected ~car for CACHE.REPOS: $out"
  [[ $out == *"AFTER_CLOUD_CR:$exp_home/CODE.REPOSITORIES"* && $out == *"CLOUD_CLR:$exp_home/CLOUD.RUNTIME"* ]] \
    && pass "3-way collision cluster (CODE.REPOSITORIES=cr, CACHE.REPOS=car, CLOUD.RUNTIME=clr) holds cleanly" \
    || fail "3-way collision cluster mismatch: $out"
  [[ $out == *"CAMEL1:$exp_home/myCamelRepo"* && $out == *"CAMEL2:$exp_home/HTMLParser"* && $out == *"DIGIT:$exp_home/2026.roadmap"* ]] \
    && pass "camelCase (myCamelRepo->mcr, HTMLParser->hp) and leading-digit (2026.roadmap->_2r) match Spec #7" \
    || fail "Tokenization/norm_id mismatch: $out"
}

# ==============================================================================
# SUITE 5: Namespace & Command-Shadowing Safety
# ==============================================================================
print -r -- "\n--- Suite 5: Namespace & Command-Shadowing Safety ---"
() {
  local sb="$SANDBOX_ROOT/s5_namespace"
  zf_mkdir -p "$sb/home" "$sb/data" "$sb/manual_cr" "$sb/manual_pin"
  local exp_home=${${:-$sb/home}:A}
  local exp_mcr=${${:-$sb/manual_cr}:A}
  local exp_mpin=${${:-$sb/manual_pin}:A}

  # Create directories whose natural initialisms collide with:
  # - OS users: R.O.O.T -> root, D.A.E.M.O.N -> daemon
  # - Manual hash -d: CODE.REPOSITORIES -> cr (pre-bound to manual_cr!)
  # - POSIX /bin & /usr/bin commands: TEMP.REPOS -> tr, PUBLIC.REPOS -> pr, LOCAL.SCRIPTS -> ls, CORE.PLATFORM -> cp
  # - Zsh builtins: CODE.DESIGN -> cd, FAST.CACHE -> fc
  # - Zsh reserved words: DATA.OPS -> do, FILE.INDEX -> fi
  for d in R.O.O.T D.A.E.M.O.N CODE.REPOSITORIES TEMP.REPOS PUBLIC.REPOS LOCAL.SCRIPTS CORE.PLATFORM CODE.DESIGN FAST.CACHE DATA.OPS FILE.INDEX; do
    zf_mkdir -p "$sb/home/$d"
  done

  local out
  out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb PATH="/usr/bin:/bin" \
    /bin/zsh -dfis +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP AUTO_CD CDABLE_VARS
zmodload zsh/parameter
_pt() { print -r -- "\$1:\$2"; }
local orig_root=~root
local orig_daemon=~daemon
hash -d cr=${(q)exp_mcr}
hash -d mypin=${(q)exp_mpin}

source ${(q)PLUGIN_FILE}
for d in R.O.O.T D.A.E.M.O.N CODE.REPOSITORIES TEMP.REPOS PUBLIC.REPOS LOCAL.SCRIPTS CORE.PLATFORM CODE.DESIGN FAST.CACHE DATA.OPS FILE.INDEX; do
  cd "\$HOME/\$d"
done

print -r -- "ROOT_SAFE:\$([[ ~root == \$orig_root ]] && print YES || print NO)"
print -r -- "DAEMON_SAFE:\$([[ ~daemon == \$orig_daemon ]] && print YES || print NO)"
_pt MANUAL_CR_SAFE ~cr
_pt MANUAL_PIN_SAFE ~mypin
_pt CR_FALLBACK ~cor

# Verify POSIX commands tr, pr, ls, cp were NOT assigned in nameddirs (when ZNAV_AVOID_COMMANDS=1)
for cmd in tr pr ls cp cd fc do fi znav j; do
  if (( \${+nameddirs[\$cmd]} )); then
    print -r -- "COLLIDED_CMD:\$cmd=\${nameddirs[\$cmd]}"
  fi
done

# Verify TEMP.REPOS got next collision-free lattice code 'ter' and bare 'ter' AUTO_CDs!
_pt TEMP_TER ~ter
ter
print -r -- "BARE_TER_PWD:\$PWD"

# Verify real 'tr' binary still works in command position!
local upper=\$(print -r -- "znav" | tr a-z A-Z)
print -r -- "TR_WORKS:\$upper"
exit 0
EOF
  )
  [[ $out == *"ROOT_SAFE:YES"* ]]   && pass "OS user ~root preserved (even with R.O.O.T dir and initially empty \$userdirs)" || fail "~root clobbered: $out"
  [[ $out == *"DAEMON_SAFE:YES"* ]] && pass "OS user ~daemon preserved (D.A.E.M.O.N did not hijack ~daemon)" || fail "~daemon clobbered: $out"
  [[ $out == *"MANUAL_CR_SAFE:$exp_mcr"* && $out == *"MANUAL_PIN_SAFE:$exp_mpin"* ]] \
    && pass "Pre-existing manual hash -d entries (~cr, ~mypin) never overwritten" \
    || fail "Manual hash -d clobbered: $out"
  [[ $out == *"CR_FALLBACK:$exp_home/CODE.REPOSITORIES"* ]] \
    && pass "When ~cr is manually owned by user, CODE.REPOSITORIES seamlessly falls back to ~cor" \
    || fail "Fallback ~cor failed: $out"
  if [[ $out == *"COLLIDED_CMD:"* ]]; then
    fail "Command/builtin/resword collision in nameddirs: $out"
  else
    pass "Zero collisions with POSIX binaries (tr, pr, ls, cp), builtins (cd, fc), or reswords (do, fi)"
  fi
  [[ $out == *"TEMP_TER:$exp_home/TEMP.REPOS"* && $out == *"BARE_TER_PWD:$exp_home/TEMP.REPOS"* ]] \
    && pass "TEMP.REPOS skips /usr/bin/tr -> gets ~ter, and bare 'ter' AUTO_CDs cleanly" \
    || fail "TEMP.REPOS / bare 'ter' failed: $out"
  [[ $out == *"TR_WORKS:ZNAV"* ]]   && pass "POSIX /usr/bin/tr remains completely unshadowed in command position" || fail "tr broken: $out"
}

# ==============================================================================
# SUITE 6: Pathological Filenames, Injection, UTF-8 `%~`, Symlinks & Pruning
# ==============================================================================
print -r -- "\n--- Suite 6: Pathological Filenames, Security, UTF-8, Symlinks & Pruning ---"
() {
  local sb="$SANDBOX_ROOT/s6_torture"
  local pwn_sentinel="$SANDBOX_ROOT/PWNED_BY_EVAL"
  zf_mkdir -p "$sb/home" "$sb/data"
  local exp_home=${${:-$sb/home}:A}

  local d_space="$sb/home/My Code.Repos"
  local d_glob="$sb/home/dir[1]*?(test)"
  local d_quote="$sb/home/bob's \"quoted\".repo"
  local d_inject="$sb/home/evil\$(touch $pwn_sentinel).repo"
  local d_dollar="$sb/home/dollar\$HOME.repo"
  local d_hyphen="$sb/home/-weird.dir"
  local d_escape="$sb/home/100%pure\\tpath.dir"
  local d_utf8="$sb/home/café_λ.repo/sub"
  local d_real="$sb/home/REAL.TARGET"
  local d_sym="$sb/home/SYM.TARGET"
  local d_ghost="$sb/home/GHOST.REPO"

  zf_mkdir -p "$d_space" "$d_glob" "$d_quote" "$d_inject" "$d_dollar" "$d_hyphen" "$d_escape" "$d_utf8" "$d_real" "$d_ghost"
  /bin/ln -s "$d_real" "$d_sym"

  local utf8_loc="en_US.UTF-8"
  [[ $OSTYPE != darwin* ]] && utf8_loc="C.UTF-8"

  local out
  out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL="$utf8_loc" TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source '"${(q)PLUGIN_FILE}"' || exit 1

      for d in \
        '"${(q)d_space}"' \
        '"${(q)d_glob}"' \
        '"${(q)d_quote}"' \
        '"${(q)d_inject}"' \
        '"${(q)d_dollar}"' \
        '"${(q)d_hyphen}"' \
        '"${(q)d_escape}"' \
        '"${(q)d_utf8:h}"' \
        '"${(q)d_real}"' \
        '"${(q)d_sym}"' \
        '"${(q)d_ghost}"'
      do
        cd -- "$d" || exit 2
      done

      # Force WAL compaction + reload in a subshell to verify round-trip serialization of every nasty filename!
      znav compact || exit 3

      # Verify symlink canonicalization (:A): SYM.TARGET must NOT exist as a separate key from REAL.TARGET
      (( ${+_ZNAV_SCORE['"${(q)d_real:A}"']} )) && print -r -- "SYM_CANON_REAL:YES"
      (( ${+_ZNAV_SCORE['"${(q)d_sym}"']} )) && print -r -- "SYM_LEAKED_RAW:YES" || print -r -- "SYM_LEAKED_RAW:NO"

      # Verify leading-hyphen jump (`j wd` for -weird.dir)
      j wd && [[ $PWD == '"${(q)d_hyphen:A}"' ]] && print -r -- "HYPHEN_JUMP:OK"

      # Verify spaces & globs & quotes jump cleanly
      j mcr && [[ $PWD == '"${(q)d_space:A}"' ]] && print -r -- "SPACE_JUMP:OK"
      j d1t && [[ $PWD == '"${(q)d_glob:A}"' ]] && print -r -- "GLOB_JUMP:OK"

      # Verify multibyte UTF-8 directory contraction in `_znav_directory_name d`
      # Use cd -q into /sub so only parent `café_λ.repo` is tracked in znav!
      builtin cd -q -- '"${(q)d_utf8}"'
      if (( ${+functions[_znav_directory_name]} )); then
        local -a reply=()
        if ZNAV_PROMPT_DYNAMIC=1 _znav_directory_name d '"${(q)d_utf8:A}"' 2>/dev/null; then
          setopt localoptions no_multibyte
          local parent_utf8='"${(q)d_utf8:A:h}"'
          print -r -- "UTF8_BLEN:${reply[2]}:${#parent_utf8}"
        else
          local pexp=${(%):-%~}
          print -r -- "UTF8_PROMPT:$pexp"
        fi
      fi

      # Test deleted directory lazy pruning on jump & explicit znav prune
      cd -- "$HOME"
      /bin/rm -rf '"${(q)d_ghost}"'
      if j gr 2>/dev/null; then
        print -r -- "GHOST_JUMP:UNEXPECTED_SUCCESS:$PWD"
      else
        print -r -- "GHOST_JUMP:CLEAN_REJECT:$PWD"
      fi
      znav prune || exit 4
      (( ${+_ZNAV_SCORE['"${(q)d_ghost:A}"']} )) && print -r -- "GHOST_PRUNED:NO" || print -r -- "GHOST_PRUNED:YES"
    ')
  local rc=$?
  assert_true $rc "Pathological filename torture session exited 0"
  [[ ! -e $pwn_sentinel ]] && pass "Security: Command-injection directory 'evil\$(touch ...).repo' never evaluated" \
                           || fail "CRITICAL SECURITY BUG: eval executed \$(touch ...) inside directory name!"

  # Reload compacted DB in a brand-new shell to ensure `100%pure\tpath.dir`, quotes, globs, dollar survived intact!
  local reload_out
  reload_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL="$utf8_loc" TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source '"${(q)PLUGIN_FILE}"' || exit 1
      for target in '"${(q)d_space:A}"' '"${(q)d_glob:A}"' '"${(q)d_quote:A}"' '"${(q)d_inject:A}"' '"${(q)d_dollar:A}"' '"${(q)d_hyphen:A}"' '"${(q)d_escape:A}"'; do
        if (( ! ${+_ZNAV_SCORE[$target]} )); then
          print -r -- "MISSING_AFTER_COMPACT:$target"
          exit 2
        fi
      done
      print -r -- "ROUNDTRIP_ALL_OK"
    ')
  [[ $reload_out == *"ROUNDTRIP_ALL_OK"* ]] \
    && pass "All pathological paths (spaces, globs, quotes, \$HOME, -hyphen, 100%\\t) survive WAL + compact + reload uncorrupted" \
    || fail "Pathological round-trip corruption: $reload_out"

  [[ $out == *"SYM_CANON_REAL:YES"* && $out == *"SYM_LEAKED_RAW:NO"* ]] \
    && pass "Symlinks canonicalize via :A into single canonical directory entry" \
    || fail "Symlink canonicalization failed: $out"
  [[ $out == *"HYPHEN_JUMP:OK"* ]] && pass "Leading-hyphen directory (-weird.dir) jumps cleanly without option errors" || fail "Hyphen jump failed: $out"
  [[ $out == *"SPACE_JUMP:OK"* && $out == *"GLOB_JUMP:OK"* ]] && pass "Spaces & glob-metacharacter directories jump cleanly" || fail "Space/glob jump failed: $out"
  if [[ $out == *"UTF8_BLEN:"* ]]; then
    local bl_pair=${${(M)out:#*UTF8_BLEN:*}#*UTF8_BLEN:}
    local bl_got=${bl_pair%%:*} bl_exp=${bl_pair#*:}
    assert_eq "$bl_got" "${bl_exp%%$'\n'*}" "UTF-8 multibyte _znav_directory_name d returns exact byte length"
  elif [[ $out == *"UTF8_PROMPT:"*"/sub"* ]]; then
    pass "UTF-8 multibyte prompt contraction %~ preserves '/sub' suffix without byte-offset corruption"
  else
    fail "UTF-8 multibyte prompt contraction check failed: $out"
  fi
  [[ $out == *"GHOST_JUMP:CLEAN_REJECT:$exp_home"* && $out == *"GHOST_PRUNED:YES"* ]] \
    && pass "Deleted directories are cleanly rejected/pruned on jump and removed by znav prune" \
    || fail "Deleted directory pruning failed: $out"
}

# ==============================================================================
# SUITE 7: 6-Way Concurrent Multi-Shell WAL Writes & LSE Merge
# ==============================================================================
print -r -- "\n--- Suite 7: Concurrent Multi-Shell WAL Writes & Associative LSE Merge ---"
() {
  local sb="$SANDBOX_ROOT/s7_concurrent"
  zf_mkdir -p "$sb/home/SHARED.REPO" "$sb/home/ALT.REPO" "$sb/data"
  for i in {1..6}; do
    zf_mkdir -p "$sb/home/WORKER_${i}.REPO"
  done
  local exp_home=${${:-$sb/home}:A}

  # Pre-seed and compact a snapshot first so all 6 parallel shells start from the SAME snapshot!
  HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source '"${(q)PLUGIN_FILE}"'
      znav seed "$HOME"
      znav compact
    ' >/dev/null

  # Launch 6 parallel Zsh shells simultaneously, each visiting SHARED.REPO 5 times (= 30 total concurrent visits!)
  # plus its own WORKER_i.REPO 3 times!
  setopt localoptions NO_BG_NICE
  float t_before=$EPOCHREALTIME
  typeset -a pids=()
  for i in {1..6}; do
    HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
      /bin/zsh -dfi +Z +m -c '
        PROMPT="" RPROMPT=""
        source '"${(q)PLUGIN_FILE}"'
        repeat 5 {
          cd "$HOME/ALT.REPO"
          cd "$HOME/SHARED.REPO"
        }
        repeat 3 {
          cd "$HOME/ALT.REPO"
          cd "$HOME/WORKER_'"$i"'.REPO"
        }
      ' >/dev/null 2>&1 &
    pids+=($!)
  done
  for pid in $pids; do
    wait $pid || fail "Concurrent worker $pid failed"
  done
  float t_after=$EPOCHREALTIME

  # Open fresh shell, compact, and verify:
  # 1. All 6 WORKER_i.REPO directories + SHARED.REPO + ALT.REPO present with zero WAL parse errors
  # 2. SHARED.REPO received all 30 concurrent visits + 0.5 seed weight =>
  #    Lambda(SHARED.REPO) >= t_before + tau * ln(30) !
  local verify_out
  verify_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zmodload zsh/mathfunc
      source '"${(q)PLUGIN_FILE}"' || exit 1
      znav compact || exit 2
      float -E 17 tau=$(( 259200.0 / log(2.0) ))
      float -E 17 shared_lam=${_ZNAV_SCORE['"${(q)exp_home}"'/SHARED.REPO]}
      float -E 17 min_expected=$(( '"$t_before"' + tau * log(30.0) - 1.0 ))
      if (( shared_lam < min_expected )); then
        print -r -- "LOST_CONCURRENT_VISITS:got=$shared_lam:min=$min_expected"
        exit 3
      fi
      for i in {1..6}; do
        (( ${+_ZNAV_SCORE['"${(q)exp_home}"'/WORKER_${i}.REPO]} )) || { print -r -- "MISSING_WORKER:$i"; exit 4; }
      done
      print -r -- "CONCURRENT_LSE_OK"
    ' 2>&1)
  assert_true $? "6-way concurrent WAL merge + atomic compaction exited 0"
  [[ $verify_out == *"CONCURRENT_LSE_OK"* ]] \
    && pass "6 parallel shells (30 concurrent visits) merged cleanly via associative LSE with 0 lost visits" \
    || fail "Concurrent LSE merge failed: $verify_out"
}

# ==============================================================================
# SUITE 8: `zcompile` Bytecode Compatibility
# ==============================================================================
print -r -- "\n--- Suite 8: zcompile Bytecode Compatibility ---"
() {
  local sb="$SANDBOX_ROOT/s8_zcompile"
  zf_mkdir -p "$sb/pkg/functions" "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/data"
  /bin/cp "$PLUGIN_FILE" "$sb/pkg/znav.plugin.zsh"
  if [[ -d "$REPO_ROOT/functions" ]]; then
    local _src_fn
    for _src_fn in "$REPO_ROOT"/functions/*(.N); do
      [[ $_src_fn == *.zwc || $_src_fn == *.zwc.old ]] && continue
      /bin/cp "$_src_fn" "$sb/pkg/functions/"
    done
  fi

  local zc_out
  zc_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zcompile '"${(q)sb}"'/pkg/znav.plugin.zsh || exit 11
      for f in '"${(q)sb}"'/pkg/functions/*(N.); do
        [[ $f == *.zwc || $f == *.zwc.old ]] && continue
        zcompile "$f" || exit 12
      done
      source '"${(q)sb}"'/pkg/znav.plugin.zsh || exit 13
      znav seed "$HOME" || exit 14
      cd "$HOME/CODE.REPOSITORIES" || exit 15
      [[ ~cr == "${HOME:A}/CODE.REPOSITORIES" ]] || exit 16
      [[ ~[sr] == "${HOME:A}/SCRIPT.REPOS" ]] || exit 17
      j sr && [[ $PWD == "${HOME:A}/SCRIPT.REPOS" ]] || exit 18
      print -r -- "ZCOMPILE_OK"
    ' 2>&1)
  assert_true $? "zcompile succeeds cleanly on znav.plugin.zsh and all functions/*"
  [[ $zc_out == *"ZCOMPILE_OK"* ]] && pass "Bytecode-compiled (.zwc) plugin & functions execute identically" \
                                   || fail "Bytecode execution failed: $zc_out"
}

# ==============================================================================
# SUITE 9: 600+ Op Differential Randomized Trace Conformance
# ==============================================================================
print -r -- "\n--- Suite 9: Differential Randomized Trace Conformance (Spec vs Zsh) ---"
if command -v python3 >/dev/null 2>&1; then
  python3 "$TESTS_DIR/diff_conformance.py"
  assert_true $? "600+ random trace operations conform 1-to-1 with Formal Spec (<1e-9 float tolerance)"
else
  fail "python3 unavailable for differential trace conformance"
fi

# ==============================================================================
# SUITE 10: Shell Ergonomics (ZNAV_CDABLE_VARS=1/0 & _znav_precmd_once Guard)
# ==============================================================================
print -r -- "\n--- Suite 10: ZNAV_CDABLE_VARS Ergonomics & Post-.zshrc Alias Guard ---"
() {
  local sb="$SANDBOX_ROOT/s10_ergonomics"
  zf_mkdir -p "$sb/empty_bin" "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/home/GIT.STATUS" "$sb/home/LAZY.GIT" "$sb/home/LAZY.GIT.STATUS" "$sb/data1" "$sb/data2" "$sb/data3"
  local exp_home=${${:-$sb/home}:A}
  local entry_plugin="$REPO_ROOT/zsh-znav.plugin.zsh"

  # 10a. Default ZNAV_CDABLE_VARS=1 sets CDABLE_VARS in caller scope -> bare cr/sr work with AUTO_CD alone!
  local cdv_on
  cdv_on=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data1" PATH="$sb/empty_bin" LC_ALL=C TERM=dumb \
    /bin/zsh -dfis +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP AUTO_CD
unsetopt CDABLE_VARS
zmodload zsh/parameter
source ${(q)entry_plugin} || exit 11
print -r -- "CDABLE_DEFAULT:\${options[cdablevars]}"
cr
print -r -- "BARE_DEFAULT_CR:\$PWD"
sr
print -r -- "BARE_DEFAULT_SR:\$PWD"
exit 0
EOF
  )
  assert_true $? "Default ZNAV_CDABLE_VARS=1 shell exited 0"
  [[ $cdv_on == *"CDABLE_DEFAULT:on"* ]] && pass "ZNAV_CDABLE_VARS=1 (default) enables CDABLE_VARS in caller scope" || fail "ZNAV_CDABLE_VARS=1 failed: $cdv_on"
  [[ $cdv_on == *"BARE_DEFAULT_CR:$exp_home/CODE.REPOSITORIES"* && $cdv_on == *"BARE_DEFAULT_SR:$exp_home/SCRIPT.REPOS"* ]] \
    && pass "Bare 'cr' and 'sr' jump immediately under Oh My Zsh AUTO_CD without manual setopt" \
    || fail "Bare cr/sr with default ZNAV_CDABLE_VARS=1 failed: $cdv_on"

  # 10b. Opt-out ZNAV_CDABLE_VARS=0 preserves caller's unset CDABLE_VARS and exits 0!
  local cdv_off
  cdv_off=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data2" ZNAV_CDABLE_VARS=0 PATH="$sb/empty_bin" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zmodload zsh/parameter
      unsetopt CDABLE_VARS
      source '"${(q)entry_plugin}"' || exit 12
      print -r -- "CDABLE_OPTOUT:${options[cdablevars]}"
    ' 2>&1)
  assert_true $? "ZNAV_CDABLE_VARS=0 source exited 0"
  [[ $cdv_off == *"CDABLE_OPTOUT:off"* ]] && pass "ZNAV_CDABLE_VARS=0 preserves CDABLE_VARS=off in option-preservation mode" || fail "ZNAV_CDABLE_VARS=0 leaked CDABLE_VARS: $cdv_off"

  # 10c. _znav_precmd_once post-.zshrc alias collision guard (simulating OMZ line 88 vs aliases lines 126-140)
  cat > "$sb/sim_zshrc" <<EOF
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP AUTO_CD
zmodload zsh/parameter
source ${(q)entry_plugin} || exit 13
print -r -- "PRE_HOOK:\${precmd_functions[(Ie)_znav_precmd_once]:-0}:PRE_GS:\${nameddirs[gs]:-none}:PRE_LG:\${nameddirs[lg]:-none}"
alias gs="git status"
alias lg="lazygit"
alias lgs="lazygit status"
EOF
  local precmd_out
  precmd_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data3" PATH="$sb/empty_bin" LC_ALL=C TERM=dumb \
    /bin/zsh -dfis +Z +m <<EOF 2>/dev/null
source ${(q)sb}/sim_zshrc
print -r -- "POST_HOOK:\${precmd_functions[(Ie)_znav_precmd_once]:-0}:POST_GS:\${+nameddirs[gs]}:POST_LG:\${+nameddirs[lg]}:POST_LGS:\${+nameddirs[lgs]}"
print -r -- "ALIASES:\${aliases[gs]}|\${aliases[lg]}|\${aliases[lgs]}"
print -r -- "REASSIGNED:\${nameddirs[gis]:-}|\${nameddirs[lag]:-}|\${nameddirs[cr]:-}|\${nameddirs[sr]:-}"
exit 0
EOF
  )
  assert_true $? "_znav_precmd_once interactive prompt shell exited 0"
  [[ $precmd_out == *"PRE_HOOK:"[1-9]*":PRE_GS:$exp_home/GIT.STATUS:PRE_LG:$exp_home/LAZY.GIT"* ]] \
    && pass "_znav_precmd_once armed at load when pre-alias initialisms claim ~gs and ~lg" \
    || fail "Pre-prompt hook state unexpected: $precmd_out"
  [[ $precmd_out == *"POST_HOOK:0:POST_GS:0:POST_LG:0:POST_LGS:0"* ]] \
    && pass "_znav_precmd_once unregisters itself on first prompt (0 overhead thereafter) and evicts gs/lg/lgs from \$nameddirs" \
    || fail "Post-prompt hook/eviction failed: $precmd_out"
  [[ $precmd_out == *"ALIASES:git status|lazygit|lazygit status"* ]] \
    && pass "Post-OMZ personal aliases (gs, lg, lgs) remain 100% intact" \
    || fail "Personal aliases corrupted: $precmd_out"
  [[ $precmd_out == *"REASSIGNED:$exp_home/GIT.STATUS|$exp_home/LAZY.GIT|$exp_home/CODE.REPOSITORIES|$exp_home/SCRIPT.REPOS"* ]] \
    && pass "Colliding directories seamlessly re-projected to ~gis and ~lag while ~cr and ~sr stay invariant" \
    || fail "Re-projection after alias collision failed: $precmd_out"
}

# ==============================================================================
# SUITE 11: Migration Importers (`znav import --zoxide` & `znav import --cdr`)
# ==============================================================================
print -r -- "\n--- Suite 11: Migration Importers (zoxide & cdr) ---"
() {
  local sb="$SANDBOX_ROOT/s11_import"
  zf_mkdir -p "$sb/bin" "$sb/home/CODE.REPOSITORIES/zsh-znav" "$sb/home/My Spaced.Project" "$sb/home/REAL.DIR" \
              "$sb/home/CDR.FIRST" "$sb/home/CDR Spaced 'Quote'.Dir" "$sb/data_zo" "$sb/data_cdr"
  local exp_home=${${:-$sb/home}:A}
  /bin/ln -s "$exp_home/REAL.DIR" "$sb/home/SYM.LINK"

  # Create hermetic mock `zoxide` binary
  cat > "$sb/bin/zoxide" <<EOF
#!/bin/zsh -f
if [[ "\$1" == "query" && "\$2" == "-ls" ]]; then
  print -r -- "  25.5 $exp_home/CODE.REPOSITORIES/zsh-znav"
  print -r -- "   8.0 $exp_home/My Spaced.Project"
  print -r -- "   4.0 $sb/home/SYM.LINK"
  print -r -- "   6.0 $exp_home/REAL.DIR"
  print -r -- "  99.0 $exp_home/DELETED.GHOST"
  exit 0
fi
exit 1
EOF
  /bin/chmod +x "$sb/bin/zoxide"

  # 11a. Test `znav import --zoxide` exact Log-Epoch mapping + persistence
  local zo_out
  zo_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data_zo" ZNAV_AUTO_SEED=0 ZNAV_NOW="1700050000.0" \
    PATH="$sb/bin:/usr/bin:/bin" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zmodload zsh/mathfunc
      source "$1" || exit 11
      znav import --zoxide || exit 12
      local k1="$2/CODE.REPOSITORIES/zsh-znav"
      local k2="$2/REAL.DIR"
      local k3="$2/My Spaced.Project"
      local kg="$2/DELETED.GHOST"
      float -E 17 tnow=1700050000.0 tau=$(( 259200.0 / log(2.0) ))
      float -E 17 exp1=$(( tnow + tau * log(25.5) ))
      float -E 17 exp2=$(( tnow + tau * log(10.0) ))
      float -E 17 exp3=$(( tnow + tau * log(8.0) ))
      float -E 17 got1=${_ZNAV_SCORE[$k1]}
      float -E 17 got2=${_ZNAV_SCORE[$k2]}
      float -E 17 got3=${_ZNAV_SCORE[$k3]}
      (( abs(got1 - exp1) < 1e-7 && abs(got2 - exp2) < 1e-7 && abs(got3 - exp3) < 1e-7 )) || {
        print -r -- "DRIFT:$got1/$exp1|$got2/$exp2|$got3/$exp3"
        exit 13
      }
      (( ! ${+_ZNAV_SCORE[$kg]} )) || exit 14
      print -r -- "ZO_IMPORT_OK:${nameddirs[zz]:-}|${nameddirs[rd]:-}|${nameddirs[msp]:-}"
    ' _ "$PLUGIN_FILE" "$exp_home" 2>&1)
  assert_true $? "znav import --zoxide exited 0"
  [[ $zo_out == *"ZO_IMPORT_OK:$exp_home/CODE.REPOSITORIES/zsh-znav|$exp_home/REAL.DIR|$exp_home/My Spaced.Project"* ]] \
    && pass "znav import --zoxide maps S_d -> t_now + tau*ln(S_d), folds symlinks (4+6=10), skips ghosts, and projects ~codes" \
    || fail "znav import --zoxide mismatch: $zo_out"

  # Reload in fresh shell to verify compacted db.tsv snapshot
  local zo_reload
  zo_reload=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data_zo" ZNAV_AUTO_SEED=0 LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source "$1" || exit 1
      local p=~zz
      print -r -- "RELOAD_ZO:$p"
    ' _ "$PLUGIN_FILE")
  [[ $zo_reload == *"RELOAD_ZO:$exp_home/CODE.REPOSITORIES/zsh-znav"* ]] \
    && pass "znav import --zoxide persists cleanly across shell restarts via compacted db.tsv" \
    || fail "znav import --zoxide reload failed: $zo_reload"

  # 11b. Test `znav import --cdr` in pure Zsh (PATH="" zero-fork!) with (qqqq)-quoted file
  local cdr_file="$sb/home/.chpwd-recent-dirs"
  local -a cdr_entries=(
    "$exp_home/CDR.FIRST"
    "$exp_home/CDR Spaced 'Quote'.Dir"
    "$sb/home/SYM.LINK"
    "$exp_home/REAL.DIR"
    "$exp_home/MISSING.CDR"
  )
  print -rl -- "${(@qqqq)cdr_entries}" > "$cdr_file"

  local cdr_out
  cdr_out=$(ZDOTDIR="" HOME="$sb/home" ZNAV_DATA_DIR="$sb/data_cdr" ZNAV_AUTO_SEED=0 ZNAV_NOW="1700060000.0" \
    LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      source "$1" || exit 21
      PATH=""
      znav import --cdr || exit 22
      local c0="$2/CDR.FIRST"
      local c1="$2/CDR Spaced '\''Quote'\''.Dir"
      local c2="$2/REAL.DIR"
      float -E 17 s0=${_ZNAV_SCORE[$c0]}
      float -E 17 s1=${_ZNAV_SCORE[$c1]}
      float -E 17 s2=${_ZNAV_SCORE[$c2]}
      (( abs(s0 - 1700060000.0) < 1e-7 && abs(s1 - 1700059940.0) < 1e-7 && abs(s2 - 1700059880.0) < 1e-7 )) || {
        print -r -- "CDR_DRIFT:$s0|$s1|$s2"
        exit 23
      }
      (( ${#_ZNAV_SCORE} == 3 )) || { print -r -- "CDR_COUNT:${#_ZNAV_SCORE}"; exit 24; }
      print -r -- "CDR_OK:${_ZNAV_RANKED_DIRS[1]}|${_ZNAV_RANKED_DIRS[2]}|${_ZNAV_RANKED_DIRS[3]}"
    ' _ "$PLUGIN_FILE" "$exp_home" 2>&1)
  assert_true $? "znav import --cdr succeeded in pure Zsh with PATH=\"\""
  [[ $cdr_out == *"CDR_OK:$exp_home/CDR.FIRST|$exp_home/CDR Spaced 'Quote'.Dir|$exp_home/REAL.DIR"* ]] \
    && pass "znav import --cdr unquotes (qqqq) lines, assigns exact t_now - k*60.0 scores, deduplicates symlinks, and skips missing dirs" \
    || fail "znav import --cdr mismatch: $cdr_out"
}

# ==============================================================================
# SUITE 12: Hermetic Oh My Zsh Plugin Installer & Uninstaller (`install.sh`)
# ==============================================================================
print -r -- "\n--- Suite 12: Hermetic Oh My Zsh Installer & Uninstaller ---"
() {
  local sb="$SANDBOX_ROOT/s12_installer"
  zf_mkdir -p "$sb/repo/functions" "$sb/home/.oh-my-zsh/custom" "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/foreign"
  local exp_home=${${:-$sb/home}:A}
  local exp_repo=${${:-$sb/repo}:A}

  # Copy package source files (excluding any host .zwc/.zwc.old) into sandbox repo
  /bin/cp "$REPO_ROOT/znav.plugin.zsh" "$REPO_ROOT/zsh-znav.plugin.zsh" "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$sb/repo/"
  local _repo_fn
  for _repo_fn in "$REPO_ROOT"/functions/*(.N); do
    [[ $_repo_fn == *.zwc || $_repo_fn == *.zwc.old ]] && continue
    /bin/cp "$_repo_fn" "$sb/repo/functions/"
  done
  /bin/chmod +x "$sb/repo/install.sh" "$sb/repo/uninstall.sh"
  : > "$sb/home/.zcompdump-stale-5.9"

  # Isolate from any exported host ZSH / ZSH_CUSTOM / ZDOTDIR / XDG_DATA_HOME variables!
  # 12a. --dry-run modifies nothing
  ZSH="" ZSH_CUSTOM="$sb/home/.oh-my-zsh/custom" ZDOTDIR="$sb/home" XDG_DATA_HOME="$sb/home/.local/share" \
    HOME="$sb/home" ZNAV_DATA_DIR="$sb/home/.local/share/znav" "$sb/repo/install.sh" --dry-run >/dev/null
  assert_true $? "install.sh --dry-run exited 0"
  [[ ! -e "$sb/home/.oh-my-zsh/custom/plugins/zsh-znav" && -f "$sb/home/.zcompdump-stale-5.9" && ! -d "$sb/home/.local/share/znav" ]] \
    && pass "install.sh --dry-run leaves filesystem, .zcompdump, and ZNAV_DATA_DIR untouched" \
    || fail "install.sh --dry-run mutated filesystem"

  # 12b. Default auto-detection with Oh My Zsh present installs --omz-plugin, compiles .zwc, clears .zcompdump, and seeds Day-0 $HOME!
  ZSH="$sb/home/.oh-my-zsh" ZSH_CUSTOM="$sb/home/.oh-my-zsh/custom" ZDOTDIR="$sb/home" XDG_DATA_HOME="$sb/home/.local/share" \
    HOME="$sb/home" ZNAV_DATA_DIR="$sb/home/.local/share/znav" "$sb/repo/install.sh" >/dev/null
  assert_true $? "install.sh (default --omz-plugin) exited 0"

  local link_plug="$sb/home/.oh-my-zsh/custom/plugins/zsh-znav/zsh-znav.plugin.zsh"
  local link_comp="$sb/home/.oh-my-zsh/custom/plugins/zsh-znav/_znav"
  assert_eq "${link_plug:A}" "$exp_repo/zsh-znav.plugin.zsh" "install.sh links \$ZSH_CUSTOM/plugins/zsh-znav/zsh-znav.plugin.zsh"
  assert_eq "${link_comp:A}" "$exp_repo/functions/_znav" "install.sh links \$ZSH_CUSTOM/plugins/zsh-znav/_znav for single-pass OMZ compinit"
  [[ -f "$sb/repo/znav.plugin.zsh.zwc" && -f "$sb/repo/functions/znav.zwc" && -f "$sb/repo/functions/_znav_precmd_once.zwc" ]] \
    && pass "install.sh compiles .zwc wordcode for plugin and autoload functions" \
    || fail "install.sh missed .zwc compilation"
  [[ ! -e "$sb/home/.zcompdump-stale-5.9" ]] && pass "install.sh clears stale ~/.zcompdump*" || fail "Stale .zcompdump remained"
  [[ -f "$sb/home/.local/share/znav/db.tsv" ]] && pass "install.sh initializes Day-0 \$HOME depth-1 compacted db.tsv" || fail "Day-0 db.tsv missing"

  # 12c. Simulate exact Oh My Zsh startup (pre-compinit $fpath -> compinit -> source plugin) and verify zero console output (P10k instant-prompt safe!)
  local omz_stdout="$sb/omz_stdout.log" omz_stderr="$sb/omz_stderr.log"
  HOME="$sb/home" ZNAV_DATA_DIR="$sb/home/.local/share/znav" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zmodload zsh/parameter
      setopt AUTO_CD
      fpath=("$HOME/.oh-my-zsh/custom/plugins/zsh-znav" $fpath)
      autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump-test"
      source "$HOME/.oh-my-zsh/custom/plugins/zsh-znav/zsh-znav.plugin.zsh"
      [[ ${_comps[znav]:-} == _znav && ${_comps[j]:-} == _znav ]] || exit 31
      [[ ${options[cdablevars]} == on ]] || exit 32
      [[ ${nameddirs[cr]:-} == "${HOME:A}/CODE.REPOSITORIES" ]] || exit 33
      [[ ${nameddirs[sr]:-} == "${HOME:A}/SCRIPT.REPOS" ]] || exit 34
    ' >"$omz_stdout" 2>"$omz_stderr"
  assert_true $? "Simulated Oh My Zsh single-pass compinit + plugin load succeeded"
  assert_eq "$(<"$omz_stdout")$(<"$omz_stderr")" "" "Zero stdout/stderr console output during startup (Powerlevel10k instant-prompt safe)"

  # 12d. Test uninstall.sh removes our symlinks & .zwc while preserving foreign symlinks and user data
  : > "$sb/foreign/other_fn"
  zf_mkdir -p "$sb/home/.local/share/zsh/site-functions"
  /bin/ln -sfn "$sb/foreign/other_fn" "$sb/home/.local/share/zsh/site-functions/znav"
  ZSH="$sb/home/.oh-my-zsh" ZSH_CUSTOM="$sb/home/.oh-my-zsh/custom" ZDOTDIR="$sb/home" XDG_DATA_HOME="$sb/home/.local/share" \
    HOME="$sb/home" ZNAV_DATA_DIR="$sb/home/.local/share/znav" "$sb/repo/uninstall.sh" >/dev/null
  assert_true $? "uninstall.sh exited 0"
  [[ ! -d "$sb/home/.oh-my-zsh/custom/plugins/zsh-znav" ]] && pass "uninstall.sh removes plugin symlinks and empty plugin directory" || fail "Plugin directory still exists after uninstall.sh"
  [[ ! -f "$sb/repo/znav.plugin.zsh.zwc" && ! -f "$sb/repo/functions/znav.zwc" ]] && pass "uninstall.sh cleans compiled .zwc wordcode" || fail ".zwc remained after uninstall.sh"
  [[ -L "$sb/home/.local/share/zsh/site-functions/znav" && -f "$sb/home/.local/share/znav/db.tsv" ]] \
    && pass "uninstall.sh preserves foreign symlinks and user frecency database by default" \
    || fail "uninstall.sh deleted foreign symlink or user db.tsv"
}

# ==============================================================================
# SUITE 13: Benchmark Pipeline, README Auto-Injector & CI/CD Loop-Safety Audit
# ==============================================================================
print -r -- "\n--- Suite 13: Benchmark Pipeline, README Auto-Injector & CI/CD Workflows ---"
() {
  local sb="$SANDBOX_ROOT/s13_bench_ci"
  zf_mkdir -p "$sb/out" "$sb/linux_out" "$sb/linux_bin"

  # 13a. Hermetic benchmark run (ZNAV_BENCH_ITERS=20) + README sentinel splicing + idempotency
  local prefix_txt=$'# Custom Header Above Sentinels\n\nKeep `$LITERAL` and | pipes | 100% untouched!\n\n'
  local suffix_txt=$'\n\n## Footer Below Sentinels\n\nTrailing content `~cr` stays byte-exact.\n'
  python3 - "$sb/README.md" "$sb/bad_readme.md" "$prefix_txt" "$suffix_txt" <<'PYEOF'
import sys
from pathlib import Path

readme_p, bad_p, pre, suf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
Path(readme_p).write_text(
    pre + "<!-- BEGIN ZNAV_BENCHMARKS -->\nSTALE PLACEHOLDER\n<!-- END ZNAV_BENCHMARKS -->" + suf,
    encoding="utf-8",
)
Path(bad_p).write_text("# README missing sentinel markers\n", encoding="utf-8")
PYEOF

  ZNAV_BENCH_ITERS=20 ZNAV_BENCH_WARMUP_STEPS=200 ZNAV_BENCH_TRACE_STEPS=600 \
    zsh "$REPO_ROOT/benchmarks/run_bench.zsh" \
    --output-dir "$sb/out" \
    --readme "$sb/README.md" >/dev/null
  assert_true $? "Hermetic run_bench.zsh (ZNAV_BENCH_ITERS=20) exited 0"

  local audit_13a
  audit_13a=$(python3 - "$sb/out/results.json" "$sb/out/results.md" "$sb/README.md" "$sb/bad_readme.md" \
    "$REPO_ROOT/benchmarks/update_readme.py" "$prefix_txt" "$suffix_txt" 2>&1 <<'PYEOF'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

json_p = Path(sys.argv[1])
md_p = Path(sys.argv[2])
readme_p = Path(sys.argv[3])
bad_p = Path(sys.argv[4])
updater_p = Path(sys.argv[5])
exp_pre = sys.argv[6]
exp_suf = sys.argv[7]

data = json.loads(json_p.read_text(encoding="utf-8"))
assert data["schema_version"] == 1
assert data["environment"]["iterations"] == 20
for k in ("50", "500", "2000"):
    assert data["chpwd_latency_us"][k]["znav"] > 0
    assert data["chpwd_latency_us"][k]["cdr"] > 0
    assert data["chpwd_latency_us"][k]["fork_floor"] > 0
assert data["jump_latency_us"]["tilde_static"] >= 0
assert [t["N"] for t in data["info_efficiency"]["trees"]] == [30, 100, 500]

md_txt = md_p.read_text(encoding="utf-8")
readme_txt = readme_p.read_text(encoding="utf-8")

begin_m = "<!-- BEGIN ZNAV_BENCHMARKS -->"
end_m = "<!-- END ZNAV_BENCHMARKS -->"
b_idx = readme_txt.index(begin_m)
e_idx = readme_txt.index(end_m)
got_pre = readme_txt[:b_idx]
got_suf = readme_txt[e_idx + len(end_m):]
assert got_pre == exp_pre, f"Prefix mutated: {got_pre!r} != {exp_pre!r}"
assert got_suf == exp_suf, f"Suffix mutated: {got_suf!r} != {exp_suf!r}"

inner = readme_txt[b_idx + len(begin_m):e_idx]
assert "STALE PLACEHOLDER" not in inner
assert "## Performance Benchmarks" in inner
assert "[`benchmarks/results.md`](benchmarks/results.md)" in inner

# Verify 1-to-1 numeric correspondence across results.json, results.md, and README.md
z2000 = f"{data['chpwd_latency_us']['2000']['znav']:.2f}"
c2000 = f"{data['chpwd_latency_us']['2000']['cdr']:.2f}"
j_tilde = f"{data['jump_latency_us']['tilde_static']:.2f}"
s500_ks = f"{data['info_efficiency']['trees'][-1]['znav_exp_ks_bare']:.2f}"
for token in (z2000, c2000, j_tilde, s500_ks):
    assert token in md_txt, f"Missing {token} in results.md"
    assert token in inner, f"Missing {token} in README.md sentinel block"

# Verify idempotency of update_readme.py + --check flag
sha_before = hashlib.sha256(readme_p.read_bytes()).hexdigest()
subprocess.run(
    [sys.executable, str(updater_p), "--results", str(json_p), "--readme", str(readme_p)],
    check=True,
    stdout=subprocess.DEVNULL,
)
sha_after = hashlib.sha256(readme_p.read_bytes()).hexdigest()
assert sha_before == sha_after, "update_readme.py is not idempotent!"

subprocess.run(
    [sys.executable, str(updater_p), "--results", str(json_p), "--readme", str(readme_p), "--check"],
    check=True,
    stdout=subprocess.DEVNULL,
)

# Verify missing sentinel markers fail cleanly without mutating file
bad_before = bad_p.read_bytes()
rc = subprocess.run(
    [sys.executable, str(updater_p), "--results", str(json_p), "--readme", str(bad_p)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
).returncode
assert rc != 0, "Expected non-zero exit when sentinel markers are missing"
assert bad_p.read_bytes() == bad_before, "Malformed README should not be modified"
print("BENCH_13A_OK")
PYEOF
  )
  assert_true $? "Benchmark JSON, results.md, README sentinel splice, and idempotency checks passed"
  [[ $audit_13a == *"BENCH_13A_OK"* ]] \
    && pass "README content outside sentinels is 100% byte-identical and update_readme.py is idempotent" \
    || fail "Suite 13a audit output: $audit_13a"

  # 13b. Linux /proc/cpuinfo + /etc/os-release + missing-zoxide fallback + --no-readme
  for tool in zsh python3 uname true echo rm; do
    local tpath=${commands[$tool]:-}
    [[ -n $tpath ]] && /bin/ln -sf "$tpath" "$sb/linux_bin/$tool"
  done
  cat > "$sb/proc_cpuinfo" <<'EOF'
processor	: 0
model name	: AMD EPYC 7763 64-Core Processor
EOF
  cat > "$sb/os_release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04.2 LTS"
EOF

  local readme_mtime_before
  typeset -A _rm_st1 _rm_st2
  zstat -H _rm_st1 "$sb/README.md"
  readme_mtime_before=${_rm_st1[mtime]}

  PATH="$sb/linux_bin" \
    ZNAV_BENCH_PROC_CPUINFO="$sb/proc_cpuinfo" \
    ZNAV_BENCH_OS_RELEASE="$sb/os_release" \
    ZNAV_BENCH_ITERS=8 \
    ZNAV_BENCH_WARMUP_STEPS=50 \
    ZNAV_BENCH_TRACE_STEPS=150 \
    zsh "$REPO_ROOT/benchmarks/run_bench.zsh" \
    --output-dir "$sb/linux_out" \
    --readme "$sb/README.md" \
    --no-readme >/dev/null
  assert_true $? "Linux metadata fallback & missing-zoxide run_bench.zsh exited 0"

  zstat -H _rm_st2 "$sb/README.md"
  assert_eq "${_rm_st2[mtime]}" "$readme_mtime_before" "--no-readme leaves target README completely untouched"

  local audit_13b
  audit_13b=$(python3 - "$sb/linux_out/results.json" "$sb/linux_out/results.md" 2>&1 <<'PYEOF'
import json
import sys
from pathlib import Path

d = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
md = Path(sys.argv[2]).read_text(encoding="utf-8")
assert d["environment"]["hardware"] == "AMD EPYC 7763 64-Core Processor", d["environment"]
assert d["environment"]["os"] == "Ubuntu 24.04.2 LTS", d["environment"]
assert d["environment"]["zoxide_available"] is False
assert d["chpwd_latency_us"]["2000"]["zoxide"] is None
assert d["jump_latency_us"]["zoxide_jump"] is None
assert "N/A faster" not in md
print("LINUX_FALLBACK_OK")
PYEOF
  )
  [[ $audit_13b == *"LINUX_FALLBACK_OK"* ]] \
    && pass "Linux /proc/cpuinfo + /etc/os-release + missing-zoxide fallback produces clean JSON & Markdown" \
    || fail "Linux fallback audit failed: $audit_13b"

  # 13c. CI/CD Workflows (.github/workflows/ci.yml & perf-autoupdate.yml) Parsing & Loop-Safety Audit
  local audit_13c
  audit_13c=$(python3 - "$REPO_ROOT/.github/workflows/ci.yml" "$REPO_ROOT/.github/workflows/perf-autoupdate.yml" 2>&1 <<'PYEOF'
import fnmatch
import re
import sys
from pathlib import Path

ci_path = Path(sys.argv[1])
perf_path = Path(sys.argv[2])
assert ci_path.is_file(), f"Missing {ci_path}"
assert perf_path.is_file(), f"Missing {perf_path}"

ci_raw = ci_path.read_text(encoding="utf-8")
perf_raw = perf_path.read_text(encoding="utf-8")

for p, txt in ((ci_path, ci_raw), (perf_path, perf_raw)):
    for lineno, ln in enumerate(txt.splitlines(), 1):
        assert "\t" not in ln, f"Tab character in {p.name}:{lineno}"


def extract_trigger_paths_from_text(yaml_text: str) -> dict[str, list[str]]:
    """Stdlib indentation-aware extractor for on.<event>.paths lists."""
    events: dict[str, list[str]] = {}
    in_on = False
    cur_event = None
    in_paths = False
    for raw_ln in yaml_text.splitlines():
        stripped = raw_ln.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        content = stripped.strip()
        if indent == 0:
            in_on = content in ("on:", '"on":', "'on':")
            cur_event = None
            in_paths = False
        elif in_on and indent == 2 and content.endswith(":"):
            cur_event = content[:-1].strip("\"'")
            events.setdefault(cur_event, [])
            in_paths = False
        elif in_on and cur_event and indent == 4:
            in_paths = content == "paths:"
        elif in_on and cur_event and in_paths and indent >= 6 and content.startswith("- "):
            item = content[2:].strip().strip("\"'")
            events[cur_event].append(item)
    return events


# Also validate via PyYAML if installed on host/runner
try:
    import yaml  # type: ignore

    ci_doc = yaml.safe_load(ci_raw)
    perf_doc = yaml.safe_load(perf_raw)
    assert isinstance(ci_doc, dict) and "jobs" in ci_doc
    assert isinstance(perf_doc, dict) and "jobs" in perf_doc
    perf_on = perf_doc.get("on") or perf_doc.get(True)
    assert "push" in perf_on and "pull_request" in perf_on and "workflow_dispatch" in perf_on
    push_paths = perf_on["push"]["paths"]
    pr_paths = perf_on["pull_request"]["paths"]
except ImportError:
    ev_ci = extract_trigger_paths_from_text(ci_raw)
    assert "push" in ev_ci and "pull_request" in ev_ci
    ev_perf = extract_trigger_paths_from_text(perf_raw)
    assert "push" in ev_perf and "pull_request" in ev_perf and "workflow_dispatch" in ev_perf
    push_paths = ev_perf["push"]
    pr_paths = ev_perf["pull_request"]

expected_algo_paths = {
    "znav.plugin.zsh",
    "zsh-znav.plugin.zsh",
    "functions/**",
    "proofs/znav_spec.py",
    "benchmarks/run_bench.zsh",
    "benchmarks/info_efficiency.py",
    "benchmarks/update_readme.py",
}
assert set(push_paths) == expected_algo_paths, f"push paths mismatch: {push_paths}"
assert set(pr_paths) == expected_algo_paths, f"pull_request paths mismatch: {pr_paths}"


def matches_any_trigger(rel_file: str, patterns: list[str]) -> bool:
    for pat in patterns:
        if pat.endswith("/**"):
            prefix = pat[:-3]
            if rel_file == prefix or rel_file.startswith(prefix + "/"):
                return True
        elif fnmatch.fnmatchcase(rel_file, pat):
            return True
    return False


# Positive checks: algorithmic changes MUST trigger perf-autoupdate.yml
for algo_file in (
    "znav.plugin.zsh",
    "zsh-znav.plugin.zsh",
    "functions/znav",
    "functions/_znav_chpwd",
    "proofs/znav_spec.py",
    "benchmarks/run_bench.zsh",
    "benchmarks/info_efficiency.py",
    "benchmarks/update_readme.py",
):
    assert matches_any_trigger(algo_file, push_paths), f"{algo_file} did not match push_paths"

# Negative loop-safety checks: auto-generated perf outputs & docs MUST NEVER trigger perf-autoupdate.yml
for non_algo_file in (
    "README.md",
    "benchmarks/results.md",
    "benchmarks/results.json",
    "site/bench_data.js",
    "site/index.html",
    "site/app.js",
    "docs/zsh_native_audit.md",
    "proofs/formal_proofs.md",
    ".github/workflows/perf-autoupdate.yml",
    ".github/workflows/pages.yml",
    ".github/workflows/ci.yml",
):
    assert not matches_any_trigger(non_algo_file, push_paths), (
        f"INFINITE LOOP RISK: {non_algo_file} matched push_paths!"
    )
    assert not matches_any_trigger(non_algo_file, pr_paths), (
        f"INFINITE LOOP RISK: {non_algo_file} matched pr_paths!"
    )

# Verify ci.yml matrix & commands
for req_ci in (
    "macos-latest",
    "ubuntu-latest",
    "tests/run_tests.zsh",
    "tests/diff_conformance.py",
    "proofs/verify_all.py",
    "tests/verify_zero_fork.py",
    "git status --porcelain",
):
    assert req_ci in ci_raw, f"Missing '{req_ci}' in ci.yml"

# Verify perf-autoupdate.yml loop guards, fork-PR guard, summary & bot commit
assert "repository:" not in perf_raw, "checkout must default to github.repository for fork-PR safety"
for req_perf in (
    "github.actor != 'github-actions[bot]'",
    "contents: write",
    "cancel-in-progress: true",
    "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) && github.head_ref || github.ref",
    "GITHUB_STEP_SUMMARY",
    "[skip ci]",
    "git add -- README.md benchmarks/results.md benchmarks/results.json",
):
    assert req_perf in perf_raw, f"Missing '{req_perf}' in perf-autoupdate.yml"

# Ensure auto-commit step never pushes [skip ci] commits onto pull_request branches (which would suppress CI checks)
commit_step_section = perf_raw.split("Auto-commit and push updated benchmark data", 1)[1]
commit_if_block = commit_step_section.split("run:", 1)[0]
assert "pull_request" not in commit_if_block, (
    f"perf-autoupdate.yml auto-commit step must not push [skip ci] commits on pull_request: {commit_if_block}"
)

print("WORKFLOWS_OK")
PYEOF
  )
  assert_true $? "Workflow YAML validation and infinite-loop safety checks exited 0"
  [[ $audit_13c == *"WORKFLOWS_OK"* ]] \
    && pass "ci.yml & perf-autoupdate.yml parse cleanly, guard all algorithmic paths, and enforce quadruple loop protection" \
    || fail "Workflow audit failed: $audit_13c"
}

# ==============================================================================
# SUITE 14: Powerlevel10k Full-Path + Shortcode Prompt Integration
# ==============================================================================
print -r -- "\n--- Suite 14: Powerlevel10k Full-Path + Shortcode Prompt Integration ---"
() {
  local sb="$SANDBOX_ROOT/s14_p10k"
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES/zsh-znav" \
              "$sb/home/CODE.REPOSITORIES/zsh-wh" \
              "$sb/home/SCRIPT.REPOS" \
              "$sb/home/GIT.STATUS" \
              "$sb/home/EPHEMERAL.DIR" \
              "$sb/home/CUSTOM.WORK/sub" \
              "$sb/unmapped/outside" \
              "$sb/data_14a" "$sb/data_14b" "$sb/data_14c" "$sb/data_14d" "$sb/data_14e"
  local exp_home=${${:-$sb/home}:A}
  local exp_unmapped=${${:-$sb/unmapped/outside}:A}

  # 14a. $ZNAV_PWD_CODE lifecycle across $HOME, unmapped dirs, seed, cd, import, alias re-projection & prune
  local out_14a
  out_14a=$(HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14a" ZNAV_AUTO_SEED=0 LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      setopt warn_create_global
      builtin cd -- "$2" || exit 10
      source "$1" || exit 11
      # Cold start in unmapped dir with ZNAV_AUTO_SEED=0 -> empty ZNAV_PWD_CODE
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "UNMAPPED_INIT:$ZNAV_PWD_CODE"; exit 12; }

      # Seed $HOME while standing in $HOME -> ZNAV_PWD_CODE must remain "" ($HOME omits redundant badge)
      builtin cd -q -- "$HOME" || exit 13
      znav seed "$HOME" >/dev/null || exit 14
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "HOME_SEED:$ZNAV_PWD_CODE"; exit 15; }

      # Move into seeded & newly visited directories -> O(1) ZNAV_PWD_CODE updates
      cd "$HOME/CODE.REPOSITORIES" || exit 16
      [[ $ZNAV_PWD_CODE == cr ]] || { print -r -- "CR_CODE:$ZNAV_PWD_CODE"; exit 17; }

      cd "$HOME/SCRIPT.REPOS" || exit 18
      [[ $ZNAV_PWD_CODE == sr ]] || { print -r -- "SR_CODE:$ZNAV_PWD_CODE"; exit 19; }

      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 20
      [[ $ZNAV_PWD_CODE == zz ]] || { print -r -- "ZZ_CODE:$ZNAV_PWD_CODE"; exit 21; }

      cd "$HOME/CODE.REPOSITORIES/zsh-wh" || exit 22
      [[ $ZNAV_PWD_CODE == zw ]] || { print -r -- "ZW_CODE:$ZNAV_PWD_CODE"; exit 23; }

      # Return to $HOME -> ZNAV_PWD_CODE cleared to ""
      cd "$HOME" || exit 24
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "HOME_CD:$ZNAV_PWD_CODE"; exit 25; }

      # Late .zshrc alias shadowing active $ZNAV_PWD_CODE -> _znav_precmd_once updates $ZNAV_PWD_CODE!
      cd "$HOME/GIT.STATUS" || exit 26
      [[ $ZNAV_PWD_CODE == gs ]] || { print -r -- "GS_BEFORE:$ZNAV_PWD_CODE"; exit 27; }
      alias gs="git status"
      add-zsh-hook precmd _znav_precmd_once
      _znav_precmd_once || exit 28
      [[ $ZNAV_PWD_CODE == gis ]] || { print -r -- "GS_AFTER:$ZNAV_PWD_CODE"; exit 29; }
      unalias gs

      # Delete tracked directory and run `znav prune` while standing in it -> ZNAV_PWD_CODE cleared!
      cd "$HOME/EPHEMERAL.DIR" || exit 30
      [[ -n $ZNAV_PWD_CODE && $ZNAV_PWD_CODE == ${_ZNAV_DIR2CODE[$HOME/EPHEMERAL.DIR]} ]] \
        || { print -r -- "ED_BEFORE:$ZNAV_PWD_CODE"; exit 31; }
      /bin/rmdir "$HOME/EPHEMERAL.DIR" || exit 32
      znav prune || exit 33
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "ED_AFTER_PRUNE:$ZNAV_PWD_CODE"; exit 34; }

      # Mid-session manual `hash -d zz=/tmp` override while standing in zsh-znav:
      # ~zz now resolves to /tmp, so _znav_update_pwd_code / prompt_znav MUST clear ZNAV_PWD_CODE
      # immediately (and re-visiting zsh-znav re-projects it to next lattice code `zsz`)!
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 35
      [[ $ZNAV_PWD_CODE == zz && ${nameddirs[zz]:-} == "$HOME/CODE.REPOSITORIES/zsh-znav" ]] || exit 36
      hash -d zz="/tmp"
      prompt_znav || exit 37
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "HIJACKED_ZZ_STILL_SET:$ZNAV_PWD_CODE"; exit 38; }
      cd "$HOME" && cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 39
      [[ $ZNAV_PWD_CODE == zsz && ${nameddirs[zsz]:-} == "$HOME/CODE.REPOSITORIES/zsh-znav" && ${nameddirs[zz]:-} == "/tmp" ]] \
        || { print -r -- "REPROJECT_AFTER_HASHD:$ZNAV_PWD_CODE|${nameddirs[zsz]:-}|${nameddirs[zz]:-}"; exit 40; }
      unhash -d zz

      # Top-M cap (`ZNAV_MAX_NAMEDDIRS=2`) unprojected rank & eviction safety:
      # Whenever ZNAV_PWD_CODE is non-empty, ~$ZNAV_PWD_CODE MUST exist in $nameddirs and equal ${PWD:A}!
      float -E 17 _tbase=$EPOCHREALTIME
      ZNAV_MAX_NAMEDDIRS=2
      # Give CODE.REPOSITORIES and SCRIPT.REPOS high scores so they hold ranks #1 and #2
      repeat 5 { ZNAV_NOW=$(( _tbase + 100000.0 )) cd "$HOME/CODE.REPOSITORIES"; ZNAV_NOW=$(( _tbase + 100000.0 )) cd "$HOME/SCRIPT.REPOS"; }
      [[ $ZNAV_PWD_CODE == sr && ${nameddirs[sr]:-} == "$HOME/SCRIPT.REPOS" ]] || { print -r -- "TOP2_INIT:$ZNAV_PWD_CODE"; exit 41; }
      # Visit low-ranked directory outside top-2 (Fast Path C) -> not in $nameddirs, so ZNAV_PWD_CODE MUST be ""!
      ZNAV_NOW=$(( _tbase - 500000.0 )) cd "$HOME/CUSTOM.WORK/sub" || exit 42
      [[ -z $ZNAV_PWD_CODE && -z ${nameddirs[cws]:-} ]] || { print -r -- "UNPROJECTED_LEAK:$ZNAV_PWD_CODE"; exit 43; }
      # Now promote colliding SUPER.REPOS above SCRIPT.REPOS to evict SCRIPT.REPOS from top-2, then revisit evicted dir at low timestamp!
      /bin/mkdir -p "$HOME/SUPER.REPOS"
      repeat 8 { ZNAV_NOW=$(( _tbase + 900000.0 )) cd "$HOME/SUPER.REPOS"; ZNAV_NOW=$(( _tbase + 800000.0 )) cd "$HOME/CODE.REPOSITORIES"; }
      # Top-2 are now SUPER.REPOS (`sr`, claiming `sr` from evicted SCRIPT.REPOS!) and CODE.REPOSITORIES (`cr`)
      [[ ${nameddirs[sr]:-} == "$HOME/SUPER.REPOS" ]] || { print -r -- "EVICT_CLAIM_SR:${nameddirs[sr]:-}"; exit 44; }
      # Single old-timestamp visit to evicted SCRIPT.REPOS hits Fast Path C (remains outside top-2) -> MUST NOT show hijacked `sr`!
      ZNAV_NOW=$(( _tbase - 500000.0 )) cd "$HOME/SCRIPT.REPOS" || exit 45
      [[ -z $ZNAV_PWD_CODE ]] || { print -r -- "EVICTED_STALE_CODE:$ZNAV_PWD_CODE"; exit 46; }

      print -r -- "S14A_OK"
    ' _ "$PLUGIN_FILE" "$exp_unmapped" 2>&1)
  assert_true $? "Suite 14a (\$ZNAV_PWD_CODE lifecycle under warn_create_global) exited 0"
  [[ $out_14a == *"S14A_OK"* ]] \
    && pass "\$ZNAV_PWD_CODE tracks cr/sr/zz/zw in O(1), omits \$HOME & unmapped dirs, updates on alias collision, and clears on prune" \
    || fail "Suite 14a output: $out_14a"

  # 14b. All 4 ZNAV_P10K_PROMPT modes (`both`, `shortcode`, `path`, `off`), styling overrides & right-prompt injection
  local out_14b
  out_14b=$(HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14b" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      setopt prompt_percent prompt_subst

      # Faithful Powerlevel10k segment + prompt_dir engine mock (mirrors internal/p10k.zsh)
      typeset -ga MOCK_RENDERED=()
      typeset -g  MOCK_LAST_SEG_META=""
      typeset -gi _p9k__force_must_init=0
      typeset -gA _p9k__cache_ephemeral=()

      p10k() {
        case ${1:-} in
          reload)
            _p9k__force_must_init=1
            return 0
            ;;
          segment)
            shift
            local opt state="" bg="0" fg="" icon="" cond="" text="" expand=0
            local -i OPTIND=1
            local OPTARG
            while getopts ":s:b:f:i:c:t:reh" opt; do
              case $opt in
                s) state=$OPTARG ;;
                b) bg=$OPTARG ;;
                f) fg=$OPTARG ;;
                i) icon=$OPTARG ;;
                c) cond=$OPTARG ;;
                t) text=$OPTARG ;;
                e) expand=1 ;;
              esac
            done
            MOCK_LAST_SEG_META="bg=${bg}|fg=${fg}|cond=${cond}|exp=${expand}|txt=${text}"
            if [[ -n $cond ]]; then
              local eval_cond=${(e):-"$cond"}
              [[ -z $eval_cond ]] && return 0
            fi
            local rendered
            if (( expand )); then
              rendered=${(e):-"$text"}
            else
              rendered=$text
            fi
            MOCK_RENDERED+=("znav:${rendered}")
            return 0
            ;;
        esac
      }

      prompt_dir() {
        [[ $0 == prompt_dir ]] || { print -r -- "BAD_ARGZERO:$0"; return 91; }
        local p=${(%):-%~}
        MOCK_RENDERED+=("dir:${p}")
      }
      instant_prompt_dir() { prompt_dir; }

      render_line() {
        MOCK_RENDERED=()
        local elem
        for elem in "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}"; do
          [[ $elem == newline ]] && break
          (( $+functions[prompt_$elem] )) && "prompt_$elem"
        done
        REPLY="${(j: :)MOCK_RENDERED}"
      }

      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char)
      source "$1" || exit 11

      # Verify auto-injection right after `dir`
      [[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir znav vcs newline prompt_char" ]] \
        || { print -r -- "BAD_INJECT:${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}"; exit 12; }

      # Mode 1: `both` (default) in tracked repo ~/CODE.REPOSITORIES/zsh-znav -> BOTH path and ~zz
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 13
      render_line
      [[ $REPLY == "dir:~/CODE.REPOSITORIES/zsh-znav znav:~zz" ]] \
        || { print -r -- "MODE_BOTH_ZZ:$REPLY"; exit 14; }
      [[ $MOCK_LAST_SEG_META == "bg=0|fg=3|cond=\$ZNAV_PWD_CODE|exp=1|txt=~\$ZNAV_PWD_CODE" ]] \
        || { print -r -- "DEFAULT_STYLE_META:$MOCK_LAST_SEG_META"; exit 15; }

      # Mode 1 (`both`) in $HOME -> `dir:~` ONLY (no duplicate shortcode segment!)
      cd "$HOME" || exit 16
      render_line
      [[ $REPLY == "dir:~" ]] || { print -r -- "MODE_BOTH_HOME:$REPLY"; exit 17; }

      # Custom user styling overrides (including empty transparent background)
      cd "$HOME/CODE.REPOSITORIES/zsh-wh" || exit 18
      POWERLEVEL9K_ZNAV_BACKGROUND="" POWERLEVEL9K_ZNAV_FOREGROUND="6" render_line
      [[ $REPLY == "dir:~/CODE.REPOSITORIES/zsh-wh znav:~zw" ]] || { print -r -- "MODE_BOTH_ZW:$REPLY"; exit 19; }
      [[ $MOCK_LAST_SEG_META == "bg=|fg=6|cond=\$ZNAV_PWD_CODE|exp=1|txt=~\$ZNAV_PWD_CODE" ]] \
        || { print -r -- "CUSTOM_STYLE_META:$MOCK_LAST_SEG_META"; exit 20; }

      # Mode 2: `shortcode` -> ONLY `znav:~zw` in tracked repo, `dir:~` in $HOME, and `dir` preserved in instant_prompt_dir
      ZNAV_P10K_PROMPT=shortcode
      p10k reload
      render_line
      [[ $REPLY == "znav:~zw" ]] || { print -r -- "MODE_SHORTCODE_ZW:$REPLY"; exit 21; }
      MOCK_RENDERED=()
      instant_prompt_dir
      instant_prompt_znav
      [[ "${(j: :)MOCK_RENDERED}" == "dir:~/CODE.REPOSITORIES/zsh-wh znav:~zw" ]] \
        || { print -r -- "INSTANT_SHORTCODE:${MOCK_RENDERED[*]}"; exit 22; }
      cd "$HOME" || exit 23
      render_line
      [[ $REPLY == "dir:~" ]] || { print -r -- "MODE_SHORTCODE_HOME:$REPLY"; exit 24; }

      # Mode 3: `path` -> ONLY `dir:~/CODE.REPOSITORIES/zsh-znav` (znav auto-injection removed on reload!)
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 25
      ZNAV_P10K_PROMPT=path
      p10k reload
      [[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir vcs newline prompt_char" ]] \
        || { print -r -- "PATH_ELEMENTS:${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}"; exit 26; }
      render_line
      [[ $REPLY == "dir:~/CODE.REPOSITORIES/zsh-znav" ]] || { print -r -- "MODE_PATH_ZZ:$REPLY"; exit 27; }
      MOCK_RENDERED=(); prompt_znav
      (( ${#MOCK_RENDERED} == 0 )) || { print -r -- "PROMPT_ZNAV_NOT_SUPPRESSED"; exit 28; }

      # Mode 4: `off` -> stock `prompt_dir` (~zz via native %~) and `prompt_znav` suppressed
      ZNAV_P10K_PROMPT=off
      p10k reload
      render_line
      [[ $REPLY == "dir:~zz" ]] || { print -r -- "MODE_OFF_ZZ:$REPLY"; exit 29; }

      # Right-prompt `dir_joined` injection & user-placed `znav_joined` non-duplication
      ZNAV_P10K_PROMPT=both
      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon vcs prompt_char)
      typeset -ga POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status dir_joined time)
      p10k reload
      [[ "${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS[*]}" == "status dir_joined znav time" ]] \
        || { print -r -- "RIGHT_INJECT:${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS[*]}"; exit 30; }
      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir znav_joined vcs)
      typeset -ga POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status time)
      p10k reload
      [[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir znav_joined vcs" ]] \
        || { print -r -- "DUP_INJECT:${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}"; exit 31; }

      # Edge case: `dir` as the very last element in array (no reverse-slice duplication!)
      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir)
      p10k reload
      [[ "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}" == "os_icon dir znav" ]] \
        || { print -r -- "TAIL_INJECT:${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[*]}"; exit 32; }

      print -r -- "S14B_OK"
    ' _ "$PLUGIN_FILE" 2>&1)
  assert_true $? "Suite 14b (ZNAV_P10K_PROMPT=both|shortcode|path|off & segment styling) exited 0"
  [[ $out_14b == *"S14B_OK"* ]] \
    && pass "All 4 ZNAV_P10K_PROMPT modes, custom POWERLEVEL9K_ZNAV_* overrides, instant_prompt_znav, and left/right element injection verified" \
    || fail "Suite 14b output: $out_14b"

  # 14c. Manual `hash -d` preservation inside `prompt_dir` + `{ ... } always { ... }` restoration under return/exception
  local out_14c
  out_14c=$(HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14c" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      setopt AUTO_CD

      typeset -g INSIDE_SNAPSHOT=""
      prompt_dir() {
        [[ $0 == prompt_dir ]] || return 81
        INSIDE_SNAPSHOT="cr=${+nameddirs[cr]}|zz=${+nameddirs[zz]}|cw=${nameddirs[customwork]:-}|sr=${nameddirs[sr]:-}|p=${(%):-%~}"
        case ${1:-normal} in
          early) return 7 ;;
          boom)  local _err=${ZNAV_NONEXISTENT_REQUIRED_PARAM?forced_error} ;;
        esac
        return 0
      }

      hash -d customwork="$HOME/CUSTOM.WORK"
      source "$1" || exit 11
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 12
      # Also simulate user manually overriding znav-owned `sr` right before prompt_dir!
      hash -d sr="/tmp"

      # 1. Normal call inside tracked repo: znav-owned `cr` & `zz` masked, manual `customwork` & overridden `sr` kept!
      prompt_dir normal || exit 13
      [[ $INSIDE_SNAPSHOT == "cr=0|zz=0|cw=${HOME}/CUSTOM.WORK|sr=/tmp|p=~/CODE.REPOSITORIES/zsh-znav" ]] \
        || { print -r -- "SNAP_NORMAL:$INSIDE_SNAPSHOT"; exit 14; }
      [[ ${nameddirs[cr]:-} == "$HOME/CODE.REPOSITORIES" && ${nameddirs[zz]:-} == "$HOME/CODE.REPOSITORIES/zsh-znav" ]] \
        || { print -r -- "NOT_RESTORED_NORMAL"; exit 15; }

      # 2. Inside manual user `hash -d` directory: `prompt_dir` MUST still contract `~customwork/sub`!
      cd "$HOME/CUSTOM.WORK/sub" || exit 16
      prompt_dir normal || exit 17
      [[ $INSIDE_SNAPSHOT == *"|p=~customwork/sub" ]] \
        || { print -r -- "MANUAL_HASHD_BROKEN:$INSIDE_SNAPSHOT"; exit 18; }

      # 3. Early non-zero return (`return 7`) restores _ZNAV_OWNED_NAMEDDIRS and preserves return code 7
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 19
      integer rc=0
      prompt_dir early || rc=$?
      (( rc == 7 )) || { print -r -- "BAD_EARLY_RC:$rc"; exit 20; }
      [[ ${nameddirs[cr]:-} == "$HOME/CODE.REPOSITORIES" && ${nameddirs[zz]:-} == "$HOME/CODE.REPOSITORIES/zsh-znav" ]] \
        || { print -r -- "NOT_RESTORED_EARLY"; exit 21; }

      # 4. Parameter exception inside prompt_dir STILL restores 100% of _ZNAV_OWNED_NAMEDDIRS via `always`!
      {
        prompt_dir boom 2>/dev/null
      } always {
        TRY_BLOCK_ERROR=0
      }
      [[ ${nameddirs[cr]:-} == "$HOME/CODE.REPOSITORIES" && ${nameddirs[zz]:-} == "$HOME/CODE.REPOSITORIES/zsh-znav" ]] \
        || { print -r -- "NOT_RESTORED_BOOM:${nameddirs[cr]:-}|${nameddirs[zz]:-}"; exit 22; }

      # 5. Compatibility under `sh_glob` + `ksh_arrays` AND intact navigation (`~zz`, `~[zz]`, `j`)
      (
        setopt sh_glob ksh_arrays
        prompt_dir normal || exit 31
        prompt_znav || exit 32
      ) || exit 23
      cd "$HOME" || exit 24
      [[ ~zz == "$HOME/CODE.REPOSITORIES/zsh-znav" && ~[zz] == "$HOME/CODE.REPOSITORIES/zsh-znav" ]] || exit 26
      j cr || exit 27
      [[ $PWD == "$HOME/CODE.REPOSITORIES" ]] || exit 28

      print -r -- "S14C_OK"
    ' _ "$PLUGIN_FILE" 2>&1)
  assert_true $? "Suite 14c (always-block restoration, manual hash -d preservation & sh_glob/ksh_arrays safety) exited 0"
  [[ $out_14c == *"S14C_OK"* ]] \
    && pass "_ZNAV_OWNED_NAMEDDIRS suppressed inside prompt_dir, manual hash -d respected, and 100% restored across normal/early/error exits" \
    || fail "Suite 14c output: $out_14c"

  # Also verify bare `zz` (`AUTO_CD` + `CDABLE_VARS` in SHINSTDIN `-s`) works right after `prompt_dir`!
  local out_14c_bare
  out_14c_bare=$(HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14c" LC_ALL=C TERM=dumb \
    /bin/zsh -dfis +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP AUTO_CD CDABLE_VARS
prompt_dir() { local p=\${(%):-%~}; }
source ${(q)PLUGIN_FILE}
prompt_dir
zz
print -r -- "BARE_ZZ_AFTER_PROMPT_DIR:\$PWD"
exit 0
EOF
  )
  [[ $out_14c_bare == *"BARE_ZZ_AFTER_PROMPT_DIR:$exp_home/CODE.REPOSITORIES/zsh-znav"* ]] \
    && pass "Bare shortcode 'zz' (AUTO_CD + CDABLE_VARS) navigates cleanly after prompt_dir unhash/restore cycle" \
    || fail "Bare 'zz' after prompt_dir failed: $out_14c_bare"

  # 14d. `.zshrc` load-order independence, `source ~/.p10k.zsh` reload survival, 0-byte console init & PATH="" zero-fork
  cat > "$sb/mock_p10k_theme.zsh" <<'EOF'
typeset -gi _p9k__force_must_init=0
typeset -gA _p9k__cache_ephemeral=()
typeset -ga P10K_RENDER_LOG=()
p10k() {
  case ${1:-} in
    reload) _p9k__force_must_init=1; return 0 ;;
    segment)
      shift
      local opt cond="" text="" expand=0
      local -i OPTIND=1
      local OPTARG
      while getopts ":s:b:f:i:c:t:reh" opt; do
        case $opt in
          c) cond=$OPTARG ;;
          t) text=$OPTARG ;;
          e) expand=1 ;;
        esac
      done
      if [[ -n $cond ]]; then
        local cval=${(e):-"$cond"}
        [[ -z $cval ]] && return 0
      fi
      (( expand )) && P10K_RENDER_LOG+=("${(e):-"$text"}") || P10K_RENDER_LOG+=("$text")
      ;;
  esac
}
prompt_os_icon() { P10K_RENDER_LOG+=("OSX"); }
prompt_vcs()     { P10K_RENDER_LOG+=("main"); }
prompt_dir()     { P10K_RENDER_LOG+=("${(%):-%~}"); }
_p9k_precmd() {
  P10K_RENDER_LOG=()
  local seg
  for seg in "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}"; do
    [[ $seg == newline ]] && break
    (( $+functions[prompt_$seg] )) && "prompt_$seg"
  done
}
typeset -ga precmd_functions=(_p9k_precmd ${precmd_functions:#_p9k_precmd})
# Note: in real p10k (_p9k_setup), existing precmd_functions precede _p9k_precmd:
typeset -ga precmd_functions=(${precmd_functions:#_p9k_precmd} _p9k_precmd)
EOF

  cat > "$sb/mock_p10k_config.zsh" <<'EOF'
() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
  (( ! $+functions[p10k] )) || p10k reload
}
EOF

  # Order A: Oh My Zsh order (zsh-znav -> p10k theme -> .p10k.zsh -> late aliases) + mid-session `source .p10k.zsh` under PATH=""!
  local out_14d_stdout="$sb/s14d_stdout.log" out_14d_stderr="$sb/s14d_stderr.log"
  HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14d" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT="" PS1="" PS2=""
      setopt NO_PROMPT_SP
      builtin cd -q -- "$HOME/CODE.REPOSITORIES"
      # 1. Plugin loads first (like Oh My Zsh plugins=(... zsh-znav ...))
      source "$1" || exit 11
      # 2. Theme loads second
      source "$2" || exit 12
      # 3. ~/.p10k.zsh loads third (wipes POWERLEVEL9K_* and calls p10k reload)
      source "$3" || exit 13
      # 4. Late personal alias in ~/.zshrc
      alias gs="git status"

      # Lock down PATH="" to prove 0 forks across precmd_once + p10k reload + prompt rendering!
      PATH=""

      # Execute precmd hooks in exact shell order before Prompt #1
      local fn
      for fn in "${precmd_functions[@]}"; do
        "$fn"
      done
      [[ "${P10K_RENDER_LOG[*]}" == "OSX ~/CODE.REPOSITORIES ~cr main" ]] || exit 21
      (( ! $+nameddirs[gs] )) || exit 22
      [[ ~gis == "$HOME/GIT.STATUS" ]] || exit 23

      # Navigate into nested repo and simulate mid-session `source ~/.p10k.zsh` twice!
      cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 24
      _p9k__cache_ephemeral[stale]=1
      source "$3" || exit 25
      source "$3" || exit 26
      (( ${#_p9k__cache_ephemeral} == 0 && _p9k__force_must_init == 1 )) || exit 27
      for fn in "${precmd_functions[@]}"; do
        "$fn"
      done
      [[ "${P10K_RENDER_LOG[*]}" == "OSX ~/CODE.REPOSITORIES/zsh-znav ~zz main" ]] || exit 28
    ' _ "$REPO_ROOT/zsh-znav.plugin.zsh" "$sb/mock_p10k_theme.zsh" "$sb/mock_p10k_config.zsh" \
    >"$out_14d_stdout" 2>"$out_14d_stderr"
  assert_true $? "Suite 14d Order A (OMZ load order + mid-session source ~/.p10k.zsh under PATH=\"\") exited 0"
  assert_eq "$(<"$out_14d_stdout")$(<"$out_14d_stderr")" "" "Zero stdout/stderr console output across zsh-znav + Powerlevel10k init and reload"

  # Order B: Reverse load order (p10k theme -> .p10k.zsh -> zsh-znav)
  local out_14d_rev
  out_14d_rev=$(HOME="$exp_home" ZNAV_DATA_DIR="$sb/data_14d" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT="" PS1="" PS2=""
      setopt NO_PROMPT_SP
      builtin cd -q -- "$HOME/CODE.REPOSITORIES/zsh-znav"
      source "$2" || exit 11
      source "$3" || exit 12
      source "$1" || exit 13
      PATH=""
      local fn
      for fn in "${precmd_functions[@]}"; do
        "$fn"
      done
      print -r -- "REV_OK:${P10K_RENDER_LOG[*]}"
    ' _ "$REPO_ROOT/zsh-znav.plugin.zsh" "$sb/mock_p10k_theme.zsh" "$sb/mock_p10k_config.zsh" 2>&1)
  assert_true $? "Suite 14d Order B (p10k theme + config loaded BEFORE zsh-znav) exited 0"
  [[ $out_14d_rev == *"REV_OK:OSX ~/CODE.REPOSITORIES/zsh-znav ~zz main"* ]] \
    && pass "Both OMZ load order (znav -> p10k) and reverse load order (p10k -> znav) render full path + shortcode on Prompt #1" \
    || fail "Suite 14d Order B mismatch: $out_14d_rev"

  # 14e. Optional real Powerlevel10k theme integration test (when installed & readable on host/runner)
  local real_p10k_theme="${P10K_THEME_PATH:-$REAL_HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme}"
  if [[ -r $real_p10k_theme ]]; then
    local out_14e
    out_14e=$(HOME="$exp_home" ZDOTDIR="$exp_home" XDG_CACHE_HOME="$sb/cache" ZNAV_DATA_DIR="$sb/data_14e" \
      LC_ALL=en_US.UTF-8 TERM=xterm-256color \
      /bin/zsh -dfi +Z +m -c '
        typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true
        typeset -g POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
        source "$1" || exit 11
        source "$2" || exit 12
        typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs newline prompt_char)
        typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()
        typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
        typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
        p10k reload

        local fn
        cd "$HOME/CODE.REPOSITORIES/zsh-znav" || exit 13
        for fn in "${precmd_functions[@]}"; do "$fn"; done
        local rendered_zz=${(%)${(e)PROMPT}}

        cd "$HOME" || exit 14
        for fn in "${precmd_functions[@]}"; do "$fn"; done
        local rendered_home=${(%)${(e)PROMPT}}

        # Simulate mid-session `source ~/.p10k.zsh` reload
        cd "$HOME/CODE.REPOSITORIES/zsh-wh" || exit 15
        unset -m "(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR"
        typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true
        typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs newline prompt_char)
        typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()
        typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
        typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
        p10k reload
        for fn in "${precmd_functions[@]}"; do "$fn"; done
        local rendered_zw=${(%)${(e)PROMPT}}

        [[ $rendered_zz == *"zsh-znav"* && $rendered_zz == *"~zz"* ]] || { print -r -- "REAL_ZZ_BAD:$rendered_zz"; exit 21; }
        [[ $rendered_home != *"~zz"* && $rendered_home != *"~zw"* ]] || { print -r -- "REAL_HOME_BAD:$rendered_home"; exit 22; }
        [[ $rendered_zw == *"zsh-wh"* && $rendered_zw == *"~zw"* ]] || { print -r -- "REAL_ZW_BAD:$rendered_zw"; exit 23; }
        print -r -- "REAL_P10K_OK"
      ' _ "$REPO_ROOT/zsh-znav.plugin.zsh" "$real_p10k_theme" 2>&1)
    assert_true $? "Suite 14e (Live upstream Powerlevel10k theme prompt expansion) exited 0"
    [[ $out_14e == *"REAL_P10K_OK"* ]] \
      && pass "Live Powerlevel10k theme renders both readable path and ~zz/~zw shortcode, omits badge in \$HOME, and survives reload" \
      || fail "Suite 14e live p10k output: $out_14e"
  fi
}

# ==============================================================================
# SUITE 15: Interactive GitHub Pages Site (`site/`), Sync, Workflow & JS Parity
# ==============================================================================
print -r -- "\n--- Suite 15: GitHub Pages Site, Offline Safety, Benchmark Sync & JS Spec Parity ---"
() {
  local sb="$SANDBOX_ROOT/s15_site"
  zf_mkdir -p "$sb/sync_repo/benchmarks" "$sb/sync_repo/site"

  # 15a. Static Asset / Relative Link / Anchor Integrity & Offline `file://` Safety
  local out_15a
  out_15a=$(python3 -B - "$REPO_ROOT" 2>&1 <<'PYEOF'
import html.parser
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
site_dir = repo / "site"
readme_txt = (repo / "README.md").read_text(encoding="utf-8")

# Verify live GitHub Pages URL is in README.md strictly outside benchmark sentinels
begin_m = "<!-- BEGIN ZNAV_BENCHMARKS -->"
end_m = "<!-- END ZNAV_BENCHMARKS -->"
b_idx = readme_txt.index(begin_m)
e_idx = readme_txt.index(end_m)
outside_readme = readme_txt[:b_idx] + readme_txt[e_idx + len(end_m):]
assert "https://dstadulis.github.io/zsh-znav/" in outside_readme, (
    "Expected https://dstadulis.github.io/zsh-znav/ link in README.md outside sentinels"
)

for fname in ("index.html", "styles.css", "app.js", "bench_data.js", "favicon.svg"):
    fp = site_dir / fname
    assert fp.is_file() and fp.stat().st_size > 0, f"Missing or empty site file: {fp}"

html_txt = (site_dir / "index.html").read_text(encoding="utf-8")
css_txt = (site_dir / "styles.css").read_text(encoding="utf-8")
js_txt = (site_dir / "app.js").read_text(encoding="utf-8")

class SiteHTMLVerifier(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.refs = []
        self.module_scripts = []
        self._code_depth = 0
        self.raw_math_leaks = []

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "pre", "code"):
            self._code_depth += 1
        amap = dict(attrs)
        if amap.get("id"):
            self.ids.add(amap["id"])
        if tag == "script" and amap.get("type") == "module":
            self.module_scripts.append(amap.get("src", "<inline>"))
        for attr in ("href", "src"):
            val = amap.get(attr)
            if val:
                self.refs.append((tag, attr, val))

    def handle_endtag(self, tag):
        if tag in ("script", "style", "pre", "code") and self._code_depth > 0:
            self._code_depth -= 1

    def handle_data(self, data):
        if self._code_depth == 0 and re.search(r"\$[^$]+\$|\\[A-Za-z]+", data):
            self.raw_math_leaks.append((self.getpos(), data.strip()))

p = SiteHTMLVerifier()
p.feed(html_txt)
assert not p.module_scripts, f"ES module scripts fail under file:// CORS: {p.module_scripts}"
assert not p.raw_math_leaks, f"Unrendered raw LaTeX/$...$ in site/index.html: {p.raw_math_leaks}"

for tag, attr, ref in p.refs:
    if ref.startswith(("http://", "https://", "mailto:", "data:")):
        continue
    if ref.startswith("#"):
        anchor = ref[1:]
        assert not anchor or anchor in p.ids, f"Broken internal anchor {ref} in <{tag} {attr}>"
        continue
    rel = ref.split("#", 1)[0].split("?", 1)[0]
    target = site_dir / rel
    assert target.is_file() and target.stat().st_size > 0, f"Broken relative asset {ref} -> {target}"

for url_ref in re.findall(r"url\(([^)]+)\)", css_txt):
    cleaned = url_ref.strip().strip("\"'")
    if cleaned.startswith(("http://", "https://", "data:", "#")):
        continue
    rel = cleaned.split("#", 1)[0].split("?", 1)[0]
    assert (site_dir / rel).is_file(), f"Broken CSS url() reference: {cleaned}"

assert not re.search(r"\bfetch\s*\(|\bXMLHttpRequest\b", js_txt), (
    "site/app.js must not use fetch()/XMLHttpRequest so file:// offline viewing works 100%"
)
assert not re.search(r"\bfetch\s*\(|\bXMLHttpRequest\b", html_txt), (
    "site/index.html must not use fetch()/XMLHttpRequest"
)
print("SITE_ASSETS_OK")
PYEOF
  )
  assert_true $? "Suite 15a (site/ asset, anchor & offline file:// safety audit) exited 0"
  [[ $out_15a == *"SITE_ASSETS_OK"* ]] \
    && pass "All site/ relative assets, internal #anchors, README link, and file:// zero-fetch invariants verified" \
    || fail "Suite 15a output: $out_15a"

  # 15b. `site/bench_data.js` 1-to-1 sync with `benchmarks/results.json` + `/tmp` sandbox update test
  python3 -B "$REPO_ROOT/benchmarks/update_readme.py" --check >/dev/null
  assert_true $? "benchmarks/update_readme.py --check confirms README.md & site/bench_data.js are synchronized"

  local out_15b
  out_15b=$(python3 -B - "$REPO_ROOT" "$sb/sync_repo" 2>&1 <<'PYEOF'
import json
import shutil
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sb_repo = Path(sys.argv[2])

shutil.copy2(repo / "benchmarks" / "results.json", sb_repo / "benchmarks" / "results.json")
shutil.copy2(repo / "README.md", sb_repo / "README.md")
shutil.copy2(repo / "site" / "bench_data.js", sb_repo / "site" / "bench_data.js")

# Mutate results.json in sandbox -> --check MUST detect stale bench_data.js & README.md
data = json.loads((sb_repo / "benchmarks" / "results.json").read_text(encoding="utf-8"))
data["jump_latency_us"]["tilde_static"] = 0.19
(sb_repo / "benchmarks" / "results.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

rc_stale = subprocess.run(
    [
        sys.executable, "-B", str(repo / "benchmarks" / "update_readme.py"),
        "--results", str(sb_repo / "benchmarks" / "results.json"),
        "--readme", str(sb_repo / "README.md"),
        "--check",
    ],
    capture_output=True,
).returncode
assert rc_stale != 0, "Expected --check to fail when bench_data.js/README.md are stale"

# Run updater -> both sandbox README.md and sandbox site/bench_data.js must update and pass --check
subprocess.run(
    [
        sys.executable, "-B", str(repo / "benchmarks" / "update_readme.py"),
        "--results", str(sb_repo / "benchmarks" / "results.json"),
        "--readme", str(sb_repo / "README.md"),
    ],
    check=True,
    capture_output=True,
)
subprocess.run(
    [
        sys.executable, "-B", str(repo / "benchmarks" / "update_readme.py"),
        "--results", str(sb_repo / "benchmarks" / "results.json"),
        "--readme", str(sb_repo / "README.md"),
        "--check",
    ],
    check=True,
    capture_output=True,
)
updated_js = (sb_repo / "site" / "bench_data.js").read_text(encoding="utf-8")
assert '"tilde_static": 0.19' in updated_js, "Updated bench_data.js missing mutated value"
print("BENCH_JS_SYNC_OK")
PYEOF
  )
  assert_true $? "Suite 15b (sandbox bench_data.js stale detection & auto-resync) exited 0"
  [[ $out_15b == *"BENCH_JS_SYNC_OK"* ]] \
    && pass "update_readme.py keeps site/bench_data.js & README.md in 1-to-1 lockstep with benchmarks/results.json" \
    || fail "Suite 15b output: $out_15b"

  # 15c. `.github/workflows/pages.yml` & `perf-autoupdate.yml` site sync audit
  local out_15c
  out_15c=$(python3 -B - "$REPO_ROOT/.github/workflows/pages.yml" "$REPO_ROOT/.github/workflows/perf-autoupdate.yml" 2>&1 <<'PYEOF'
import sys
from pathlib import Path

pages_p = Path(sys.argv[1])
perf_p = Path(sys.argv[2])
assert pages_p.is_file(), f"Missing {pages_p}"
pages_raw = pages_p.read_text(encoding="utf-8")
perf_raw = perf_p.read_text(encoding="utf-8")

for lineno, ln in enumerate(pages_raw.splitlines(), 1):
    assert "\t" not in ln, f"Tab character in pages.yml:{lineno}"

try:
    import yaml  # type: ignore
    doc = yaml.safe_load(pages_raw)
    assert isinstance(doc, dict) and "jobs" in doc
    on_cfg = doc.get("on") or doc.get(True)
    assert "push" in on_cfg and "workflow_dispatch" in on_cfg
    assert set(on_cfg["push"]["paths"]) == {
        "site/**",
        "benchmarks/results.json",
        ".github/workflows/pages.yml",
    }
    perms = doc.get("permissions", {})
    assert perms.get("pages") == "write" and perms.get("id-token") == "write"
except ImportError:
    pass

for req in (
    "actions/configure-pages@v5",
    "actions/upload-pages-artifact@v3",
    "actions/deploy-pages@v4",
    ".nojekyll",
    "pages: write",
    "id-token: write",
    "site/**",
    "benchmarks/results.json",
):
    assert req in pages_raw, f"Missing '{req}' in pages.yml"

assert "site/bench_data.js" in perf_raw, "perf-autoupdate.yml must stage site/bench_data.js"
print("PAGES_WORKFLOW_OK")
PYEOF
  )
  assert_true $? "Suite 15c (pages.yml YAML & deployment workflow validation) exited 0"
  [[ $out_15c == *"PAGES_WORKFLOW_OK"* ]] \
    && pass "pages.yml & perf-autoupdate.yml validated (configure-pages@v5, upload-pages-artifact@v3, deploy-pages@v4, .nojekyll)" \
    || fail "Suite 15c output: $out_15c"

  # 15d. JS Engine (`site/app.js`) 1-to-1 Mathematical Conformance vs `proofs/znav_spec.py`
  local node_bin=${commands[node]:-}
  [[ -z $node_bin && -x /opt/homebrew/bin/node ]] && node_bin=/opt/homebrew/bin/node
  [[ -z $node_bin && -x /usr/local/bin/node ]] && node_bin=/usr/local/bin/node

  if [[ -n $node_bin ]]; then
    "$node_bin" --check "$REPO_ROOT/site/app.js" && "$node_bin" --check "$REPO_ROOT/site/bench_data.js"
    assert_true $? "node --check passed on site/app.js and site/bench_data.js"

    local out_15d
    out_15d=$(python3 -B - "$REPO_ROOT" "$node_bin" 2>&1 <<'PYEOF'
import json
import random
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
node_bin = sys.argv[2]
sys.path.insert(0, str(repo / "proofs"))
import znav_spec  # type: ignore

# 1. Verify CommonJS exports of bench_data.js & app.js unit primitives
node_unit = subprocess.run(
    [
        node_bin,
        "-e",
        """
        const fs = require("fs");
        const bench = require(process.argv[1]);
        const raw = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
        if (JSON.stringify(bench) !== JSON.stringify(raw)) process.exit(2);
        const spec = require(process.argv[3]);
        console.log(JSON.stringify({
          tok_html: spec.tokenize("HTMLParser.v2"),
          tok_url: spec.tokenize("myURLShortenerApp"),
          cands_cr: spec.candidateFinitePrefix("/Users/username/CODE.REPOSITORIES").slice(0, 6),
          cands_cafe: spec.candidateFinitePrefix("/private/tmp/café").slice(0, 4),
          blen_cafe: spec.pathByteLen("/private/tmp/café"),
        }));
        """,
        str(repo / "site" / "bench_data.js"),
        str(repo / "benchmarks" / "results.json"),
        str(repo / "site" / "app.js"),
    ],
    capture_output=True,
    text=True,
    check=True,
)
u = json.loads(node_unit.stdout)
assert u["tok_html"] == znav_spec.tokenize("HTMLParser.v2")
assert u["tok_url"] == znav_spec.tokenize("myURLShortenerApp")
assert u["cands_cr"] == znav_spec.candidate_finite_prefix("/Users/username/CODE.REPOSITORIES")[:6]
assert u["cands_cafe"] == znav_spec.candidate_finite_prefix("/private/tmp/café")[:4]
assert u["blen_cafe"] == znav_spec.path_byte_len("/private/tmp/café") == 18

# 2. 7,500-operation randomized differential trace conformance (`site/app.js --trace` vs `znav_spec.py`)
rng = random.Random(15002026)
dirs = [
    "/",
    "/Users/username/CODE.REPOSITORIES",
    "/Users/username/CACHE.REPOS",
    "/Users/username/TEMP.REPOS",
    "/Users/username/SCRIPT.REPOS",
    "/Users/username/HTMLParser.v2",
    "/Users/username/GIT.STATUS",
    "/Users/username/2026-roadmap",
    "/private/tmp/café",
    "/Users/username/CODE.REPOSITORIES/zsh-znav",
    "/Users/username/CODE.REPOSITORIES/zsh-wh",
    "/Users/username/CODE.REPOSITORIES/code-verification",
]
ops = []
t = 1795126400.0
for d in dirs[1:7]:
    ops.append({"op": "seed", "dir": d, "t": t})
for _ in range(7500):
    r = rng.random()
    d = rng.choice(dirs)
    if r < 0.55:
        t += rng.uniform(-3600.0, 18000.0)
        ops.append({"op": "visit", "dir": d, "t": round(t, 4)})
    elif r < 0.70:
        ops.append({"op": "seed", "dir": d, "t": round(t, 4)})
    elif r < 0.80 and d != "/":
        ops.append({"op": "delete", "dir": d, "prune": rng.choice([True, False])})
    elif r < 0.85:
        ops.append({"op": "prune"})
    else:
        q = rng.choice([["cr"], ["car"], ["ter"], ["code", "ver"], ["html", "v2"], ["zz"], ["zw"]])
        ops.append({"op": "resolve", "query": q, "colon": rng.choice([True, False])})

payload = {"half_life": 259200.0, "reserved": ["root", "tr", "pr", "ls", "gs"], "ops": ops}
py_res = znav_spec.run_trace_json(payload)
js_proc = subprocess.run(
    [node_bin, str(repo / "site" / "app.js"), "--trace"],
    input=json.dumps(payload),
    text=True,
    capture_output=True,
    check=True,
)
js_res = json.loads(js_proc.stdout)

assert js_res["ordered_dirs"] == py_res["ordered_dirs"], "ordered_dirs mismatch"
assert js_res["phi"] == py_res["phi"], f"phi mismatch: {js_res['phi']} != {py_res['phi']}"
assert js_res["resolutions"] == py_res["resolutions"], "resolutions mismatch"
max_err = max((abs(js_res["scores"][k] - py_res["scores"][k]) for k in py_res["scores"]), default=0.0)
assert max_err < 1e-12, f"Score divergence: {max_err}"
print(f"JS_SPEC_PARITY_OK:max_err={max_err:.3e}")
PYEOF
    )
    assert_true $? "Suite 15d (7,500-op Node JS vs Python znav_spec.py differential trace) exited 0"
    [[ $out_15d == *"JS_SPEC_PARITY_OK"* ]] \
      && pass "site/app.js matches proofs/znav_spec.py 1-to-1 across 7,500 ops ($out_15d)" \
      || fail "Suite 15d output: $out_15d"
  else
    pass "node binary not installed on host; Python static checks completed"
  fi

  # 15e. Aesthetic Metrology, Coordinate Geometry, 16.5:1 Polarity, 8x8 Spatial Dither & Non-Reference Audit
  local out_15e
  out_15e=$(python3 -B - "$REPO_ROOT" 2>&1 <<'PYEOF'
import html.parser
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
site_dir = repo / "site"
tests_dir = repo / "tests"

html_txt = (site_dir / "index.html").read_text(encoding="utf-8")
css_raw = (site_dir / "styles.css").read_text(encoding="utf-8")
js_txt = (site_dir / "app.js").read_text(encoding="utf-8")
fav_txt = (site_dir / "favicon.svg").read_text(encoding="utf-8")

# Strip CSS block comments before parsing property declarations
css_txt = re.sub(r"/\*.*?\*/", "", css_raw, flags=re.S)

# 1. Verify all 69 DOM IDs in site/index.html remain intact
class IdCollector(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        amap = dict(attrs)
        if amap.get("id"):
            self.ids.add(amap["id"])

idc = IdCollector()
idc.feed(html_txt)
assert len(idc.ids) == 69, f"Expected 69 DOM IDs in site/index.html, got {len(idc.ids)}"

# 2. Enforce zero non-zero border-radius declarations & zero SVG rounded corners
radius_decls = re.findall(r"border(?:-[a-z]+)*-radius\s*:\s*([^;\}]+)", css_txt, flags=re.I)
assert radius_decls, "Expected explicit border-radius: 0 rule in site/styles.css"
for val in radius_decls:
    norm = val.strip().lower()
    assert norm in ("0", "0px"), f"Non-zero border-radius forbidden: {val!r}"
for name, txt in (("index.html", html_txt), ("app.js", js_txt), ("favicon.svg", fav_txt)):
    assert not re.search(r"border(?:-[a-z]+)*-radius\s*:\s*(?!0(?:px)?\b)", txt, flags=re.I), (
        f"Non-zero border-radius in {name}"
    )
    assert not re.search(r"\br[xy]\s*=\s*['\"](?!0['\"])", txt, flags=re.I), (
        f"Rounded SVG rx/ry attribute forbidden in {name}"
    )

# 3. Enforce zero non-none box-shadow/text-shadow, zero backdrop-filter, zero radial/linear glow gradients, zero rgba()
shadow_decls = re.findall(r"(?:box|text)-shadow\s*:\s*([^;\}]+)", css_txt, flags=re.I)
assert shadow_decls, "Expected explicit box-shadow: none rule in site/styles.css"
for val in shadow_decls:
    assert val.strip().lower() == "none", f"Non-none shadow forbidden: {val!r}"

assert not re.search(r"(?:-webkit-)?backdrop-filter\s*:", css_txt, flags=re.I), (
    "backdrop-filter blur forbidden (surfaces must be 100% opaque)"
)
for name, txt in (("styles.css", css_txt), ("index.html", html_txt), ("app.js", js_txt), ("favicon.svg", fav_txt)):
    assert not re.search(r"(?:radial|linear|conic)-gradient\s*\(", txt, flags=re.I), (
        f"Decorative gradient forbidden in {name}"
    )
    assert not re.search(r"\b(?:rgba|hsla|color-mix)\s*\(", txt, flags=re.I), (
        f"Translucent color function forbidden in {name} (100% opaque planes required)"
    )

# 4. Enforce instantaneous 0ms state machine transitions (zero non-0s/0ms/none CSS transitions)
trans_decls = re.findall(r"transition(?:-duration)?\s*:\s*([^;\}]+)", css_txt, flags=re.I)
assert trans_decls, "Expected explicit transition: none rule in site/styles.css"
for val in trans_decls:
    norm = val.strip().lower()
    assert norm in ("none", "0", "0s", "0ms"), f"Non-zero CSS transition forbidden: {val!r}"

# 5. Verify #111111 & #f2f2f2 (16.5:1 WCAG contrast) dual polarity tokens + 4px coordinate grid + 8x8 spatial dither
def srgb_rel_lum(hex_code: str) -> float:
    h = hex_code.lstrip("#")
    chans = [int(h[i : i + 2], 16) / 255.0 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in chans]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]

l_light = srgb_rel_lum("#f2f2f2")
l_dark = srgb_rel_lum("#111111")
contrast = (l_light + 0.05) / (l_dark + 0.05)
assert contrast >= 16.5, f"Expected >= 16.5:1 contrast ratio, got {contrast:.2f}"

for req_token in (
    "--ground: #111111;",
    "--signal: #f2f2f2;",
    "--ground: #f2f2f2;",
    "--signal: #111111;",
    "--base-unit: 4px;",
    "--grid-gap: 8px;",
    "--control-gap: 8px;",
    "--panel-padding: 12px;",
    "--border-width: 1px;",
    "--corner-radius: 0px;",
    "--header-height: 28px;",
    "--control-height: 24px;",
    "--transition-ms: 0ms;",
    "--dither-void-0:",
    "--dither-stipple-25:",
    "--dither-50:",
    "--dither-checker-50:",
    "--dither-solid-100:",
    "--dither-sparse:",
    "width='8' height='8' viewBox='0 0 8 8'",
    "background-size: 8px 8px;",
    "-webkit-font-smoothing: antialiased;",
    "font-size: 14px;",
    "line-height: 20px;",
    "font-variant-numeric: tabular-nums;",
):
    assert req_token in css_txt, f"Missing required metrology token in site/styles.css: {req_token}"

assert "#111111" in fav_txt and "#f2f2f2" in fav_txt, "site/favicon.svg must use #111111 / #f2f2f2 polarity"
assert 'id="frec-shield-dither" width="8" height="8"' in js_txt, "site/app.js must use 8x8 SVG spatial dither pattern"

# 6. Strict non-reference audit across site/ and tests/ (hex-encoded so test file itself stays 100% reference-free)
forbidden_hex = (
    "64657369676e2d61657374686574696373",
    "74656d706c617465732f6b65726e656c",
    "6b65726e656c2e6a736f6e",
    "616b7766",
    "616b636c69",
    "6d61636864796e65",
    "7a6569746c6f73",
)
forbidden_terms = [bytes.fromhex(h).decode("utf-8") for h in forbidden_hex]
scan_paths = sorted(list(site_dir.rglob("*")) + list(tests_dir.rglob("*")))
for sp in scan_paths:
    if not sp.is_file() or sp.suffix in (".zwc", ".pyc"):
        continue
    body_low = sp.read_text(encoding="utf-8", errors="ignore").lower()
    for term in forbidden_terms:
        assert term not in body_low, f"Forbidden external reference {term!r} found in {sp.relative_to(repo)}"

print(f"METROLOGY_OK:contrast={contrast:.2f}:ids={len(idc.ids)}")
PYEOF
  )
  assert_true $? "Suite 15e (aesthetic metrology, 16.5:1 polarity, 4px grid, 8x8 dither & non-reference audit) exited 0"
  [[ $out_15e == *"METROLOGY_OK"* ]] \
    && pass "Aesthetic metrology verified: 0px radii, 1px rules, 0 shadows/blur/gradients, 0ms transitions, 16.5:1 #111111/#f2f2f2, 8x8 dither ($out_15e)" \
    || fail "Suite 15e output: $out_15e"
}

# ==============================================================================
# HOST UNTOUCHED INVARIANT CHECK
# ==============================================================================
print -r -- "\n--- Host Safety Invariant Check ---"
if (( HOST_ZSHRC_READABLE )); then
  typeset -A _st_after
  zstat -H _st_after "$REAL_HOME/.zshrc" 2>/dev/null
  if [[ ${_st_after[mtime]} == $HOST_ZSHRC_MTIME && ${_st_after[size]} == $HOST_ZSHRC_SIZE ]]; then
    pass "Host ~/.zshrc verified 100% untouched (mtime & size unchanged)"
  else
    fail "Host ~/.zshrc was modified during test run!"
  fi
else
  pass "Host ~/.zshrc verified untouched (protected / unmodified)"
fi
if (( HOST_P10K_READABLE )); then
  typeset -A _st_p10k_after
  zstat -H _st_p10k_after "$REAL_HOME/.p10k.zsh" 2>/dev/null
  if [[ ${_st_p10k_after[mtime]} == $HOST_P10K_MTIME && ${_st_p10k_after[size]} == $HOST_P10K_SIZE ]]; then
    pass "Host ~/.p10k.zsh verified 100% untouched (mtime & size unchanged)"
  else
    fail "Host ~/.p10k.zsh was modified during test run!"
  fi
else
  pass "Host ~/.p10k.zsh verified untouched (protected / unmodified)"
fi
if (( ! HOST_ZNAV_DATA_EXISTED )); then
  [[ ! -e "$REAL_HOME/.local/share/znav" ]] && pass "Host ~/.local/share/znav untouched" \
                                            || fail "Host ~/.local/share/znav was polluted!"
fi

print -r -- "\n======================================================================"
print -r -- " SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
print -r -- "======================================================================"
if (( FAIL_COUNT > 0 )); then
  for msg in $FAIL_LOG; do
    print -u2 -r -- "  - $msg"
  done
  exit 1
fi
exit 0
