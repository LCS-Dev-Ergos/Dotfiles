local icons = require("icons")
local colors = require("colors")

local whitelist = { ["TIDAL"] = true,
                    ["Spotify"] = true,
                    ["Music"] = true };
local last_media_key = nil

local media_cover = sbar.add("item", {
  position = "right",
  background = {
    image = {
      string = "media.artwork",
      scale = 0.85,
      corner_radius = 9,
      border_color = colors.grey,
      border_width = 1,
    },
    color = colors.transparent,
  },
  label = { drawing = false },
  icon = { drawing = false },
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
  icon = { drawing = false },
  label = {
    width = 0,
    font = { size = 9 },
    color = colors.with_alpha(colors.white, 0.6),
    max_chars = 18,
    y_offset = 6,
  },
})

local media_title = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = 3,
  padding_right = 0,
  icon = { drawing = false },
  label = {
    font = { size = 11 },
    width = 0,
    max_chars = 16,
    y_offset = -5,
  },
})

sbar.add("item", {
  position = "popup." .. media_cover.name,
  icon = { string = icons.media.back },
  label = { drawing = false },
  click_script = "command -v nowplaying-cli >/dev/null 2>&1 && nowplaying-cli previous",
})
sbar.add("item", {
  position = "popup." .. media_cover.name,
  icon = { string = icons.media.play_pause },
  label = { drawing = false },
  click_script = "command -v nowplaying-cli >/dev/null 2>&1 && nowplaying-cli togglePlayPause",
})
sbar.add("item", {
  position = "popup." .. media_cover.name,
  icon = { string = icons.media.forward },
  label = { drawing = false },
  click_script = "command -v nowplaying-cli >/dev/null 2>&1 && nowplaying-cli next",
})

local interrupt = 0
local function animate_detail(detail)
  if (not detail) then interrupt = interrupt - 1 end
  if interrupt > 0 and (not detail) then return end

  media_artist:set({ label = { width = detail and "dynamic" or 0 } })
  media_title:set({ label = { width = detail and "dynamic" or 0 } })
end

media_cover:subscribe("media_change", function(env)
  if not env.INFO then return end
  if whitelist[env.INFO.app] then
    local media_key = table.concat({
      env.INFO.app or "",
      env.INFO.state or "",
      env.INFO.artist or "",
      env.INFO.title or "",
    }, "\31")
    if media_key == last_media_key then return end
    last_media_key = media_key

    local drawing = (env.INFO.state == "playing")
    media_artist:set({ drawing = drawing, label = env.INFO.artist, })
    media_title:set({ drawing = drawing, label = env.INFO.title, })
    media_cover:set({ drawing = drawing })

    if drawing then
      animate_detail(true)
      interrupt = interrupt + 1
      sbar.delay(5, animate_detail)
    else
      media_cover:set({ popup = { drawing = false } })
    end
  end
end)

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
