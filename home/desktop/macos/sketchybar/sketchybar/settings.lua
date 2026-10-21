-- Geometry and type scale for the whole bar. Widgets take every margin, gap
-- and font size from here (through helpers/style.lua) instead of local
-- numbers, so one change here moves the whole bar consistently.
return {
  bar = {
    height = 40,
    -- Bar edge to the outermost pills; equal to the pills' vertical margin.
    margin = 7,
  },

  -- Every group on the bar (Apple menu, each Desktop, the front app, each
  -- widget, the clock) is one pill of this shape.
  pill = {
    height = 26,
    corner_radius = 9,
    -- Pill edge to its first and last content.
    inset = 9,
    -- Between neighbouring pills.
    gap = 7,
  },

  -- Desktops are roomier pills, and the focused one is circled by a ring.
  -- SketchyBar draws a border inside its rectangle, so the ring's rectangle
  -- extends the border width plus a one-point hairline of bar color beyond
  -- the pill on every side.
  space = {
    inset = 14,
    spacing = 12,
    ring_width = 2,
    ring = 3,
  },

  -- Between an icon and its label inside a pill.
  spacing = 6,

  type = {
    text = 13,
    icon = 15,
    -- Desktop numbers.
    space = 14,
    -- Stacked network rates and the CPU overlay.
    small = 9,
  },

  -- Fixed cells keep a pill's width steady while its value changes. Values
  -- are right-aligned, so the pill's right margin never moves. A cell's
  -- padding does not count towards its width, so the cells that end a pill
  -- add the pill's inset themselves (helpers/style.lua).
  cell = {
    -- "100%" in SF Mono Semibold 13 measures 32.1 points.
    percent = 33,
    -- The widest volume symbol (speaker.wave.3.fill) at 15 points is 25.5.
    volume_icon = 26,
  },

  popup = {
    width = 280,
    -- A hairline in colors.popup.border separates a menu from what lies
    -- beneath it.
    border_width = 1,
    row_height = 30,
    text_size = 13,
    inset = 12,
    close_delay = 0.15,
  },

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- SF Pro and SF Mono, installed by Homebrew (darwin/homebrew.nix).
  font = require("helpers.default_font"),
}
