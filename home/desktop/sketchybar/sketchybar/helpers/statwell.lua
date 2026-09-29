-- Shared StatWell event wiring for status widgets.
local runtime = require("helpers.runtime")
local M = {}

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.watch(metric, event)
  -- Retire a watcher from an older generation before starting this one.
  local pattern = "^/nix/store/[^/]+-statwell-[^/]+/bin/statwell watch --metric " .. metric .. " --event " .. event
  local interface = ""
  if metric == "network" and runtime.network_interface and runtime.network_interface ~= "" then
    interface = " --interface " .. quote(runtime.network_interface)
  end
  local provider = ""
  if metric == "homebrew" then
    provider = " --package-timeout-ms " .. tostring(runtime.package_timeout_ms or 10000)
  end
  local environment = metric == "homebrew" and "HOMEBREW_NO_AUTO_UPDATE=1 " or ""
  local script = "/usr/bin/pkill -TERM -u \"$(/usr/bin/id -u)\" -f " .. quote(pattern)
    .. " >/dev/null 2>&1 || true; " .. environment .. quote(runtime.statwell) .. " watch --metric "
    .. quote(metric) .. " --event " .. quote(event) .. interface .. provider .. " >/dev/null 2>&1 &"
  sbar.exec("/bin/zsh -c " .. quote(script))
end

function M.fresh(env)
  if env.status ~= "ok" then return false end
  local value_at = tonumber(env.value_at_unix_ms)
  local max_age = tonumber(env.max_age_ms)
  if not value_at or not max_age or value_at <= 0 or max_age <= 0 then return false end
  local now = os.time() * 1000
  -- os.time has one-second resolution; a sample from this second may appear
  -- slightly ahead of the rounded clock used by Lua.
  return value_at <= now + 999 and now - value_at <= max_age
end

function M.rate(bytes)
  bytes = tonumber(bytes)
  if not bytes or bytes < 0 then return nil end
  if bytes >= 1024 * 1024 then return string.format("%.1f MBps", bytes / (1024 * 1024)) end
  if bytes >= 1024 then return string.format("%.1f KBps", bytes / 1024) end
  return string.format("%03d Bps", math.floor(bytes + 0.5))
end

return M
