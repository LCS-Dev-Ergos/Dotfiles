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
of the tab bar and battery popup was confirmed by the user after restarting
Kitty.

The subsequent StatWell audit found and fixed a stalled-daemon case: a watcher
now sends one expiry event when an unchanged sample becomes stale. StatWell
[PR #2](https://github.com/LCS-Dev-Ergos/StatWell/pull/2) merged as
`5213cac858af8ce1b33f2a06578ff334684fdbfe`; its Linux and macOS CI
passes. Kitty now stops an in-flight one-shot fallback immediately on daemon
recovery. The updated pin, both-host flake evaluation, Kitty and SketchyBar
tests, and full Darwin generation build pass. The user switched to this
audit-corrected generation on 2026-09-28.

A subsequent Homebrew refresh exposed a brief misleading `1!` in red while
`brew outdated --json=v2` reported two updates. A live restart reproduced the
same status path: the new daemon publishes `unavailable` before its first
Homebrew result, and the Lua widget treated that pending state as a failed
check with the prior count. The widget now shows a muted `?` during that
interval and still marks a completed failed check in red. The Homebrew check
has a 30-second deadline on macOS: an observed successful probe took 8.2
seconds, near the previous 10-second limit. The user activated these changes
on 2026-09-28; a live refresh showed `2` → muted `?` → `2`.

On 2026-09-29, both network labels showed `??? Bps`. The StatWell LaunchAgent
was absent from launchd although its managed plist remained installed.
Bootstrapping that service restored valid network rates immediately; why it
was unloaded is not yet known. During the outage, the network watcher fell
back to one-shot sampling without an interface and received `invalid_input`;
the same probe with `--interface en0` succeeded. The watcher now uses the
configured interface for fallback. Lua callback tests cover the command.
The new generation still needs a switch and live fallback verification.

The Linux Home Manager output evaluates, but this repository has no live
`lcs-legion-arch` build or switch evidence. Its systemd user service and Kitty
tab bar require checks on that host before claiming Linux migration complete.
The user confirmed that the host is not physically available today. Current
Dotfiles commits are also ahead of the remote `main`, so the deployment path
for that host must carry this branch before the switch.
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
