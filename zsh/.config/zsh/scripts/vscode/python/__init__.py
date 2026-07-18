# ============================================================================ #
"""
VS Code sync Python backend package.

Manages synchronization of VS Code Stable and Insiders editions, including:
- Extension symlink sharing between Stable and Insiders roots
- Duplicate extension cleanup with manifest-aware reference protection
- Profile and root manifest repair
- Non-extension item sync (settings, keybindings, snippets, MCP config)
- Missing extension recovery via CLI reinstall or compatibility aliases
- Native excluded-extension update isolation with rollback safety

Architecture overview::

    vscode_models          -- Shared dataclasses and enumerations
    vscode_fs              -- Low-level filesystem helpers (canonicalize, mtime)
    vscode_config          -- VscodePathsConfig: edition discovery, profile roots
    vscode_scanner         -- Extension root scanner and folder-name parser
    vscode_versions        -- Shell-compatible version comparison
    vscode_manifests       -- extensions.json parsing and reference collection
    vscode_planner         -- Cleanup-plan and symlink-drift planners
    vscode_cleanup         -- Quarantine-based duplicate cleanup application
    vscode_profiles        -- Manifest repair planning and safe application
    vscode_sync_apply      -- Non-destructive symlink repair and migration
    vscode_sync_workflow   -- Top-level status, setup, and remove workflows
    vscode_recovery        -- Missing extension reinstall and alias planning
    vscode_update          -- End-to-end extension update workflow
    cli                    -- argparse CLI exposing all subcommands

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #
