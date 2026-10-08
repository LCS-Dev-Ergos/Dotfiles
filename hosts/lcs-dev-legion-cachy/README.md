# CachyOS Configuration

This configuration defines application settings and the Hyprland session for
CachyOS. Standalone Home Manager shares the application
modules used by macOS; the operating system retains ownership of the kernel,
graphics drivers, graphical runtimes and login infrastructure.

## Configuration State

The host entrypoint imports shared applications, Linux settings and
native Hyprland configuration. Caelestia is disabled: its retained module is
not imported, and its service and IPC bindings are absent from the selected
configuration. The retained source is not an installation requirement.
No replacement desktop-shell configuration is selected here.

| Host property | Value |
| --- | --- |
| Flake output | `homeConfigurations."lcs-dev@LCS.Dev-Legion-Cachy"` |
| Platform | `x86_64-linux` |
| Account and home | `lcs-dev`, `/home/lcs-dev` |
| Configuration checkout | `/home/lcs-dev/Dotfiles` |
| Home Manager state version | `26.05` |

These values are declared in `flake.nix` and the host entrypoint. The state
version controls Home Manager compatibility defaults; it is not a package
version or an instruction to upgrade the operating system. The retired Arch
entrypoint remains in the repository without an active flake output.

## Architecture and Ownership

`home/common.nix` contains shared application configuration, and
`home/linux.nix` adds Linux-specific modules. The host entrypoint selects its
desktop modules explicitly. Platform differences stay inside shared modules
where possible; distribution detection does not select a desktop.

| Responsibility | Owner |
| --- | --- |
| Kernel, NVIDIA drivers, PAM, display manager and power policy | CachyOS |
| Hyprland, UWSM, Qt, portals, polkit and KWallet executables | Native packages |
| Graphical terminal executables | Native packages |
| Portable CLI tools and application configuration | Home Manager |
| Session lifecycle | UWSM and session-scoped systemd user units |
| Wallets, clipboard history and application-generated data | User data outside the checkout and Nix store |

The `nativeGraphics` host fact suppresses Nix-owned Alacritty, Ghostty,
WezTerm and ueberzugpp executables while retaining their shared configuration.
This avoids mixing independently packaged graphical runtimes and native
libraries. Cava configuration is immutable on this host.

HyDE compositor and shell assets remain available for historical reference.
They are excluded from the active desktop and deployed Zsh source.
`~/.hyde.zshrc` and `~/.user.zsh` do not participate in startup. Generic
Linux environment defaults live in `conf.d/linux/env.zsh`; prompt and plugin
ownership remains in the shared Zsh modules.

## Session Integration

Native Hyprland uses the Lua configuration in `home/desktop/hyprland/`.
`hyprland.lua` loads `legion.lua`, which defines host-specific input and
display settings. The startup hook calls `uwsm finalize` once the compositor
environment is ready. UWSM owns environment import, XDG autostart, session
startup and teardown; Home Manager's Hyprland systemd integration is disabled
to avoid a competing lifecycle.

The native session entry is **Hyprland (uwsm-managed)**. KDE remains an
independent recovery and daily-use session. Session transitions require logout;
concurrent graphical sessions for the same account can share stale D-Bus and
systemd activation state.

The polkit agent and clipboard history units are bound to
`wayland-session@hyprland.desktop.target` through `After`, `PartOf`,
`Requisite` and `WantedBy`, with a Hyprland desktop condition. They are not
attached to the generic user default target. Qt and NVIDIA session variables
are scoped through `uwsm/env-hyprland`, so they do not alter KDE.

No desktop shell, notification daemon or screen locker is provisioned by the
selected Hyprland modules. Those capabilities require an explicitly selected
native implementation; the retained Caelestia module must not be treated as an
active service.

## Portals, Secrets and Power Policy

Only Hyprland's portal preference file is managed. The Hyprland backend handles
screen capture, GTK supplies fallback interfaces, KDE supplies file selection
and KWallet supplies Secret Service. Portal processes remain D-Bus activated;
parallel manually launched providers would bypass that ownership.

The compositor requests the native `org.kde.secretservicecompat` D-Bus service.
CachyOS owns KWallet startup and PAM integration. Home Manager neither installs
a second secret provider nor modifies authentication policy. Wallet unlock,
password login, application secret storage and screen locking require runtime
verification in the selected session.

NVIDIA driver parameters, udev rules, system sleep targets and suspend/resume
services remain operating-system responsibilities. Home Manager does not
enable suspend or hibernation. An existing operating-system mitigation must be
preserved until suspend/resume testing establishes a replacement policy.

## Native Prerequisites and Reproducibility

Before activation, inspect the configured native repositories for Hyprland,
UWSM, the portal backends, the KDE polkit agent, KWallet, Qt Wayland, Kitty,
PipeWire tools, brightnessctl, playerctl, wl-clipboard and cliphist. Application
bindings also require their corresponding native applications, including
Dolphin, Firefox and VS Code.

Native repository metadata describes available packages rather than a locked
machine state. Reproducible recovery therefore requires the reviewed package
inventory, compatible versions and retained package artifacts or a defined
repository snapshot alongside the Nix lockfile. A Home Manager build alone
does not establish native-runtime reproducibility.

The development recovery target combines shared configuration with canonical
native ecosystem-manager installation on macOS and Arch/CachyOS, and nixpkgs
adapters on NixOS.
Project manifests select language versions and dependencies. Additional
package managers are introduced only when the selected native installation
requires them. The flake does not expose a complete NixOS host or a
fully locked native toolchain baseline.

## Build, Activation and Rollback

Build from the reviewed checkout before changing the active generation:

```sh
nix build '.#homeConfigurations."lcs-dev@LCS.Dev-Legion-Cachy".activationPackage' \
  --no-link --print-out-paths
```

Git flakes include tracked source only. New source files must be registered
before evaluation. Build success validates the Nix configuration and closure;
it does not install native prerequisites or validate rendering and input.

Before activation, save the current Home Manager generation, native package
inventory, relevant user-unit state and any home files that collide with the
generated `home-files` tree. Store private backups outside the repository.
Whole-directory symlinks require particular care: a per-file backup cannot
make a linked parent directory safe.

Activate only the completed generation, from KDE or a recoverable TTY:

```sh
HOME_MANAGER_BACKUP_EXT=<unique-backup-suffix> <generation>/activate
```

The suffix renames a colliding file in place (`~/.zshrc` becomes
`~/.zshrc.<suffix>`); activation stops instead when that name already exists,
so each activation needs a fresh suffix. The generation installs the
`home-manager` command from the flake's Home Manager input. Later switches
build with it first, then activate the same build:

```sh
home-manager build --flake ~/Dotfiles
home-manager switch --flake ~/Dotfiles -b <unique-backup-suffix>
```

If an earlier generation exists, its activation script restores managed
configuration. First-activation recovery instead requires restoring the
recorded profile state and backed-up collision files. Home Manager rollback
does not undo native package transactions, wallets or generated application
data. Native rollback requires retained compatible package artifacts or an
operating-system snapshot.

Acceptance includes login and logout in both desktops, session-bound unit
startup and teardown, compositor configuration errors, NVIDIA rendering,
input and display scaling, audio and brightness controls, polkit prompts,
wallet access, file selection and screen sharing. Lock/unlock, reboot recovery
and suspend/resume on the hardware are separate checks; build success must not be
reported as their completion.
