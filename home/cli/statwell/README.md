# StatWell Consumers

StatWell is the status sampler shared by the macOS and Linux Home Manager
configurations. Its package is pinned as a flake input, and this module
configures the shared user service. On macOS the service samples `en0` and
enables the Homebrew provider; on Linux it has no fixed network interface or
package provider. The Nix update provider is excluded.

The input is fetched over Git (`git+https`) at a pinned revision, so
evaluation needs read access to the StatWell repository.

## Consumers

| Surface | StatWell input | Local behavior |
| --- | --- | --- |
| SketchyBar CPU | `statwell_cpu` watch event | The previous C source remains in Git history for rollback. |
| SketchyBar Wi-Fi rates | `statwell_network` watch event | Connection details and the popup use the existing Wi-Fi logic. |
| SketchyBar battery | `statwell_battery` watch event | The popup queries `pmset` for a time estimate on demand. |
| SketchyBar Homebrew | `statwell_homebrew` watch event | Brew actions remain in `brew_action.sh`; completion restarts the StatWell user service to refresh the count. |
| Kitty tab bar | Owner-only `snapshot.json` | CPU uses the same normalized percentage as SketchyBar. A missing daemon triggers an asynchronous one-shot snapshot, at most once per five seconds. `USE_STATWELL = False` restores the legacy load sampler. |

The SketchyBar widgets show an unknown value when an event reports an error or
its timestamp is stale. Kitty checks the schema, file ownership and mode, the
daemon lock and each metric's timestamp before using the snapshot. The legacy
SketchyBar C providers are no longer packaged; Git history retains them.

When an unchanged sample becomes stale, the watcher sends one expiry event, so
a stalled daemon turns the widgets unknown. Kitty stops an in-flight one-shot
fallback as soon as the daemon recovers.

Before the daemon publishes its first Homebrew result, the Homebrew widget
shows a muted `?`; a completed failed check is marked in red. The Homebrew
check has a 30-second deadline on macOS; the Homebrew watcher inherits it and
disables metadata auto-update. A failed package check is retried after 30
seconds instead of waiting for the hourly cadence. While the daemon is
unavailable, the network watcher falls back to one-shot sampling on the
configured interface.

The module runs the service in the `gui` launchd domain, which belongs to the
login session that also runs SketchyBar. The CPU metric uses a one-second
daemon cadence on both platforms: Kitty reads the snapshot every second, and
SketchyBar receives the same sample through its watch event.

## Activation and Checks

Build, then switch:

```bash
nix build .#darwinConfigurations.LCSMacBook-Pro.system --no-link
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

After the switch, check the user service and take a snapshot:

```bash
launchctl print "gui/$(id -u)/org.nix-community.home.statwell"
statwell snapshot
```

Reload SketchyBar and inspect CPU, upload and download rates, battery and the
Homebrew count on the bar. Let at least one sample interval elapse, then stop
the service briefly to check the stale and error presentation and the recovery.
Check the battery popup estimate and a Homebrew refresh action separately. Open
a new Kitty tab and inspect the memory, CPU, disk and battery segments, then
reload the tab bar and repeat while the daemon is unavailable to exercise the
one-shot fallback. Ordinary redraws must not spawn probes.

On Linux, the systemd user service and the Kitty tab bar take the same checks
after a Home Manager switch.

## Rollback

`sudo darwin-rebuild switch --rollback` returns to the previous macOS
generation. To roll back only SketchyBar, restore `home/desktop/sketchybar/`
from the pre-migration commit `4f76c39`, including its native provider sources,
build rules and Brew action, then build and switch. To roll back only Kitty, set
`USE_STATWELL = False` in `home/terminals/kitty/kitty/tab_bar.py`, then build
and switch. The StatWell service can stay active for the other consumer during
a one-consumer rollback.

## Release Gate

This consumer integration precedes StatWell's first stable release. Before
that release,
[StatWell's release audit plan](https://github.com/LCS-Dev-Ergos/StatWell/blob/main/docs/release-audit.md)
requires a security, correctness, robustness and performance audit, including
measured daemon idle CPU and RSS and sample latency.
