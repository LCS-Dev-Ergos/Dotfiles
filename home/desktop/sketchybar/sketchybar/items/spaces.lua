local colors = require("colors")
local runtime = require("helpers.runtime")
local space_pill = require("helpers.space_pill")

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local spaces = {}

-- Mission-control indices run across displays, as yabai numbers them. An item
-- is drawn on the display that holds its space and hidden while that space
-- does not exist, so every Desktop of every display gets its number.
local max_spaces = 16

local function valid_space_id(sid)
  sid = tostring(sid or "")
  return sid:match("^%d+$") and sid or nil
end

for i = 1, max_spaces, 1 do
  local space, select = space_pill.add("space", i, { space = i })
  spaces[i] = space

  -- Middle click previews the Desktop in a popup.
  local space_popup = sbar.add("item", "space.preview." .. i, {
    position = "popup." .. space.name,
    background = {
      drawing = true,
      image = {
        corner_radius = 9,
        scale = 0.2,
        border_color = colors.grey,
        border_width = 1,
      },
    },
  })

  -- Every Desktop item receives each change, and each set makes SketchyBar
  -- redraw. Only the items whose selection changed have anything to set.
  space:subscribe("space_change", function(env)
    select(env.SELECTED == "true")
  end)

  space:subscribe("mouse.clicked", function(env)
    local sid = valid_space_id(env.SID)
    if not sid then return end

    if env.BUTTON == "other" then
      space_popup:set({ background = { image = "space." .. sid } })
      space:set({ popup = { drawing = "toggle" } })
    else
      if env.BUTTON == "right" then
        -- Handle right click to destroy the space
        sbar.exec(shell_quote(runtime.yabai) .. " -m space --destroy " .. sid)
      else
        -- Handle left click to switch space. The yabai module's space.sh
        -- (shared with skhd) fades the space in and focuses its frontmost
        -- window.
        sbar.exec(shell_quote(runtime.space_script) .. " focus " .. sid,
          function(_, code)
            if code ~= 0 then
              print("SketchyBar: space focus failed for " .. sid .. " (exit " .. tostring(code) .. ")")
            end
          end)
      end
    end
  end)

  space:subscribe("mouse.exited", function(_)
    space:set({ popup = { drawing = false } })
  end)
end

local space_window_observer = sbar.add("item", "spaces.observer", {
  drawing = false,
  updates = true,
})

-- WindowServer emits bursts while the session changes. Keep only the latest
-- icon list per space and apply it once, without starting layout animations.
local last_icons, pending_icons = {}, {}
local refresh_pending, locked = false, false
local function flush_icons()
  refresh_pending = false
  if locked then return end
  for sid, line in pairs(pending_icons) do
    if last_icons[sid] ~= line then
      spaces[sid]:set({ label = line })
      last_icons[sid] = line
    end
  end
  pending_icons = {}
end
sbar.add("event", "session_locked", "com.apple.screenIsLocked")
sbar.add("event", "session_unlocked", "com.apple.screenIsUnlocked")
space_window_observer:subscribe("session_locked", function() locked = true end)
space_window_observer:subscribe("session_unlocked", function()
  locked = false
  if not refresh_pending then
    refresh_pending = true
    sbar.delay(0.3, flush_icons)
  end
end)
space_window_observer:subscribe("space_windows_change", function(env)
  if type(env.INFO) ~= "table" or type(env.INFO.apps) ~= "table" then return end
  local sid = tonumber(env.INFO.space)
  if not sid or not spaces[sid] then return end
  pending_icons[sid] = space_pill.icons(env.INFO.apps)
  if not locked and not refresh_pending then
    refresh_pending = true
    sbar.delay(0.15, flush_icons)
  end
end)
