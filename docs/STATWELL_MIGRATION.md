# StatWell consumer migration

StatWell is the shared status sampler for the Mac and Linux Home Manager
configurations. The package is pinned in `flake.nix`; the shared user service
is configured in `home/cli/statwell/default.nix`. The macOS service samples
`en0` and enables the Homebrew provider. The Linux service has no fixed network
interface or package provider. The Nix update provider is deliberately excluded.

## Consumers

| Surface | StatWell input | Local behavior retained |
| --- | --- | --- |
| SketchyBar CPU | `statwell_cpu` watch event | The old C source remains in Git history for rollback. |
| SketchyBar Wi-Fi rates | `statwell_network` watch event | Connection details and popup still use the existing Wi-Fi logic. |
| SketchyBar battery | `statwell_battery` watch event | The popup queries `pmset` for a time estimate on demand. |
| SketchyBar Homebrew | `statwell_homebrew` watch event | Brew actions remain in `brew_action.sh`; completion restarts the StatWell user service to refresh the count. |
| Kitty tab bar | Owner-only `snapshot.json` | A missing daemon triggers an asynchronous one-shot snapshot, at most once per five seconds. The legacy sampler remains available through `USE_STATWELL = False`. |

The SketchyBar widgets show an unknown value when an event reports an error or
its timestamp is stale. Kitty checks the schema, file ownership and mode,
daemon lock, and each metric's timestamp before using the snapshot. The old
SketchyBar C providers were removed after CPU, network, battery, and Homebrew
values appeared on the live bar, and the Homebrew refresh action succeeded.

## Activation and live checks

The user runs the macOS switch after a successful build:

```bash
cd ~/Dotfiles
nix build .#darwinConfigurations.LCSMacBook-Pro.system --no-link
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

After the switch, check the user service and take a snapshot:

```bash
launchctl print "user/$(id -u)/org.nix-community.home.statwell"
statwell snapshot
```

Reload SketchyBar and inspect CPU, upload/download rates, battery, and
Homebrew count on the real bar. Let at least one sample interval elapse, then
stop the service briefly to check stale/error presentation and recovery. Check
the battery popup estimate and a Homebrew refresh action separately. Open a
fresh Kitty tab and inspect memory, load, disk, and battery segments, then
reload the tab bar and repeat while the daemon is unavailable to exercise the
one-shot fallback. Confirm that ordinary redraws do not spawn probes.

## Verification status, 2026-09-28

The user activated the Darwin generation after a full build. The StatWell
launch agent is running and its snapshot reports `ok` for CPU, memory, load,
disk, battery, network, and Homebrew. Queries against the running SketchyBar
show values for all four migrated widgets. A middle-click Homebrew refresh
restarted the service and restored the count; no old C provider processes
remain. Kitty's active configuration was reloaded, and its deployed snapshot
reader returns fresh memory, load, disk, and battery values. Visual inspection
of the tab bar and battery popup is still pending.

The Linux Home Manager output evaluates, but this repository has no live
`lcs-legion-arch` build or switch evidence. Its systemd user service and Kitty
tab bar require checks on that host before claiming Linux migration complete.
The pinned StatWell input uses authenticated Git transport because GitHub's
archive endpoint returned 404 for the private repository. Linux deployment
therefore also requires Git access to that repository.

## Rollback

For an entire macOS generation, the user can run
`sudo darwin-rebuild --rollback switch`; see
[Nix environment guide](NIX_ENVIRONMENT_GUIDE.md#rollback). To roll back only
SketchyBar, restore `home/desktop/sketchybar/` from the pre-migration commit
`f489fbd`, including its native provider sources, build rules, and Brew action,
then build and switch. To roll back only Kitty, set `USE_STATWELL = False` in
`home/terminals/kitty/kitty/tab_bar.py`, then build and switch. Git history
retains the removed C providers; the active StatWell service can remain for the
other consumer during a one-consumer rollback.

## Release gate

This consumer migration is not a first stable release. Before the first
stable StatWell version, complete the security, correctness, robustness, and
performance audit in
[StatWell's release audit plan](https://github.com/LCS-Dev-Ergos/StatWell/blob/main/docs/release-audit.md),
including measured daemon idle CPU/RSS and sample latency.
