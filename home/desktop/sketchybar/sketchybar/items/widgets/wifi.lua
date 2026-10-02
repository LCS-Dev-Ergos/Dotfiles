local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")
local popup = require("helpers.popup")
local popup_data = require("helpers.popup_data")
local style = require("helpers.style")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Assigned below; the popup callbacks and refreshes reach them through these.
local cache
local details_generation = 0

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

-- Two stacked rows share one slot: the upload item has zero width and draws
-- over the download item, so both use identical cells and only the download
-- item reserves space; with no item padding both draw in the same place. Rates are
-- right-aligned in a cell sized for the longest value, so the units line up
-- and the pill never changes width.
local function rate_row(name, arrow, color, y_offset, width)
  return sbar.add("item", name, {
    position = "right",
    width = width,
    scroll_texts = false,
    icon = {
      string = arrow,
      width = 12,
      font = style.font.small_icon(),
    },
    label = style.merge(style.end_cell(statwell.rate_width), {
      string = statwell.rate_unknown,
      font = style.font.small(),
      color = color,
    }),
    y_offset = y_offset,
  })
end

-- The fixed icon/label cells determine the download item's width. An item
-- width smaller than this content would clip the unit on the right.
local wifi_up = rate_row("widgets.wifi1", icons.wifi.upload, colors.magenta, 4, 0)
local wifi_down = rate_row("widgets.wifi2", icons.wifi.download, colors.blue, -4, "dynamic")

local wifi = sbar.add("item", "widgets.wifi", {
  position = "right",
  -- Unknown until the first interface lookup answers.
  icon = { string = icons.wifi.connected, color = colors.muted,
    padding_left = settings.pill.inset, padding_right = settings.spacing },
  label = { drawing = false },
})

local wifi_bracket = style.pill("widgets.wifi.bracket", { wifi.name, wifi_up.name, wifi_down.name })
style.gap("widgets.wifi.padding", "right")

local menu = popup.new(wifi_bracket, {
  open = function() cache.show() end,
  close = function() details_generation = details_generation + 1 end,
})

local ssid = menu.text_row("widgets.wifi.ssid", {
  icon = { drawing = true, string = icons.wifi.router, padding_right = settings.spacing },
  label = { width = "dynamic", max_chars = 24, string = "Loading…" },
})
local hostname = menu.detail_row("widgets.wifi.hostname", "Hostname")
local ip = menu.detail_row("widgets.wifi.ip", "IP address")
local mask = menu.detail_row("widgets.wifi.mask", "Subnet mask")
local router = menu.detail_row("widgets.wifi.router", "Router")

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

-- macOS redacts the SSID in ipconfig and networksetup for processes without
-- Location Services access; system_profiler still reports it but needs a few
-- seconds. It is therefore read in the background whenever the network
-- changes, and the menu shows the last answer.
local ssid_generation = 0
local function read_ssid()
  ssid_generation = ssid_generation + 1
  local generation = ssid_generation
  network_state.ssid_pending = true
  sbar.exec("/usr/sbin/system_profiler SPAirPortDataType 2>/dev/null"
    .. " | /usr/bin/awk '/Current Network Information:/ { getline; sub(/^[ \t]+/, \"\"); sub(/:$/, \"\"); print; exit }'",
    function(result)
      if generation ~= ssid_generation then return end
      result = type(result) == "string" and result:gsub("[\r\n]+$", "") or ""
      network_state.ssid = result ~= "" and result or nil
      network_state.ssid_pending = false
      if cache then cache.invalidate() end
    end)
end

local function refresh_network()
  resolve_network(function(iface, service)
    network_state.iface = iface
    network_state.service = service
    network_state.ssid = nil
    update_connection(iface)
    if cache then cache.invalidate() end
    if iface then read_ssid() end
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

local detail_values = {}
local copy_generations = {}
local function render_details(snapshot)
  details_generation = details_generation + 1
  for _, entry in ipairs({{ssid, "ssid"}, {hostname, "hostname"}, {ip, "ip"}, {mask, "mask"}, {router, "router"}}) do
    local item, key = entry[1], entry[2]
    local value = snapshot and (snapshot[key] or "Unavailable") or "Loading…"
    detail_values[item.name] = snapshot and value or nil
    item:set({ label = { string = value } })
  end
end
local function load_details(done)
  local snapshot, remaining = {}, 2
  snapshot.ssid = network_state.ssid or (network_state.ssid_pending and "Loading…" or nil)
  local function text(result, code)
    return code == 0 and type(result) == "string" and result:gsub("[\r\n]+$", "") or ""
  end
  local function finish()
    remaining = remaining - 1
    if remaining == 0 then done(snapshot) end
  end
  sbar.exec("networksetup -getcomputername", function(result, code)
    result = text(result, code)
    snapshot.hostname = result ~= "" and result or nil
    finish()
  end)
  local function query_interface(iface, service)
    if not iface then finish(); return end
    if service then
      sbar.exec("networksetup -getinfo " .. shell_quote(service), function(result, code)
        result = text(result, code)
        snapshot.ip = result:match("\nIP address:[ \t]*([^\r\n]+)") or result:match("^IP address:[ \t]*([^\r\n]+)")
        snapshot.mask = result:match("Subnet mask:[ \t]*([^\r\n]+)")
        snapshot.router = result:match("Router:[ \t]*([^\r\n]+)")
        finish()
      end)
    else
      sbar.exec("ipconfig getifaddr " .. shell_quote(iface), function(result, code)
        result = text(result, code)
        snapshot.ip = result ~= "" and result or nil
        finish()
      end)
    end
  end
  query_interface(network_state.iface, network_state.service)
end

for _, item in ipairs({wifi, wifi_up, wifi_down}) do
  menu.trigger(item)
  item:subscribe("mouse.clicked", menu.show)
end
cache = popup_data.new(load_details, render_details, menu.is_open, {})
refresh_network()

local function copy_label_to_clipboard(env)
  local label = detail_values[env.NAME]
  if not label then return end
  local generation = details_generation
  copy_generations[env.NAME] = (copy_generations[env.NAME] or 0) + 1
  local copy_generation = copy_generations[env.NAME]
  sbar.exec("printf %s " .. shell_quote(label) .. " | pbcopy")
  sbar.set(env.NAME, { label = { string = icons.clipboard } })
  sbar.delay(1, function()
    if generation ~= details_generation or copy_generation ~= copy_generations[env.NAME] then return end
    sbar.set(env.NAME, { label = { string = label } })
  end)
end

ssid:subscribe("mouse.clicked", copy_label_to_clipboard)
hostname:subscribe("mouse.clicked", copy_label_to_clipboard)
ip:subscribe("mouse.clicked", copy_label_to_clipboard)
mask:subscribe("mouse.clicked", copy_label_to_clipboard)
router:subscribe("mouse.clicked", copy_label_to_clipboard)
