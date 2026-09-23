#!/usr/bin/env bash
# shellcheck shell=bash
# Focused regression tests for repository-level Bash policy checks.

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

for required_command in bash chmod cp env git grep mkdir mktemp mv nix rm sed; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Script regression tests require %s.\n' "$required_command" >&2
    exit 2
  fi
done

if ! temp_root="$(
  mktemp -d "${TMPDIR:-/tmp}/dotfiles-script-tests.XXXXXX" 2>/dev/null ||
    mktemp -d "$repo_root/.dotfiles-script-tests.XXXXXX"
)"; then
  printf 'Unable to create a private script-test workspace.\n' >&2
  exit 2
fi
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  local label="$1"
  local expected="$2"
  local actual
  shift 2

  set +e
  "$@" >"$temp_root/command.stdout" 2>"$temp_root/command.stderr"
  actual=$?
  set -e

  if ((actual != expected)); then
    printf 'FAIL: %s (expected status %d, received %d)\n' \
      "$label" "$expected" "$actual" >&2
    sed 's/^/  stdout: /' "$temp_root/command.stdout" >&2
    sed 's/^/  stderr: /' "$temp_root/command.stderr" >&2
    exit 1
  fi
}

printf 'Repository policy checks\n'
expect_status 'current package ownership policy' 0 \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"
expect_status 'current out-of-store allowlist' 0 \
  bash "$repo_root/scripts/check-out-of-store-allowlist.sh"
expect_status 'current declared-secret scan' 0 \
  bash "$repo_root/scripts/check-declared-secrets.sh"

policy_fixture="$temp_root/package-policy.tsv"
printf '%s\n' \
  '  # leading-whitespace comments are valid' \
  $'ripgrep\trg\tnix\tNix owns the interactive command.' \
  >"$policy_fixture"
expect_status 'valid package policy fixture' 0 \
  env PACKAGE_OWNERSHIP_POLICY_FILE="$policy_fixture" \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"

printf '%s\n' \
  $'ripgrep\trg\tnix\tFirst declaration.' \
  $'ripgrep\trg\tnix\tDuplicate declaration.' \
  >"$policy_fixture"
expect_status 'duplicate package policy fixture' 1 \
  env PACKAGE_OWNERSHIP_POLICY_FILE="$policy_fixture" \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"

fixture_repo="$temp_root/secret-fixture"
mkdir -p "$fixture_repo/scripts"
cp "$repo_root/scripts/check-declared-secrets.sh" "$fixture_repo/scripts/"
printf '%s\n' '{ value = "ordinary configuration"; }' \
  >"$fixture_repo/flake.nix"
expect_status 'clean secret fixture' 0 \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

# Split the marker so this regression test does not trigger the repository scan.
printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----' \
  >"$fixture_repo/private-key.txt"
expect_status 'private-key secret fixture' 1 \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

printf '%s\n' 'ordinary text' >"$fixture_repo/private-key.txt"
mock_bin="$temp_root/mock-bin"
mkdir -p "$mock_bin"
printf '%s\n' '#!/bin/sh' 'exit 2' >"$mock_bin/rg"
chmod 0700 "$mock_bin/rg"
expect_status 'secret scanner fails closed on ripgrep error' 2 \
  env PATH="$mock_bin:/usr/bin:/bin" \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

expect_output() {
  local label="$1"
  local needle="$2"
  local stream="${3:-stdout}"

  if ! grep -qF -- "$needle" "$temp_root/command.$stream"; then
    printf 'FAIL: %s (%s lacks %s)\n' "$label" "$stream" "$needle" >&2
    sed "s/^/  $stream: /" "$temp_root/command.$stream" >&2
    exit 1
  fi
}

expect_pristine() {
  if ! git -C "$pin_fixture" diff --quiet HEAD; then
    printf 'FAIL: %s left the fixture flake modified\n' "$1" >&2
    git -C "$pin_fixture" diff >&2
    exit 1
  fi
}

printf 'Pinned-input updater\n'
# The updater talks to remote repositories and to Nix. The git shim answers
# ls-remote from fixture files and passes everything else to the real git; the
# nix shim passes evaluation to the real nix and "relocks" by copying the pins
# out of flake.nix, so the suite never touches the network or the store.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
real_git="$(command -v git)"
real_nix="$(command -v nix)"
pin_fixture="$temp_root/pin-fixture"
pin_remotes="$temp_root/pin-remotes"
pin_mock="$temp_root/pin-mock-bin"
nix_log="$temp_root/nix.log"
ssh_log="$temp_root/ssh.log"
mkdir -p "$pin_fixture/scripts" "$pin_remotes" "$pin_mock"
cp "$repo_root/scripts/update-pinned-inputs.sh" "$pin_fixture/scripts/"

cat >"$pin_mock/git" <<EOF
#!/bin/sh
[ "\$1" = ls-remote ] || exec '$real_git' "\$@"
printf '%s\n' "\$GIT_SSH_COMMAND" >'$ssh_log'
kind=head
for arg in "\$@"; do
  case "\$arg" in
    --tags) kind=tags ;;
    refs/heads/*) kind="heads.\${arg#refs/heads/}" ;;
    *://*) remote="\$arg" ;;
  esac
done
reply='$pin_remotes'/"\$(printf '%s' "\$remote" | sed 's#^[a-z+]*://##; s#/#__#g').\$kind"
if [ ! -f "\$reply" ]; then
  printf 'fatal: repository not found\n' >&2
  exit 128
fi
cat "\$reply"
EOF
cat >"$pin_mock/nix" <<EOF
#!/bin/sh
case " \$* " in
  *" eval "*) exec '$real_nix' "\$@" ;;
esac
printf '%s\n' "\$*" >>'$nix_log'
while [ "\$#" -gt 0 ] && [ "\$1" != --flake ]; do shift; done
flake="\$2"
if [ -n "\${MOCK_NIX_FAIL:-}" ]; then
  printf 'half-written\n' >"\$flake/flake.lock"
  exit 1
fi
[ -z "\${MOCK_NIX_NOOP:-}" ] || exit 0
grep -oE '[/=](v?[0-9][0-9.]*|[0-9a-f]{40})' "\$flake/flake.nix" |
  sed 's#^.#"rev": "#; s#\$#"#' >"\$flake/flake.lock"
EOF
chmod 0700 "$pin_mock/git" "$pin_mock/nix"

old_commit="$(printf 'a%.0s' {1..40})"
new_commit="$(printf 'b%.0s' {1..40})"
same_commit="$(printf 'c%.0s' {1..40})"
# Every URL form the updater understands, a second inputs definition and a
# one-line block to prove the listing does not depend on layout, and decoys
# outside the inputs that must never be rewritten.
cat >"$pin_fixture/flake.nix" <<EOF
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    commit-pin = {
      url = "github:example/commit-pin/$old_commit";
      flake = false;
    };
    dotted-pin.url = "github:example/dotted.repo/$same_commit";
    tag-pin = {
      url = "github:example/tag-pin/v0.8.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    gitlab-pin.url = "gitlab:group%2Fsub/tool/v1.0";
    query-pin.url = "github:example/query?rev=$old_commit&dir=nix";
    git-pin.url = "git+https://git.example.org/team/tool?ref=main&rev=$old_commit";
  };
  inputs.layout-pin = { flake = false; url = "github:example/layout/$same_commit"; };

  outputs = _: {
    decoy = {
      url = "github:example/decoy/$old_commit";
      fork = "github:example/tag-pin/v0.8.2-fork";
    };
  };
}
EOF
printf '%s\tHEAD\n' "$new_commit" >"$pin_remotes/github.com__example__commit-pin.head"
printf '%s\tHEAD\n' "$same_commit" >"$pin_remotes/github.com__example__dotted.repo.head"
printf '%s\tHEAD\n' "$same_commit" >"$pin_remotes/github.com__example__layout.head"
printf '%s\tHEAD\n' "$new_commit" >"$pin_remotes/github.com__example__query.head"
# ls-remote matches ref patterns by suffix; only the exact branch counts.
printf '%s\t%s\n' \
  "$same_commit" refs/heads/team/refs/heads/main \
  "$new_commit" refs/heads/main \
  >"$pin_remotes/git.example.org__team__tool.heads.main"
printf '%s\trefs/tags/%s\n' "$old_commit" v1.0 "$old_commit" v1.1 \
  >"$pin_remotes/gitlab.com__group__sub__tool.tags"
printf '%s\trefs/tags/v1.1\n' "$old_commit" \
  >"$pin_remotes/github.com__example__interp.tags"
# Mixed spellings that git's version sort ranks wrongly (v0.9.0 over 1.0.0),
# a pre-release that must be ignored, and enough filler to overflow a pipe
# buffer so an early-exiting reader would kill ls-remote with SIGPIPE.
{
  for tag in v0.8.2 v0.9.0 1.0.0 0.10.0 2.0.0-rc1; do
    printf '%s\trefs/tags/%s\n' "$old_commit" "$tag"
  done
  for patch in {1..5000}; do
    printf '%s\trefs/tags/0.0.%d\n' "$old_commit" "$patch"
  done
} >"$pin_remotes/github.com__example__tag-pin.tags"

"$real_git" -C "$pin_fixture" init -q
env PATH="$pin_mock:$PATH" nix flake update --flake "$pin_fixture"
: >"$nix_log"
"$real_git" -C "$pin_fixture" add -A
"$real_git" -C "$pin_fixture" -c user.name=test -c user.email=test@example.invalid \
  commit -q -m fixture

pin_run() {
  env PATH="$pin_mock:$PATH" bash "$pin_fixture/scripts/update-pinned-inputs.sh" "$@"
}
pin_line() {
  printf '%-28s %s' "$1" "$2"
}

expect_status 'check reports available updates' 1 pin_run --check
expect_output 'commit pin moves to HEAD' \
  "$(pin_line commit-pin 'aaaaaaaaaaaa -> bbbbbbbbbbbb https://github.com/example/commit-pin/compare/')"
expect_output 'tag pin takes the numerically highest release' \
  "$(pin_line tag-pin 'v0.8.2       -> 1.0.0        https://github.com/example/tag-pin/compare/v0.8.2...1.0.0')"
expect_output 'up-to-date pin is reported current' \
  "$(pin_line dotted-pin 'cccccccccccc current')"
expect_output 'input outside the inputs block is listed' \
  "$(pin_line layout-pin 'cccccccccccc current')"
expect_output 'gitlab subgroup pin links to its compare view' \
  "$(pin_line gitlab-pin 'v1.0         -> v1.1         https://gitlab.com/group/sub/tool/-/compare/v1.0...v1.1')"
expect_output 'query rev pin moves to HEAD' \
  "$(pin_line query-pin 'aaaaaaaaaaaa -> bbbbbbbbbbbb')"
expect_output 'git+https pin follows its tracked branch' \
  "$(pin_line git-pin 'aaaaaaaaaaaa -> bbbbbbbbbbbb https://git.example.org/team/tool')"
if grep -qE 'decoy|nixpkgs|nix-darwin' "$temp_root/command.stdout"; then
  printf 'FAIL: check reported an input outside the pinned set\n' >&2
  exit 1
fi
expect_pristine 'check'

expect_status 'check of a current input' 0 \
  env GIT_SSH_COMMAND='ssh -F /dev/null' PATH="$pin_mock:$PATH" \
  bash "$pin_fixture/scripts/update-pinned-inputs.sh" --check dotted-pin
if ! grep -qx 'ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=15' "$ssh_log"; then
  printf 'FAIL: ssh was not made non-interactive on top of GIT_SSH_COMMAND\n' >&2
  cat "$ssh_log" >&2
  exit 1
fi
expect_status 'misspelled input is rejected' 2 pin_run --check commit-pinn
expect_output 'misspelled input is named' "no input named 'commit-pinn'" stderr
expect_status 'branch-following input is rejected' 2 pin_run --check nixpkgs
expect_output 'branch-following input is explained' 'nixpkgs follows a branch' stderr
expect_status 'unknown option is rejected' 2 pin_run --update

printf ' \n' >>"$pin_fixture/flake.nix"
"$real_git" -C "$pin_fixture" add flake.nix
expect_status 'apply refuses a staged flake.nix' 2 pin_run --apply commit-pin
"$real_git" -C "$pin_fixture" reset -q --hard

tag_reply="$pin_remotes/github.com__example__tag-pin.tags"
mv "$tag_reply" "$temp_root/tag-pin.tags"
expect_status 'apply with an unresolvable input' 2 pin_run --apply commit-pin tag-pin
mv "$temp_root/tag-pin.tags" "$tag_reply"
expect_pristine 'apply with an unresolvable input'
if [[ -s "$nix_log" ]]; then
  printf 'FAIL: nix ran although resolution failed\n' >&2
  exit 1
fi

expect_status 'apply with a failing nix flake update' 2 \
  env MOCK_NIX_FAIL=1 PATH="$pin_mock:$PATH" \
  bash "$pin_fixture/scripts/update-pinned-inputs.sh" --apply commit-pin
expect_pristine 'apply with a failing nix flake update'

expect_status 'apply with a lock nix did not refresh' 2 \
  env MOCK_NIX_NOOP=1 PATH="$pin_mock:$PATH" \
  bash "$pin_fixture/scripts/update-pinned-inputs.sh" --apply commit-pin
expect_pristine 'apply with a lock nix did not refresh'

pin_commit() {
  "$real_git" -C "$pin_fixture" -c user.name=test -c user.email=test@example.invalid \
    commit -q -am "$1"
}

printf '# "github:example/commit-pin/%s"\n' "$old_commit" >>"$pin_fixture/flake.nix"
pin_commit duplicate
expect_status 'apply refuses an ambiguous pin' 2 pin_run --apply commit-pin
expect_pristine 'apply refuses an ambiguous pin'
"$real_git" -C "$pin_fixture" reset -q --hard HEAD~1

# Evaluates to a pinned URL that is nowhere in the text, so it cannot be
# rewritten in place.
awk '{ print } /^  inputs = \{$/ { print "    interp-pin.url = \"github:example/interp/${\"v1\"}.0\";" }' \
  "$pin_fixture/flake.nix" >"$temp_root/flake.nix.interp"
cat "$temp_root/flake.nix.interp" >"$pin_fixture/flake.nix"
pin_commit interpolated
expect_status 'apply refuses an interpolated pin' 2 pin_run --apply interp-pin
expect_output 'interpolated pin is explained' 'expected one "github:example/interp/v1.0"' stderr
expect_pristine 'apply refuses an interpolated pin'
"$real_git" -C "$pin_fixture" reset -q --hard HEAD~1

: >"$nix_log"
expect_status 'apply advances every pinned input' 0 pin_run --apply
expect_output 'apply names what it updated' \
  'Updated commit-pin git-pin gitlab-pin query-pin tag-pin.'
if ! grep -qx 'flake update --flake .* commit-pin git-pin gitlab-pin query-pin tag-pin' "$nix_log" ||
  ! grep -qF "\"github:example/commit-pin/$new_commit\"" "$pin_fixture/flake.nix" ||
  ! grep -qF '"github:example/tag-pin/1.0.0"' "$pin_fixture/flake.nix" ||
  ! grep -qF '"gitlab:group%2Fsub/tool/v1.1"' "$pin_fixture/flake.nix" ||
  ! grep -qF "\"github:example/query?rev=$new_commit&dir=nix\"" "$pin_fixture/flake.nix" ||
  ! grep -qF "\"git+https://git.example.org/team/tool?ref=main&rev=$new_commit\"" "$pin_fixture/flake.nix" ||
  ! grep -qF "\"github:example/decoy/$old_commit\"" "$pin_fixture/flake.nix" ||
  ! grep -qF '"github:example/tag-pin/v0.8.2-fork"' "$pin_fixture/flake.nix" ||
  ! grep -qF "\"github:example/dotted.repo/$same_commit\"" "$pin_fixture/flake.nix"; then
  printf 'FAIL: apply did not rewrite exactly the outdated pins\n' >&2
  cat "$nix_log" "$pin_fixture/flake.nix" >&2
  exit 1
fi

printf 'Script regression tests passed.\n'
