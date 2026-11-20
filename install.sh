#!/usr/bin/env zsh
# Symlink installer for zsh-znav (`znav`/`j` navigation engine and `_znav` completion).
# SPDX-License-Identifier: MIT

emulate -L zsh
set -euo pipefail

REPO_DIR="${0:A:h}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Installs `zsh-znav` (`znav`, `j`, `~code` named directories, and `_znav`
completion) from this repository into your local Zsh configuration.

Options:
  --omz-plugin      Link as an Oh My Zsh plugin under $ZSH_CUSTOM/plugins/zsh-znav (default when Oh My Zsh is present)
  --omz-custom      Link zsh-znav.zsh + completions/_znav directly into $ZSH_CUSTOM
  --zsh-dir <dir>   Link autoload functions into <dir> (default fallback: ~/.local/share/zsh/site-functions)
  --import-zoxide   Seed initial frecency scores from `zoxide query -ls` via `znav import --zoxide`
  --no-compile      Skip compiling .zwc Zsh wordcode files
  --dry-run         Print actions without modifying the filesystem
  -h, --help        Show this help
EOF
}

mode=""
zsh_dir_override=""
import_zoxide=0
no_compile=0
dry_run=0

while (( $# > 0 )); do
  case "$1" in
    --omz-plugin)
      mode="omz-plugin"
      ;;
    --omz-custom)
      mode="omz-custom"
      ;;
    --zsh-dir)
      shift
      (( $# > 0 )) || { print -u2 "Error: --zsh-dir requires a directory argument"; exit 1; }
      zsh_dir_override="$1"
      mode="site-functions"
      ;;
    --zsh-dir=*)
      zsh_dir_override="${1#--zsh-dir=}"
      [[ -n "$zsh_dir_override" ]] || { print -u2 "Error: --zsh-dir requires a directory argument"; exit 1; }
      mode="site-functions"
      ;;
    --import-zoxide)
      import_zoxide=1
      ;;
    --no-compile)
      no_compile=1
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

omz_custom="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
if [[ -z "$mode" ]]; then
  if [[ -d "$omz_custom" || -d "${ZSH:-$HOME/.oh-my-zsh}" ]]; then
    mode="omz-plugin"
  else
    mode="site-functions"
  fi
fi

run_link() {
  local src="$1" dst="$2"
  if (( dry_run )); then
    print -r -- "[dry-run] ln -sfn $src $dst"
    return 0
  fi
  command mkdir -p "${dst:h}"
  command chmod 755 "${dst:h}" 2>/dev/null || true
  command ln -sfn "$src" "$dst"
  print -r -- "==> Linked $dst -> $src"
}

refresh_zcompdump() {
  if (( dry_run )); then
    print -r -- "[dry-run] refresh ~/.zcompdump*"
    return 0
  fi
  local zdot="${ZDOTDIR:-$HOME}"
  command rm -f "$zdot"/.zcompdump*(N)
  print -r -- "==> Cleared stale Zsh completion dump in $zdot"
}

case "$mode" in
  omz-plugin)
    run_link "$REPO_DIR/zsh-znav.plugin.zsh" "$omz_custom/plugins/zsh-znav/zsh-znav.plugin.zsh"
    run_link "$REPO_DIR/functions/_znav" "$omz_custom/plugins/zsh-znav/_znav"
    ;;
  omz-custom)
    run_link "$REPO_DIR/zsh-znav.plugin.zsh" "$omz_custom/zsh-znav.zsh"
    run_link "$REPO_DIR/functions/_znav" "$omz_custom/completions/_znav"
    ;;
  site-functions)
    target_dir="${zsh_dir_override:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions}"
    for fn_src in "$REPO_DIR"/functions/*(.N); do
      [[ "$fn_src" == *.zwc || "$fn_src" == *.zwc.old ]] && continue
      run_link "$fn_src" "$target_dir/${fn_src:t}"
    done
    ;;
esac

if (( ! no_compile )); then
  if (( dry_run )); then
    print -r -- "[dry-run] znav compile ($REPO_DIR/*.zwc, $REPO_DIR/functions/*.zwc)"
  else
    ZNAV_AUTO_SEED=0 ZNAV_CDABLE_VARS=0 \
      /bin/zsh -fc 'source "$1/znav.plugin.zsh" && znav compile' -- "$REPO_DIR"
    print -r -- "==> Compiled Zsh .zwc wordcode in $REPO_DIR"
  fi
fi

refresh_zcompdump

data_dir="${ZNAV_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/znav}"
if [[ ! -d "$data_dir" ]]; then
  if (( dry_run )); then
    print -r -- "[dry-run] initialize Day-0 \$HOME depth-1 seed in $data_dir"
  else
    ZNAV_DATA_DIR="$data_dir" ZNAV_AUTO_SEED=1 ZNAV_CDABLE_VARS=0 \
      /bin/zsh -fc 'source "$1/znav.plugin.zsh" && znav compact' -- "$REPO_DIR"
    print -r -- "==> Seeded Day-0 \$HOME depth-1 directories in $data_dir"
  fi
fi

if (( import_zoxide )); then
  if (( dry_run )); then
    print -r -- "[dry-run] znav import --zoxide into $data_dir"
  else
    ZNAV_DATA_DIR="$data_dir" ZNAV_AUTO_SEED=0 ZNAV_CDABLE_VARS=0 \
      /bin/zsh -fc 'source "$1/znav.plugin.zsh" && znav import --zoxide' -- "$REPO_DIR"
    print -r -- "==> Imported zoxide history into $data_dir"
  fi
fi

case "$mode" in
  omz-plugin)
    print -r -- "==> Ensure 'zsh-znav' is listed in plugins=(...) in ~/.zshrc"
    ;;
  site-functions)
    target_dir="${zsh_dir_override:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions}"
    print -r -- "==> Ensure '$target_dir' is in \$fpath and add 'source $REPO_DIR/zsh-znav.plugin.zsh' to ~/.zshrc"
    ;;
esac

print -r -- "==> Done! Open a new terminal or reload your shell (e.g. 'source ~/.zshrc' or 'exec zsh')."
