local icons = require("icons")
local colors = require("colors")

local runtime = require("helpers.runtime")
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"
local refresh_media
local pending = false
local generation = 0

local last_media_key = nil
local media_visible = false

local media_cover = sbar.add("item", "media.cover", {
  position = "right",
  background = {
    image = {
      drawing = false,
      scale = 0.85,
      corner_radius = 9,
      border_color = colors.grey,
      border_width = 1,
    },
    color = colors.transparent,
  },
  label = { drawing = false },
  icon = { drawing = false, string = icons.media.play_pause },
  drawing = false,
  updates = true,
  popup = {
    align = "center",
    horizontal = true,
  }
})

local media_artist = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = 3,
  padding_right = 0,
  width = 0,
  scroll_texts = false,
  icon = { drawing = false },
  label = {
    width = 0,
    font = { size = 10 },
    color = colors.muted,
    max_chars = 18,
    y_offset = 6,
  },
})

local media_title = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = 3,
  padding_right = 0,
  scroll_texts = false,
  icon = { drawing = false },
  label = {
    font = { size = 12 },
    width = 0,
    max_chars = 16,
    y_offset = -5,
  },
})

for _, control in ipairs({
  { icons.media.back, "previous" },
  { icons.media.play_pause, "togglePlayPause" },
  { icons.media.forward, "next" },
}) do
  local command = control[2]
  local button = sbar.add("item", {
    position = "popup." .. media_cover.name,
    icon = { string = control[1] },
    label = { drawing = false },
  })
  button:subscribe("mouse.clicked", function()
    sbar.exec(quote(runtime.nowplaying) .. " " .. command, function()
      refresh_media()
    end)
  end)
end

local interrupt = 0
local function animate_detail(detail)
  if (not detail) then interrupt = interrupt - 1 end
  if interrupt > 0 and (not detail) then return end

  media_artist:set({ label = { width = detail and "dynamic" or 0 } })
  media_title:set({ label = { width = detail and "dynamic" or 0 } })
end

local function apply_media(info)
  local drawing = type(info) == "table" and (info.state == "playing" or info.state == "paused")
  if not drawing then
    if not media_visible then return end
    media_visible = false
    last_media_key = nil
    media_artist:set({ drawing = false })
    media_title:set({ drawing = false })
    media_cover:set({ drawing = false, popup = { drawing = false } })
    return
  end
  local key = table.concat({ info.state, info.app or "", info.artist or "", info.title or "", info.artwork or "" }, "\31")
  if key == last_media_key then return end
  last_media_key = key
  media_visible = true
  local artwork = info.artwork and info.artwork ~= ""
  media_artist:set({ drawing = true, label = info.artist or "" })
  media_title:set({ drawing = true, label = {
    string = info.title or "", color = info.state == "paused" and colors.muted or colors.white,
  } })
  media_cover:set({ drawing = true, icon = { drawing = not artwork },
    background = { image = artwork and { string = info.artwork, drawing = true } or { drawing = false } } })
  animate_detail(true)
  interrupt = interrupt + 1
  sbar.delay(5, animate_detail)
end

refresh_media = function()
  if pending then return end
  pending = true
  local current = generation
  sbar.exec(quote(runtime.python) .. " " .. quote(config_dir .. "/helpers/media.py")
    .. " " .. quote(runtime.nowplaying), function(info, code)
      pending = false
      if current ~= generation then return end
      apply_media(code == 0 and info or nil)
    end)
end

-- An invisible observer keeps polling even when playback is paused. Do not
-- subscribe to the obsolete native MediaRemote event/artwork path.
local observer = sbar.add("item", "media.observer", { drawing = false, updates = true, update_freq = 3 })
local sleeping = false
observer:subscribe({ "routine", "forced" }, function()
  if not sleeping then refresh_media() end
end)
observer:subscribe("system_will_sleep", function()
  sleeping = true
  generation = generation + 1
end)
observer:subscribe("system_woke", function()
  sleeping = false
  generation = generation + 1
  sbar.delay(2, refresh_media)
end)
refresh_media()

media_cover:subscribe("mouse.entered", function(env)
  interrupt = interrupt + 1
  animate_detail(true)
end)

media_cover:subscribe("mouse.exited", function(env)
  animate_detail(false)
end)

media_cover:subscribe("mouse.clicked", function(env)
  media_cover:set({ popup = { drawing = "toggle" }})
end)

media_title:subscribe("mouse.exited.global", function(env)
  media_cover:set({ popup = { drawing = false }})
end)
