-- Tokyo Night. Roles, not just hues: text is primary content, muted is
-- secondary content, grey marks inactive content and outlines. The accent
-- hues only ever signal a state (load, charge, pending updates, focus).
return {
  black = 0xff1a1b26,
  white = 0xffc0caf5,
  red = 0xfff7768e,
  green = 0xff9ece6a,
  blue = 0xff7aa2f7,
  yellow = 0xffe0af68,
  orange = 0xffff9e64,
  magenta = 0xffbb9af7,
  grey = 0xff565f89,
  muted = 0xff9aa5ce,
  transparent = 0x00000000,

  bar = {
    bg = 0xff1a1b26,
  },
  -- Fill of every pill; the focused Desktop recolors only the border.
  pill = 0xff24283b,
  popup = {
    bg = 0xf21f2335,
    -- Darker than the grey outlines, so the edge reads without competing
    -- with the rows.
    border = 0xff3b4261,
  },
  bg1 = 0xff24283b,
  bg2 = 0xff1a1b26,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
