#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ BLOG WORKFLOW COMMON LAYER ++++++++++++++++++++++ #
# ============================================================================ #
# Cross-command primitives shared by the blog command module.
# ============================================================================ #

_blog_common_ready() {
  typeset -f _blog_acquire_lock >/dev/null 2>&1 &&
    typeset -f _blog_release_lock >/dev/null 2>&1
}

if [[ -n "${_BLOG_COMMON_LOADED:-}" ]] && _blog_common_ready; then
  unfunction _blog_common_ready 2>/dev/null
  return 0
fi

# -----------------------------------------------------------------------------
# _blog_acquire_lock
# @internal
# @description Acquires the mkdir-based blog workflow lock, reclaiming a stale
# lock left by a dead process.
# @noargs
# @exitcode 1 If another workflow is running or the lock cannot be created.
# -----------------------------------------------------------------------------
_blog_acquire_lock() {
  local lock_parent="${BLOG_LOCK_DIR:h}"
  mkdir -p "$lock_parent" 2>/dev/null || {
    blog_error "Cannot create lock directory parent: $lock_parent"
    return 1
  }
  if mkdir "$BLOG_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >| "$BLOG_LOCK_DIR/pid"
    return 0
  fi

  local lock_pid
  lock_pid=$(<"$BLOG_LOCK_DIR/pid" 2>/dev/null)
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    blog_error "Another blog workflow is running (PID: $lock_pid)."
    return 1
  fi

  rm -f -- "$BLOG_LOCK_DIR/pid" 2>/dev/null
  rmdir "$BLOG_LOCK_DIR" 2>/dev/null || {
    blog_error "Cannot reclaim stale lock: $BLOG_LOCK_DIR"
    return 1
  }
  mkdir "$BLOG_LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" >| "$BLOG_LOCK_DIR/pid"
}

# -----------------------------------------------------------------------------
# _blog_release_lock
# @internal
# @description Releases the blog workflow lock; safe to call even if not held.
# @noargs
# -----------------------------------------------------------------------------
_blog_release_lock() {
  rm -f -- "$BLOG_LOCK_DIR/pid" 2>/dev/null
  rmdir "$BLOG_LOCK_DIR" 2>/dev/null
}

_BLOG_COMMON_LOADED=1
unfunction _blog_common_ready 2>/dev/null

# ============================================================================ #
# End of blog/_common.zsh
