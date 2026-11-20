#!/usr/bin/env zsh
# Cleanly remove symlinks and wordcode artifacts installed by ./install.sh.
# SPDX-License-Identifier: MIT

emulate -L zsh
set -euo pipefail

REPO_DIR="${0:A:h}"

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Cleanly removes symlinks and compiled .zwc wordcode created by ./install.sh.

Options:
  --zsh-dir <dir>   Also remove function symlinks from <dir>
  --purge-data      Also remove $ZNAV_DATA_DIR (~/.local/share/znav)
  --dry-run         Print actions without modifying the filesystem
  -h, --help        Show this help
EOF
}

zsh_dir_override=""
purge_data=0
dry_run=0

while (( $# > 0 )); do
  case "$1" in
    --zsh-dir)
      shift
      (( $# > 0 )) || { print -u2 "Error: --zsh-dir requires a directory argument"; exit 1; }
      zsh_dir_override="$1"
      ;;
    --zsh-dir=*)
      zsh_dir_override="${1#--zsh-dir=}"
      ;;
    --purge-data)
      purge_data=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -r -- "Error: unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

remove_if_ours() {
  local target_path="$1"
  if [[ -L "$target_path" ]]; then
    local resolved="${target_path:A}"
    if [[ "$resolved" == "$REPO_DIR"/* ]]; then
      if (( dry_run )); then
        print -r -- "[dry-run] rm -f $target_path"
      else
        command rm -f "$target_path"
        print -r -- "==> Removed $target_path"
      fi
    fi
  fi
}

omz_custom="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
remove_if_ours "$omz_custom/zsh-znav.zsh"
remove_if_ours "$omz_custom/znav.zsh"
remove_if_ours "$omz_custom/completions/_znav"
remove_if_ours "$omz_custom/plugins/zsh-znav/zsh-znav.plugin.zsh"
remove_if_ours "$omz_custom/plugins/zsh-znav/_znav"
if [[ -d "$omz_custom/plugins/zsh-znav" ]]; then
  if (( dry_run )); then
    print -r -- "[dry-run] rmdir $omz_custom/plugins/zsh-znav"
  else
    command rmdir "$omz_custom/plugins/zsh-znav" 2>/dev/null || true
  fi
fi

site_dir="${zsh_dir_override:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions}"
for fn_name in znav _znav _znav_chpwd _znav_directory_name _znav_zshexit _znav_precmd_once; do
  remove_if_ours "$site_dir/$fn_name"
done

typeset -a zwc_files=(
  "$REPO_DIR"/*.zwc(N)
  "$REPO_DIR"/*.zwc.old(N)
  "$REPO_DIR"/functions/*.zwc(N)
  "$REPO_DIR"/functions/*.zwc.old(N)
)
if (( ${#zwc_files} > 0 )); then
  if (( dry_run )); then
    print -r -- "[dry-run] rm -f ${zwc_files[*]}"
  else
    command rm -f "${zwc_files[@]}"
    print -r -- "==> Removed compiled .zwc wordcode files in $REPO_DIR"
  fi
fi

if (( purge_data )); then
  data_dir="${ZNAV_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/znav}"
  if [[ -d "$data_dir" ]]; then
    if (( dry_run )); then
      print -r -- "[dry-run] rm -rf $data_dir"
    else
      command rm -rf "$data_dir"
      print -r -- "==> Removed data directory $data_dir"
    fi
  fi
fi

zdot="${ZDOTDIR:-$HOME}"
if (( dry_run )); then
  print -r -- "[dry-run] refresh $zdot/.zcompdump*"
else
  command rm -f "$zdot"/.zcompdump*(N)
  print -r -- "==> Cleared Zsh completion dump in $zdot"
fi
