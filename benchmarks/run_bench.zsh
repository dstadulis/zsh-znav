#!/usr/bin/env zsh
# ==============================================================================
# znav Quantitative Latency & Information-Efficiency Benchmark Suite
# ==============================================================================
# Cross-platform (macOS + Linux) benchmark pipeline:
#   1. chpwd Hook Latency (µs/op) at N = 50, 500, 2000 directories:
#      - znav O(1) pure-Zsh hook (0 forks, 1-line WAL append)
#      - Zsh built-in cdr / chpwd_recent_dirs O(N) hook (in-process slurp+lex+rewrite)
#      - External-fork floor (true -- "$PWD")
#      - External Rust frecency engine (zoxide, if installed; isolated via _ZO_DATA_DIR)
#   2. Jump & Inline Path Expansion Latency (µs/op) at N = 500:
#      - ~cr (Zsh C nameddirtab hash lookup)
#      - ~[cr] (zsh_directory_name dynamic hook)
#      - cd ~cr (jump + znav chpwd)
#      - j cr (full znav jump function including builtin cd + chpwd)
#      - ~[1] & cdr 1 (Zsh built-in MRU dynamic expand & jump at N = 500)
#      - External-fork jump floor ($(echo ...) + cd -q) & zoxide `z` jump
#   3. Empirical Information Efficiency & Code-Churn (Zipf s=1.2, N = 30, 100, 500)
#      via benchmarks/info_efficiency.py.
#   4. Emits machine-readable results.json, detailed results.md, and (unless
#      --no-readme is passed) auto-updates README.md via benchmarks/update_readme.py.
# ==============================================================================

emulate -L zsh
setopt extended_glob typeset_silent no_short_loops pipe_fail

# Clear any inherited caller FPATH so child `zsh -dfi` processes use the OS's
# native compiled-in $fpath (/usr/share/zsh/$ZSH_VERSION/functions on macOS,
# /usr/share/zsh/functions/{Chpwd,Misc,...} on Debian/Ubuntu, etc.).
unset FPATH

readonly BENCH_DIR=${0:A:h}
readonly REPO_ROOT=${BENCH_DIR:h}
readonly PLUGIN_FILE="$REPO_ROOT/znav.plugin.zsh"

zmodload zsh/datetime zsh/mathfunc zsh/parameter zsh/system
zmodload -F zsh/files b:zf_mkdir

usage() {
  cat <<'EOF'
Usage: zsh benchmarks/run_bench.zsh [options]

Options:
  --output-dir <dir>   Directory for results.json and results.md (default: benchmarks/)
  --readme <path>      README file to update between ZNAV_BENCHMARKS sentinels (default: README.md)
  --no-readme          Skip updating README.md
  -h, --help           Show this help message

Environment:
  ZNAV_BENCH_ITERS     Iterations per latency measurement (default: 1000)
EOF
}

local OUTPUT_DIR="$BENCH_DIR"
local README_PATH="$REPO_ROOT/README.md"
integer UPDATE_README=1

while (( $# > 0 )); do
  case $1 in
    --output-dir)
      shift
      (( $# > 0 )) || { print -u2 "[ABORT] --output-dir requires an argument"; exit 1; }
      OUTPUT_DIR=$1
      ;;
    --output-dir=*)
      OUTPUT_DIR=${1#--output-dir=}
      [[ -n $OUTPUT_DIR ]] || { print -u2 "[ABORT] --output-dir requires an argument"; exit 1; }
      ;;
    --readme)
      shift
      (( $# > 0 )) || { print -u2 "[ABORT] --readme requires a file path"; exit 1; }
      README_PATH=$1
      ;;
    --readme=*)
      README_PATH=${1#--readme=}
      [[ -n $README_PATH ]] || { print -u2 "[ABORT] --readme requires a file path"; exit 1; }
      ;;
    --no-readme)
      UPDATE_README=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -r -- "[ABORT] Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f $PLUGIN_FILE ]]; then
  print -u2 -r -- "[ABORT] Plugin not found at $PLUGIN_FILE"
  exit 1
fi

local raw_iters=${ZNAV_BENCH_ITERS:-1000}
if [[ $raw_iters != <-> ]] || (( raw_iters < 1 )); then
  print -u2 -r -- "[ABORT] ZNAV_BENCH_ITERS must be a positive integer (got '$raw_iters')"
  exit 1
fi
readonly integer ITERS=$raw_iters
readonly integer PAIRS=$(( (ITERS + 1) / 2 ))
readonly integer PAIR_OPS=$(( PAIRS * 2 ))
readonly integer WARMUP_LONG=$(( ITERS < 50 ? 2 : 20 ))
readonly integer WARMUP_SHORT=$(( ITERS < 50 ? 2 : 10 ))
readonly integer WARMUP_TILDE=$(( ITERS < 50 ? 4 : 50 ))

zf_mkdir -p -- "$OUTPUT_DIR"
readonly OUTPUT_DIR_ABS=${OUTPUT_DIR:A}
readonly RESULTS_JSON="$OUTPUT_DIR_ABS/results.json"
readonly RESULTS_MD="$OUTPUT_DIR_ABS/results.md"

# Resolve binaries portably across macOS and Linux
readonly ZSH_BIN=${ZNAV_BENCH_ZSH:-${commands[zsh]:-/bin/zsh}}
readonly PYTHON_BIN=${ZNAV_BENCH_PYTHON:-${commands[python3]:-python3}}
readonly UNAME_BIN=${commands[uname]:-/usr/bin/uname}
readonly RM_BIN=${commands[rm]:-/bin/rm}

local _true_bin=${commands[true]:-}
if [[ -z $_true_bin ]]; then
  [[ -x /usr/bin/true ]] && _true_bin=/usr/bin/true || _true_bin=/bin/true
fi
readonly TRUE_BIN=$_true_bin

local _echo_bin=${commands[echo]:-}
if [[ -z $_echo_bin ]]; then
  [[ -x /bin/echo ]] && _echo_bin=/bin/echo || _echo_bin=/usr/bin/echo
fi
readonly ECHO_BIN=$_echo_bin

# Cross-platform CPU & OS detection (macOS sysctl/sw_vers + Linux /proc/cpuinfo & /etc/os-release)
readonly ARCH_NAME=$("$UNAME_BIN" -m 2>/dev/null || print "unknown")

detect_hw_model() {
  local hw=""
  if (( $+commands[sysctl] )); then
    hw=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    [[ -z $hw ]] && hw=$(sysctl -n hw.model 2>/dev/null || true)
  fi
  if [[ -z $hw ]]; then
    local cpuinfo_file=${ZNAV_BENCH_PROC_CPUINFO:-/proc/cpuinfo}
    if [[ -r $cpuinfo_file ]]; then
      local line val
      while IFS= read -r line; do
        case $line in
          model\ name[[:space:]:]*|Hardware[[:space:]:]*|Processor[[:space:]:]*|cpu\ model[[:space:]:]*)
            if [[ $line == *:* ]]; then
              val=${line#*:}
              val=${val##[[:space:]]##}
              val=${val%%[[:space:]]##}
              if [[ -n $val ]]; then
                hw=$val
                break
              fi
            fi
            ;;
        esac
      done < "$cpuinfo_file"
    fi
  fi
  [[ -z $hw ]] && hw=$ARCH_NAME
  REPLY=$hw
}

detect_os_label() {
  local os_lbl=""
  if (( $+commands[sw_vers] )); then
    local prod ver
    prod=$(sw_vers -productName 2>/dev/null || print "macOS")
    ver=$(sw_vers -productVersion 2>/dev/null || true)
    if [[ -n $ver ]]; then
      os_lbl="${prod:-macOS} $ver"
    fi
  fi
  if [[ -z $os_lbl ]]; then
    local os_rel_file=${ZNAV_BENCH_OS_RELEASE:-/etc/os-release}
    if [[ -r $os_rel_file ]]; then
      local line pretty="" name="" ver=""
      while IFS= read -r line; do
        case $line in
          PRETTY_NAME=*)
            pretty=${line#PRETTY_NAME=}
            pretty=${pretty#[\"\']}
            pretty=${pretty%[\"\']}
            ;;
          NAME=*)
            name=${line#NAME=}
            name=${name#[\"\']}
            name=${name%[\"\']}
            ;;
          VERSION_ID=*)
            ver=${line#VERSION_ID=}
            ver=${ver#[\"\']}
            ver=${ver%[\"\']}
            ;;
        esac
      done < "$os_rel_file"
      if [[ -n $pretty ]]; then
        os_lbl=$pretty
      elif [[ -n $name ]]; then
        os_lbl="${name}${ver:+ $ver}"
      fi
    fi
  fi
  if [[ -z $os_lbl ]]; then
    os_lbl="$("$UNAME_BIN" -s 2>/dev/null || print unknown) $("$UNAME_BIN" -r 2>/dev/null || true)"
    os_lbl=${os_lbl%%[[:space:]]##}
  fi
  REPLY=$os_lbl
}

detect_hw_model
readonly HW_MODEL=$REPLY
detect_os_label
readonly OS_LABEL=$REPLY

local _zoxide_bin="" _zoxide_ver="zoxide"
if [[ ${ZNAV_BENCH_NO_ZOXIDE:-0} != 1 ]] && (( $+commands[zoxide] )); then
  _zoxide_bin=${commands[zoxide]}
  _zoxide_ver=$("$_zoxide_bin" --version 2>/dev/null || print "zoxide")
  _zoxide_ver=${_zoxide_ver%%$'\n'*}
  _zoxide_ver=${_zoxide_ver%%[[:space:]]##}
  [[ -z $_zoxide_ver ]] && _zoxide_ver="zoxide"
fi
readonly ZOXIDE_BIN=$_zoxide_bin
readonly ZOXIDE_VER=$_zoxide_ver

readonly RAW_BENCH="/tmp/znav_bench_${sysparams[pid]}_${RANDOM}"
zf_mkdir -p "$RAW_BENCH"
readonly BENCH_SANDBOX=${RAW_BENCH:A}

cleanup() {
  "$RM_BIN" -rf "$BENCH_SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

local _zo_disp="not installed"
[[ -n $ZOXIDE_BIN ]] && _zo_disp=$ZOXIDE_VER
print -r -- "======================================================================"
print -r -- " znav Quantitative Benchmark Suite"
print -r -- " Host: $HW_MODEL ($ARCH_NAME, $OS_LABEL), Zsh $ZSH_VERSION"
print -r -- " Iterations per measurement: $ITERS (zoxide: $_zo_disp)"
print -r -- "======================================================================"

typeset -A CHPWD_US=()
typeset -A JUMP_US=()

# ------------------------------------------------------------------------------
# Helper: Measure chpwd hooks at directory count N
# ------------------------------------------------------------------------------
measure_chpwd_at_n() {
  integer N=$1
  local sb="$BENCH_SANDBOX/n_${N}"
  zf_mkdir -p "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "$sb/dirs" "$sb/znav_data" "$sb/zo_data"

  print -r -- $'\n'"[Benchmarking chpwd @ N = $N directories ($ITERS iterations)...]"

  integer i
  typeset -a all_dirs=()
  for (( i = 1; i <= N; i++ )); do
    local d="$sb/dirs/repo_${(l:4::0:)i}_pkg"
    zf_mkdir -p "$d"
    all_dirs+=("$d")
  done
  local dir_list_file="$sb/dir_list.txt"
  print -rl -- "${all_dirs[@]}" > "$dir_list_file"

  # 1. znav chpwd @ N (steady-state with N directories in DB + active WAL)
  local znav_us
  znav_us=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/znav_data" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime zsh/mathfunc
integer idx=0
float -E 17 base_t=\$EPOCHREALTIME
local -a db_lines=()
while IFS= read -r d; do
  (( idx++ ))
  float -E 17 sc=\$(( base_t - 1000.0 - idx ))
  local sc_s
  printf -v sc_s '%.17g' \$sc
  db_lines+=("S \${sc_s} \${(qqqq)d}")
done < ${(q)dir_list_file}
print -rl -- "\${db_lines[@]}" > "\$ZNAV_DATA_DIR/db.tsv"

source ${(q)PLUGIN_FILE}
cd "\$HOME/CODE.REPOSITORIES"
cd "\$HOME/SCRIPT.REPOS"
repeat $WARMUP_LONG { cd "\$HOME/CODE.REPOSITORIES"; cd "\$HOME/SCRIPT.REPOS"; }
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  cd "\$HOME/CODE.REPOSITORIES"
  cd "\$HOME/SCRIPT.REPOS"
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_per_op=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "RESULT:\$us_per_op"
exit 0
EOF
  )
  CHPWD_US[znav_$N]=${${(M)${(f)znav_us}:#RESULT:*}#RESULT:}
  print -r -- "  znav O(1) chpwd          (N=$N): ${CHPWD_US[znav_$N]} µs/op"

  # 2. Zsh built-in `cdr` (`chpwd_recent_dirs`) @ N
  local cdr_file="$sb/cdr_recent_dirs"
  local cdr_us
  cdr_us=$(HOME="$sb/home" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime zsh/zutil
autoload -Uz chpwd_recent_dirs chpwd_recent_filehandler chpwd_recent_add cdr add-zsh-hook
zstyle ':chpwd:*' recent-dirs-file ${(q)cdr_file}
zstyle ':chpwd:*' recent-dirs-max 0
local -a init_dirs=(\${(f)"\$(<${(q)dir_list_file})"})
chpwd_recent_filehandler "\$HOME/SCRIPT.REPOS" "\$HOME/CODE.REPOSITORIES" "\${init_dirs[@]}"
add-zsh-hook chpwd chpwd_recent_dirs
repeat $WARMUP_SHORT { cd "\$HOME/CODE.REPOSITORIES"; cd "\$HOME/SCRIPT.REPOS"; }
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  cd "\$HOME/CODE.REPOSITORIES"
  cd "\$HOME/SCRIPT.REPOS"
}
float -E 17 t1=\$EPOCHREALTIME
local -a check_lines=(\${(f)"\$(<${(q)cdr_file})"})
(( \${#check_lines} >= $N )) || { print -u2 "CDR_TRUNCATED:\${#check_lines}"; exit 2; }
float -F 2 us_per_op=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "RESULT:\$us_per_op"
exit 0
EOF
  )
  CHPWD_US[cdr_$N]=${${(M)${(f)cdr_us}:#RESULT:*}#RESULT:}
  print -r -- "  cdr O(N) chpwd           (N=$N): ${CHPWD_US[cdr_$N]} µs/op"

  # 3. Minimal External-Fork Baseline (true -- "$PWD" on chpwd)
  local fork_us
  fork_us=$(HOME="$sb/home" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime
_ext_fork_hook() { ${(q)TRUE_BIN} -- "\$PWD"; }
chpwd_functions=(_ext_fork_hook)
repeat $WARMUP_SHORT { cd "\$HOME/CODE.REPOSITORIES"; cd "\$HOME/SCRIPT.REPOS"; }
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  cd "\$HOME/CODE.REPOSITORIES"
  cd "\$HOME/SCRIPT.REPOS"
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_per_op=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "RESULT:\$us_per_op"
exit 0
EOF
  )
  CHPWD_US[fork_$N]=${${(M)${(f)fork_us}:#RESULT:*}#RESULT:}
  print -r -- "  external-fork floor      (N=$N): ${CHPWD_US[fork_$N]} µs/op"

  # 4. External Rust CLI `zoxide` (if installed, strictly isolated via _ZO_DATA_DIR)
  if [[ -n $ZOXIDE_BIN ]]; then
    _ZO_DATA_DIR="$sb/zo_data" "$ZOXIDE_BIN" add "$sb/home/CODE.REPOSITORIES" "$sb/home/SCRIPT.REPOS" "${all_dirs[@]}"
    local zo_us
    zo_us=$(HOME="$sb/home" _ZO_DATA_DIR="$sb/zo_data" PATH="${ZOXIDE_BIN:h}:/usr/bin:/bin" LC_ALL=C TERM=dumb \
      "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime
eval "\$(${(q)ZOXIDE_BIN} init zsh)"
repeat $WARMUP_SHORT { cd "\$HOME/CODE.REPOSITORIES"; cd "\$HOME/SCRIPT.REPOS"; }
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  cd "\$HOME/CODE.REPOSITORIES"
  cd "\$HOME/SCRIPT.REPOS"
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_per_op=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "RESULT:\$us_per_op"
exit 0
EOF
    )
    CHPWD_US[zoxide_$N]=${${(M)${(f)zo_us}:#RESULT:*}#RESULT:}
    print -r -- "  $ZOXIDE_VER (Rust CLI) (N=$N): ${CHPWD_US[zoxide_$N]} µs/op"
  else
    CHPWD_US[zoxide_$N]="N/A"
    print -r -- "  zoxide (not installed)   (N=$N): N/A"
  fi
}

for N_VAL in 50 500 2000; do
  measure_chpwd_at_n $N_VAL
done

# ------------------------------------------------------------------------------
# Part 2: Directory Jump & Path Expansion Latency (N = 500)
# ------------------------------------------------------------------------------
print -r -- $'\n'"[Benchmarking Jump & Path Expansion Latency @ N = 500 ($ITERS iterations)...]"
() {
  local sb="$BENCH_SANDBOX/n_500"

  local znav_j_out
  znav_j_out=$(HOME="$sb/home" ZNAV_DATA_DIR="$sb/znav_data" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime
source ${(q)PLUGIN_FILE}
repeat 5 { cd "\$HOME/CODE.REPOSITORIES"; cd "\$HOME/SCRIPT.REPOS"; }

# 1. Static ~cr / ~sr expansion (Zsh C nameddirtab hash table)
local _p=""
repeat $WARMUP_TILDE { _p=~cr; _p=~sr; }
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  _p=~cr
  _p=~sr
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_tilde=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "TILDE_STATIC:\$us_tilde"

# 2. Dynamic ~[cr] / ~[sr] expansion (zsh_directory_name n hook)
repeat $WARMUP_TILDE { _p=~[cr]; _p=~[sr]; }
t0=\$EPOCHREALTIME
repeat $PAIRS {
  _p=~[cr]
  _p=~[sr]
}
t1=\$EPOCHREALTIME
float -F 2 us_dyn=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "TILDE_DYN:\$us_dyn"

# 3. 'j cr' full jump (includes cd + chpwd)
repeat $WARMUP_LONG { j cr; j sr; }
t0=\$EPOCHREALTIME
repeat $PAIRS {
  j cr
  j sr
}
t1=\$EPOCHREALTIME
float -F 2 us_j=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "JUMP_J:\$us_j"

# 4. cd ~cr (including chpwd) for apples-to-apples jump comparison
repeat $WARMUP_LONG { cd ~cr; cd ~sr; }
t0=\$EPOCHREALTIME
repeat $PAIRS {
  cd ~cr
  cd ~sr
}
t1=\$EPOCHREALTIME
float -F 2 us_cd_tilde=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "CD_TILDE:\$us_cd_tilde"
exit 0
EOF
  )
  JUMP_US[tilde_static]=${${(M)${(f)znav_j_out}:#TILDE_STATIC:*}#TILDE_STATIC:}
  JUMP_US[tilde_dyn]=${${(M)${(f)znav_j_out}:#TILDE_DYN:*}#TILDE_DYN:}
  JUMP_US[jump_j]=${${(M)${(f)znav_j_out}:#JUMP_J:*}#JUMP_J:}
  JUMP_US[cd_tilde]=${${(M)${(f)znav_j_out}:#CD_TILDE:*}#CD_TILDE:}

  print -r -- "  ~cr (C hash table expand)      : ${JUMP_US[tilde_static]} µs/op"
  print -r -- "  ~[cr] (dynamic hook expand)    : ${JUMP_US[tilde_dyn]} µs/op"
  print -r -- "  cd ~cr (jump + znav chpwd)     : ${JUMP_US[cd_tilde]} µs/op"
  print -r -- "  j cr (znav jump + chpwd)       : ${JUMP_US[jump_j]} µs/op"

  # 5. cdr 1 jump & ~[1] dynamic expand @ N = 500
  local cdr_j_out
  cdr_j_out=$(HOME="$sb/home" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime zsh/zutil
autoload -Uz chpwd_recent_dirs chpwd_recent_filehandler chpwd_recent_add cdr zsh_directory_name_cdr add-zsh-hook
zstyle ':chpwd:*' recent-dirs-file ${(q)sb}/cdr_recent_dirs
zstyle ':chpwd:*' recent-dirs-max 0
add-zsh-hook chpwd chpwd_recent_dirs
add-zsh-hook zsh_directory_name zsh_directory_name_cdr
cd "\$HOME/CODE.REPOSITORIES"
cd "\$HOME/SCRIPT.REPOS"

local _p=""
repeat $WARMUP_SHORT { _p=~[1]; }
float -E 17 t0=\$EPOCHREALTIME
repeat $ITERS {
  _p=~[1]
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_cdr_dyn=\$(( (t1 - t0) * 1000000.0 / $ITERS.0 ))
print -r -- "CDR_DYN:\$us_cdr_dyn"

t0=\$EPOCHREALTIME
repeat $ITERS {
  cdr 1
}
t1=\$EPOCHREALTIME
float -F 2 us_cdr_jump=\$(( (t1 - t0) * 1000000.0 / $ITERS.0 ))
print -r -- "CDR_JUMP:\$us_cdr_jump"
exit 0
EOF
  )
  JUMP_US[cdr_dyn]=${${(M)${(f)cdr_j_out}:#CDR_DYN:*}#CDR_DYN:}
  JUMP_US[cdr_jump]=${${(M)${(f)cdr_j_out}:#CDR_JUMP:*}#CDR_JUMP:}
  print -r -- "  ~[1] (cdr dynamic expand N=500): ${JUMP_US[cdr_dyn]} µs/op"
  print -r -- "  cdr 1 (cdr jump+chpwd N=500)   : ${JUMP_US[cdr_jump]} µs/op"

  # 6. External-fork jump floor & zoxide 'z' jump
  local ext_path="/usr/bin:/bin"
  [[ -n $ZOXIDE_BIN ]] && ext_path="${ZOXIDE_BIN:h}:$ext_path"
  local ext_j_out
  ext_j_out=$(HOME="$sb/home" _ZO_DATA_DIR="$sb/zo_data" PATH="$ext_path" LC_ALL=C TERM=dumb \
    "$ZSH_BIN" -dfi +Z +m <<EOF 2>/dev/null
PROMPT="" RPROMPT="" PS1="" PS2=""
setopt NO_PROMPT_SP INTERACTIVE_COMMENTS NO_BANG_HIST
zmodload zsh/datetime
local d1="\$HOME/CODE.REPOSITORIES" d2="\$HOME/SCRIPT.REPOS" _res=""
float -E 17 t0=\$EPOCHREALTIME
repeat $PAIRS {
  _res=\$(${(q)ECHO_BIN} "\$d1") && builtin cd -q -- "\$_res"
  _res=\$(${(q)ECHO_BIN} "\$d2") && builtin cd -q -- "\$_res"
}
float -E 17 t1=\$EPOCHREALTIME
float -F 2 us_ext_floor=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
print -r -- "EXT_JUMP_FLOOR:\$us_ext_floor"

if [[ -n ${(q)ZOXIDE_BIN} && -x ${(q)ZOXIDE_BIN} ]]; then
  eval "\$(${(q)ZOXIDE_BIN} init zsh)"
  repeat 5 { ${(q)ZOXIDE_BIN} add "\$d1" "\$d2"; }
  t0=\$EPOCHREALTIME
  repeat $PAIRS {
    z code.repositories
    z script.repos
  }
  t1=\$EPOCHREALTIME
  float -F 2 us_zo_jump=\$(( (t1 - t0) * 1000000.0 / $PAIR_OPS.0 ))
  print -r -- "ZO_JUMP:\$us_zo_jump"
fi
exit 0
EOF
  )
  JUMP_US[ext_floor]=${${(M)${(f)ext_j_out}:#EXT_JUMP_FLOOR:*}#EXT_JUMP_FLOOR:}
  JUMP_US[zo_jump]=${${${(M)${(f)ext_j_out}:#ZO_JUMP:*}#ZO_JUMP:}:-N/A}
  print -r -- "  external-fork jump floor       : ${JUMP_US[ext_floor]} µs/op"
  print -r -- "  $ZOXIDE_VER 'z' jump + hook  : ${JUMP_US[zo_jump]} µs/op"
}

# ------------------------------------------------------------------------------
# Part 3: Empirical Information Efficiency (Zipf s=1.2, N = 30, 100, 500)
# ------------------------------------------------------------------------------
print -r -- $'\n'"[Running Zipf(s=1.2) Information-Efficiency & Code-Churn Benchmarks...]"
local info_json
info_json=$(ZNAV_BENCH_ZSH="$ZSH_BIN" "$PYTHON_BIN" "$BENCH_DIR/info_efficiency.py" --plugin "$PLUGIN_FILE")
print -r -- "$info_json"

# ------------------------------------------------------------------------------
# Part 4: Emit Structured results.json + Render results.md & README.md
# ------------------------------------------------------------------------------
"$PYTHON_BIN" - "$RESULTS_JSON" "$HW_MODEL" "$ARCH_NAME" "$OS_LABEL" "$ZSH_VERSION" "$ZSH_BIN" \
  "${ZOXIDE_BIN:+1}" "$ZOXIDE_VER" "$ITERS" \
  "${ZNAV_BENCH_WARMUP_STEPS:-1500}" "${ZNAV_BENCH_TRACE_STEPS:-5000}" \
  "${CHPWD_US[znav_50]}" "${CHPWD_US[znav_500]}" "${CHPWD_US[znav_2000]}" \
  "${CHPWD_US[cdr_50]}" "${CHPWD_US[cdr_500]}" "${CHPWD_US[cdr_2000]}" \
  "${CHPWD_US[fork_50]}" "${CHPWD_US[fork_500]}" "${CHPWD_US[fork_2000]}" \
  "${CHPWD_US[zoxide_50]}" "${CHPWD_US[zoxide_500]}" "${CHPWD_US[zoxide_2000]}" \
  "${JUMP_US[tilde_static]}" "${JUMP_US[tilde_dyn]}" "${JUMP_US[cd_tilde]}" \
  "${JUMP_US[jump_j]}" "${JUMP_US[cdr_dyn]}" "${JUMP_US[cdr_jump]}" \
  "${JUMP_US[ext_floor]}" "${JUMP_US[zo_jump]}" \
  "$info_json" <<'PYEOF'
import json
import sys
from pathlib import Path

(
    _,
    json_path,
    hw,
    arch,
    os_label,
    zsh_ver,
    zsh_bin,
    zo_avail_s,
    zo_ver,
    iters_s,
    warmup_s,
    trace_s,
    z50, z500, z2000,
    c50, c500, c2000,
    f50, f500, f2000,
    zo50, zo500, zo2000,
    j_tilde, j_dyn, j_cd_tilde, j_j, j_cdr_dyn, j_cdr_jump, j_ext_floor, j_zo,
    info_raw,
) = sys.argv


def parse_opt_us(s: str) -> float | None:
    if not s or s == "N/A":
        return None
    return round(float(s), 2)


def ratio_str(slow: float | None, fast: float | None) -> str:
    if slow is None or fast is None or fast <= 0.0:
        return "N/A"
    return f"{slow / fast:.1f}x"


zo_avail = bool(zo_avail_s)
z50_f, z500_f, z2000_f = parse_opt_us(z50), parse_opt_us(z500), parse_opt_us(z2000)
c50_f, c500_f, c2000_f = parse_opt_us(c50), parse_opt_us(c500), parse_opt_us(c2000)
f50_f, f500_f, f2000_f = parse_opt_us(f50), parse_opt_us(f500), parse_opt_us(f2000)
zo50_f, zo500_f, zo2000_f = parse_opt_us(zo50), parse_opt_us(zo500), parse_opt_us(zo2000)

jt_f = parse_opt_us(j_tilde)
jd_f = parse_opt_us(j_dyn)
jcd_f = parse_opt_us(j_cd_tilde)
jj_f = parse_opt_us(j_j)
jcdrd_f = parse_opt_us(j_cdr_dyn)
jcdrj_f = parse_opt_us(j_cdr_jump)
jext_f = parse_opt_us(j_ext_floor)
jzo_f = parse_opt_us(j_zo)

ext_base_val = jzo_f if jzo_f is not None else jext_f
ext_base_name = "zoxide" if jzo_f is not None else "ext_jump_floor"

for required_name, required_val in [
    ("znav_50", z50_f), ("znav_500", z500_f), ("znav_2000", z2000_f),
    ("cdr_50", c50_f), ("cdr_500", c500_f), ("cdr_2000", c2000_f),
    ("fork_50", f50_f), ("fork_500", f500_f), ("fork_2000", f2000_f),
    ("tilde_static", jt_f), ("tilde_dynamic", jd_f), ("cd_tilde", jcd_f),
    ("jump_j", jj_f), ("cdr_dynamic", jcdrd_f), ("cdr_jump", jcdrj_f),
    ("ext_jump_floor", jext_f),
]:
    if required_val is None:
        raise RuntimeError(f"Missing benchmark measurement for {required_name}")

payload = {
    "schema_version": 1,
    "environment": {
        "hardware": hw,
        "arch": arch,
        "os": os_label,
        "zsh_version": zsh_ver,
        "zsh_bin": zsh_bin,
        "zoxide_available": zo_avail,
        "zoxide_version": zo_ver if zo_avail else None,
        "iterations": int(iters_s),
    },
    "chpwd_latency_us": {
        "50": {
            "znav": z50_f,
            "cdr": c50_f,
            "fork_floor": f50_f,
            "zoxide": zo50_f,
        },
        "500": {
            "znav": z500_f,
            "cdr": c500_f,
            "fork_floor": f500_f,
            "zoxide": zo500_f,
        },
        "2000": {
            "znav": z2000_f,
            "cdr": c2000_f,
            "fork_floor": f2000_f,
            "zoxide": zo2000_f,
            "speedup_vs_cdr": ratio_str(c2000_f, z2000_f),
            "speedup_vs_zoxide": ratio_str(zo2000_f, z2000_f),
            "cdr_vs_zoxide": ratio_str(zo2000_f, c2000_f),
        },
    },
    "jump_latency_us": {
        "n_dirs": 500,
        "tilde_static": jt_f,
        "tilde_dynamic": jd_f,
        "cd_tilde": jcd_f,
        "jump_j": jj_f,
        "cdr_dynamic": jcdrd_f,
        "cdr_jump": jcdrj_f,
        "ext_jump_floor": jext_f,
        "zoxide_jump": jzo_f,
        "external_baseline": ext_base_name,
        "speedups_vs_external": {
            "tilde_static": ratio_str(ext_base_val, jt_f),
            "tilde_dynamic": ratio_str(ext_base_val, jd_f),
            "cd_tilde": ratio_str(ext_base_val, jcd_f),
            "jump_j": ratio_str(ext_base_val, jj_f),
        },
    },
    "info_efficiency": {
        "zipf_s": 1.2,
        "warmup_steps": int(warmup_s),
        "trace_steps": int(trace_s),
        "alphabet_size": 36,
        "trees": json.loads(info_raw),
    },
}

out_p = Path(json_path)
out_p.parent.mkdir(parents=True, exist_ok=True)
out_p.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"\n[OK] Wrote structured benchmark JSON to {out_p}")
PYEOF

if (( UPDATE_README )); then
  "$PYTHON_BIN" "$BENCH_DIR/update_readme.py" \
    --results "$RESULTS_JSON" \
    --results-md "$RESULTS_MD" \
    --readme "$README_PATH"
else
  "$PYTHON_BIN" "$BENCH_DIR/update_readme.py" \
    --results "$RESULTS_JSON" \
    --results-md "$RESULTS_MD" \
    --no-readme
fi
