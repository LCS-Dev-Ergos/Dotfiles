-- Consistency checks for the bar's visual language (helpers/style.lua).
--
-- Loads every bar module against the in-memory `sbar` stub, rebuilds the
-- left and right item sequences in screen order, and checks that every
-- visible item belongs to a pill with the shared shape and margins, that
-- neighbouring pills are one gap apart, and that fonts come from the type
-- scale. It also keeps emoji out of the configuration.
--
-- Usage: lua style.lua <sketchybar-config-dir>

local root = assert(arg[1], "usage: lua style.lua <sketchybar-config-dir>")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
package.preload["helpers.runtime"] = function()
  return {
    nowplaying = "/fixture/nowplaying",
    statwell = "/nix/store/fixture-statwell/bin/statwell",
    network_interface = "en0",
    package_timeout_ms = 30000,
    python = "/fixture/python",
    audio = "/fixture/audio",
    yabai = "/fixture/yabai",
    space_script = "/fixture/space.sh",
  }
end

-- The real map is installed by Nix from the font release (default.nix).
package.preload["helpers.app_icon_map"] = function()
  return { TIDAL = ":tidal:", Music = ":music:" }
end

local fixture = dofile(root .. "/../tests/fixtures/sbar.lua")()
local items, commands = fixture.items, fixture.commands
sbar = fixture.api
local bar, defaults
function sbar.bar(props) bar = props end
function sbar.default(props) defaults = props end
function sbar.trigger() end

require("bar")
require("default")
require("items.apple")
require("items.menus")
require("items.spaces")
require("items.front_app")
require("items.calendar")
require("items.widgets")
require("items.media")
require("helpers.statwell").prepare()

local settings = require("settings")
local colors = require("colors")
local inset, gap = settings.pill.inset, settings.pill.gap

local failures = {}
local function check(condition, message)
  if not condition then failures[#failures + 1] = message end
end

-- The bar's own margin equals the pills' vertical margin.
check(bar.padding_left == settings.bar.margin and bar.padding_right == settings.bar.margin,
  "bar padding must be the shared margin")
check((settings.bar.height - settings.pill.height) / 2 == settings.bar.margin,
  "pills must sit one margin from the bar's top and bottom")
check(defaults.padding_left == 0 and defaults.padding_right == 0,
  "items start without padding; widgets state their spacing explicitly")
check(defaults.popup.background.border_width == settings.popup.border_width
    and settings.popup.border_width > 0 and defaults.popup.background.border_color == colors.popup.border,
  "menus must carry the popup border")

local function is_fill(background)
  return type(background) == "table" and background.color == colors.pill
    and background.height == settings.pill.height
    and background.corner_radius == settings.pill.corner_radius
end

-- A pill is a bracket with the shared fill, or (for the Desktops) an item
-- whose own background is that fill. Rings are transparent brackets.
local pill_of, ring_of = {}, {}
for _, item in ipairs(items) do
  if item.kind == "bracket" then
    local background = item.props.background or {}
    if background.color == colors.transparent then
      check(#item.members == 1 and background.border_width == settings.space.ring_width
        and background.height == settings.pill.height + 2 * settings.space.ring,
        item.name .. " must be a single Desktop ring of the shared size")
      ring_of[item.members[1]] = item.name
    else
      check(is_fill(background) and (background.border_width or 0) == 0,
        item.name .. " must use the shared pill background")
      for _, member in ipairs(item.members) do
        if not member:match("^/") then pill_of[member] = item.name end
      end
    end
  end
end

local function own_pill(item)
  return item.kind ~= "bracket" and is_fill(item.props.background) and item.name or nil
end

local function is_spacer(item)
  local props = item.props
  return type(props.width) == "number" and (props.padding_left or 0) == 0 and (props.padding_right or 0) == 0
    and props.icon and props.icon.drawing == false and props.label and props.label.drawing == false
end

-- Items laid out on one side of the bar, in screen order from the edge.
local function visible(position)
  local list = {}
  for _, item in ipairs(items) do
    local props = item.props
    if item.kind ~= "bracket" and props.drawing ~= false and not tostring(props.position):match("^popup%.")
        and (props.position or "left") == position then
      list[#list + 1] = item
    end
  end
  return list
end

-- The space between an item's window edge and its first or last content.
local function edge_padding(item, side)
  local props = item.props
  local icon = props.icon and props.icon.drawing ~= false and props.icon.string ~= nil
  local label = props.label and props.label.drawing ~= false
  -- An empty item of fixed width is itself the margin.
  if not icon and not label and type(props.width) == "number" then return props.width end
  local component = side == "left" and (icon and props.icon or label and props.label)
    or (label and props.label or icon and props.icon)
  if not component then return 0 end
  -- SketchyBar ignores a fixed cell's padding when it measures the item, so
  -- a fixed cell at a pill's edge must be wider than the inset it holds.
  local padding = component["padding_" .. side] or 0
  if type(component.width) == "number" and padding > 0 then
    check(component.width >= padding, item.name .. " has a fixed cell narrower than its inset")
  end
  return padding
end

local function inset_for(pill)
  return pill:match("^space%.") and settings.space.inset or inset
end

local function walk(position)
  local list = visible(position)
  -- Right-hand items are added from the bar's edge inwards; read them
  -- left to right like the screen does.
  if position == "right" then
    for i = 1, #list // 2 do list[i], list[#list - i + 1] = list[#list - i + 1], list[i] end
  end
  local function pill_id(item) return item and (pill_of[item.name] or own_pill(item)) end
  local current, distance
  for index, item in ipairs(list) do
    local pill = pill_id(item)
    local props = item.props
    if not pill then
      check(is_spacer(item), item.name .. " is neither in a pill nor a gap")
      if distance then distance = distance + props.width end
    else
      local own = own_pill(item) ~= nil
      if own then
        -- The Desktop's padding is the ring's room outside its fill.
        check(ring_of[item.name] and (props.padding_left or 0) == settings.space.ring
          and (props.padding_right or 0) == settings.space.ring,
          item.name .. " must leave room for its ring")
      else
        -- Item padding is outside the item's window but inside the
        -- bracket's: a click there would raise the fill above the items.
        check((props.padding_left or 0) == 0 and (props.padding_right or 0) == 0,
          item.name .. " has item padding inside the pill " .. pill)
      end
      if pill ~= current then
        if distance then
          local between = distance + (own and props.padding_left or 0)
          check(between == gap, pill .. " is " .. between .. " points from the pill before it")
        end
        check(edge_padding(item, "left") == inset_for(pill),
          pill .. " must start one inset from its edge (" .. item.name .. ")")
      end
      if pill_id(list[index + 1]) ~= pill then
        check(edge_padding(item, "right") == inset_for(pill),
          pill .. " must end one inset from its edge (" .. item.name .. ")")
        distance = own and props.padding_right or 0
      end
      current = pill
    end
  end
  return list
end
walk("left")
walk("right")

-- Popup rows have no item padding either: their margins would expose the
-- menu's background window to clicks.
for _, item in ipairs(items) do
  if tostring(item.props.position):match("^popup%.") then
    check((item.props.padding_left or 0) == 0 and (item.props.padding_right or 0) == 0,
      item.name .. " has item padding inside its menu")
  end
end

-- Media: the pill grows with title and artist, keeps its margins, and the
-- cover stays at the fixed (right) end so hovering never moves it away.
for i = #commands, 1, -1 do
  if commands[i][1]:find("media.py", 1, true) then
    commands[i][2]({ state = "playing", app = "TIDAL", title = "Track", artist = "Artist", artwork = "" }, 0)
    break
  end
end
local right = walk("right")
local order = {}
for _, item in ipairs(right) do
  if item.name:match("^media%.") then order[#order + 1] = item.name end
end
check(table.concat(order, " ") == "media.edge media.title media.artist media.cover media.edge_right",
  "media reads title, artist, cover with the cover at the fixed end: " .. table.concat(order, " "))

-- Hover menus hang from pill brackets. SketchyBar stops reporting hover for
-- an item after the pointer passed through that item's own popup.
for _, item in ipairs(items) do
  local host = tostring(item.props.position):match("^popup%.(.+)$")
  if host and not host:match("^space%.") then
    check(items[host] and items[host].kind == "bracket",
      item.name .. " belongs to a menu hosted by " .. host .. ", which is not a pill bracket")
  end
end

-- Fonts come from the type scale.
local icon_sizes = { [settings.type.icon] = true, [settings.type.small] = true, [settings.type.space] = true }
local label_sizes = { [settings.type.text] = true, [settings.type.small] = true }
for _, item in ipairs(items) do
  local props = item.props
  if props.icon and type(props.icon.font) == "table" then
    check(icon_sizes[props.icon.font.size] or props.icon.font.size == settings.type.text,
      item.name .. " icon size " .. tostring(props.icon.font.size) .. " is outside the type scale")
  end
  if props.label and type(props.label.font) == "table" then
    check(label_sizes[props.label.font.size],
      item.name .. " label size " .. tostring(props.label.font.size) .. " is outside the type scale")
  end
end

-- Symbols are SF Symbols (Supplementary Private Use Area-B), never emoji.
local function each_symbol(table_, path, visit)
  for key, value in pairs(table_) do
    if type(value) == "table" then each_symbol(value, path .. "." .. key, visit)
    elseif type(value) == "string" then visit(path .. "." .. key, value) end
  end
end
each_symbol(require("icons"), "icons", function(name, value)
  for _, code in utf8.codes(value) do
    check(code >= 0x100000, name .. " is not an SF Symbol")
  end
end)
local function emoji(code)
  return (code >= 0x1F000 and code <= 0x1FAFF) or (code >= 0x2600 and code <= 0x27BF)
end
local listing = io.popen("find '" .. root .. "' -type f \\( -name '*.lua' -o -name '*.py' -o -name '*.sh' \\)")
for path in listing:lines() do
  local file = assert(io.open(path, "rb"))
  local source = file:read("a")
  file:close()
  local ok, err = pcall(function()
    for _, code in utf8.codes(source) do
      check(not emoji(code), path .. " contains the emoji U+" .. string.format("%X", code))
    end
  end)
  check(ok, path .. " is not valid UTF-8: " .. tostring(err))
end
listing:close()

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print("bar style consistency: PASS")
