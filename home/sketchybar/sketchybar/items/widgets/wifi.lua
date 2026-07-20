local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"
local network_provider = config_dir .. "/helpers/event_providers/network_load/bin/network_load"
local network_state = {
  iface = nil,
  service = nil,
  provider_iface = nil,
  refresh_generation = 0,
}

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

local function start_network_provider(iface)
  if not iface then return end

  local script
  if network_state.provider_iface == iface then
    script = string.format(
      "if ! pgrep -f %s >/dev/null 2>&1; then %s %s network_update 2.0 >/dev/null 2>&1 & fi",
      shell_quote(network_provider .. " " .. iface .. " network_update"),
      shell_quote(network_provider),
      shell_quote(iface)
    )
  else
    network_state.provider_iface = iface
    script = string.format(
      "pkill -TERM -f %s >/dev/null 2>&1; %s %s network_update 2.0 >/dev/null 2>&1 &",
      shell_quote(network_provider .. " .* network_update"),
      shell_quote(network_provider),
      shell_quote(iface)
    )
  end

  sbar.exec("/bin/zsh -c " .. shell_quote(script))
end

local popup_width = 250

local wifi_up = sbar.add("item", "widgets.wifi1", {
  position = "right",
  padding_left = -5,
  width = 0,
  icon = {
    padding_right = 0,
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
    color = colors.red,
    string = "??? Bps",
  },
  y_offset = 4,
})

local wifi_down = sbar.add("item", "widgets.wifi2", {
  position = "right",
  padding_left = -5,
  icon = {
    padding_right = 0,
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
    string = "??? Bps",
  },
  y_offset = -4,
})

local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  label = { drawing = false },
})

-- Background around the item
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
  wifi_up.name,
  wifi_down.name
}, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 }
})

local ssid = sbar.add("item", {
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

local hostname = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Hostname:",
    width = popup_width / 2,
  },
  label = {
    max_chars = 20,
    string = "????????????",
    width = popup_width / 2,
    align = "right",
  }
})

local ip = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "IP:",
    width = popup_width / 2,
  },
  label = {
    string = "???.???.???.???",
    width = popup_width / 2,
    align = "right",
  }
})

local mask = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Subnet mask:",
    width = popup_width / 2,
  },
  label = {
    string = "???.???.???.???",
    width = popup_width / 2,
    align = "right",
  }
})

local router = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Router:",
    width = popup_width / 2,
  },
  label = {
    string = "???.???.???.???",
    width = popup_width / 2,
    align = "right",
  },
})

sbar.add("item", { position = "right", width = settings.group_paddings })

wifi_up:subscribe("network_update", function(env)
  local up_color = (env.upload == "000 Bps") and colors.grey or colors.red
  local down_color = (env.download == "000 Bps") and colors.grey or colors.blue
  wifi_up:set({
    icon = { color = up_color },
    label = {
      string = env.upload,
      color = up_color
    }
  })
  wifi_down:set({
    icon = { color = down_color },
    label = {
      string = env.download,
      color = down_color
    }
  })
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
    start_network_provider(iface)
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

local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true }})
    sbar.exec("networksetup -getcomputername", function(result)
      hostname:set({ label = result })
    end)

    local function update_details(iface, service)
      if not iface then
        ssid:set({ label = "Unavailable" })
        ip:set({ label = "Unavailable" })
        mask:set({ label = "Unavailable" })
        router:set({ label = "Unavailable" })
        return
      end

      sbar.exec("ipconfig getifaddr " .. shell_quote(iface), function(result)
        ip:set({ label = result ~= "" and result or "Unavailable" })
      end)
      sbar.exec("ipconfig getsummary " .. shell_quote(iface) .. " | awk -F ' SSID : '  '/ SSID : / {print $2}'", function(result)
        ssid:set({ label = result ~= "" and result or "Unavailable" })
      end)
      if service then
        sbar.exec("networksetup -getinfo " .. shell_quote(service), function(result)
          result = result or ""
          local subnet = result:match("Subnet mask:%s*([^\r\n]+)") or ""
          local gateway = result:match("Router:%s*([^\r\n]+)") or ""
          mask:set({ label = subnet ~= "" and subnet or "Unavailable" })
          router:set({ label = gateway ~= "" and gateway or "Unavailable" })
        end)
      else
        mask:set({ label = "Unavailable" })
        router:set({ label = "Unavailable" })
      end
    end

    if network_state.iface then
      update_details(network_state.iface, network_state.service)
    else
      resolve_network(function(iface, service)
        network_state.iface = iface
        network_state.service = service
        update_details(iface, service)
      end)
    end
  else
    hide_details()
  end
end

wifi_up:subscribe("mouse.clicked", toggle_details)
wifi_down:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)

local function copy_label_to_clipboard(env)
  local label = sbar.query(env.NAME).label.value
  sbar.exec("printf %s " .. shell_quote(label) .. " | pbcopy")
  sbar.set(env.NAME, { label = { string = icons.clipboard, align="center" } })
  sbar.delay(1, function()
    sbar.set(env.NAME, { label = { string = label, align = "right" } })
  end)
end

ssid:subscribe("mouse.clicked", copy_label_to_clipboard)
hostname:subscribe("mouse.clicked", copy_label_to_clipboard)
ip:subscribe("mouse.clicked", copy_label_to_clipboard)
mask:subscribe("mouse.clicked", copy_label_to_clipboard)
router:subscribe("mouse.clicked", copy_label_to_clipboard)
