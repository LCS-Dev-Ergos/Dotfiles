#!/usr/bin/env bash
# shellcheck shell=bash
# Report or advance flake inputs pinned in flake.nix by tag or commit.
#
# Usage:
#   scripts/update-pinned-inputs.sh --check [input...]
#   scripts/update-pinned-inputs.sh --apply [input...]
#
# Understood forms: github:, gitlab:, and sourcehut: with the pin as the third
# path segment or as ?rev= / ?ref=, and git+https, git+http, git+ssh, and
# git+file with ?rev= (optionally tracking ?ref=<branch>) or ?ref=<tag>.
#
# Tag-pinned inputs move to the highest upstream release tag (v?N(.N)*,
# compared numerically); commit-pinned inputs move to the head of the tracked
# branch, or of the default branch. Every selected input is resolved before
# anything is written, so a network or upstream failure leaves the repository
# untouched. --apply then rewrites the URLs in flake.nix, refreshes only those
# lock nodes, and restores both files if the refresh fails. It never builds,
# stages, commits, or switches. Inputs that follow a branch (nixpkgs,
# home-manager, nix-darwin) are left to `nix flake update`.
#
# A commit pin follows upstream blindly, so every update prints a link to what
# changed: read it before building.
#
# Exit status: 0 nothing to do or applied, 1 updates available (--check),
# 2 usage, environment, or resolution error.

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
# A renamed or private repository must fail, not wait for credentials, and a
# stalled connection must not hang the run.
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

usage='usage: update-pinned-inputs.sh --check|--apply [input...]'
die() {
  printf 'update-pinned-inputs: %s\n' "$1" >&2
  exit 2
}

(($# >= 1)) || die "$usage"
case "$1" in
--check | --apply) operation="$1" ;;
-h | --help)
  printf '%s\n' "$usage"
  exit 0
  ;;
*) die "unknown option: $1 ($usage)" ;;
esac
shift

for required_command in awk cat cp git grep mktemp nix rm sed; do
  command -v "$required_command" >/dev/null 2>&1 ||
    die "requires $required_command"
done

# Anchor on the script, not the working directory, so a run from another
# repository or worktree can never rewrite that checkout's flake.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
flake_file="$repo_root/flake.nix"
lock_file="$repo_root/flake.lock"
[[ -f "$flake_file" ]] || die "missing $flake_file"

# An ssh remote, or an https one that url.<base>.insteadOf rewrites to ssh,
# must fail rather than stop at a passphrase or host-key prompt. Extend the
# command git would use anyway instead of replacing it.
ssh_command="${GIT_SSH_COMMAND:-}"
if [[ -z "$ssh_command" ]]; then
  ssh_command="$(git -C "$repo_root" config --get core.sshCommand || true)"
fi
[[ -n "$ssh_command" ]] || ssh_command="${GIT_SSH:-ssh}"
export GIT_SSH_COMMAND="$ssh_command -o BatchMode=yes -o ConnectTimeout=15"

if [[ "$operation" == --apply ]]; then
  [[ -f "$lock_file" ]] || die "missing $lock_file"
  # Against HEAD, so staged edits count too: --apply must start from a
  # committed flake.nix and flake.lock for the diff it leaves to be reviewable.
  if git -C "$repo_root" diff --quiet HEAD -- flake.nix flake.lock; then
    :
  else
    git_status=$?
    ((git_status == 1)) || die "cannot inspect git state of $repo_root"
    die 'flake.nix or flake.lock has uncommitted changes; commit or stash them first'
  fi
fi

if ! tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/update-pinned-inputs.XXXXXX")"; then
  die 'unable to create a temporary directory'
fi
restore_on_exit=0
cleanup() {
  if ((restore_on_exit)); then
    cat -- "$tmp_root/flake.nix" >"$flake_file"
    cat -- "$tmp_root/flake.lock" >"$lock_file"
    printf 'update-pinned-inputs: restored flake.nix and flake.lock\n' >&2
  fi
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

commit_pattern='^[0-9a-f]{40}$'
tag_pattern='^v?[0-9]+(\.[0-9]+)*$'
shorthand_pattern='^(github|gitlab|sourcehut):([^/?#]+)/([^/?#]+)(/([^?#]+))?(\?([^#]*))?$'
git_url_pattern='^git\+((https?|ssh|file)://[^?#]+)(\?([^#]*))?$'

# Prints the value of one key in a URL query string.
query_param() {
  local pair pairs
  IFS='&' read -r -a pairs <<<"$1"
  for pair in "${pairs[@]}"; do
    if [[ "$pair" == "$2="* ]]; then
      printf '%s' "${pair#*=}"
      return 0
    fi
  done
}

# Splits one input URL into the globals below. kind is commit, tag, branch
# (follows a moving ref: not pinned), or unsupported.
parse_url() {
  local owner repo host rev_param ref_param path_ref=''
  url="$1"
  forge='' remote='' web='' slot='' current='' track='' path_prefix='' query=''
  kind=unsupported
  if [[ "$url" =~ $shorthand_pattern ]]; then
    forge="${BASH_REMATCH[1]}"
    path_prefix="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/"
    owner="${BASH_REMATCH[2]}"
    repo="${BASH_REMATCH[3]}"
    path_ref="${BASH_REMATCH[5]}"
    query="${BASH_REMATCH[7]}"
    # GitLab spells subgroups as %2F inside the owner segment.
    owner="${owner//%2[Ff]//}"
    repo="${repo//%2[Ff]//}"
    host="$(query_param "$query" host)"
    if [[ -z "$host" ]]; then
      case "$forge" in
      github) host=github.com ;;
      gitlab) host=gitlab.com ;;
      sourcehut) host=git.sr.ht ;;
      esac
    fi
    remote="https://$host/$owner/$repo"
    web="$remote"
  elif [[ "$url" =~ $git_url_pattern ]]; then
    forge=git
    remote="${BASH_REMATCH[1]}"
    query="${BASH_REMATCH[4]}"
  else
    return 0
  fi

  rev_param="$(query_param "$query" rev)"
  ref_param="$(query_param "$query" ref)"
  ref_param="${ref_param#refs/heads/}"
  if [[ -n "$path_ref" ]]; then
    slot=path
    current="$path_ref"
  elif [[ -n "$rev_param" ]]; then
    slot=rev
    current="$rev_param"
    # rev together with a tag ref cannot be advanced independently.
    [[ ! "$ref_param" =~ $tag_pattern && "$ref_param" != refs/* ]] || return 0
    track="$ref_param"
  elif [[ -n "$ref_param" ]]; then
    slot=ref
    current="$ref_param"
  else
    kind=branch
    return 0
  fi

  # ?rev= only ever holds a commit; ?ref= and a path segment name a tag or a
  # branch, and a 40-hex path segment is a commit.
  if [[ "$slot" != ref && "$current" =~ $commit_pattern ]]; then
    kind=commit
  elif [[ "$slot" != rev && "$current" =~ $tag_pattern ]]; then
    kind=tag
  elif [[ "$slot" != rev ]]; then
    kind=branch
  fi
  return 0
}

# Prints the URL parsed last with its pin replaced by $1. Everything else,
# query parameters included, is carried over byte for byte.
pinned_url() {
  local pair pairs rebuilt=''
  if [[ "$slot" == path ]]; then
    printf '%s%s%s' "$path_prefix" "$1" "${query:+?$query}"
    return 0
  fi
  IFS='&' read -r -a pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    [[ "$pair" != "$slot="* ]] || pair="$slot=$1"
    rebuilt+="${rebuilt:+&}$pair"
  done
  printf '%s?%s' "${url%%\?*}" "$rebuilt"
}

# Prints where to read what changed between two pins.
change_link() {
  case "$forge" in
  github) printf '%s/compare/%s...%s' "$web" "$1" "$2" ;;
  gitlab) printf '%s/-/compare/%s...%s' "$web" "$1" "$2" ;;
  sourcehut) printf '%s/log' "$web" ;;
  *) printf '%s' "$remote" ;;
  esac
}

# Evaluating the inputs attribute, rather than scanning the text, makes the
# listing independent of layout and of where each input is written. Names
# and URLs containing whitespace are dropped here so they cannot split lines.
# shellcheck disable=SC2016 # Nix interpolation, not shell.
inputs_expression='inputs:
  let
    plain = s: builtins.isString s && builtins.match "[^[:space:]]+" s != null;
    line = name:
      let url = inputs.${name}.url or null;
      in if plain name && plain url then "${name}\t${url}\n" else "";
  in
  builtins.concatStringsSep "" (map line (builtins.attrNames inputs))'
if ! listing="$(nix --extra-experimental-features nix-command eval --raw \
  --file "$flake_file" inputs --apply "$inputs_expression" \
  2>"$tmp_root/eval.err")"; then
  sed 's/^/    /' "$tmp_root/eval.err" >&2
  die "unable to evaluate the inputs of $flake_file"
fi
[[ -n "$listing" ]] || die 'no inputs with a URL found in flake.nix'

names=()
urls=()
kinds=()
while IFS=$'\t' read -r name url; do
  parse_url "$url"
  names+=("$name")
  urls+=("$url")
  kinds+=("$kind")
done <<<"$listing"

targets=()
add_target() {
  local index
  for index in "${targets[@]}"; do
    [[ "$index" != "$1" ]] || return 0
  done
  targets+=("$1")
}

if (($# == 0)); then
  for index in "${!names[@]}"; do
    case "${kinds[index]}" in
    commit | tag) add_target "$index" ;;
    esac
  done
else
  for wanted in "$@"; do
    found=''
    for index in "${!names[@]}"; do
      [[ "${names[index]}" == "$wanted" ]] || continue
      found="$index"
      break
    done
    [[ -n "$found" ]] || die "no input named '$wanted' in flake.nix"
    case "${kinds[found]}" in
    commit | tag) add_target "$found" ;;
    branch)
      die "$wanted follows a branch, not a tag or commit; use nix flake update $wanted"
      ;;
    *) die "$wanted uses a URL form this script cannot advance: ${urls[found]}" ;;
    esac
  done
fi
((${#targets[@]} > 0)) || die 'no tag- or commit-pinned inputs found in flake.nix'

# Prints "latest<TAB>note" for one input. The whole ls-remote reply is
# captured before parsing: a reader that stops early kills ls-remote with
# SIGPIPE, which pipefail turns into a silent exit.
resolve() {
  local kind="$1" remote="$2" current="$3" track="$4" listing ref head
  if [[ "$kind" == commit ]]; then
    ref=HEAD
    [[ -z "$track" ]] || ref="refs/heads/$track"
    listing="$(git ls-remote "$remote" "$ref" </dev/null)" || return 1
    # ls-remote matches patterns by suffix, so keep only the exact ref.
    head="$(awk -F '\t' -v ref="$ref" '$2 == ref && !seen++ { print $1 }' \
      <<<"$listing")"
    if [[ ! "$head" =~ $commit_pattern ]]; then
      printf 'no commit id for %s in the reply from %s\n' "$ref" "$remote" >&2
      return 1
    fi
    printf '%s\t\n' "$head"
    return 0
  fi

  listing="$(git ls-remote --tags --refs "$remote" </dev/null)" || return 1
  # Numeric, component-wise comparison with the optional v ignored: git's
  # version sort ranks v0.9.0 above 1.0.0 when a repository mixes spellings.
  # The pin never moves backwards, and on a tie keeps its own spelling.
  awk -F '\t' -v current="$current" '
    function newer(a, b,   pa, pb, na, nb, i, x, y) {
      sub(/^v/, "", a)
      sub(/^v/, "", b)
      na = split(a, pa, ".")
      nb = split(b, pb, ".")
      for (i = 1; i <= na || i <= nb; i++) {
        x = (i <= na) ? pa[i] + 0 : 0
        y = (i <= nb) ? pb[i] + 0 : 0
        if (x != y) return x > y
      }
      return 0
    }
    BEGIN { best = current }
    { tag = $2; sub(/^refs\/tags\//, "", tag) }
    tag == current { seen = 1 }
    tag !~ /^v?[0-9]+(\.[0-9]+)*$/ { next }
    newer(tag, best) { best = tag; next }
    best != current && !newer(best, tag) && (tag ~ /^v/) == (current ~ /^v/) { best = tag }
    END { print best "\t" (seen ? "" : "pinned tag no longer exists upstream") }
  ' <<<"$listing"
}

pids=()
for index in "${targets[@]}"; do
  parse_url "${urls[index]}"
  resolve "$kind" "$remote" "$current" "$track" \
    >"$tmp_root/$index.out" 2>"$tmp_root/$index.err" &
  pids+=("$!")
done

failures=0
updated=()
: >"$tmp_root/replacements"
for position in "${!targets[@]}"; do
  index="${targets[position]}"
  name="${names[index]}"
  parse_url "${urls[index]}"
  latest=''
  note=''
  if wait "${pids[position]}"; then
    IFS=$'\t' read -r latest note <"$tmp_root/$index.out" || true
  fi
  if [[ "$kind" == commit ]]; then
    pattern="$commit_pattern"
  else
    pattern="$tag_pattern"
  fi
  if [[ ! "$latest" =~ $pattern ]]; then
    failures=$((failures + 1))
    printf '%-28s failed to resolve %s\n' "$name" "$remote" >&2
    sed 's/^/    /' "$tmp_root/$index.err" >&2
    continue
  fi

  suffix=''
  [[ -z "$note" ]] || suffix=" ($note)"
  if [[ "$latest" == "$current" ]]; then
    printf '%-28s %-12s current%s\n' "$name" "${current:0:12}" "$suffix"
    continue
  fi
  printf '%-28s %-12s -> %-12s %s%s\n' "$name" "${current:0:12}" \
    "${latest:0:12}" "$(change_link "$current" "$latest")" "$suffix"
  printf '%s\t%s\t%s\t%s\n' "$url" "$(pinned_url "$latest")" "$name" "$latest" \
    >>"$tmp_root/replacements"
  updated+=("$name")
done

if ((failures > 0)); then
  die "$failures input(s) could not be resolved; nothing was changed"
fi
((${#updated[@]} > 0)) || exit 0
if [[ "$operation" == --check ]]; then
  printf 'Updates available. Review the links, then run --apply.\n'
  exit 1
fi

# Rewrite into a scratch copy first. Each quoted URL is matched literally and
# must occur exactly once, so a URL that is built by interpolation, or written
# twice, aborts before the real file is touched.
if ! awk -F '\t' '
  NR == FNR {
    old[++count] = "\"" $1 "\""
    new[count] = "\"" $2 "\""
    input[count] = $3
    next
  }
  {
    for (i = 1; i <= count; i++) {
      at = index($0, old[i])
      if (!at) continue
      $0 = substr($0, 1, at - 1) new[i] substr($0, at + length(old[i]))
      hits[i]++
      if (index($0, old[i])) hits[i]++
    }
    print
  }
  END {
    for (i = 1; i <= count; i++) {
      if (hits[i] != 1) {
        printf "%s: expected one %s in flake.nix, found %d\n", input[i], old[i], hits[i] > "/dev/stderr"
        failed = 1
      }
    }
    exit failed
  }
' "$tmp_root/replacements" "$flake_file" >"$tmp_root/flake.nix.new"; then
  die 'flake.nix does not match the evaluated pins; nothing was changed'
fi

cp -- "$flake_file" "$tmp_root/flake.nix"
cp -- "$lock_file" "$tmp_root/flake.lock"
restore_on_exit=1
cat -- "$tmp_root/flake.nix.new" >"$flake_file"
nix flake update --flake "$repo_root" "${updated[@]}" ||
  die 'nix flake update failed'
while IFS=$'\t' read -r _ _ name latest; do
  grep -qF "\"$latest\"" "$lock_file" ||
    die "flake.lock does not record $name at $latest"
done <"$tmp_root/replacements"
restore_on_exit=0

git -C "$repo_root" diff --stat -- flake.nix flake.lock
printf -v joined '%s ' "${updated[@]}"
printf 'Updated %s. Review, build, then commit and switch when ready.\n' \
  "${joined% }"
