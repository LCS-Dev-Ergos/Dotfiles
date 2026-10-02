local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local style = require("helpers.style")
local popup = require("helpers.popup")

local runtime = require("helpers.runtime")
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"
local refresh_media
local pending = false
local generation = 0

-- media.py renders covers at this many pixels; the bar shows them two pixels
-- per point (Retina) and three points inside the pill's top and bottom.
local artwork_pixels = 64
local cover_points = settings.pill.height - 6

local last_media_key = nil
local media_visible = false
local details = false
local text = { title = "", artist = "" }

-- Right-hand items are laid out from the right, so the pill reads title,
-- artist, cover from left to right. The bar grows leftwards, so expanding
-- the details never moves the cover. Its properties never change either:
-- SketchyBar stops reporting hover for an item whose geometry changes under
-- the pointer. A cover has no text to carry the pill's inset, so two empty
-- edge items of fixed width hold it.
local function edge(name)
  return sbar.add("item", name, {
    position = "right",
    drawing = false,
    width = settings.pill.inset,
    icon = { drawing = false },
    label = { drawing = false },
  })
end

local media_edge_right = edge("media.edge_right")

local media_cover = sbar.add("item", "media.cover", {
  position = "right",
  drawing = false,
  background = {
    image = {
      drawing = false,
      scale = cover_points / artwork_pixels,
      corner_radius = 4,
    },
    color = colors.transparent,
  },
  label = { drawing = false },
  icon = { drawing = false, string = icons.media.play_pause },
  updates = true,
})

local media_artist = sbar.add("item", "media.artist", {
  position = "right",
  drawing = false,
  scroll_texts = false,
  icon = { drawing = false },
  label = { color = colors.muted, max_chars = 24, padding_right = settings.spacing },
})

local media_title = sbar.add("item", "media.title", {
  position = "right",
  drawing = false,
  scroll_texts = false,
  icon = { drawing = false },
  label = { max_chars = 32, padding_right = settings.spacing },
})

local media_edge = edge("media.edge")

local media_pill = style.pill("media.pill", { media_edge.name, media_title.name, media_artist.name,
  media_cover.name, media_edge_right.name }, { popup = { horizontal = true } })

-- Title and artist show for a few seconds after a track change and while
-- the controls are open; the pill otherwise holds only the cover.
local function layout()
  media_edge:set({ drawing = media_visible })
  media_edge_right:set({ drawing = media_visible })
  media_cover:set({ drawing = media_visible })
  media_title:set({ drawing = media_visible and details and text.title ~= "" })
  media_artist:set({ drawing = media_visible and details and text.artist ~= "" })
end

local menu
local detail_timer = 0
local function show_details(show)
  detail_timer = detail_timer + 1
  details = show
  layout()
end

local function show_details_briefly()
  show_details(true)
  local token = detail_timer
  sbar.delay(5, function()
    if token == detail_timer and not menu.is_open() then show_details(false) end
  end)
end

-- Right-aligned, so the controls hang below the cover at the pill's end.
menu = popup.new(media_pill, {
  align = "right",
  open = function() show_details(true) end,
  close = function() show_details(false) end,
})

for _, control in ipairs({
  { "back", icons.media.back, "previous" },
  { "play_pause", icons.media.play_pause, "togglePlayPause" },
  { "forward", icons.media.forward, "next" },
}) do
  local command = control[3]
  local button = sbar.add("item", "media.control." .. control[1], {
    position = "popup." .. media_pill.name,
    width = settings.popup.row_height + 2 * settings.spacing,
    align = "center",
    icon = { string = control[2] },
    label = { drawing = false },
  })
  button:subscribe("mouse.clicked", function()
    sbar.exec(quote(runtime.nowplaying) .. " " .. command, function()
      refresh_media()
    end)
  end)
  menu.member(button)
end
for _, item in ipairs({ media_cover, media_title, media_artist }) do menu.trigger(item) end

local function apply_media(info)
  local drawing = type(info) == "table" and (info.state == "playing" or info.state == "paused")
  if not drawing then
    if not media_visible then return end
    media_visible = false
    last_media_key = nil
    menu.close()
    show_details(false)
    return
  end
  local key = table.concat({ info.state, info.app or "", info.artist or "", info.title or "", info.artwork or "" }, "\31")
  if key == last_media_key then return end
  local track_changed = not media_visible or text.title ~= (info.title or "") or text.artist ~= (info.artist or "")
  last_media_key = key
  media_visible = true
  text.title, text.artist = info.title or "", info.artist or ""
  local artwork = info.artwork and info.artwork ~= ""
  media_artist:set({ label = { string = text.artist } })
  media_title:set({ label = {
    string = text.title, color = info.state == "paused" and colors.muted or colors.white,
  } })
  media_cover:set({ icon = { drawing = not artwork },
    background = { image = artwork and { string = info.artwork, drawing = true } or { drawing = false } } })
  if track_changed then show_details_briefly() else layout() end
end

-- One snapshot at a time. A reply that never arrives must not stop polling,
-- so a request older than ten seconds is abandoned and its late reply ignored.
local request, requested_at = 0, 0
refresh_media = function()
  if pending and os.time() - requested_at < 10 then return end
  pending, requested_at = true, os.time()
  request = request + 1
  local current, token = generation, request
  sbar.exec(quote(runtime.python) .. " " .. quote(config_dir .. "/helpers/media.py")
    .. " " .. quote(runtime.nowplaying) .. " " .. artwork_pixels, function(info, code)
      if token ~= request then return end
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
