# Retired HyDE Integration

The CachyOS output replaces the former Arch desktop entrypoint. No active
flake output imports `home/desktop/hypr` or `home/desktop/hyprdots`.
Their original files and `hosts/lcs-legion-arch/home.nix` remain available
for historical reference.

The host entrypoint in `hosts/lcs-dev-legion-cachy/home.nix` selects the
replacement desktop modules explicitly. Native packages own graphical
runtimes; Home Manager owns their configuration. Cava configuration is
immutable on CachyOS, so external theme writers must not modify the checkout.

The original Zsh assets in `home/shells/zsh/config/conf.d/hyde/`,
`user.zsh` and `prompt.zsh` are retained but excluded from deployed shell
sources. Startup does not read those assets or the home-local
`~/.hyde.zshrc` and `~/.user.zsh` overrides. Generic Linux environment
defaults live in `conf.d/linux/env.zsh`; plugin and prompt ownership remains
shared across desktops.

Restoring the retired installers or autostart configuration would bypass the
current package, configuration and session boundaries. Any useful legacy
customization must be ported explicitly into the selected modules.
