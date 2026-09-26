_: {
  # Only the vendored theme file is managed here. ~/.config/zed/
  # is otherwise a real, unmanaged directory (settings.json,
  # conversations/, prompts/ -- live app state and real user
  # customization, currently on a different theme entirely), so only this
  # one file is placed, deliberately not touching anything else there.
  xdg.configFile."zed/themes/Tokyo Night.json".source = ./themes + "/Tokyo Night.json";
}
