{ ... }:
{
  # config uses ';' comments, which aren't valid TOML, and programs.cava
  # only offers a settings attrset (no raw extraConfig passthrough) --
  # routing this through its INI-style generator would risk the same
  # comment loss and casing issues found with btop. Linking everything
  # raw preserves the file (heavily documented with commented-out
  # defaults) exactly as-is.
  programs.cava.enable = true;

  xdg.configFile."cava/config".source = ./config;
  xdg.configFile."cava/frappe.cava".source = ./frappe.cava;
  xdg.configFile."cava/shaders/bar_spectrum.frag".source = ./shaders/bar_spectrum.frag;
  xdg.configFile."cava/shaders/pass_through.vert".source = ./shaders/pass_through.vert;
  xdg.configFile."cava/shaders/northern_lights.frag".source = ./shaders/northern_lights.frag;
}
