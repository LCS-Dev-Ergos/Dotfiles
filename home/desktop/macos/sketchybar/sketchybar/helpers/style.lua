-- The bar's visual language: pills, the gaps between them, and the fonts.
--
-- Every item is its own window, sized to its icon and label but not to its
-- padding, while a bracket's window spans its members and their padding. A
-- click raises the window it lands on, so a click on a pill's padding would
-- raise the bracket above its items and its fill would hide them. Members
-- of a pill therefore have no item padding: the inset lives in the outer
-- icon and label padding, so the items' windows tile the whole pill.
local colors = require("colors")
local settings = require("settings")

local M = {}

local font, size = settings.font, settings.type

-- Fresh tables per call: callers may adjust a copy without touching others.
local function face(family, style, points)
  return function() return { family = family, style = font.style_map[style], size = points } end
end
M.font = {
  icon = face(font.text, "Semibold", size.icon),
  text = face(font.text, "Semibold", size.text),
  body = face(font.text, "Regular", size.text),
  strong = face(font.text, "Bold", size.text),
  number = face(font.numbers, "Semibold", size.text),
  space  = face(font.numbers, "Bold", size.space),
  small  = face(font.numbers, "Bold", size.small),
  small_icon = face(font.text, "Bold", size.small),
}

function M.merge(target, values)
  for key, value in pairs(values or {}) do
    if type(value) == "table" and type(target[key]) == "table" then
      M.merge(target[key], value)
    else
      target[key] = value
    end
  end
  return target
end

--- Background of a pill: a bracket's, or a single item's own.
function M.pill_background(overrides)
  return M.merge({
    drawing = true,
    color = colors.pill,
    border_width = 0,
    height = settings.pill.height,
    corner_radius = settings.pill.corner_radius,
  }, overrides)
end

--- A fixed, right-aligned cell of `width` that ends a pill: the inset is
--- part of the cell, because SketchyBar ignores a fixed cell's padding when
--- it measures the item.
function M.end_cell(width)
  return { width = width + settings.pill.inset, align = "right",
    padding_right = settings.pill.inset }
end

--- Wraps the members in one pill. Members must have no item padding.
function M.pill(name, members, overrides)
  overrides = overrides or {}
  overrides.background = M.pill_background(overrides.background)
  return sbar.add("bracket", name, members, overrides)
end

--- Fixed space between two pills, settings.pill.gap unless `width` says
--- otherwise. A `space` gap follows its Desktop's visibility, so a hidden
--- Desktop leaves no hole behind.
function M.gap(name, position, space, width)
  return sbar.add(space and "space" or "item", name, {
    position = position,
    space  = space,
    script = space and "" or nil,
    width  = width or settings.pill.gap,
    icon   = { drawing = false },
    label  = { drawing = false },
    background = { drawing = false },
  })
end

return M
