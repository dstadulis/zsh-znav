# znav.plugin.zsh — Formally Verified, Zero-Fork Directory Navigation for Zsh
#
# Architecture:
#   1. O(1) Overflow-Safe Log-Epoch Frecency Monoid (zsh/datetime + zsh/mathfunc)
#   2. Strict Total Order (succ) & Segment-Initialism Candidate Lattice K(d)
#   3. O(1)-in-N Incremental Top-M Static Named Directory Projection (hash -d)
#   4. Dynamic Named Directory Protocol (zsh_directory_name: ~[code], ~[a:b])
#   5. Crash-Safe Append-Only WAL + Atomic Lock-Protected Compaction (zsh/files)
#
# Zero external binaries, zero subshells, zero forks across startup and all hot paths.

() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops

  # Load Zsh C modules selectively so standard commands (mv, mkdir, rm, stat) are never shadowed.
  zmodload zsh/datetime
  zmodload zsh/mathfunc
  zmodload zsh/parameter
  zmodload -i zsh/system 2>/dev/null || true
  zmodload -F zsh/files b:zf_mv b:zf_mkdir b:zf_rm b:zf_rmdir

  # Resolve plugin root and prepend functions/ to $fpath without forks or (%) nicechar mangling.
  local _plugin_src=${funcfiletrace[1]%:*}
  [[ -z $_plugin_src || ! -e $_plugin_src ]] && _plugin_src=$1
  typeset -g ZNAV_PLUGIN_DIR=${_plugin_src:A:h}
  if (( ! ${fpath[(Ie)$ZNAV_PLUGIN_DIR/functions]} )); then
    fpath=("$ZNAV_PLUGIN_DIR/functions" $fpath)
  fi

  # Public configuration defaults (all user-overridable prior to or after sourcing).
  typeset -g ZNAV_DATA_DIR=${ZNAV_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/znav}
  typeset -g ZNAV_HALF_LIFE=${ZNAV_HALF_LIFE:-259200.0}
  typeset -g ZNAV_MAX_NAMEDDIRS=${ZNAV_MAX_NAMEDDIRS:-256}
  typeset -g ZNAV_AVOID_COMMANDS=${ZNAV_AVOID_COMMANDS:-1}
  typeset -g ZNAV_CMD=${ZNAV_CMD:-j}
  typeset -g ZNAV_PROMPT_DYNAMIC=${ZNAV_PROMPT_DYNAMIC:-0}
  typeset -g ZNAV_P10K_PROMPT=${ZNAV_P10K_PROMPT:-both}
  typeset -g ZNAV_AUTO_SEED=${ZNAV_AUTO_SEED:-1}
  typeset -g ZNAV_CDABLE_VARS=${ZNAV_CDABLE_VARS:-1}
  typeset -g ZNAV_PWD_CODE=""

  # Internal global engine state.
  typeset -g  REPLY=""
  typeset -ga reply=()
  typeset -gA _ZNAV_SCORE=()
  typeset -gA _ZNAV_DIR2CODE=()
  typeset -gA _ZNAV_CODE2DIR=()
  typeset -gA _ZNAV_OWNED_NAMEDDIRS=()
  typeset -gA _ZNAV_P10K_SAVED_ND=()
  typeset -gA _ZNAV_USER_CACHE=()
  typeset -gA _ZNAV_CAND_CACHE=()
  typeset -gA _ZNAV_TOP_POS=()
  typeset -ga _ZNAV_TOP_DIRS=()
  typeset -ga _ZNAV_RANKED_DIRS=()
  typeset -g  _ZNAV_HOME_RAW=""
  typeset -g  _ZNAV_HOME_CANON=""
  typeset -gi _ZNAV_WAL_LINES=0
  typeset -gi _ZNAV_CACHE_VALID=0
  typeset -gi _ZNAV_ALL_DIRTY=1
  typeset -gi _ZNAV_LAST_SCORE_COUNT=-1
  typeset -gi _ZNAV_LAST_AVOID_CMDS=-1
  typeset -gi _ZNAV_LAST_MAX_NAMEDDIRS=-1
  typeset -gi _ZNAV_P10K_AUTO_INJECTED=0
} "$0"

# ---------------------------------------------------------------------------
# Core Zero-Fork Utilities & Security Sanitizers
# ---------------------------------------------------------------------------

_znav_now() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  float -E 17 _t
  local _zn=${ZNAV_NOW:-} _uzn=${_ZNAV_NOW:-}
  if [[ -n $_zn && $_zn == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]]; then
    (( _t = _zn ))
  elif [[ -n $_uzn && $_uzn == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]]; then
    (( _t = _uzn ))
  else
    (( _t = EPOCHREALTIME ))
  fi
  REPLY=$_t
}

_znav_half_life() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _raw_hl=${ZNAV_HALF_LIFE:-}
  float -E 17 _hl=259200.0
  if [[ -n $_raw_hl && $_raw_hl == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]]; then
    (( _hl = _raw_hl ))
    (( _hl > 0.0 && _hl < 1.7e308 )) || _hl=259200.0
  fi
  REPLY=$_hl
}

_znav_sanitize_display() {
  # Escapes ASCII C0/DEL, UTF-8 C1 controls (\xc2[\x80-\x9f] incl. CSI \xc2\x9b),
  # and Trojan Source BiDi codepoints (U+202A..U+202E, U+2066..U+2069, U+061C)
  # for human-facing terminal strings while preserving valid UTF-8 (e.g. 日本) intact.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _s=$1
  if [[ $_s != *[$'\x00'-$'\x1f'$'\x7f'$'\xc2'$'\xd8'$'\xe2']* ]]; then
    REPLY=$_s
    return 0
  fi
  local _out="" _c1 _c2 _c3 _hex
  integer _i=1 _n=${#_s} _b1 _b2 _b3
  while (( _i <= _n )); do
    _c1=${_s[_i]}
    _b1=$(( #_c1 & 255 ))
    if (( _b1 < 0x20 || _b1 == 0x7F )); then
      case $_b1 in
        (9)  _out+='\t' ;;
        (10) _out+='\n' ;;
        (13) _out+='\r' ;;
        (*)  builtin printf -v _hex '\\x%02x' $_b1; _out+=$_hex ;;
      esac
      (( _i++ ))
    elif (( _b1 == 0xC2 && _i + 1 <= _n )); then
      _c2=${_s[_i+1]}
      _b2=$(( #_c2 & 255 ))
      if (( _b2 >= 0x80 && _b2 <= 0x9F )); then
        builtin printf -v _hex '\\u00%02x' $_b2
        _out+=$_hex
        (( _i += 2 ))
      else
        _out+=$_c1
        (( _i++ ))
      fi
    elif (( _b1 == 0xD8 && _i + 1 <= _n )); then
      _c2=${_s[_i+1]}
      _b2=$(( #_c2 & 255 ))
      if (( _b2 == 0x9C )); then
        _out+='\u061c'
        (( _i += 2 ))
      else
        _out+=$_c1
        (( _i++ ))
      fi
    elif (( _b1 == 0xE2 && _i + 2 <= _n )); then
      _c2=${_s[_i+1]}
      _c3=${_s[_i+2]}
      _b2=$(( #_c2 & 255 ))
      _b3=$(( #_c3 & 255 ))
      if (( _b2 == 0x80 && _b3 >= 0xAA && _b3 <= 0xAE )); then
        builtin printf -v _hex '\\u20%02x' $(( 0x2A + (_b3 - 0xAA) ))
        _out+=$_hex
        (( _i += 3 ))
      elif (( _b2 == 0x81 && _b3 >= 0xA6 && _b3 <= 0xA9 )); then
        builtin printf -v _hex '\\u20%02x' $(( 0x66 + (_b3 - 0xA6) ))
        _out+=$_hex
        (( _i += 3 ))
      else
        _out+=$_c1
        (( _i++ ))
      fi
    else
      _out+=$_c1
      (( _i++ ))
    fi
  done
  REPLY=$_out
}

_znav_unquote_path() {
  # Cross-locale lossless unquoting under LC_ALL=C + no_multibyte.
  # Converts any $'...\uHHHH...' / $'...\UHHHHHHHH...' escapes into UTF-8 octal
  # escapes prior to ${(Q)} so C-locale shells never fail charset conversion.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _q=$1
  if [[ $_q == "\$'"*"'" && $_q == *\\[uU]* ]]; then
    local _body=${_q[3,-2]} _out="" _ch _nx _hex _esc
    integer _i=1 _n=${#_body} _cp _k _maxd
    while (( _i <= _n )); do
      _ch=${_body[_i]}
      if [[ $_ch == '\' ]] && (( _i < _n )); then
        _nx=${_body[_i+1]}
        if [[ $_nx == (u|U) ]]; then
          [[ $_nx == u ]] && _maxd=4 || _maxd=8
          _hex=""
          (( _k = _i + 2 ))
          while (( _k <= _n && ${#_hex} < _maxd )) && [[ ${_body[_k]} == [0-9A-Fa-f] ]]; do
            _hex+=${_body[_k]}
            (( _k++ ))
          done
          if (( ${#_hex} > 0 )); then
            (( _cp = 16#$_hex ))
            if (( _cp <= 0x7F )); then
              builtin printf -v _esc '\\%03o' $_cp
            elif (( _cp <= 0x7FF )); then
              builtin printf -v _esc '\\%03o\\%03o' $(( 0xC0 | (_cp >> 6) )) $(( 0x80 | (_cp & 0x3F) ))
            elif (( _cp <= 0xFFFF )); then
              builtin printf -v _esc '\\%03o\\%03o\\%03o' $(( 0xE0 | (_cp >> 12) )) $(( 0x80 | ((_cp >> 6) & 0x3F) )) $(( 0x80 | (_cp & 0x3F) ))
            elif (( _cp <= 0x10FFFF )); then
              builtin printf -v _esc '\\%03o\\%03o\\%03o\\%03o' $(( 0xF0 | (_cp >> 18) )) $(( 0x80 | ((_cp >> 12) & 0x3F) )) $(( 0x80 | ((_cp >> 6) & 0x3F) )) $(( 0x80 | (_cp & 0x3F) ))
            else
              _esc="\\${_nx}${_hex}"
            fi
            _out+=$_esc
            _i=$_k
            continue
          fi
        fi
        _out+="${_ch}${_nx}"
        (( _i += 2 ))
        continue
      fi
      _out+=$_ch
      (( _i++ ))
    done
    _q="\$'${_out}'"
  fi
  REPLY=${(Q)_q}
}

_znav_canon_path() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _raw=$1
  [[ -z $_raw ]] && return 1
  local _c=${_raw:A}
  [[ -z $_c ]] && return 1
  if [[ $_c != / ]]; then
    _c=${_c%/}
    [[ -z $_c ]] && _c=/
  fi
  REPLY=$_c
  return 0
}

_znav_ensure_data_dir() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  [[ -d $ZNAV_DATA_DIR ]] || zf_mkdir -p -- "$ZNAV_DATA_DIR"
}

_znav_update_pwd_code() {
  # Updates public scalar ZNAV_PWD_CODE in O(1) time with 0 forks.
  # Optional $1: pre-canonicalized PWD path (avoids second :A lookup on chpwd).
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _canon=${1:-}
  if [[ -z $_canon ]]; then
    local _raw=${PWD:-}
    if [[ -z $_raw ]]; then
      typeset -g ZNAV_PWD_CODE=""
      return 0
    fi
    _canon=${_raw:A}
    [[ $_canon != / ]] && _canon=${_canon%/}
    [[ -z $_canon ]] && _canon=/
  fi
  if [[ -n ${HOME:-} ]]; then
    if [[ $HOME != ${_ZNAV_HOME_RAW:-} ]]; then
      typeset -g _ZNAV_HOME_RAW=$HOME
      local _hc=${HOME:A}
      [[ $_hc != / ]] && _hc=${_hc%/}
      typeset -g _ZNAV_HOME_CANON=${_hc:-/}
    fi
    if [[ $_canon == $_ZNAV_HOME_CANON ]]; then
      typeset -g ZNAV_PWD_CODE=""
      return 0
    fi
  fi
  local _c=${_ZNAV_DIR2CODE[$_canon]:-}
  if (( $+_ZNAV_SCORE[$_canon] && $+_ZNAV_TOP_POS[$_canon] )) && [[ -n $_c && ${_ZNAV_CODE2DIR[$_c]:-} == $_canon && ${nameddirs[$_c]:-} == $_canon ]]; then
    typeset -g ZNAV_PWD_CODE=$_c
  else
    typeset -g ZNAV_PWD_CODE=""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Primitive 1: Overflow-Safe Log-Epoch Frecency Monoid (R u {-inf}, (+)_tau)
# ---------------------------------------------------------------------------

_znav_lse_fold_tmp() {
  # Folds event timestamp $2 into scratch associative array _ZNAV_TMP_MAP[$1]
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _d=$1
  float -E 17 _x=$2
  if [[ -z ${_ZNAV_TMP_MAP[$_d]+x} ]]; then
    _ZNAV_TMP_MAP[$_d]=$_x
    return 0
  fi
  local _raw_cur=${_ZNAV_TMP_MAP[$_d]} _raw_hl=${ZNAV_HALF_LIFE:-}
  float -E 17 _cur _hl=259200.0 _tau _mx _diff _next
  (( _cur = _raw_cur ))
  if [[ -n $_raw_hl && $_raw_hl == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]]; then
    (( _hl = _raw_hl ))
    (( _hl > 0.0 && _hl < 1.7e308 )) || _hl=259200.0
  fi
  (( _tau = _hl / log(2.0) ))
  (( _mx = _cur >= _x ? _cur : _x ))
  (( _diff = _cur >= _x ? _cur - _x : _x - _cur ))
  (( _next = _mx + _tau * log(1.0 + exp(-_diff / _tau)) ))
  _ZNAV_TMP_MAP[$_d]=$_next
}

_znav_lse_fold_score() {
  # Fast-path O(1) direct fold into _ZNAV_SCORE[$1] with event timestamp $2
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _d=$1
  float -E 17 _x=$2
  if (( _ZNAV_LAST_SCORE_COUNT != ${#_ZNAV_SCORE} )); then
    _ZNAV_CACHE_VALID=0
  fi
  if [[ -z ${_ZNAV_SCORE[$_d]+x} ]]; then
    _ZNAV_SCORE[$_d]=$_x
    _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
    return 0
  fi
  local _raw_cur=${_ZNAV_SCORE[$_d]} _raw_hl=${ZNAV_HALF_LIFE:-}
  float -E 17 _cur _hl=259200.0 _tau _mx _diff _next
  (( _cur = _raw_cur ))
  if [[ -n $_raw_hl && $_raw_hl == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]]; then
    (( _hl = _raw_hl ))
    (( _hl > 0.0 && _hl < 1.7e308 )) || _hl=259200.0
  fi
  (( _tau = _hl / log(2.0) ))
  (( _mx = _cur >= _x ? _cur : _x ))
  (( _diff = _cur >= _x ? _cur - _x : _x - _cur ))
  (( _next = _mx + _tau * log(1.0 + exp(-_diff / _tau)) ))
  _ZNAV_SCORE[$_d]=$_next
  _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
}

# ---------------------------------------------------------------------------
# Strict Total Order (succ) & Native C-qsort Ranking
# ---------------------------------------------------------------------------

_znav_gt() {
  # Returns 0 (true) iff canonical directory $1 strictly precedes $2 under succ.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _a=$1 _b=$2
  [[ $_a == $_b ]] && return 1
  local _ra=${_ZNAV_SCORE[$_a]:--1e300} _rb=${_ZNAV_SCORE[$_b]:--1e300}
  float -E 17 _la _lb
  (( _la = _ra ))
  (( _lb = _rb ))
  if (( _la != _lb )); then
    (( _la > _lb )) && return 0 || return 1
  fi
  integer _da=0 _db=0
  if [[ $_a != / ]]; then
    local _sa=${_a//[^\/]/}
    _da=${#_sa}
  fi
  if [[ $_b != / ]]; then
    local _sb=${_b//[^\/]/}
    _db=${#_sb}
  fi
  if (( _da != _db )); then
    (( _da < _db )) && return 0 || return 1
  fi
  integer _lena=${#_a} _lenb=${#_b}
  if (( _lena != _lenb )); then
    (( _lena < _lenb )) && return 0 || return 1
  fi
  # Compare exact unsigned UTF-8 byte values (avoids Zsh metafied 0x83..0xA2 strcmp inversion).
  integer _i
  local _ca _cb
  for (( _i = 1; _i <= _lena; _i++ )); do
    _ca=${_a[_i]}
    _cb=${_b[_i]}
    [[ $_ca == $_cb ]] && continue
    (( (#_ca & 255) < (#_cb & 255) )) && return 0 || return 1
  done
  return 1
}

_znav_sort_dirs() {
  # Sorts all keys of _ZNAV_SCORE in descending succ order into _ZNAV_RANKED_DIRS.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  _ZNAV_RANKED_DIRS=()
  (( ${#_ZNAV_SCORE} == 0 )) && return 0

  local -a _rows=() _sorted=()
  local _d _raw_sc _sci _mant _exp_s _slashes _key
  float -E 17 _sc
  integer _bkt _exp _ek _mk _depth _blen

  for _d in "${(@k)_ZNAV_SCORE}"; do
    _raw_sc=${_ZNAV_SCORE[$_d]}
    (( _sc = _raw_sc ))
    builtin printf -v _sci '%+.17e' $_sc
    _mant=${_sci[2,20]//./}
    _exp_s=${_sci#*e}
    (( _exp = _exp_s ))
    if (( _sc > 0.0 )); then
      _bkt=0
      (( _ek = 9999 - (_exp + 5000) ))
      (( _mk = 999999999999999999 - 10#$_mant ))
    elif (( _sc == 0.0 )); then
      _bkt=1
      _ek=5000
      _mk=0
    else
      _bkt=2
      (( _ek = _exp + 5000 ))
      (( _mk = 10#$_mant ))
    fi
    if [[ $_d == / ]]; then
      _depth=0
    else
      _slashes=${_d//[^\/]/}
      _depth=${#_slashes}
    fi
    _blen=${#_d}
    builtin printf -v _key '%d:%04d:%018d:%06d:%06d' $_bkt $_ek $_mk $_depth $_blen
    _rows+=("${_key}"$'\x1f'"${_d}")
  done

  _sorted=("${(@o)_rows}")
  _ZNAV_RANKED_DIRS=("${(@)_sorted#*$'\x1f'}")

  # Exact adjacent tie-check pass for subnormal / ulp edge fidelity
  integer _n=${#_ZNAV_RANKED_DIRS} _i
  local _tmp
  for (( _i = 1; _i < _n; _i++ )); do
    if _znav_gt "${_ZNAV_RANKED_DIRS[_i+1]}" "${_ZNAV_RANKED_DIRS[_i]}"; then
      _tmp=${_ZNAV_RANKED_DIRS[_i]}
      _ZNAV_RANKED_DIRS[_i]=${_ZNAV_RANKED_DIRS[_i+1]}
      _ZNAV_RANKED_DIRS[_i+1]=$_tmp
      (( _i > 1 )) && (( _i -= 2 ))
    fi
  done
}

# ---------------------------------------------------------------------------
# Primitive 2: ASCII Segment Tokenizer & Candidate Lattice Stream K(d)
# ---------------------------------------------------------------------------

_znav_tokenize() {
  # Sets global array `reply` to non-empty lowercase alphanumeric tokens of $1.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _s=$1
  local -a match mbegin mend
  _s=${_s//(#b)([a-z0-9])([A-Z])/${match[1]} ${match[2]}}
  _s=${_s//(#b)([A-Z])([A-Z][a-z])/${match[1]} ${match[2]}}
  _s=${(L)${_s//[^A-Za-z0-9]##/ }}
  typeset -ga reply=(${=_s})
}

_znav_candidates_finite() {
  # Sets `reply` to Tiers 1..4 of K($1), memoized in _ZNAV_CAND_CACHE[$1].
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _d=$1
  if [[ -n ${_ZNAV_CAND_CACHE[$_d]+x} ]]; then
    typeset -ga reply=(${=_ZNAV_CAND_CACHE[$_d]})
    return 0
  fi

  local -a _T=() _P=()
  if [[ $_d == / ]]; then
    _T=("root" "dir")
    _P=()
  else
    _znav_tokenize "${_d:t}"
    _T=("${reply[@]}")
    (( ${#_T} == 0 )) && _T=("dir")
    local _parent=${_d:h}
    if [[ $_parent == / || $_parent == . || -z $_parent ]]; then
      _P=()
    else
      _znav_tokenize "${_parent:t}"
      _P=("${reply[@]}")
    fi
  fi

  local -a _raw_list=() _out=()
  local -A _seen=()
  local _s

  integer _m=${#_T} _L _i
  if (( _m == 1 )); then
    local _t1=${_T[1]}
    integer _max1=$(( ${#_t1} < 8 ? ${#_t1} : 8 ))
    for (( _L = 2; _L <= _max1; _L++ )); do
      _raw_list+=("${_t1[1,_L]}")
    done
  else
    if (( _m > 4 )); then
      local _init8=""
      integer _lim8=$(( _m < 8 ? _m : 8 ))
      for (( _i = 1; _i <= _lim8; _i++ )); do
        _init8+=${_T[_i][1]}
      done
      _raw_list+=("$_init8")
    fi

    integer _meff=$(( _m < 4 ? _m : 4 ))
    if (( _meff == 2 )); then
      local _u1=${_T[1]} _u2=${_T[2]}
      integer _c1=${#_u1} _c2=${#_u2} _l1 _l2 _hi1 _lo1
      for (( _L = 2; _L <= 6; _L++ )); do
        (( _hi1 = _c1 < _L - 1 ? _c1 : _L - 1 ))
        (( _lo1 = 1 > _L - _c2 ? 1 : _L - _c2 ))
        for (( _l1 = _hi1; _l1 >= _lo1; _l1-- )); do
          (( _l2 = _L - _l1 ))
          _raw_list+=("${_u1[1,_l1]}${_u2[1,_l2]}")
        done
      done
    elif (( _meff == 3 )); then
      local _u1=${_T[1]} _u2=${_T[2]} _u3=${_T[3]}
      integer _c1=${#_u1} _c2=${#_u2} _c3=${#_u3}
      integer _l1 _l2 _l3 _hi1 _lo1 _rem1 _hi2 _lo2
      for (( _L = 3; _L <= 6; _L++ )); do
        (( _hi1 = _c1 < _L - 2 ? _c1 : _L - 2 ))
        (( _lo1 = 1 > _L - _c2 - _c3 ? 1 : _L - _c2 - _c3 ))
        for (( _l1 = _hi1; _l1 >= _lo1; _l1-- )); do
          (( _rem1 = _L - _l1 ))
          (( _hi2 = _c2 < _rem1 - 1 ? _c2 : _rem1 - 1 ))
          (( _lo2 = 1 > _rem1 - _c3 ? 1 : _rem1 - _c3 ))
          for (( _l2 = _hi2; _l2 >= _lo2; _l2-- )); do
            (( _l3 = _rem1 - _l2 ))
            _raw_list+=("${_u1[1,_l1]}${_u2[1,_l2]}${_u3[1,_l3]}")
          done
        done
      done
    else
      local _u1=${_T[1]} _u2=${_T[2]} _u3=${_T[3]} _u4=${_T[4]}
      integer _c1=${#_u1} _c2=${#_u2} _c3=${#_u3} _c4=${#_u4}
      integer _l1 _l2 _l3 _l4 _hi1 _lo1 _rem1 _hi2 _lo2 _rem2 _hi3 _lo3
      for (( _L = 4; _L <= 6; _L++ )); do
        (( _hi1 = _c1 < _L - 3 ? _c1 : _L - 3 ))
        (( _lo1 = 1 > _L - _c2 - _c3 - _c4 ? 1 : _L - _c2 - _c3 - _c4 ))
        for (( _l1 = _hi1; _l1 >= _lo1; _l1-- )); do
          (( _rem1 = _L - _l1 ))
          (( _hi2 = _c2 < _rem1 - 2 ? _c2 : _rem1 - 2 ))
          (( _lo2 = 1 > _rem1 - _c3 - _c4 ? 1 : _rem1 - _c3 - _c4 ))
          for (( _l2 = _hi2; _l2 >= _lo2; _l2-- )); do
            (( _rem2 = _rem1 - _l2 ))
            (( _hi3 = _c3 < _rem2 - 1 ? _c3 : _rem2 - 1 ))
            (( _lo3 = 1 > _rem2 - _c4 ? 1 : _rem2 - _c4 ))
            for (( _l3 = _hi3; _l3 >= _lo3; _l3-- )); do
              (( _l4 = _rem2 - _l3 ))
              _raw_list+=("${_u1[1,_l1]}${_u2[1,_l2]}${_u3[1,_l3]}${_u4[1,_l4]}")
            done
          done
        done
      done
    fi
  fi

  # Tier 3: Normalized Basename
  local _b_full=${(j:_:)_T}
  _raw_list+=("${(j::)_T}" "$_b_full")

  # Tier 4: Parent Disambiguation
  integer _r=${#_P}
  if (( _r > 0 )); then
    local _p_init="" _b_init=""
    integer _pr=$(( _r < 4 ? _r : 4 ))
    integer _bm=$(( _m < 4 ? _m : 4 ))
    for (( _i = 1; _i <= _pr; _i++ )); do _p_init+=${_P[_i][1]}; done
    for (( _i = 1; _i <= _bm; _i++ )); do _b_init+=${_T[_i][1]}; done
    local _p_full=${(j:_:)_P}
    _raw_list+=("${_p_init}${_b_init}" "${_p_init}_${_b_full}" "${_p_full}_${_b_full}")
  fi

  # Single tight normalization + deduplication pass (zero inner function call overhead)
  for _s in "${_raw_list[@]}"; do
    [[ -z $_s ]] && continue
    [[ $_s == [0-9]* ]] && _s="_$_s"
    if (( ${#_s} >= 2 && !$+_seen[$_s] )); then
      _seen[$_s]=1
      _out+=("$_s")
    fi
  done

  _ZNAV_CAND_CACHE[$_d]=${(j: :)_out}
  typeset -ga reply=("${_out[@]}")
}

_znav_tier5_stem() {
  # Sets REPLY to the Tier 5 collision-free stem for canonical directory $1.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _d=$1
  local -a _T=() _P=()
  if [[ $_d == / ]]; then
    _T=("root" "dir")
  else
    _znav_tokenize "${_d:t}"
    _T=("${reply[@]}")
    (( ${#_T} == 0 )) && _T=("dir")
    local _parent=${_d:h}
    if [[ $_parent != / && $_parent != . && -n $_parent ]]; then
      _znav_tokenize "${_parent:t}"
      _P=("${reply[@]}")
    fi
  fi
  local _b_full=${(j:_:)_T}
  local _raw_stem
  if (( ${#_P} > 0 )); then
    _raw_stem="${(j:_:)_P}_${_b_full}"
  else
    _raw_stem=$_b_full
  fi
  local _stem=$_raw_stem
  [[ $_stem == [0-9]* ]] && _stem="_$_stem"
  if (( ${#_stem} < 2 )); then
    _stem="_$_raw_stem"
    (( ${#_stem} < 2 )) && _stem="_dir"
  fi
  REPLY=$_stem
}

# ---------------------------------------------------------------------------
# Reserved Namespace Protection R & Greedy Bijection Projector
# ---------------------------------------------------------------------------

_znav_is_reserved() {
  # Returns 0 (true) if identifier $1 is in reserved set R, 1 (false) otherwise.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_nomatch no_multibyte
  local LC_ALL=C
  local _k=$1
  [[ $_k == [a-z_][a-z0-9_]## ]] || return 0
  [[ $_k == znav || $_k == j ]] && return 0
  [[ -n ${ZNAV_CMD:-} && ${ZNAV_CMD} != none && $_k == $ZNAV_CMD ]] && return 0

  if [[ -n ${ZNAV_AVOID_COMMANDS:-} && ${ZNAV_AVOID_COMMANDS} != [+-]#0## ]]; then
    if (( $+commands[$_k] || $+builtins[$_k] || $+functions[$_k] || $+aliases[$_k] || ${reswords[(Ie)$_k]} )); then
      return 0
    fi
  fi

  (( $+userdirs[$_k] )) && return 0

  if (( $+nameddirs[$_k] )); then
    if (( ! $+_ZNAV_OWNED_NAMEDDIRS[$_k] )); then
      return 0
    fi
    # Detect if user manually overrode a znav-owned nameddir via `hash -d k=/custom`
    if [[ ${nameddirs[$_k]} != ${_ZNAV_OWNED_NAMEDDIRS[$_k]} ]]; then
      unset "_ZNAV_OWNED_NAMEDDIRS[$_k]"
      return 0
    fi
  fi

  # Check OS user via getpwnam tilde probe (cached; must run when $_k is not in $nameddirs)
  if (( $+_ZNAV_USER_CACHE[$_k] )); then
    (( _ZNAV_USER_CACHE[$_k] )) && return 0 || return 1
  fi

  if (( ! $+nameddirs[$_k] )); then
    local _t="~$_k"
    local _exp=${~_t}
    if [[ $_exp != $_t ]]; then
      _ZNAV_USER_CACHE[$_k]=1
      return 0
    else
      _ZNAV_USER_CACHE[$_k]=0
      return 1
    fi
  fi

  return 1
}

_znav_pick_code_for_dir() {
  # Picks earliest candidate in K($1) not in _ZNAV_USED_CODES and not in R. Sets REPLY.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _d=$1 _cand
  _znav_candidates_finite "$_d"
  local -a _cands=("${reply[@]}")
  for _cand in "${_cands[@]}"; do
    if (( ! $+_ZNAV_USED_CODES[$_cand] )) && ! _znav_is_reserved "$_cand"; then
      REPLY=$_cand
      return 0
    fi
  done

  _znav_tier5_stem "$_d"
  local _stem=$REPLY
  if (( ! $+_ZNAV_USED_CODES[$_stem] )) && ! _znav_is_reserved "$_stem"; then
    REPLY=$_stem
    return 0
  fi

  integer _idx=2
  while true; do
    _cand="${_stem}_${_idx}"
    if (( ! $+_ZNAV_USED_CODES[$_cand] )) && ! _znav_is_reserved "$_cand"; then
      REPLY=$_cand
      return 0
    fi
    (( _idx++ ))
  done
}

_znav_apply_nameddirs_top() {
  # Projects _ZNAV_TOP_DIRS -> _ZNAV_DIR2CODE into Zsh C nameddirs hash table safely.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _raw_max=${ZNAV_MAX_NAMEDDIRS:-}
  integer _max=256
  if [[ -z $_raw_max ]]; then
    _max=0
  elif [[ $_raw_max == [+-]#<-> ]]; then
    (( _max = _raw_max > 0 ? _raw_max : 0 ))
  fi
  local -A _desired=()
  local _d _code
  integer _i _lim=$(( ${#_ZNAV_TOP_DIRS} < _max ? ${#_ZNAV_TOP_DIRS} : _max ))

  for (( _i = 1; _i <= _lim; _i++ )); do
    _d=${_ZNAV_TOP_DIRS[_i]}
    _code=${_ZNAV_DIR2CODE[$_d]:-}
    [[ -n $_code ]] && _desired[$_code]=$_d
  done

  # Remove previously owned nameddirs that are no longer desired (and weren't overridden by user)
  for _code in "${(@k)_ZNAV_OWNED_NAMEDDIRS}"; do
    if (( ! $+_desired[$_code] )); then
      if [[ ${nameddirs[$_code]:-} == ${_ZNAV_OWNED_NAMEDDIRS[$_code]} ]]; then
        builtin unhash -d -- "$_code" 2>/dev/null || true
      fi
      unset "_ZNAV_OWNED_NAMEDDIRS[$_code]"
    fi
  done

  # Install new/updated static nameddirs in Zsh C hash table
  for _code _d in "${(@kv)_desired}"; do
    if [[ ${nameddirs[$_code]:-} != $_d ]]; then
      builtin hash -d -- "${_code}=${_d}"
    fi
    _ZNAV_OWNED_NAMEDDIRS[$_code]=$_d
  done
}

_znav_rebuild_projections() {
  # Full O(N log N) descending-succ bijection & static hash -d sync.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops

  _znav_sort_dirs
  _ZNAV_DIR2CODE=()
  _ZNAV_CODE2DIR=()
  _ZNAV_TOP_DIRS=()
  _ZNAV_TOP_POS=()

  typeset -gA _ZNAV_USED_CODES=()
  local _d _code _raw_max=${ZNAV_MAX_NAMEDDIRS:-}
  integer _idx=0 _max=256 _avoid=1
  [[ -z ${ZNAV_AVOID_COMMANDS:-} || ${ZNAV_AVOID_COMMANDS:-} == [+-]#0## ]] && _avoid=0
  if [[ -z $_raw_max ]]; then
    _max=0
  elif [[ $_raw_max == [+-]#<-> ]]; then
    (( _max = _raw_max > 0 ? _raw_max : 0 ))
  fi

  for _d in "${_ZNAV_RANKED_DIRS[@]}"; do
    (( _idx++ ))
    _znav_pick_code_for_dir "$_d"
    _code=$REPLY
    _ZNAV_USED_CODES[$_code]=1
    _ZNAV_DIR2CODE[$_d]=$_code
    _ZNAV_CODE2DIR[$_code]=$_d
    if (( _idx <= _max )); then
      _ZNAV_TOP_DIRS+=("$_d")
      _ZNAV_TOP_POS[$_d]=$_idx
    fi
  done
  unset _ZNAV_USED_CODES

  _znav_apply_nameddirs_top
  _ZNAV_CACHE_VALID=1
  _ZNAV_ALL_DIRTY=0
  _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
  _ZNAV_LAST_AVOID_CMDS=$_avoid
  _ZNAV_LAST_MAX_NAMEDDIRS=$_max
  _znav_update_pwd_code
}

_znav_sync_visit() {
  # O(1)-in-N incremental top-M ranking & shortcode update after visiting directory $1.
  # Relies on Time-Translation Order Invariance + No-Hijack Prefix Stability!
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _d=$1 _raw_max=${ZNAV_MAX_NAMEDDIRS:-}
  integer _max=256 _avoid=1
  [[ -z ${ZNAV_AVOID_COMMANDS:-} || ${ZNAV_AVOID_COMMANDS:-} == [+-]#0## ]] && _avoid=0
  if [[ -z $_raw_max ]]; then
    _max=0
  elif [[ $_raw_max == [+-]#<-> ]]; then
    (( _max = _raw_max > 0 ? _raw_max : 0 ))
  fi

  if (( !_ZNAV_CACHE_VALID || _ZNAV_LAST_AVOID_CMDS != _avoid || _ZNAV_LAST_MAX_NAMEDDIRS != _max )); then
    _znav_rebuild_projections
    return 0
  fi

  # Detect external mutation of _ZNAV_SCORE (e.g. test harness reset)
  if (( _ZNAV_LAST_SCORE_COUNT != ${#_ZNAV_SCORE} )); then
    _znav_rebuild_projections
    return 0
  fi

  if (( _max == 0 )); then
    _ZNAV_ALL_DIRTY=1
    return 0
  fi

  integer _k=${#_ZNAV_TOP_DIRS}
  integer _old_pos=${_ZNAV_TOP_POS[$_d]:-0}

  # Verify cached entry integrity
  if (( _old_pos > 0 )); then
    if (( _old_pos > _k )) || [[ ${_ZNAV_TOP_DIRS[_old_pos]:-} != $_d ]]; then
      _znav_rebuild_projections
      return 0
    fi
  fi

  local _cur_code=${_ZNAV_DIR2CODE[$_d]:-}

  # Fast Path A: Already #1 in top-M and nameddir still intact -> 0 rank/bijection changes!
  if (( _old_pos == 1 )) && [[ -n $_cur_code && ${nameddirs[$_cur_code]:-} == $_d ]] && ! _znav_is_reserved "$_cur_code"; then
    return 0
  fi

  # Fast Path B: In top-M at _old_pos > 1, and predecessor still strictly precedes $_d -> 0 changes!
  if (( _old_pos > 1 )) && _znav_gt "${_ZNAV_TOP_DIRS[_old_pos-1]}" "$_d"; then
    if [[ -n $_cur_code && ${nameddirs[$_cur_code]:-} == $_d ]] && ! _znav_is_reserved "$_cur_code"; then
      return 0
    fi
  fi

  # Fast Path C: Outside top-M, top-M is full (_k == _max), and M-th entry still strictly precedes $_d!
  if (( _old_pos == 0 && _k >= _max )) && _znav_gt "${_ZNAV_TOP_DIRS[_max]}" "$_d"; then
    _ZNAV_ALL_DIRTY=1
    return 0
  fi

  # Incremental bubble within top-M (at most M <= 256 elements, strictly O(1) wrt total N!)
  integer _pos
  if (( _old_pos == 0 )); then
    _ZNAV_TOP_DIRS+=("$_d")
    (( _pos = ${#_ZNAV_TOP_DIRS} ))
    _ZNAV_TOP_POS[$_d]=$_pos
  else
    _pos=$_old_pos
  fi

  local _prev_d
  while (( _pos > 1 )); do
    _prev_d=${_ZNAV_TOP_DIRS[_pos-1]}
    if _znav_gt "$_d" "$_prev_d"; then
      _ZNAV_TOP_DIRS[_pos]=$_prev_d
      _ZNAV_TOP_POS[$_prev_d]=$_pos
      (( _pos-- ))
    else
      break
    fi
  done
  _ZNAV_TOP_DIRS[_pos]=$_d
  _ZNAV_TOP_POS[$_d]=$_pos

  # Evict (M+1)-th entry if insertion overflowed _max
  if (( ${#_ZNAV_TOP_DIRS} > _max )); then
    local _evicted=${_ZNAV_TOP_DIRS[_max+1]}
    local _ev_code=${_ZNAV_DIR2CODE[$_evicted]:-}
    if [[ -n $_ev_code && ${_ZNAV_CODE2DIR[$_ev_code]:-} == $_evicted ]]; then
      unset "_ZNAV_CODE2DIR[$_ev_code]"
    fi
    {
      setopt localoptions no_multibyte
      local LC_ALL=C
      _ZNAV_DIR2CODE=("${(@kv)_ZNAV_DIR2CODE[(I)^${(b)_evicted}]}")
      _ZNAV_TOP_POS=("${(@kv)_ZNAV_TOP_POS[(I)^${(b)_evicted}]}")
    }
    _ZNAV_TOP_DIRS=("${_ZNAV_TOP_DIRS[1,_max]}")
    _ZNAV_ALL_DIRTY=1
  fi

  # By No-Hijack Stability, ranks 1 .. (_pos - 1) keep their exact assigned shortcodes!
  typeset -gA _ZNAV_USED_CODES=()
  integer _i _new_k=${#_ZNAV_TOP_DIRS} _changed=0 _converged=0
  local _td _tc _old_c
  for (( _i = 1; _i < _pos; _i++ )); do
    _td=${_ZNAV_TOP_DIRS[_i]}
    _tc=${_ZNAV_DIR2CODE[$_td]:-}
    if [[ -z $_tc ]] || _znav_is_reserved "$_tc"; then
      unset _ZNAV_USED_CODES
      _znav_rebuild_projections
      return 0
    fi
    _ZNAV_USED_CODES[$_tc]=1
  done

  for (( _i = _pos; _i <= _new_k; _i++ )); do
    _td=${_ZNAV_TOP_DIRS[_i]}
    _old_c=${_ZNAV_DIR2CODE[$_td]:-}
    if [[ -n $_old_c && ${_ZNAV_CODE2DIR[$_old_c]:-} == $_td ]]; then
      unset "_ZNAV_CODE2DIR[$_old_c]"
    fi
    _znav_pick_code_for_dir "$_td"
    _tc=$REPLY
    _ZNAV_USED_CODES[$_tc]=1
    _ZNAV_DIR2CODE[$_td]=$_tc
    _ZNAV_CODE2DIR[$_tc]=$_td
    if [[ $_tc != $_old_c || ${nameddirs[$_tc]:-} != $_td ]]; then
      _changed=1
    fi
    # Convergence Early-Exit: if $_d moved within top-M (_old_pos > 0) and every
    # directory in [_pos .. _old_pos] retained its exact shortcode, then the used
    # shortcode set after _old_pos is unchanged, so [_old_pos+1 .. _new_k] are invariant!
    if (( _old_pos > 0 && _i == _old_pos && !_changed )); then
      _converged=1
      break
    fi
  done
  unset _ZNAV_USED_CODES

  if (( ${#_ZNAV_SCORE} > _new_k )); then
    _ZNAV_ALL_DIRTY=1
  else
    _ZNAV_RANKED_DIRS=("${_ZNAV_TOP_DIRS[@]}")
    _ZNAV_ALL_DIRTY=0
  fi

  if (( !_converged )); then
    _znav_apply_nameddirs_top
  fi
}

_znav_ensure_full_bijection() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _raw_max=${ZNAV_MAX_NAMEDDIRS:-}
  integer _max=256 _avoid=1
  [[ -z ${ZNAV_AVOID_COMMANDS:-} || ${ZNAV_AVOID_COMMANDS:-} == [+-]#0## ]] && _avoid=0
  if [[ -z $_raw_max ]]; then
    _max=0
  elif [[ $_raw_max == [+-]#<-> ]]; then
    (( _max = _raw_max > 0 ? _raw_max : 0 ))
  fi
  if (( !_ZNAV_CACHE_VALID || _ZNAV_ALL_DIRTY || _ZNAV_LAST_SCORE_COUNT != ${#_ZNAV_SCORE} || _ZNAV_LAST_AVOID_CMDS != _avoid || _ZNAV_LAST_MAX_NAMEDDIRS != _max )); then
    _znav_rebuild_projections
  fi
}

# ---------------------------------------------------------------------------
# WAL Persistence, Atomic Compaction & Lazy Pruning
# ---------------------------------------------------------------------------

_znav_wal_append() {
  # Usage: _znav_wal_append <kind:V|I|D|S> <ts_float> <canon_dir>
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _kind=$1 _d=$3
  float -E 17 _ts=$2
  _znav_ensure_data_dir
  local _wal="$ZNAV_DATA_DIR/wal.log"
  local _ts_str
  builtin printf -v _ts_str '%.17g' $_ts
  builtin print -r -- "${_kind} ${_ts_str} ${(qqqq)_d}" >> "$_wal"
  (( _ZNAV_WAL_LINES++ ))

  integer _thresh=$(( 2 * ${#_ZNAV_SCORE} + 64 ))
  if (( _ZNAV_WAL_LINES > _thresh )); then
    _znav_compact_impl 1
  fi
}

_znav_replay_into_tmp() {
  # Replays a db.tsv or wal.log file ($1) directly into _ZNAV_TMP_MAP (safe for all path chars).
  # Sets REPLY to processed line count.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  local _file=$1
  [[ -r $_file ]] || { REPLY=0; return 0; }

  integer _lines=0
  local _kind _ts_s _qpath _d
  float -E 17 _val
  while IFS=$' \t' read -r _kind _ts_s _qpath; do
    [[ -z $_kind || $_kind == \#* ]] && continue
    (( _lines++ ))
    [[ -z $_qpath ]] && continue
    _znav_unquote_path "$_qpath"
    _d=$REPLY
    [[ -z $_d ]] && continue
    case $_kind in
      (S)
        [[ $_ts_s == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]] || continue
        (( _val = _ts_s ))
        (( _val > -1.7e308 && _val < 1.7e308 )) || continue
        _ZNAV_TMP_MAP[$_d]=$_val
        ;;
      (I)
        [[ $_ts_s == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]] || continue
        if [[ -z ${_ZNAV_TMP_MAP[$_d]+x} ]]; then
          (( _val = _ts_s ))
          (( _val > -1.7e308 && _val < 1.7e308 )) || continue
          _ZNAV_TMP_MAP[$_d]=$_val
        fi
        ;;
      (V)
        [[ $_ts_s == [+-]#(<->|<->.<->|<->.|.<->)([eE][+-]#<->|) ]] || continue
        (( _val = _ts_s ))
        (( _val > -1.7e308 && _val < 1.7e308 )) || continue
        _znav_lse_fold_tmp "$_d" "$_val"
        ;;
      (D)
        if [[ -n ${_ZNAV_TMP_MAP[$_d]+x} ]]; then
          _ZNAV_TMP_MAP=("${(@kv)_ZNAV_TMP_MAP[(I)^${(b)_d}]}")
        fi
        ;;
    esac
  done < "$_file"
  REPLY=$_lines
}

_znav_load_db() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  _ZNAV_SCORE=()
  _ZNAV_WAL_LINES=0
  _ZNAV_CACHE_VALID=0
  _ZNAV_ALL_DIRTY=1

  [[ -d $ZNAV_DATA_DIR ]] || return 0
  typeset -gA _ZNAV_TMP_MAP=()
  _znav_replay_into_tmp "$ZNAV_DATA_DIR/db.tsv"
  if [[ -r "$ZNAV_DATA_DIR/wal.compacting" ]]; then
    _znav_replay_into_tmp "$ZNAV_DATA_DIR/wal.compacting"
  fi
  if [[ -r "$ZNAV_DATA_DIR/wal.log" ]]; then
    _znav_replay_into_tmp "$ZNAV_DATA_DIR/wal.log"
    _ZNAV_WAL_LINES=$REPLY
  fi
  _ZNAV_SCORE=("${(@kv)_ZNAV_TMP_MAP}")
  unset _ZNAV_TMP_MAP
  _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
}

_znav_compact_impl() {
  # Atomic multi-shell-safe compaction using kernel mkdir lock + zf_mv rename.
  # Optional $1=1 means opportunistic background call (skip quietly if locked).
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local LC_ALL=C
  integer _opportunistic=0
  [[ ${1:-0} == <-> ]] && _opportunistic=$(( 10#${1:-0} ))
  _znav_ensure_data_dir

  local _lock="$ZNAV_DATA_DIR/compact.lock"
  if ! zf_mkdir -- "$_lock" 2>/dev/null; then
    (( _opportunistic )) && return 0
    # Reclaim stale lock if holder crashed; retry once
    zf_rmdir -- "$_lock" 2>/dev/null || zf_rm -rf -- "$_lock" 2>/dev/null || true
    zf_mkdir -- "$_lock" 2>/dev/null || return 0
  fi

  {
    local _db="$ZNAV_DATA_DIR/db.tsv"
    local _wal="$ZNAV_DATA_DIR/wal.log"
    local _wcomp="$ZNAV_DATA_DIR/wal.compacting"
    local _tmp="$ZNAV_DATA_DIR/db.tsv.tmp.$$"

    typeset -gA _ZNAV_TMP_MAP=()

    # 1. Read committed snapshot from disk
    if [[ -r $_db ]]; then
      _znav_replay_into_tmp "$_db"
    fi
    # 2. Replay any leftover wal.compacting from an interrupted prior run
    if [[ -r $_wcomp ]]; then
      _znav_replay_into_tmp "$_wcomp"
      zf_rm -f -- "$_wcomp" 2>/dev/null || true
    fi
    # 3. Atomically rotate active wal.log -> wal.compacting and replay
    if [[ -f $_wal ]]; then
      if zf_mv -f -- "$_wal" "$_wcomp" 2>/dev/null; then
        _znav_replay_into_tmp "$_wcomp"
      else
        _znav_replay_into_tmp "$_wal"
      fi
    fi
    # 4. Also merge any in-memory entries if disk files were absent
    if (( ${#_ZNAV_TMP_MAP} == 0 && ${#_ZNAV_SCORE} > 0 )); then
      _ZNAV_TMP_MAP=("${(@kv)_ZNAV_SCORE}")
    fi

    # 5. Write deterministic snapshot and atomically rename into place
    local -a _out_lines=()
    local _d _raw_v _val_s
    float -E 17 _v
    for _d in "${(@ok)_ZNAV_TMP_MAP}"; do
      _raw_v=${_ZNAV_TMP_MAP[$_d]}
      (( _v = _raw_v ))
      builtin printf -v _val_s '%.17g' $_v
      _out_lines+=("S ${_val_s} ${(qqqq)_d}")
    done

    if (( ${#_out_lines} > 0 )); then
      builtin print -rl -- "${_out_lines[@]}" > "$_tmp"
    else
      : > "$_tmp"
    fi
    zf_mv -f -- "$_tmp" "$_db"
    [[ -f $_wcomp ]] && zf_rm -f -- "$_wcomp" 2>/dev/null || true

    # 6. Replay any concurrent wal.log lines appended during steps 3-5
    integer _rem_wal=0
    if [[ -r $_wal ]]; then
      _znav_replay_into_tmp "$_wal"
      _rem_wal=$REPLY
    fi

    # 7. Synchronize current shell state with exact merged snapshot
    _ZNAV_SCORE=("${(@kv)_ZNAV_TMP_MAP}")
    unset _ZNAV_TMP_MAP
    _ZNAV_WAL_LINES=$_rem_wal
    _znav_rebuild_projections
  } always {
    zf_rmdir -- "$_lock" 2>/dev/null || zf_rm -rf -- "$_lock" 2>/dev/null || true
  }
}

_znav_prune_missing() {
  # Removes any tracked directories that no longer exist on disk. Sets REPLY to pruned count.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local -a _dead=()
  local -A _keep=()
  local _d _v
  for _d _v in "${(@kv)_ZNAV_SCORE}"; do
    if [[ -d $_d ]]; then
      _keep[$_d]=$_v
    else
      _dead+=("$_d")
    fi
  done
  if (( ${#_dead} == 0 )); then
    _znav_update_pwd_code
    REPLY=0
    return 0
  fi
  _ZNAV_SCORE=("${(@kv)_keep}")
  _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
  _znav_now
  float -E 17 _now=$REPLY
  for _d in "${_dead[@]}"; do
    _znav_wal_append D "$_now" "$_d"
  done
  _znav_rebuild_projections
  REPLY=${#_dead}
  return 0
}

# ---------------------------------------------------------------------------
# Multi-Token Query Resolver resolve(Q) (Conforming 1-to-1 with znav_spec.py)
# ---------------------------------------------------------------------------

_znav_ordered_substrings() {
  # Returns 0 iff lowercased tokens $2..$# appear in order (non-overlapping) in $1.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops no_multibyte
  local _rem=$1
  shift
  local _tok
  for _tok in "$@"; do
    [[ $_rem == *"$_tok"* ]] || return 1
    _rem=${_rem#*"$_tok"}
  done
  return 0
}

_znav_matches_primary() {
  # Usage: _znav_matches_primary <canon_dir> <q_low_1> ... <q_low_r>
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _d=$1
  shift
  (( $# == 0 )) && return 1

  if (( $# == 1 )); then
    local _q1=$1
    _znav_candidates_finite "$_d"
    if (( ${reply[(Ie)$_q1]} )); then
      return 0
    fi
  fi

  local _d_low=${(L)_d}
  local _base_low=""
  [[ $_d != / ]] && _base_low=${(L)${_d:t}}
  local _last=${argv[-1]}
  {
    setopt localoptions no_multibyte
    [[ $_base_low == *"$_last"* ]] || return 1
  }
  _znav_ordered_substrings "$_d_low" "$@"
}

_znav_resolve() {
  # Usage: _znav_resolve <colon_flag:0|1> <tok1> [tok2 ...]
  # Resolves over existing directories in _ZNAV_SCORE (lazily pruning dead hits).
  # Sets REPLY to winning canonical path and returns 0, or returns 1 if none.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  integer _colon=0
  [[ ${1:-0} == <-> ]] && _colon=$(( 10#${1:-0} ))
  shift

  local -a _q_raw=() _q_low=()
  local _t
  for _t in "$@"; do
    if [[ -n $_t ]]; then
      _q_raw+=("$_t")
      _q_low+=("${(L)_t}")
    fi
  done
  (( ${#_q_low} == 0 )) && return 1

  # O(1) Top-M Shortcode Fast Path: By No-Hijack Prefix Stability, top-M shortcodes
  # in _ZNAV_CODE2DIR are 100% exact even when tail ranks > M have _ZNAV_ALL_DIRTY=1!
  integer _avoid=1
  [[ -z ${ZNAV_AVOID_COMMANDS:-} || ${ZNAV_AVOID_COMMANDS:-} == [+-]#0## ]] && _avoid=0
  if (( !_colon && ${#_q_raw} == 1 && _ZNAV_CACHE_VALID && _ZNAV_LAST_SCORE_COUNT == ${#_ZNAV_SCORE} && _ZNAV_LAST_AVOID_CMDS == _avoid )); then
    local _fq0=${_q_raw[1]} _fq0l=${_q_low[1]} _fhit=""
    if [[ -n ${_ZNAV_CODE2DIR[$_fq0]+x} ]]; then
      _fhit=${_ZNAV_CODE2DIR[$_fq0]}
    elif [[ -n ${_ZNAV_CODE2DIR[$_fq0l]+x} ]]; then
      _fhit=${_ZNAV_CODE2DIR[$_fq0l]}
    fi
    if [[ -n $_fhit && ( !_ZNAV_ALL_DIRTY || -n ${_ZNAV_TOP_POS[$_fhit]+x} ) && -d $_fhit ]]; then
      REPLY=$_fhit
      return 0
    fi
  fi

  integer _retried=0
  while true; do
    _znav_ensure_full_bijection
    (( ${#_ZNAV_SCORE} == 0 )) && return 1

    # 1. Exact Shortcode Lookup (for single-token non-colon queries)
    if (( !_colon && ${#_q_raw} == 1 )); then
      local _q0=${_q_raw[1]} _q0l=${_q_low[1]} _hit=""
      if [[ -n ${_ZNAV_CODE2DIR[$_q0]+x} ]]; then
        _hit=${_ZNAV_CODE2DIR[$_q0]}
      elif [[ -n ${_ZNAV_CODE2DIR[$_q0l]+x} ]]; then
        _hit=${_ZNAV_CODE2DIR[$_q0l]}
      fi
      if [[ -n $_hit ]]; then
        if [[ -d $_hit ]]; then
          REPLY=$_hit
          return 0
        elif (( !_retried )); then
          _retried=1
          _znav_prune_missing
          continue
        fi
      fi
    fi

    # 2. Primary (succ)-maximal intrinsic match
    local _d
    for _d in "${_ZNAV_RANKED_DIRS[@]}"; do
      if _znav_matches_primary "$_d" "${_q_low[@]}"; then
        if [[ -d $_d ]]; then
          REPLY=$_d
          return 0
        elif (( !_retried )); then
          _retried=1
          _znav_prune_missing
          continue 2
        fi
      fi
    done

    # 3. Fallback (succ)-maximal ordered substring match anywhere along lower(d)
    for _d in "${_ZNAV_RANKED_DIRS[@]}"; do
      if _znav_ordered_substrings "${(L)_d}" "${_q_low[@]}"; then
        if [[ -d $_d ]]; then
          REPLY=$_d
          return 0
        elif (( !_retried )); then
          _retried=1
          _znav_prune_missing
          continue 2
        fi
      fi
    done

    break
  done

  return 1
}

_znav_seed_roots() {
  # Seeds unseen immediate non-hidden subdirectories of "$@" (default: $HOME) at t0 - H.
  # Sets REPLY to count of newly seeded directories.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local LC_ALL=C
  local -a _roots=("$@")
  (( ${#_roots} == 0 )) && [[ -n ${HOME:-} ]] && _roots=("$HOME")

  _znav_now
  float -E 17 _t0=$REPLY _hl _init_score
  _znav_half_life
  _hl=$REPLY
  (( _init_score = _t0 - _hl ))

  integer _added=0
  local _root _sub _canon
  local -a _subs=()
  for _root in "${_roots[@]}"; do
    [[ -d $_root ]] || continue
    _subs=("$_root"/*(/N))
    for _sub in "${(@o)_subs}"; do
      _znav_canon_path "$_sub" || continue
      _canon=$REPLY
      if [[ -z ${_ZNAV_SCORE[$_canon]+x} ]]; then
        _ZNAV_SCORE[$_canon]=$_init_score
        _ZNAV_LAST_SCORE_COUNT=${#_ZNAV_SCORE}
        _znav_wal_append I "$_init_score" "$_canon"
        (( _added++ ))
      fi
    done
  done

  if (( _added > 0 || !_ZNAV_CACHE_VALID )); then
    _znav_rebuild_projections
  else
    _znav_update_pwd_code
  fi
  REPLY=$_added
  return 0
}

# ---------------------------------------------------------------------------
# Powerlevel10k Zero-Fork Full-Path + Shortcode Prompt Integration
# ---------------------------------------------------------------------------

_znav_p10k_stash_nameddirs() {
  # Temporarily removes znav-owned entries from $nameddirs (preserving manual user hash -d).
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  _ZNAV_P10K_SAVED_ND=()
  local _k _v
  for _k _v in "${(@kv)_ZNAV_OWNED_NAMEDDIRS}"; do
    if [[ ${nameddirs[$_k]:-} == $_v ]]; then
      _ZNAV_P10K_SAVED_ND[$_k]=$_v
    fi
  done
  if (( ${#_ZNAV_P10K_SAVED_ND} > 0 )); then
    builtin unhash -d -- "${(@k)_ZNAV_P10K_SAVED_ND}" 2>/dev/null || true
  fi
}

_znav_p10k_unstash_nameddirs() {
  # Unconditionally restores stashed znav-owned entries into $nameddirs.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  if (( ${#_ZNAV_P10K_SAVED_ND} > 0 )); then
    local -a _pairs=()
    local _k _v
    for _k _v in "${(@kv)_ZNAV_P10K_SAVED_ND}"; do
      _pairs+=("${_k}=${_v}")
    done
    builtin hash -d -- "${_pairs[@]}"
    _ZNAV_P10K_SAVED_ND=()
  fi
}

prompt_znav() {
  if [[ -z ${_znav_in_instant:-} || ${_znav_in_instant} == 0 ]]; then
    case ${ZNAV_P10K_PROMPT:-both} in
      path|off) return 0 ;;
    esac
    _znav_update_pwd_code
  fi
  (( ${+functions[p10k]} )) || return 0
  p10k segment \
    -b "${POWERLEVEL9K_ZNAV_BACKGROUND-0}" \
    -f "${POWERLEVEL9K_ZNAV_FOREGROUND-3}" \
    -c '$ZNAV_PWD_CODE' \
    -e \
    -t '~$ZNAV_PWD_CODE'
}

instant_prompt_znav() {
  local -i _znav_in_instant=1
  prompt_znav
}

_znav_p10k_wrap_prompt_dir() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  if (( $+functions[prompt_dir] )) && [[ $functions[prompt_dir] != *_znav_orig_prompt_dir* ]]; then
    functions[_znav_orig_prompt_dir]="0=prompt_dir"$'\n'"$functions[prompt_dir]"
    prompt_dir() {
      case ${ZNAV_P10K_PROMPT:-both} in
        off)
          _znav_orig_prompt_dir "$@"
          return $?
          ;;
        shortcode)
          if [[ -z ${funcstack[(r)instant_prompt_dir]:-} ]]; then
            _znav_update_pwd_code
            [[ -n ${ZNAV_PWD_CODE:-} ]] && return 0
          fi
          ;;
      esac
      local _znav_rc=0
      _znav_p10k_stash_nameddirs
      {
        local ZNAV_PROMPT_DYNAMIC=0
        _znav_orig_prompt_dir "$@"
        _znav_rc=$?
      } always {
        _znav_p10k_unstash_nameddirs
      }
      return $_znav_rc
    }
  fi
}

_znav_p10k_reconcile() {
  # Idempotently reconciles prompt_dir wrapper, znav prompt element injection,
  # and Powerlevel10k ephemeral dir cache according to $ZNAV_P10K_PROMPT.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops
  local _mode=${ZNAV_P10K_PROMPT:-both}
  integer _changed=0

  _znav_p10k_wrap_prompt_dir

  if [[ $_mode == (both|shortcode) ]]; then
    if (( $+parameters[POWERLEVEL9K_LEFT_PROMPT_ELEMENTS] || $+parameters[POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS] )); then
      local -a _left=() _right=()
      (( $+parameters[POWERLEVEL9K_LEFT_PROMPT_ELEMENTS] )) && _left=("${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}")
      (( $+parameters[POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS] )) && _right=("${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS[@]}")
      if (( ! ${_left[(I)znav(|_joined)]} && ! ${_right[(I)znav(|_joined)]} )); then
        integer _lidx=${_left[(i)dir(|_joined)]}
        if (( _lidx <= ${#_left} )); then
          if (( _lidx < ${#_left} )); then
            typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
              "${(@)_left[1,_lidx]}"
              znav
              "${(@)_left[_lidx+1,-1]}"
            )
          else
            typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
              "${(@)_left}"
              znav
            )
          fi
          _ZNAV_P10K_AUTO_INJECTED=1
          _changed=1
        else
          integer _ridx=${_right[(i)dir(|_joined)]}
          if (( _ridx <= ${#_right} )); then
            if (( _ridx < ${#_right} )); then
              typeset -ga POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
                "${(@)_right[1,_ridx]}"
                znav
                "${(@)_right[_ridx+1,-1]}"
              )
            else
              typeset -ga POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
                "${(@)_right}"
                znav
              )
            fi
            _ZNAV_P10K_AUTO_INJECTED=1
            _changed=1
          fi
        fi
      fi
    elif (( $+functions[p10k] )) && [[ -n "${parameters[(I)POWERLEVEL9K_*~POWERLEVEL9K_(MODE|CONFIG_FILE|GITSTATUS_DIR)]}" || ( -n ${__p9k_configured:-} && ${__p9k_configured} != [+-]#0## ) ]]; then
      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir znav vcs)
      _ZNAV_P10K_AUTO_INJECTED=1
      _changed=1
    fi
  elif (( _ZNAV_P10K_AUTO_INJECTED )); then
    if (( $+parameters[POWERLEVEL9K_LEFT_PROMPT_ELEMENTS] && ${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[(Ie)znav]} )); then
      typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=("${(@)POWERLEVEL9K_LEFT_PROMPT_ELEMENTS:#znav}")
      _changed=1
    fi
    if (( $+parameters[POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS] && ${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS[(Ie)znav]} )); then
      typeset -ga POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=("${(@)POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS:#znav}")
      _changed=1
    fi
    _ZNAV_P10K_AUTO_INJECTED=0
  fi

  if (( $+parameters[_p9k__cache_ephemeral] )); then
    _p9k__cache_ephemeral=()
  fi

  REPLY=$_changed
  return 0
}

_znav_p10k_setup() {
  # Installs idempotent Powerlevel10k wrappers (prompt_dir + p10k reload hook)
  # and reconciles segment elements without console output or forks.
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops

  # Avoid wrapping the temporary instant-prompt p10k stub before powerlevel10k.zsh-theme loads.
  if (( $+functions[p10k] )) && [[ $functions[p10k] != *_znav_orig_p10k* ]] && { (( ! $+__p9k_instant_prompt_active )) || (( $+functions[prompt_dir] )); }; then
    functions[_znav_orig_p10k]="0=p10k"$'\n'"$functions[p10k]"
    p10k() {
      if [[ ${1:-} == reload && $# -eq 1 ]]; then
        _znav_p10k_reconcile
      fi
      _znav_orig_p10k "$@"
    }
  fi

  if [[ ${ZNAV_P10K_PROMPT:-both} == off ]] && (( ! _ZNAV_P10K_AUTO_INJECTED )); then
    return 0
  fi

  if (( $+functions[p10k] || $+functions[prompt_dir] || $+parameters[POWERLEVEL9K_LEFT_PROMPT_ELEMENTS] || $+parameters[POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS] )); then
    if (( $+__p9k_instant_prompt_active && ! $+functions[prompt_dir] )); then
      return 0
    fi
    _znav_p10k_reconcile
    (( $+_p9k__force_must_init )) && _p9k__force_must_init=1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Autoloads, Hooks, Wrapper Command & Bootstrap
# ---------------------------------------------------------------------------

() {
  emulate -L zsh
  setopt extended_glob warn_create_global typeset_silent no_short_loops

  autoload -Uz add-zsh-hook znav _znav _znav_chpwd _znav_zshexit _znav_directory_name _znav_precmd_once

  add-zsh-hook chpwd _znav_chpwd
  add-zsh-hook precmd _znav_precmd_once
  if (( ${precmd_functions[(Ie)_p9k_precmd]} )); then
    typeset -ga precmd_functions=(_znav_precmd_once "${(@)precmd_functions:#_znav_precmd_once}")
  fi
  add-zsh-hook zshexit _znav_zshexit
  add-zsh-hook zsh_directory_name _znav_directory_name

  if [[ -n ${ZNAV_CMD:-} && ${ZNAV_CMD} != none ]]; then
    functions[$ZNAV_CMD]='
      emulate -L zsh
      setopt extended_glob warn_create_global typeset_silent no_short_loops
      case ${1:-} in
        (-l|--list)    shift; znav list "$@" ;;
        (-s|--stats)   shift; znav stats "$@" ;;
        (-e|--explain) shift; znav explain "$@" ;;
        (-h|--help)    shift; znav help "$@" ;;
        (*)            znav jump "$@" ;;
      esac
    '
  fi

  if (( $+functions[compdef] )); then
    compdef _znav znav
    [[ -n ${ZNAV_CMD:-} && ${ZNAV_CMD} != none ]] && compdef _znav "$ZNAV_CMD"
  fi

  # Load persisted state and cold-start bootstrap if empty
  _znav_load_db
  if (( ${#_ZNAV_SCORE} == 0 )) && [[ -n ${ZNAV_AUTO_SEED:-} && ${ZNAV_AUTO_SEED} != [+-]#0## && -n ${HOME:-} && -d $HOME ]]; then
    _znav_seed_roots "$HOME"
  else
    _znav_rebuild_projections
  fi

  # Reconcile Powerlevel10k integration immediately if Powerlevel10k loaded before znav
  _znav_p10k_setup
}

# Persist CDABLE_VARS in caller scope when ZNAV_CDABLE_VARS=1 (default) so bare
# shortcodes (e.g. `cr`, `sr`) jump directly alongside AUTO_CD.
# Note: top-level caller scope may not have extended_glob enabled, so avoid `#` globs here.
if [[ -n ${ZNAV_CDABLE_VARS:-} && ${ZNAV_CDABLE_VARS} != 0 && ${ZNAV_CDABLE_VARS} != +0 && ${ZNAV_CDABLE_VARS} != -0 ]]; then
  builtin setopt CDABLE_VARS
fi
