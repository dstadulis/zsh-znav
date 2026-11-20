# Zsh Native Directory Navigation: An Upstream Source Audit & Engineering Specification

> **Host Verification Baseline**: Audited directly against `/bin/zsh` **`zsh 5.9 (arm64-apple-darwin25.0)`** (`$ZSH_PATCHLEVEL = zsh-5.9-0-g73d3173`), upstream function library `/usr/share/zsh/5.9/functions/`, manual pages `/usr/share/man/man1/zsh*.1`, and `/opt/homebrew/bin/zoxide` (`0.10.0`) on macOS. Every claim, line reference, and code snippet below has been empirically verified in isolated `zsh -df` sessions.

---

## 0. The Problem Setting

Consider a developer workspace containing structured multi-segment directory names such as:

- `~/CODE.REPOSITORIES` (and inside it, hyphen/underscore/dot-delimited repositories such as `code-verification`, `foss-agentic-forge`, `mutual-information-education`, `terminal_O1_invocation`, `zsh-mkrepo`, `zsh-rl`)
- `~/SCRIPT.REPOS`

The goal is an **information-efficient, zero-maintenance, formally sound mechanism** in Zsh so that short semantic codes like `cr` ($\to$ `~/CODE.REPOSITORIES`) and `sr` ($\to$ `~/SCRIPT.REPOS`) work:

1. **Automatically** — derived and maintained from empirical usage without hand-curating a lookup table in `~/.zshrc`.
2. **Everywhere a path is legal** — not merely to change directories (`cd`), but inline inside arbitrary commands (`vim ~cr/znav/README.md`, `diff -u ~cr/a ~sr/b`, `git -C ~cr/znav status`, `cp report.pdf ~sr/archive/`), prompt contraction (`%~`), and tab completion.
3. **At native in-process speed** — zero `fork(2)`/`execve(2)` overhead and zero command-substitution subshells on `chpwd` or lookup.
4. **With mathematical stability** — visiting a newly created `~/CACHE.REPOS` once must never hijack `cr` away from a heavily frequented `~/CODE.REPOSITORIES`.

Before designing `znav`, we examine why manual shell aliases fail this specification and what the Zsh maintainers (principally Peter Stephenson and Sven Wischnowsky) **already built natively** inside Zsh's C core and `zshcontrib`.

---

## 1. Why Manual Directory Aliases (`alias cr='cd ~/CODE.REPOSITORIES'`) Are an Anti-Pattern

Defining manual aliases in `~/.zshrc`—such as `alias cr='cd ~/CODE.REPOSITORIES'` and `alias sr='cd ~/SCRIPT.REPOS'`—is the most common approach to directory shortcuts, and also the weakest architectural primitive Zsh offers for path addressing:

1. **Lexical Confinement (Zero Non-Command Composability)**:
   Standard Zsh aliases expand *exclusively* in lexical **command position** (the first token of a simple command, or immediately following another alias whose expansion carries a trailing space). Outside command position, `cr` is treated as a literal string:
   ```zsh
   alias cr='cd ~/CODE.REPOSITORIES'
   cr                          # Works: expands in command position
   ls cr                       # FAILS: ls: cr: No such file or directory
   vim cr/znav/README.md       # FAILS: opens a nonexistent relative path
   cp patch.diff cr/           # FAILS: copies to ./cr/ or errors out
   diff -u cr/foo sr/foo       # FAILS: neither argument expands
   ```
   Attempting to work around this with **global aliases** (`alias -g cr='~/CODE.REPOSITORIES'`) is strictly worse: global aliases blindly rewrite *every* whitespace-delimited token matching `cr` anywhere on the command line, silently corrupting commands like `git branch -d cr`, `grep cr logfile`, or `tar -cr`.

2. **Global Command-Namespace Pollution & Silent Shadowing**:
   During Zsh parsing (`Src/lex.c`), aliases expand **before** reserved words, shell functions, builtins, and `$PATH` executables (`$commands`). Two- and three-letter initialisms frequently collide with real POSIX and macOS utilities (`tr` for `TEMP.REPOS`, `pr` for `PUBLIC.REPOS`, `ar` for `ARCHIVE.REPOS`, `cc`, `ps`, `df`, `du`, `id`, `ln`, `ls`, `cp`, `od`, `wc`, `dc`, `bc`, `nl`, `nm`, `vi`). Defining `alias tr='cd ~/TEMP.REPOS'` silently hijacks `/usr/bin/tr` across all interactive pipelines with zero warning.

3. **$O(N)$ Human Curation & Silent Staleness**:
   Maintaining $N$ directory shortcuts requires $O(N)$ manual edits to `~/.zshrc`, manual conflict resolution whenever two directories share initials, and manual `source ~/.zshrc` propagation across open terminals. When directories are renamed or deleted, dead aliases remain in `aliastab` indefinitely without validation.

4. **Unconditional Startup Cost & Zero Adaptivity**:
   Every `alias` declaration is parsed and inserted into the global alias hash table during every interactive shell startup, whether a directory is visited 200 times a day or has been untouched for three years. Manual aliases encode a frozen human guess rather than adapting to the true empirical visit distribution $P(d)$.

5. **Zero Reverse-Path / Prompt Awareness**:
   Zsh's prompt escape `%~` and parameter expansion `${(D)PWD}` do not consult `aliastab`. After jumping via `cr`, the prompt still renders `~/CODE.REPOSITORIES` rather than contracting to a compact semantic token.

---

## 2. What Zsh Maintainers Already Built Natively

Zsh already ships four distinct native subsystems for fast directory addressing and navigation, each solving specific pieces of the puzzle while leaving crisp formal or computational gaps.

### 2.1 Static Named Directories (`hash -d`, `$nameddirs`, `CDABLE_VARS`, `AUTO_CD`, `AUTO_NAME_DIRS`)

#### Exact Mechanics
Inside `Src/utils.c`, Zsh maintains a dedicated C hash table (`nameddirtab`) mapping short identifiers to canonical directory strings. When `zmodload zsh/parameter` is loaded, this C table is exposed directly as the special associative array `$nameddirs`. Entries are registered explicitly with `hash -d`:

```zsh
# Register static named directories in Zsh's C nameddirtab:
hash -d cr=~/CODE.REPOSITORIES
hash -d sr=~/SCRIPT.REPOS

# Works in EVERY path argument position (zero forks, C hash lookup):
cd ~cr
vim ~cr/znav/README.md
diff -u ~cr/foo.zsh ~sr/foo.zsh
git -C ~cr/znav status

# Works in reverse path contraction (%~ prompt escape and ${(D)...} flag):
() {
  local p=~/CODE.REPOSITORIES/znav/docs
  print -r -- "${(D)p}"   # -> ~cr/znav/docs
}
```

Unlike aliases, tilde expansion (`~name`) runs as part of **filename expansion** (`Src/subst.c`) on every unquoted word beginning with `~` (and after `=` when `MAGIC_EQUAL_SUBST` is set, or after `:` in PATH-like assignments). Valid static `~name` tokens accept `[[:alnum:]_.-]+` (though pure integers like `~12` and leading `+`/`-` like `~+foo` or `~-` are intercepted by Zsh's directory-stack tilde rules before `nameddirtab` is consulted; hyphens in `hash -d` require `hash -d -- -name=/path`). Moreover, Zsh's completion system automatically completes `~<TAB>` and `~cr/<TAB>` via `/usr/share/zsh/5.9/functions/_tilde` (line 25: `compadd "$suf[@]" "$@" -k nameddirs`) and `/usr/share/zsh/5.9/functions/_tilde_files` (lines 21–22: `elif (( $+nameddirs[$user] )); then user="$nameddirs[$user]"`).

#### Combining `hash -d` with `AUTO_CD` and `CDABLE_VARS`
Zsh provides two options (`zshoptions(1)`) that eliminate even the `cd ~` prefix when jumping interactively:

- **`CDABLE_VARS`**: If the argument to `cd` is not an existing directory and does not begin with `/`, Zsh checks whether it is an entry in `nameddirtab` (or a scalar parameter whose value begins with `/`) and `cd`s to `~arg`.
- **`AUTO_CD`**: If a command word cannot be executed as a normal command (i.e., it is *not* an alias, reserved word, function, builtin, or external executable in `$commands`), **and** the shell is reading commands from standard input (`-o shinstdin`, active in interactive TTY shells and `zsh -s`, though intentionally inactive under `zsh -c`), Zsh implicitly turns the word into `cd <word>`.

When **both** options are enabled alongside `hash -d`:

```zsh
# Run in an interactive shell (or zsh -dfs reading from stdin):
setopt AUTO_CD CDABLE_VARS
hash -d cr=/tmp

cd cr    # Works in both scripts and interactive shells -> /tmp
cr       # Works whenever SHINSTDIN is active -> /tmp
```

Crucially, compare command-shadowing safety between `alias` and `hash -d` + `AUTO_CD` + `CDABLE_VARS`:
- `alias tr='cd ~/TEMP.REPOS'` **breaks `/usr/bin/tr`**.
- `hash -d tr=~/TEMP.REPOS` **never breaks `/usr/bin/tr`**, because Zsh resolves `$commands[tr]` (`/usr/bin/tr`) *before* falling back to `AUTO_CD`! Conversely, typing bare `tr` executes `/usr/bin/tr` rather than changing directories (while `~tr` and `cd ~tr` always unambiguously resolve to `~/TEMP.REPOS`). Hence an automated system that wants bare-word `CDABLE_VARS` ergonomics should reserve existing command/builtin/function/alias/reserved-word names when assigning bare-word codes.

#### Why `AUTO_NAME_DIRS` Is a Trap
Zsh also offers `setopt AUTO_NAME_DIRS` (`zshoptions(1)` lines 159–165), which promises automatic population of `nameddirtab`: in an **interactive** shell (`-o interactive`; non-interactive scripts ignore `AUTO_NAME_DIRS`), *any* parameter set to an absolute path immediately enters `nameddirtab`. Live testing in `zsh -idfc` exposes why experienced Zsh users avoid `AUTO_NAME_DIRS`:

```zsh
zsh -idfc '
  setopt AUTO_NAME_DIRS
  helper() {
    local leak_dir="/usr/share"
    print -r -- "inside helper: $(hash -d)"
  }
  helper
  print -r -- "after helper : $(hash -d)"
' 2>/dev/null
# Output:
# inside helper: leak_dir=/usr/share
# after helper :
```

Under `AUTO_NAME_DIRS`, **every** global plugin variable holding an absolute path (`ZSH=/Users/username/.oh-my-zsh`, `HOMEBREW_PREFIX=/opt/homebrew`, `TMPDIR=/var/folders/...`)—and even `local` variables inside shell functions while those functions are on the call stack—pollutes `nameddirtab`, floods `~<TAB>` completion with internal variable names, and hijacks `%~` prompt rendering (`~ZSH` or `~leak_dir`).

#### Limitations of Static Named Directories Alone
`hash -d` provides the **ideal kernel mechanism** ($O(1)$ C hash lookup, universal `~code` path expansion, `%~` prompt support, zero forks), **but** Zsh ships no native intelligence to populate or maintain it automatically. Left to the user, `hash -d` still requires $O(N)$ manual curation in `~/.zshrc` and has zero awareness of visit frequency or recency.

---

### 2.2 Dynamic Named Directories (`zsh_directory_name` / `zsh_directory_name_functions`)

#### Exact Mechanics (Peter Stephenson's Extensible Protocol)
Introduced by Peter Stephenson and documented in `zshexpn(1)` (lines 2032–2077), **Dynamic Named Directories** allow arbitrary Zsh logic to resolve bracketed tilde expressions `~[namstr]` on demand without pre-populating `nameddirtab`.

When Zsh encounters `~[namstr]` (terminated by the first unquoted `]`), or formats a directory for `%~` / `${(D)...}`, or completes `~[<TAB>`, it invokes `zsh_directory_name` (if defined) followed by each function registered in the hook array `$zsh_directory_name_functions` (managed cleanly via `/usr/share/zsh/5.9/functions/add-zsh-hook`, lines 18–21) until one returns status `0`:

| Mode (`$1`) | Trigger Context | Arguments Passed | Required Hook Action on Match |
| :--- | :--- | :--- | :--- |
| **`n`** | Forward expansion: `~[cr]`, `~[cr]/znav/docs` | `$1 = "n"`, `$2 = "cr"` | Set global array `typeset -ga reply=("/resolved/dir")` and `return 0` (Zsh automatically appends `/znav/docs`). Return non-zero to decline. |
| **`d`** | Reverse contraction: `%~`, `dirs`, `${(D)var}` | `$1 = "d"`, `$2 = "/resolved/dir/sub"` | Set global array `typeset -ga reply=("cr" $matched_byte_len)` and `return 0`. Return non-zero to decline. |
| **`c`** | Tab completion: `~[<TAB>` via `_dynamic_directory_name` | `$1 = "c"` | Call `compsys` helpers (`_describe` / `compadd`, appending closing `]` via `-S]` unless `[[ $ISUFFIX == *\]* ]]`) and `return 0`. |

Inspecting `/usr/share/zsh/5.9/functions/_dynamic_directory_name` (all 15 lines of upstream Zsh 5.9 source) confirms how lightweight the completion bridge is:

```zsh
# /usr/share/zsh/5.9/functions/_dynamic_directory_name (Zsh 5.9)
local func
integer ret=1

if [[ -n $functions[zsh_directory_name] || \
  ${+zsh_directory_name_functions} -ne 0 ]] ; then
  [[ -n $functions[zsh_directory_name] ]] && zsh_directory_name c && ret=0
  for func in $zsh_directory_name_functions; do
    $func c && ret=0
  done
  return ret
else
  _message 'dynamic directory name: implemented as zsh_directory_name c'
fi
```

Zsh 5.9 also ships `/usr/share/zsh/5.9/functions/zsh_directory_name_generic` (158 lines), which resolves hierarchical colon-delimited names like `~[proj:znav]` by walking user-defined associative arrays (`zdn_top`). Notably, auditing `zsh_directory_name_generic` reveals two limitations:
1. It still requires manually declaring static associative arrays in `~/.zshrc`.
2. Line 99 of upstream `/usr/share/zsh/5.9/functions/zsh_directory_name_generic` contains an actual latent variable-name typo in mode `d` (`_zdn_name+=${_zdn_name:+${_zdh_name}:}$_zdn_cpt` — `${_zdh_name}` instead of `${_zdn_name}`), dropping parent components when contracting multi-segment dynamic names!

#### Two Subtle Zsh 5.9 C-Implementation Behaviors Verified Live
Empirical testing against Zsh 5.9's C implementation (`finddir()` in `Src/utils.c`) uncovered two undocumented subtleties that any production `zsh_directory_name` hook **must** handle:

1. **Mode `d` Expects UTF-8 *Byte* Length, Not Multibyte Character Length**:
   Under Zsh's default `MULTIBYTE` option, `${#matched_dir}` counts *characters*, whereas Zsh's C string slicer advances past `$reply[2]` **bytes** of `$2`. If a directory path contains multibyte UTF-8 characters (e.g., `/private/tmp/café`), returning character length `17` instead of byte length `18` slices mid-codepoint and corrupts `${(D)path}` into `~[cafe]$'\xa9'/sub`! Computing byte length under `setopt localoptions no_multibyte` fixes this cleanly:
   ```zsh
   zsh -dfc '
     _demo_zdn() {
       emulate -L zsh
       setopt warn_create_global
       local target="/private/tmp/café"
       if [[ $1 == n && $2 == cafe ]]; then
         typeset -ga reply=($target)
         return 0
       elif [[ $1 == d && $2 == $target(|/*) ]]; then
         integer blen
         { setopt localoptions no_multibyte; blen=${#target}; }
         typeset -ga reply=(cafe $blen)
         return 0
       fi
       return 1
     }
     zsh_directory_name_functions=(_demo_zdn)
     p="/private/tmp/café/sub"
     print -r -- "n-mode: ~[cafe]/sub -> $(print -r -- ~[cafe]/sub)"
     print -r -- "d-mode: ${(D)p}"
   '
   # Output:
   # n-mode: ~[cafe]/sub -> /private/tmp/café/sub
   # d-mode: ~[cafe]/sub
   ```

2. **Equal-Length Tie-Breaking Between Static `~cr` and Dynamic `~[cr]`**:
   Although `zshexpn(1)` (lines 2071–2074) states that a dynamic directory name is chosen only if its matched prefix length is strictly *longer* (`>`) than any static named directory, Zsh 5.9's actual C check allows a dynamic match of **equal** length (`>=`) to supersede static `hash -d` in `${(D)...}` and `%~`. Consequently, if both `hash -d cr=$dir` and `zsh_directory_name` cover `$dir`, mode `d` should decline (`return 1`) for paths already projected into `$nameddirs` whenever the cleaner `~cr` prompt form is preferred over `~[cr]`.

#### Limitations of `zsh_directory_name` Alone
`zsh_directory_name` is a **protocol**, not a ranking or shortcode engine, and `~[cr]` costs two extra bracket keystrokes (`[` and `]`, which also require quoting if `NOMATCH`/globbing could ever misconstrue unexpanded tokens in other shells) compared to static `~cr` (3 chars) or bare `cr` (2 chars). However, for rich multi-token queries (`~[code:verif]`) or entries outside the top static `hash -d` projection, `zsh_directory_name` is an unmatched native extension point.

---

### 2.3 `cdr` & `chpwd_recent_dirs` (`zshcontrib`) — Built-in Recent-Directory Stack

#### Exact Source-Level Mechanics
Zsh ships a complete persistent recent-directory subsystem written by Peter Stephenson across five autoloadable functions in `/usr/share/zsh/5.9/functions/`:

1. **`chpwd_recent_dirs` (44 lines)**:
   Hooked into `chpwd` via `add-zsh-hook chpwd chpwd_recent_dirs`.
   - **Evaluation-context guard (lines 32–36)**:
     ```zsh
     if [[ ! -o interactive || $ZSH_SUBSHELL -ne 0 || \
       ( -n $ZSH_EVAL_CONTEXT && \
       $ZSH_EVAL_CONTEXT != toplevel(:[a-z]#func|)# ) ]]; then
       return
     fi
     ```
     This ensures subshells, `eval` expressions, traps, ZLE completion widgets, and `cd -q` do not pollute the recent-directory stack.
   - **Deduplication & full rewrite (lines 6, 38–44)**: Declares `local -aU reply` (the `-U` uniqueness flag automatically strips older duplicates when `$PWD` is prepended), calls `chpwd_recent_filehandler` to read the entire history file into `$reply`, prepends `$PWD` via `chpwd_recent_add` (which honors `zstyle ':chpwd:' recent-dirs-prune` `parent` and `pattern:*`), and calls `chpwd_recent_filehandler $reply` to rewrite the file.

2. **`chpwd_recent_filehandler` (47 lines)**:
   Manages `${ZDOTDIR:-$HOME}/.chpwd-recent-dirs` (capped at `recent-dirs-max`, default `20`, line 21):
   - **Write path (line 29)**:
     ```zsh
     # Quote on write.
     # Use $'...' quoting... this fixes newlines and other nastiness.
     print -rl ${(qqqq)argv} >${files[1]}
     ```
     Note that upstream Zsh 5.9 uses **four-`q` ANSI-C `$'...'` quoting** (`${(qqqq)argv}`), *not* `(qqq)`, specifically so embedded newlines are escaped onto single physical lines. However, it writes via raw truncation `>${files[1]}`—**without** atomic temp-file `rename(2)` or locking.
   - **Read path (lines 39–45)**:
     ```zsh
     for line in ${(f)"$(<$file)"}; do
       dir=(${(z)line})
       reply+=(${(Q)${dir[1]}})
       if (( max > 0 && ${#reply} == max )); then
         break 2
       fi
     done
     ```
     While Zsh's C core (`getoutputfile()` in `Src/exec.c`) optimizes the special `$(<$file)` form—even inside double quotes `"$(<$file)"`—into an in-process file read with **`0` `fork(2)` calls**, every single read still slurps the entire file from disk and runs Zsh's full shell lexer `${(z)line}` plus quote-stripping `${(Q)...}` across up to $N$ stored lines.

3. **`cdr` (336 lines), `_cdr` (57 lines), and `zsh_directory_name_cdr` (26 lines)**:
   - `cdr [N]` reads the list, strips `$PWD` if at index 1 (`[[ $reply[1] = $PWD ]] && reply=($reply[2,-1])`, line 313), and `cd`s (or `pushd`s) to `${reply[$1]}` (defaulting `$1` to `1`, the immediately preceding directory). `cdr -l` prints indices and `${(D)dirs[i]}`; `cdr -e` opens interactive `vared reply`; `cdr -p pat` prunes matches.
   - `zsh_directory_name_cdr` hooks `~[1]`, `~[2]`, ... (`[[ $2 = <-> ]]`) by invoking `cdr -r` (re-slurping and re-lexing the file from disk on **every** `~[1]` expansion, though with `0` forks) and spawning a real command-substitution subshell `$(cdr -l)` (`1` fork) on `~[<TAB>` completion (`zsh_directory_name_cdr` line 17; `_cdr` lines 42, 53):
     ```zsh
     # Standalone verification in zsh -df (simulating interactive stack via chpwd_recent_filehandler):
     zsh -dfc '
       FPATH=/usr/share/zsh/5.9/functions
       autoload -Uz cdr chpwd_recent_filehandler zsh_directory_name_cdr add-zsh-hook
       tmpf=$(mktemp /tmp/znav_cdr_audit.XXXXXX)
       zstyle ":chpwd:*" recent-dirs-file "$tmpf"
       chpwd_recent_filehandler /private/tmp /usr/share /var
       add-zsh-hook zsh_directory_name zsh_directory_name_cdr
       cd /private/tmp
       print -r -- "~[1]=$(print -r -- ~[1]) ~[2]=$(print -r -- ~[2])"
       rm -f "$tmpf"
     '
     # Output: ~[1]=/usr/share ~[2]=/var
     ```

#### Formal & Computational Limitations of `cdr`
While `cdr` is clean Zsh craftsmanship for stepping back to a *just-left* directory (and cleverly avoids `fork(2)` on `chpwd` and `~[1]` via Zsh's built-in `$(<$file)` optimization), it fails as a primary replacement for semantic directory shortcuts across three formal dimensions:

1. **Zero Code Stability / Maximal Churn ($I(\text{Dir}; \text{Code}) \to 0$)**:
   `cdr` addresses directories solely by **positional MRU stack rank** (`1`, `2`, `3`, ...). Whenever the user visits *any* new directory $d_{\text{new}}$, every rank $k \in \{1, \dots, M-1\}$ shifts to $k+1$—a **100% mutation rate** of directory-to-code bindings on new visits. A human cannot build motor memory ("`~[1]` means `CODE.REPOSITORIES`") because `~[1]` points to a different directory after every `cd`. You must always inspect `cdr -l` or `<TAB>` menu descriptions before acting.

2. **Pure MRU Stack Eviction (No Frequency Weighting)**:
   `chpwd_recent_dirs` stores no visit counts and no timestamps—only stack order capped by default at `recent-dirs-max = 20`. If a developer visits `~/CODE.REPOSITORIES` 1,000 times a month and then inspects 20 subdirectories during a one-off build triage, `~/CODE.REPOSITORIES` is **completely evicted** from `.chpwd-recent-dirs`.

3. **$O(N)$ Full-File Slurp + Shell-Lexer Parse + Non-Atomic Truncate-Write on Every `chpwd`**:
   Even with `0` forks, every interactive `cd` slurps the entire history file via `$(<$file)`, runs Zsh's shell lexer `${(z)line}` and `${(Q)...}` across up to $N$ lines, and truncates `${files[1]}` in-place via `>` (and every `~[1]` / `cdr 1` lookup re-reads and re-lexes the file from disk instead of hitting an in-memory hash table). As Peter Stephenson candidly documents in `/usr/share/zsh/5.9/functions/cdr` (lines 65–68):
   > *"Note currently no file locking is applied: the list is updated immediately on interactive commands and nowhere else (unlike history), and it is assumed you are only going to change directory in one window at once."*
   Two concurrent Zsh terminals changing directories simultaneously can race on `>${files[1]}` or clobber each other's updates.

---

### 2.4 `cdpath` / `CDPATH`, Directory Stack (`AUTO_PUSHD`), and `compsys` Partial-Path Matchers

#### (A) `cdpath` / `CDPATH` + `AUTO_CD`
Zsh ties the array `$cdpath` to the colon-separated scalar `$CDPATH`. Adding workspace parent directories (`cdpath=(~ ~/CODE.REPOSITORIES)`) lets `cd znav` (or bare `znav` under `AUTO_CD`) locate `~/CODE.REPOSITORIES/znav` from anywhere:

```zsh
zsh -dfc '
  cdpath=(/usr/share /usr)
  cd zsh
  print -r -- "PWD=$PWD"
'
# Output: PWD=/usr/share/zsh
```

**Limitations**:
- **No Shortcode Compression**: You still must type (or tab-complete) the directory name `CODE.REPOSITORIES` (17 keystrokes), not a 2-character initialism `cr`.
- **`cd`-Only Scope**: Like aliases, `$cdpath` is consulted *only* by `cd` / `AUTO_CD`. Running `vim znav/README.md` or `cp a CODE.REPOSITORIES/` from `/tmp` fails completely.
- **Flat Basename Ambiguity & Stdout Noise**: If two roots in `$cdpath` contain identically named subdirectories (e.g., `~/work/docs` and `~/personal/docs`), the earlier root silently shadows the later one regardless of which you visit 99% of the time; and in interactive shells, every `cdpath`-resolved `cd` echoes the target path to `stdout`.

#### (B) Session Directory Stack (`AUTO_PUSHD`, `PUSHD_IGNORE_DUPS`, `PUSHD_MINUS`, `cd -<TAB>`)
Enabling `setopt AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT PUSHD_MINUS` automatically pushes every visited `$OLDPWD` onto `$dirstack`, accessible via `dirs -v`, `cd -2`, `~1` / `~-1` (with `PUSHD_MINUS` inverting `+` and `-` so `~-1` counts from the top of the stack while `~+1` counts from the bottom), and interactive menu completion `cd -<TAB>`.

```zsh
zsh -dfc '
  setopt AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_MINUS
  cd / && cd /usr && cd /var
  print -r -- "top-1 (~-1): $(print -r -- ~-1) | bottom-1 (~+1): $(print -r -- ~+1)"
'
# Output: top-1 (~-1): /usr | bottom-1 (~+1): /
```

**Limitations**: Identical positional instability to `cdr` (`~-1` shifts on every `cd`), **plus** zero persistence across shell restarts unless manually wired to `chpwd` files.

#### (C) `compsys` Partial-Path Completion & Matcher Specifications (`_path_files` + `matcher-list`)
Sven Wischnowsky's completion engine (`compsys`) includes two extraordinarily capable path-abbreviation mechanisms inside `/usr/share/zsh/5.9/functions/_path_files`:

1. **Multi-Segment Prefix Expansion (Built-in to `_path_files`)**:
   Typing `cd /u/s/z/5/f<TAB>` expands all intermediate path components simultaneously into `cd /usr/share/zsh/5.9/functions/`.
2. **Intra-Segment Delimiter-Anchor Matching (`matcher-list`)**:
   Configuring `zstyle ':completion:*' matcher-list` with right-anchor wildcard specs `r:|[._-]=* r:|=*` tells `compsys` that characters immediately before `.`, `_`, or `-` expand across arbitrary substring runs up to that delimiter.

   > **Critical Zsh `matcher-list` Subtlety (Verified via `zsh/zpty`)**: Elements of `matcher-list` are tried **sequentially** as fallback passes. Writing two separate strings `'m:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'` runs Pass 1 (case-insensitive prefix *without* delimiter anchors) and then Pass 2 (delimiter anchors *without* case-insensitivity!), causing lowercase `cd ~/c.r<TAB>` to **fail** against uppercase `~/CODE.REPOSITORIES`! Both specs **must** reside in the **same** matcher string:

   ```zsh
   # Verified live in zsh 5.9 via zsh/zpty:
   # Typing: cd ~/c.r<TAB>  --> expands in-place to: cd ~/CODE.REPOSITORIES/
   autoload -Uz compinit && compinit
   zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z} r:|[._-]=* r:|=*'
   ```

**Limitations of `compsys` Partial-Path Completion**:
- **Interactive ZLE Keystroke & Visual-Confirmation Tax**: Requires typing path structure (`~/c.r` = 5 chars + `<TAB>` = 6 keystrokes vs `cr` = 2 chars or `~cr` = 3 chars), works only interactively at ZLE `<TAB>` time, and expands into long literal strings on the command line.
- **Prefix Hijacking (Zero Frecency Ranking)**: Completion matching is purely lexical over filesystem entries. The moment `mkdir ~/CACHE.REPOS` or `~/CONFIG.REPOS` is executed, `cd ~/c.r<TAB>` becomes **ambiguous** and stalls in completion disambiguation—even if `~/CODE.REPOSITORIES` has 5,000 prior visits and `~/CACHE.REPOS` has zero.

---

### 2.5 External Frecency Jumpers (`zoxide`, `rupa/z`, `fasd`)

External tools popularized **frecency** (combining frequency and recency), solving the MRU eviction flaw of `cdr`. However, inspecting `/opt/homebrew/bin/zoxide` (`0.10.0`) directly on this machine (`zoxide init zsh`) exposes the architectural cost of living **outside** the Zsh process:

1. **Process-Creation (`fork`/`execve`) Overhead on Startup, Every `cd`, and Every Jump**:
   In `zoxide init zsh` (`zoxide 0.10.0`):
   - **Shell Startup**: `eval "$(zoxide init zsh)"` forks a subshell and execs `/opt/homebrew/bin/zoxide` on every new terminal tab.
   - **Every `chpwd`**: `__zoxide_hook` executes `\command zoxide add -- "$(__zoxide_pwd)"`, incurring **2 process forks + 1 external binary `execve`** on every single directory change.
   - **Every `z` Jump**: `__zoxide_z` runs `(\builtin cd -q -- "$1") &>/dev/null` (1 subshell fork) followed by `result="$(\command zoxide query --exclude "$(__zoxide_pwd)" -- "$@")"` (**2 more forks + 1 `execve`**, totaling **3 forks + 1 binary execution** per jump).
   - Legacy shell/awk tools are even heavier: `rupa/z` hooks **`precmd`** (running after *every* command line, even `ls` or `<Enter>`!), spawning subshells + `awk` + `date` + `mv` to rewrite `~/.z` in $O(N)$ on every prompt; `fasd` similarly forks shell/awk pipelines per command.

2. **Inability to Expand Inline in Non-`cd` Arguments or Prompts**:
   Because `zoxide` is an external process wrapped by a `z` command function, it **cannot** project entries into Zsh's in-memory `nameddirtab` (`~cr`). Users cannot write `diff ~cr/a ~sr/b`, `vim ~cr/znav/README.md`, or `cp foo.txt ~sr/`—they are forced back to manual command substitutions like `vim "$(zoxide query cr)/znav/README.md"` (yet another fork+exec per argument) or brittle two-step `z cr && vim ...` workflows.

3. **Unstable Substring Matching & Discontinuous Rescaling**:
   Querying `z cr` performs substring matching (`*cr*`, which matches `/tmp/scratch` if visited recently!), not segment-initialism bijection (`CODE.REPOSITORIES` $\mapsto$ `cr`). Furthermore, `zoxide` and `rupa/z` approximate aging by multiplying all scores by `0.9` / `0.99` whenever the sum of scores exceeds a magic threshold (`_ZO_MAXAGE=10000` / `9000`), causing discontinuous $O(N)$ rescaling passes rather than exact continuous time-invariant exponential decay.

---

### 2.6 Architectural Synthesis Matrix

| Capability / Property | Manual `alias cr='cd ...'` | Static `hash -d` + `CDABLE_VARS` | `cdr` + `zsh_directory_name_cdr` | `cdpath` + `AUTO_CD` | `compsys` `matcher-list` | External `zoxide` (`0.10.0`) | **`znav` (Pure Zsh)** |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Zero Manual Config ($O(0)$ Curation)** | No ($O(N)$) | No ($O(N)$) | Yes | Partial (roots) | Yes | Yes | **Yes (+ Day-0 `seed`)** |
| **Works in ALL Path Args (`vim ~cr/f`)** | No | **Yes (`~cr`)** | Yes (`~[1]`) | No | Interactive `<TAB>` | No | **Yes (`~cr` & `~[cr]`)** |
| **Bare Shortcode Jump (`cr` + Enter)** | Yes (shadows cmds!) | **Yes (cmd-safe)** | No (`cdr 1`) | Full basename only | No | `z <substrings>` | **Yes (`cr`, `j cr`)** |
| **Prompt `%~` Contraction** | No | **Yes (`~cr`)** | Optional `~[1]` | No | No | No | **Yes (`~cr` / `~[cr]`)** |
| **Forks / Subshells per `chpwd`** | 0 | 0 | 0 (`$(<$f)` in-proc) | 0 | 0 | **2 forks + 1 exec** | **0 forks, 0 subshells** |
| **Disk I/O & Parse per `chpwd`** | 0 | 0 | **$O(N)$ slurp+lex+rewrite** | 0 | 0 | $O(N)$ binary DB rewrite | **$O(1)$ 1-line WAL append** |
| **Forks / I/O per Jump or Expand** | 0 | **0 (C hash)** | 0 forks, **$O(N)$ disk re-read** (`1` fork on `<TAB>`) | 0 | 0 | **3 forks + 1 exec** | **0 (`~cr` C hash)** |
| **Frecency Adaptation** | Static | Static | Pure MRU (evicts!) | Static | None (lexical) | Heuristic cap-aging | **Exact $O(1)$ Log-Epoch** |
| **No-Hijack Shortcode Stability** | Manual | Manual | **0% (shifts every `cd`)** | First-root wins | Breaks on new prefix | Unbound (`*cr*` drifts) | **Formally Proven Theorem** |
| **Multi-Shell Crash-Safe Persistence** | N/A | N/A | Unsafe (`>` race) | None | N/A | Atomic temp rename | **WAL + Atomic `zf_mv`** |

---

## 3. Zsh-Maintainer Architecture & Module Capability Specification for `znav`

To build a zero-fork, formally verified navigation engine that feels indistinguishable from core upstream Zsh, `znav` leverages Zsh 5.9's loadable C modules (`zshmodules(1)`) and adheres strictly to upstream Zsh maintainer idioms. Every behavior and gotcha below was verified directly on this macOS `arm64-apple-darwin25.0` Zsh 5.9 installation.

### 3.1 Verified Loadable C Modules & Critical Gotchas

All required modules ship compiled into `/bin/zsh` 5.9 on macOS and work cleanly even with `PATH=""`:

#### 1. `zsh/datetime` — High-Resolution Monotonic-Scale Wall Clock
- Exposes `$EPOCHREALTIME` (floating-point seconds since Unix epoch with nanosecond string formatting on macOS, e.g., `1795126436.1931779385`) and integer `$EPOCHSECONDS`, read directly in C without invoking `/bin/date`.

#### 2. `zsh/mathfunc` — In-Process IEEE-754 `libm` Transcendentals (`log`, `exp`)
- Provides C `double` `log(x)` and `exp(x)` directly inside `$(( ... ))` arithmetic evaluation, enabling exact $O(1)$ Log-Epoch frecency updates:
  $$\Lambda_d \leftarrow \max(\Lambda_d, t) + \tau \ln\!\bigl(1 + \exp(-|\Lambda_d - t| / \tau)\bigr)$$
- **Verified Safety**: Local variables named `integer log=42` do **not** shadow math function calls `log(2.0)` inside `$(( ... ))`, and `exp(-1000.0)` underflows cleanly to `0.0` without error.
- **CRITICAL Precision Gotcha (`float` vs `float -F 9` / `float -E 17`)**:
  In Zsh, declaring a bare `float x` (`typeset -E x`) formats `$x` to **10 significant digits** in scientific notation (`1.795126494e+09`) whenever `$x` is expanded as a string (such as storing `_ZNAV_SCORE[$dir]=$x` into an associative array or writing to a WAL file)! On current Unix timestamps ($\approx 1.795 \times 10^9$), 10 significant digits **truncates ~0.11 seconds of precision** (`diff = -0.109532s`), violating $10^{-9}$ numerical conformance!
  ```zsh
  zsh -dfc '
    zmodload zsh/datetime zsh/mathfunc
    t=$EPOCHREALTIME
    float bare_e=$(( t ))
    float -F 9 fixed_9=$(( t ))
    float -E 17 sci_17=$(( t ))
    typeset -A scores=( [bare]=$bare_e [f9]=$fixed_9 [e17]=$sci_17 )
    print -r -- "bare float error : $(( scores[bare] - t ))"
    print -r -- "float -F 9 error : $(( scores[f9]   - t ))"
    print -r -- "float -E 17 error: $(( scores[e17]  - t ))"
  '
  # Verified output:
  # bare float error : -0.109532...   <-- LOSES ~110ms OF PRECISION!
  # float -F 9 error : 0.
  # float -E 17 error: 0.
  ```
  **Rule for `znav`**: Always declare timestamp and Log-Epoch accumulators with `float -F 9` or `float -E 17`.

#### 3. `zsh/files` — Atomic Zero-Fork Filesystem Syscalls (`zf_mv`, `zf_mkdir`, `zf_rm`)
- **CRITICAL Builtin-Shadowing Gotcha**: Running bare `zmodload zsh/files` registers **unprefixed** `mv`, `mkdir`, `rm`, `ln`, `chmod`, `chown`, and `rmdir` as shell builtins globally, silently shadowing `/bin/mv`, `/bin/mkdir`, and `/bin/rm` in the user's interactive shell (breaking BSD/GNU flags such as `mkdir -v` or `cp`/`mv` extensions)!
- **Zsh-Maintainer Best Practice**: Always use **selective feature loading** (`-F`) to expose *only* the `zf_*`-prefixed builtins:
  ```zsh
  zmodload -F zsh/files b:zf_mv b:zf_mkdir b:zf_rm b:zf_rmdir b:zf_ln
  ```
  - `zf_mkdir -p -- "$dir"` creates state directories with zero external forks.
  - `zf_mv -f -- "$tmpfile" "$dbfile"` invokes POSIX `rename(2)` in C, guaranteeing atomic, crash-safe snapshot replacement during WAL compaction even when `PATH=""`.

#### 4. `zsh/stat` & `zsh/system` — Metadata & File Descriptors
- Same selective-loading rule applies to `zsh/stat`: use `zmodload -F zsh/stat b:zstat` so `/usr/bin/stat` is never shadowed (while simple directory existence checks use core zero-fork `[[ -d $dir ]]`).
- `zsh/system` provides `sysopen`, `sysread`, `syswrite`, and `zsystem flock` if advisory file locking is ever desired alongside atomic `zf_mv` compaction.

#### 5. `zsh/parameter` — Introspecting `$nameddirs`, Commands, and the macOS `$userdirs` Trap
- `zmodload zsh/parameter` exposes live views of Zsh's internal hash tables: `$nameddirs`, `$userdirs`, `$commands`, `$builtins`, `$functions`, `$aliases`, and `$reswords`.
- **CRITICAL macOS `$userdirs` Discovery**:
  On Linux systems using flat `/etc/passwd`, `${(k)userdirs}` enumerates all local user accounts via `getpwent(3)`. On macOS (`arm64-apple-darwin25.0`, OpenDirectory-backed accounts), **`${#userdirs}` evaluates to `0` and `${+userdirs[root]}` evaluates to `0`**—even *after* expanding `~root`! Yet `~root` (`/var/root`), `~daemon` (`/var/root`), `~nobody` (`/var/empty`), and `~$USER` **do** resolve via `getpwnam(3)` inside Zsh's tilde expander, and running `hash -d root=/some/repo` **will clobber `~root`**!
  ```zsh
  zsh -dfc '
    zmodload zsh/parameter
    setopt extended_glob no_nomatch

    # Demonstrate macOS OpenDirectory $userdirs emptiness:
    print -r -- "userdirs count=${#userdirs}, +userdirs[root]=${+userdirs[root]}"
    print -r -- "yet ~root expands to: $(print -r -- ~root)"

    # Zero-fork, zero-subshell pure-Zsh OS user detector (run BEFORE hash -d):
    _is_os_user() {
      emulate -L zsh
      setopt no_nomatch
      local cand=$1
      (( $+userdirs[$cand] )) && return 0
      (( $+nameddirs[$cand] )) && return 1
      local tilde="~$cand"
      local expanded=${~tilde}
      [[ $expanded != $tilde ]]
    }

    for k in root daemon nobody $USER cr sr; do
      _is_os_user "$k" && print -r -- "$k: RESERVED_USER" || print -r -- "$k: FREE"
    done
  '
  # Verified output:
  # userdirs count=0, +userdirs[root]=0
  # yet ~root expands to: /var/root
  # root: RESERVED_USER
  # daemon: RESERVED_USER
  # nobody: RESERVED_USER
  # username: RESERVED_USER
  # cr: FREE
  # sr: FREE
  ```
  By checking `[[ ${~tilde} != $tilde ]]` (when `$cand` is not yet in `$nameddirs`), `znav` detects every OpenDirectory/POSIX user (`root`, `daemon`, `nobody`, `$USER`, `_www`, etc.) in **zero forks and zero subshells**.

---

### 3.2 Canonicalization, Namespace Safety, and Zsh Maintainer Hygiene

Distilling the engineering idioms from `/usr/share/zsh/5.9/functions/cdr`, `chpwd_recent_dirs`, `add-zsh-hook`, and `zsh_directory_name_generic` yields the exact hygiene checklist for `znav`:

1. **Function Prelude & Lexical Isolation**:
   Every autoloaded or plugin function begins with:
   ```zsh
   emulate -L zsh
   setopt extended_glob warn_create_global typeset_silent no_short_loops
   ```
   All intentional globals (`_ZNAV_*`, `reply` inside `zsh_directory_name`) are declared explicitly with `typeset -g` / `typeset -ga` / `typeset -gA` so `WARN_CREATE_GLOBAL` remains 100% clean.

2. **Symlink Canonicalization (`${dir:A}`) on macOS**:
   On macOS APFS, `/tmp` is a symlink to `/private/tmp` and `/var` is a symlink to `/private/var`. Applying Zsh's `:A` modifier (`${PWD:A}`) resolves symlinks via `realpath`-style physical traversal in pure Zsh without forking, guaranteeing that `/tmp/foo` and `/private/tmp/foo` map to a single canonical key in `_ZNAV_SCORE` and `$nameddirs`.

3. **Complete Reserved-Namespace Protection ($R$)**:
   Before projecting a candidate shortcode $k \in K(d)$ into `hash -d -- "$k=$dir"`, `znav` treats $k$ as reserved ($k \in R$) if **any** of the following hold:
   - $k$ is already in `$nameddirs` **and** was *not* placed there by `znav` (`(( $+nameddirs[$k] && !$+_ZNAV_OWNED_NAMEDDIRS[$k] ))`) — preserving all user-authored `hash -d` entries;
   - $k$ resolves to an OS user via `$userdirs[$k]` or the zero-fork `${~tilde}` probe (`root`, `daemon`, `nobody`, `$USER`, etc.);
   - $k$ collides with Zsh tilde syntax (`+`, `-`, pure digits `<->`, or leading `+`/`-`);
   - (For bare `AUTO_CD` + `CDABLE_VARS` codes) $k$ exists in `$commands`, `$builtins`, `$functions`, `$aliases`, or `$reswords` — preventing surprises with POSIX two-letter commands like `tr`, `pr`, `ar`, `cc`, `ps`, `df`, `du`, `id`, `ln`, `ls`, `cp`.

4. **Pathological Filename & Bytecode Safety**:
   - Always terminate option parsing with `--` (`builtin cd -- "$dir"`, `hash -d -- "$code=$dir"`, `zf_mv -f -- "$src" "$dst"`, `print -r -- "$line"`) so directories named `-weird.dir` never trigger invalid-option errors.
   - Escape or quote paths via `${(qqqq)dir}` (matching `chpwd_recent_filehandler` line 29) when serializing arbitrary paths containing spaces, quotes, brackets `*?[]()`, or embedded newlines to disk, and unquote via `${(Q)...}` without `eval`.
   - Maintain clean syntax across all files so `zcompile` compiles `znav.plugin.zsh` and `functions/*` into native Zsh wordcode (`.zwc`) without warnings.
