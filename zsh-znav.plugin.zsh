# Zsh plugin entrypoint (Oh My Zsh, Antidote, Zinit, Sheldon, Znap, Zgenom).
# SPDX-License-Identifier: MIT

() {
  emulate -L zsh
  zmodload zsh/parameter
  local _s=${funcfiletrace[1]%:*}
  [[ -z $_s || ! -e $_s ]] && _s=$1
  typeset -g REPLY="${_s:A:h}/znav.plugin.zsh"
} "$0"
source "$REPLY"
