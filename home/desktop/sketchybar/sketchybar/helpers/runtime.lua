-- Exact dependencies substituted by Home Manager; launchd does not inherit Nix's PATH.
return {
  nowplaying = "@nowplaying@",
  statwell = "@statwell@",
  runtime_dir = "@runtime_dir@",
  network_interface = "@network_interface@",
  package_timeout_ms = @package_timeout_ms@,
  audio = "@switchaudio@",
  python = "@python@",
  yabai = "@yabai@",
  space_script = "@space_script@",
}
