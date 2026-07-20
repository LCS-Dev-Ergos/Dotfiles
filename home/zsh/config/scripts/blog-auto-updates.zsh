#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++ BLOG AUTOMATION COMPATIBILITY LOADER +++++++++++++++++++ #
# ============================================================================ #
# Thin lazy-loadable public surface: each blog_* wrapper below sources
# blog/commands.zsh on first call and replaces itself with the real
# implementation, so the historical flat function names keep working. The
# canonical Python backend lives in blog/python/; see blog/commands.zsh for
# shdoc documentation of each command.
# ============================================================================ #

typeset -g _BLOG_LOADER_DIR="${${(%):-%N}:A:h}"

_blog_public_functions_loaded() {
  local fn
  for fn in \
    blog_log blog_info blog_warn blog_error blog_success blog_debug \
    blog_validate_location blog_validate_path blog_validate_managed_path \
    blog_safe_clear_dir blog_set_defaults blog_load_config \
    blog_create_config_template blog_create_backup blog_cleanup_backups \
    blog_check_command blog_check_dir blog_check_file blog_run_with_timeout \
    blog_detect_git_changes blog_detect_hash_changes blog_backup_before_sync \
    blog_init_git blog_sync_posts blog_detect_changes blog_update_frontmatter \
    blog_process_images blog_build_hugo blog_commit_changes blog_push_main \
    blog_deploy_hostinger blog_run_all blog_status blog_help; do
    typeset -f "$fn" >/dev/null 2>&1 || return 1
  done
}

if [[ -n "${_BLOG_WORKFLOW_LOADED:-}" ]] && _blog_public_functions_loaded; then
  unfunction _blog_public_functions_loaded 2>/dev/null
  return 0
fi

_blog_lazy_dispatch() {
  local command_name="$1"
  shift
  local module="${_BLOG_LOADER_DIR}/blog/commands.zsh"
  unfunction "$command_name" 2>/dev/null
  source "$module" || return 1
  typeset -f "$command_name" >/dev/null 2>&1 || {
    print -u2 "blog: command not found after loading workflow: $command_name"
    return 127
  }
  "$command_name" "$@"
}

blog_log() { _blog_lazy_dispatch blog_log "$@"; }
blog_info() { _blog_lazy_dispatch blog_info "$@"; }
blog_warn() { _blog_lazy_dispatch blog_warn "$@"; }
blog_error() { _blog_lazy_dispatch blog_error "$@"; }
blog_success() { _blog_lazy_dispatch blog_success "$@"; }
blog_debug() { _blog_lazy_dispatch blog_debug "$@"; }
blog_validate_location() { _blog_lazy_dispatch blog_validate_location "$@"; }
blog_validate_path() { _blog_lazy_dispatch blog_validate_path "$@"; }
blog_validate_managed_path() { _blog_lazy_dispatch blog_validate_managed_path "$@"; }
blog_safe_clear_dir() { _blog_lazy_dispatch blog_safe_clear_dir "$@"; }
blog_set_defaults() { _blog_lazy_dispatch blog_set_defaults "$@"; }
blog_load_config() { _blog_lazy_dispatch blog_load_config "$@"; }
blog_create_config_template() { _blog_lazy_dispatch blog_create_config_template "$@"; }
blog_create_backup() { _blog_lazy_dispatch blog_create_backup "$@"; }
blog_cleanup_backups() { _blog_lazy_dispatch blog_cleanup_backups "$@"; }
blog_check_command() { _blog_lazy_dispatch blog_check_command "$@"; }
blog_check_dir() { _blog_lazy_dispatch blog_check_dir "$@"; }
blog_check_file() { _blog_lazy_dispatch blog_check_file "$@"; }
blog_run_with_timeout() { _blog_lazy_dispatch blog_run_with_timeout "$@"; }
blog_detect_git_changes() { _blog_lazy_dispatch blog_detect_git_changes "$@"; }
blog_detect_hash_changes() { _blog_lazy_dispatch blog_detect_hash_changes "$@"; }
blog_backup_before_sync() { _blog_lazy_dispatch blog_backup_before_sync "$@"; }
blog_init_git() { _blog_lazy_dispatch blog_init_git "$@"; }
blog_sync_posts() { _blog_lazy_dispatch blog_sync_posts "$@"; }
blog_detect_changes() { _blog_lazy_dispatch blog_detect_changes "$@"; }
blog_update_frontmatter() { _blog_lazy_dispatch blog_update_frontmatter "$@"; }
blog_process_images() { _blog_lazy_dispatch blog_process_images "$@"; }
blog_build_hugo() { _blog_lazy_dispatch blog_build_hugo "$@"; }
blog_commit_changes() { _blog_lazy_dispatch blog_commit_changes "$@"; }
blog_push_main() { _blog_lazy_dispatch blog_push_main "$@"; }
blog_deploy_hostinger() { _blog_lazy_dispatch blog_deploy_hostinger "$@"; }
blog_run_all() { _blog_lazy_dispatch blog_run_all "$@"; }
blog_status() { _blog_lazy_dispatch blog_status "$@"; }
blog_help() { _blog_lazy_dispatch blog_help "$@"; }

unfunction _blog_public_functions_loaded 2>/dev/null

# ============================================================================ #
# End of blog-auto-updates.zsh
