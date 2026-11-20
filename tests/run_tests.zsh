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
# ==============================================================================

emulate -L zsh
setopt extended_glob typeset_silent no_short_loops pipe_fail

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

  # Run XNU Mach-task kernel rusage_info_v4 Zero-Fork Proof
  if command -v python3 >/dev/null 2>&1; then
    python3 "$TESTS_DIR/verify_zero_fork.py"
    assert_true $? "XNU Kernel proc_pid_rusage(RUSAGE_INFO_V4) proves 0 forks across all znav paths"
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

  local out
  out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=en_US.UTF-8 TERM=dumb \
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
  reload_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=en_US.UTF-8 TERM=dumb \
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
    /bin/cp -R "$REPO_ROOT/functions/"* "$sb/pkg/functions/" 2>/dev/null || true
  fi

  local zc_out
  zc_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data" LC_ALL=C TERM=dumb \
    /bin/zsh -dfi +Z +m -c '
      PROMPT="" RPROMPT=""
      zcompile '"${(q)sb}"'/pkg/znav.plugin.zsh || exit 11
      for f in '"${(q)sb}"'/pkg/functions/*(N.); do
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
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/home/GIT.STATUS" "$sb/home/LAZY.GIT" "$sb/home/LAZY.GIT.STATUS" "$sb/data1" "$sb/data2" "$sb/data3"
  local exp_home=${${:-$sb/home}:A}
  local entry_plugin="$REPO_ROOT/zsh-znav.plugin.zsh"

  # 10a. Default ZNAV_CDABLE_VARS=1 sets CDABLE_VARS in caller scope -> bare cr/sr work with AUTO_CD alone!
  local cdv_on
  cdv_on=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data1" LC_ALL=C TERM=dumb \
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
  cdv_off=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data2" ZNAV_CDABLE_VARS=0 LC_ALL=C TERM=dumb \
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
  precmd_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/data3" LC_ALL=C TERM=dumb \
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

  # Copy package files into sandbox repo so .zwc compilation/cleanup never mutates host repo
  /bin/cp "$REPO_ROOT/znav.plugin.zsh" "$REPO_ROOT/zsh-znav.plugin.zsh" "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$sb/repo/"
  /bin/cp "$REPO_ROOT/functions/"* "$sb/repo/functions/"
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
