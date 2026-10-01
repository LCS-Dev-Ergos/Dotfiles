local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")
local popup = require("helpers.popup")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local network_state = {
  iface = nil,
  service = nil,
  refresh_generation = 0,
}

statwell.watch("network", "statwell_network")

local function resolve_network(callback)
  sbar.exec([[
    hardware_ports="$(networksetup -listallhardwareports 2>/dev/null)"
    wifi_iface="$(printf '%s\n' "$hardware_ports" | awk '
      /^Hardware Port: Wi-Fi$/ { getline; if ($1 == "Device:") print $2; exit }
    ')"
    default_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    iface="${wifi_iface:-$default_iface}"
    service="$(printf '%s\n' "$hardware_ports" | awk -v iface="$iface" '
      /^Hardware Port: / { service=substr($0, 16); next }
      /^Device: / && $2 == iface { print service; exit }
    ')"
    printf '%s\n%s\n' "$iface" "$service"
  ]], function(result)
    result = result or ""
    local iface, service = result:match("^([^\r\n]*)[\r\n]+([^\r\n]*)")
    iface = (iface and iface ~= "") and iface or nil
    service = (service and service ~= "") and service or nil
    callback(iface, service)
  end)
end

local popup_width = settings.popup.width
-- Leave room for the shared outer padding and the icon/label padding.
local detail_cell_width = (popup_width - 24) / 2

local wifi_up = sbar.add("item", "widgets.wifi1", {
  position = "right",
  padding_left = -5,
  width = 0,
  scroll_texts = false,
  icon = {
    width = 12,
    padding_left = 0,
    padding_right = 2,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    string = icons.wifi.upload,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.magenta,
    string = statwell.rate_unknown,
    width = statwell.rate_width,
    align = "left",
    padding_left = 0,
    padding_right = 2,
  },
  y_offset = 4,
})

local wifi_down = sbar.add("item", "widgets.wifi2", {
  -- The fixed icon/label cells determine the width, including their padding.
  -- An item width smaller than this content would clip the unit on the right.
  width = "dynamic",
  scroll_texts = false,
  position = "right",
  padding_left = -5,
  icon = {
    width = 12,
    padding_left = 0,
    padding_right = 2,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    string = icons.wifi.download,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.blue,
    string = statwell.rate_unknown,
    width = statwell.rate_width,
    align = "left",
    padding_left = 0,
    padding_right = 2,
  },
  y_offset = -4,
})

local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  icon = { padding_right = settings.paddings + 3 },
  label = { drawing = false },
})

-- Background around the item
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
  wifi_up.name,
  wifi_down.name
}, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = settings.popup.row_height }
})

local ssid = sbar.add("item", "widgets.wifi.ssid", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    font = {
      style = settings.font.style_map["Bold"]
    },
    string = icons.wifi.router,
  },
  width = popup_width,
  align = "center",
  label = {
    font = {
      size = 15,
      style = settings.font.style_map["Bold"]
    },
    max_chars = 18,
    string = "????????????",
  },
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15
  }
})

local hostname = sbar.add("item", "widgets.wifi.hostname", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Hostname:",
    width = detail_cell_width,
  },
  label = {
    max_chars = 20,
    string = "????????????",
    width = detail_cell_width,
    align = "right",
  }
})

local ip = sbar.add("item", "widgets.wifi.ip", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "IP:",
    width = detail_cell_width,
  },
  label = {
    string = "???.???.???.???",
    width = detail_cell_width,
    align = "right",
  }
})

local mask = sbar.add("item", "widgets.wifi.mask", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Subnet mask:",
    width = detail_cell_width,
  },
  label = {
    string = "???.???.???.???",
    width = detail_cell_width,
    align = "right",
  }
})

local router = sbar.add("item", "widgets.wifi.router", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Router:",
    width = detail_cell_width,
  },
  label = {
    string = "???.???.???.???",
    width = detail_cell_width,
    align = "right",
  },
})

sbar.add("item", { position = "right", width = settings.group_paddings })

local last_upload, last_download, last_up_color, last_down_color
statwell.subscribe(wifi_up, "network", "statwell_network", function(env)
  local fresh = statwell.fresh(env)
  local upload = fresh and statwell.rate(env.upload_bytes_per_second) or statwell.rate_unknown
  local download = fresh and statwell.rate(env.download_bytes_per_second) or statwell.rate_unknown
  local up_color = (upload == statwell.rate_unknown or (tonumber(env.upload_bytes_per_second) == 0 and fresh)) and colors.muted or colors.magenta
  local down_color = (download == statwell.rate_unknown or (tonumber(env.download_bytes_per_second) == 0 and fresh)) and colors.muted or colors.blue
  if upload ~= last_upload or up_color ~= last_up_color then
    last_upload, last_up_color = upload, up_color
    wifi_up:set({
      icon = { color = up_color },
      label = { string = upload, color = up_color },
    })
  end
  if download ~= last_download or down_color ~= last_down_color then
    last_download, last_down_color = download, down_color
    wifi_down:set({
      icon = { color = down_color },
      label = { string = download, color = down_color },
    })
  end
end)

local function update_connection(iface)
  if not iface then
    wifi:set({
      icon = {
        string = icons.wifi.disconnected,
        color = colors.red,
      },
    })
    return
  end

  sbar.exec("ipconfig getifaddr " .. shell_quote(iface), function(result)
    local connected = result and result:gsub("%s+", "") ~= ""
    wifi:set({
      icon = {
        string = connected and icons.wifi.connected or icons.wifi.disconnected,
        color = connected and colors.white or colors.red,
      },
    })
  end)
end

local function refresh_network()
  resolve_network(function(iface, service)
    network_state.iface = iface
    network_state.service = service
    update_connection(iface)
  end)
end

local function schedule_network_refresh()
  network_state.refresh_generation = network_state.refresh_generation + 1
  local generation = network_state.refresh_generation

  sbar.delay(2, function()
    if generation ~= network_state.refresh_generation then return end
    refresh_network()
  end)
end

wifi:subscribe({"wifi_change", "system_woke"}, function()
  schedule_network_refresh()
end)

refresh_network()

local details_generation = 0
local detail_values = {}
local copy_generations = {}
local menu
local function network_open_details()
  details_generation = details_generation + 1
  local generation = details_generation
  for _, item in ipairs({ssid, hostname, ip, mask, router}) do
    detail_values[item.name] = nil
    item:set({ label = { string = "Loading…", align = "right" } })
  end
  local function set_label(item, value, code)
    if generation ~= details_generation then return end
    value = type(value) == "string" and value:gsub("[\r\n]+$", "") or ""
    value = (code == nil or code == 0) and value ~= "" and value or "Unavailable"
    detail_values[item.name] = value
    item:set({ label = { string = value } })
  end

  sbar.exec("networksetup -getcomputername", function(result, code)
    set_label(hostname, result, code)
  end)

  local function update_details(iface, service)
    if generation ~= details_generation then return end
    if not iface then
      for _, item in ipairs({ssid, ip, mask, router}) do set_label(item, nil) end
      return
    end
    -- Parse SSID in Lua instead of starting an extra awk process.
    sbar.exec("ipconfig getsummary " .. shell_quote(iface), function(result, code)
      local value = type(result) == "string" and result:match("SSID : ([^\r\n]+)") or nil
      set_label(ssid, value, code)
    end)
    if service then
      -- getinfo already includes the IP; avoid a separate getifaddr process.
      sbar.exec("networksetup -getinfo " .. shell_quote(service), function(result, code)
        result = type(result) == "string" and result or ""
        set_label(ip, result:match("\nIP address:[ \t]*([^\r\n]+)")
          or result:match("^IP address:[ \t]*([^\r\n]+)"), code)
        set_label(mask, result:match("Subnet mask:[ \t]*([^\r\n]+)"), code)
        set_label(router, result:match("Router:[ \t]*([^\r\n]+)"), code)
      end)
    else
      sbar.exec("ipconfig getifaddr " .. shell_quote(iface), function(result, code)
        set_label(ip, result, code)
      end)
      set_label(mask, nil)
      set_label(router, nil)
    end
  end

  if network_state.iface then
    update_details(network_state.iface, network_state.service)
  else
    resolve_network(function(iface, service)
      if generation ~= details_generation then return end
      update_details(iface, service)
    end)
  end
end

menu = popup.new(wifi_bracket, {
  open = network_open_details,
  close = function() details_generation = details_generation + 1 end,
})
for _, item in ipairs({wifi, wifi_up, wifi_down}) do
  menu.attach(item, true)
  item:subscribe("mouse.clicked", menu.show)
end
for _, item in ipairs({ssid, hostname, ip, mask, router}) do menu.attach(item) end

local function copy_label_to_clipboard(env)
  local label = detail_values[env.NAME]
  if not label then return end
  local generation = details_generation
  copy_generations[env.NAME] = (copy_generations[env.NAME] or 0) + 1
  local copy_generation = copy_generations[env.NAME]
  sbar.exec("printf %s " .. shell_quote(label) .. " | pbcopy")
  sbar.set(env.NAME, { label = { string = icons.clipboard, align="center" } })
  sbar.delay(1, function()
    if generation ~= details_generation or copy_generation ~= copy_generations[env.NAME] then return end
    sbar.set(env.NAME, { label = { string = label, align = "right" } })
  end)
end

ssid:subscribe("mouse.clicked", copy_label_to_clipboard)
hostname:subscribe("mouse.clicked", copy_label_to_clipboard)
ip:subscribe("mouse.clicked", copy_label_to_clipboard)
mask:subscribe("mouse.clicked", copy_label_to_clipboard)
router:subscribe("mouse.clicked", copy_label_to_clipboard)
