-- Shared watcher lifecycle, cache reconciliation and presentation utilities.
local runtime = require("helpers.runtime")
-- Fixed renderer cells keep the bar stable without padding the visible number.
local M = { rate_unknown = "--.- KiB/s", rate_width = 68 }
local watches, consumers = {}, {}
local started, sleeping, in_flight = false, false, false
local tick, wake_generation, cache_token, cache_started = 0, 0, 0, 0

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function finite(value)
  value = tonumber(value)
  return value and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

local function runtime_args()
  return runtime.runtime_dir and runtime.runtime_dir ~= ""
    and (" --runtime-dir " .. quote(runtime.runtime_dir)) or ""
end

function M.watch(metric, event)
  watches[metric] = { metric = metric, event = event }
end

local function ensure_watch(watch, retire)
  if watch.starting and os.time() - watch.started < 10 then return end
  watch.starting, watch.started = true, os.time()
  watch.token = (watch.token or 0) + 1
  local token = watch.token
  local pattern = "^/nix/store/[^/]+-statwell-[^/]+/bin/statwell watch --metric "
    .. watch.metric .. " --event " .. watch.event .. "( |$)"
  local options = runtime_args()
  if watch.metric == "network" and runtime.network_interface and runtime.network_interface ~= "" then
    options = options .. " --interface " .. quote(runtime.network_interface)
  end
  if watch.metric == "homebrew" then
    options = options .. " --package-timeout-ms " .. tostring(runtime.package_timeout_ms or 10000)
  end
  local environment = watch.metric == "homebrew" and "HOMEBREW_NO_AUTO_UPDATE=1 " or ""
  local command = quote(runtime.statwell) .. " watch --metric " .. watch.metric
    .. " --event " .. watch.event .. options
  local script = 'state="${XDG_STATE_HOME:-$HOME/.local/state}/sketchybar"; '
    .. 'mkdir -p "$state" || exit 1; log="$state/statwell-' .. watch.metric .. '.log"; '
    .. '[ ! -f "$log" ] || [ "$(/usr/bin/wc -c < "$log")" -lt 65536 ] || : > "$log"; '
  if retire then
    script = script .. "/usr/bin/pkill -TERM -u \"$(/usr/bin/id -u)\" -f " .. quote(pattern)
      .. " >/dev/null 2>&1 || true; "
      .. "for attempt in {1..20}; do /usr/bin/pgrep -u \"$(/usr/bin/id -u)\" -f " .. quote(pattern)
      .. " >/dev/null || break; /bin/sleep 0.1; done; "
  end
  script = script .. "/usr/bin/pgrep -u \"$(/usr/bin/id -u)\" -f " .. quote(pattern)
    .. " >/dev/null || { " .. environment .. command .. ' >> "$log" 2>&1 & };'
  sbar.exec("/bin/zsh -c " .. quote(script), function()
    if token == watch.token then watch.starting = false end
  end)
end

function M.fresh(env)
  if type(env) ~= "table" or env.status ~= "ok" then return false end
  local value_at, max_age = finite(env.value_at_unix_ms), finite(env.max_age_ms)
  if not value_at or not max_age or value_at <= 0 or max_age <= 0 then return false end
  local now = os.time() * 1000
  return value_at <= now + 999 and now - value_at <= max_age
end

local function deliver(consumer, env)
  if type(env) ~= "table" or not env.status then return end
  local instance, sequence = env.instance_id, finite(env.sequence)
  if instance then
    if not sequence or sequence < 0 or sequence % 1 ~= 0 then return end
    if consumer.retired[instance] then return end
    if consumer.instance == instance and sequence and consumer.sequence and sequence < consumer.sequence then return end
    if consumer.instance and consumer.instance ~= instance then
      consumer.retired[consumer.instance] = true
      table.insert(consumer.retired_order, consumer.instance)
      if #consumer.retired_order > 8 then
        consumer.retired[table.remove(consumer.retired_order, 1)] = nil
      end
    end
    consumer.instance, consumer.sequence = instance, sequence
  end
  consumer.revision = consumer.revision + 1
  consumer.last = env
  consumer.was_fresh = M.fresh(env)
  consumer.callback(env)
end

function M.subscribe(item, metric, event, callback)
  M.watch(metric, event)
  local consumer = { metric = metric, callback = callback, revision = 0,
    retired = {}, retired_order = {} }
  table.insert(consumers, consumer)
  item:subscribe(event, function(env) deliver(consumer, env) end)
end

function M.reconcile()
  if not started or sleeping or in_flight then return end
  in_flight, cache_started = true, os.time()
  cache_token = cache_token + 1
  local token = cache_token
  local revisions = {}
  for i, consumer in ipairs(consumers) do revisions[i] = consumer.revision end
  local generation = wake_generation
  sbar.exec(quote(runtime.statwell) .. " snapshot --cached-only" .. runtime_args(), function(document, exit_code)
    if token ~= cache_token then return end
    in_flight = false
    if sleeping then return end
    if generation ~= wake_generation then M.reconcile(); return end
    local valid = exit_code == 0 and type(document) == "table"
      and document.schema_version == 1 and type(document.metrics) == "table"
      and type(document.instance_id) == "string"
    for i, consumer in ipairs(consumers) do
      -- An event received while reading cache always wins over that reply.
      if consumer.revision == revisions[i] then
        local record = valid and document.metrics[consumer.metric] or nil
        if type(record) == "table" then
          local env = { instance_id = document.instance_id,
            captured_at_unix_ms = tostring(document.captured_at_unix_ms) }
          for k, v in pairs(record) do
            if k ~= "value" then env[k] = tostring(v) end
          end
          if type(record.value) == "table" then
            for k, v in pairs(record.value) do env[k] = tostring(v) end
          end
          deliver(consumer, env)
        elseif not consumer.last or not M.fresh(consumer.last) then
          consumer.callback({ status = "transport_error", error = "snapshot_unavailable" })
        end
      end
    end
  end)
end

function M.refresh(provider)
  if sleeping then return end
  sbar.exec(quote(runtime.statwell) .. " refresh --provider " .. quote(provider) .. runtime_args(), function(_, code)
    if code ~= 0 then
      for _, consumer in ipairs(consumers) do
        if consumer.metric == provider then
          consumer.callback({ status = "transport_error", error = "refresh_unavailable" })
        end
      end
    end
    M.reconcile()
  end)
end

function M.prepare()
  local observer = sbar.add("item", "statwell.observer", {
    position = "right", drawing = false, updates = "on", update_freq = 1,
  })
  observer:subscribe({ "routine", "system_will_sleep", "system_woke" }, function(env)
    if env.SENDER == "system_will_sleep" then
      sleeping = true
      wake_generation = wake_generation + 1
      return
    end
    if env.SENDER == "system_woke" then
      sleeping = false
      wake_generation = wake_generation + 1
      local generation = wake_generation
      sbar.delay(2, function()
        if sleeping or generation ~= wake_generation then return end
        for _, watch in pairs(watches) do ensure_watch(watch, false) end
        M.refresh("homebrew")
        M.reconcile()
      end)
      return
    end
    if not started or sleeping then return end
    if in_flight and os.time() - cache_started >= 10 then
      in_flight = false
      cache_token = cache_token + 1
      M.reconcile()
    end
    for _, consumer in ipairs(consumers) do
      if consumer.last then
        local fresh = M.fresh(consumer.last)
        if fresh ~= consumer.was_fresh then
          consumer.was_fresh = fresh
          consumer.callback(consumer.last)
        end
      end
    end
    tick = tick + 1
    if tick % 30 == 0 then
      for _, watch in pairs(watches) do ensure_watch(watch, false) end
      M.reconcile()
    end
  end)
end

function M.start()
  if started then return end
  started = true
  for _, watch in pairs(watches) do ensure_watch(watch, true) end
  M.reconcile()
end

function M.rate(bytes)
  bytes = finite(bytes)
  if not bytes or bytes < 0 then return nil end
  local units, unit, value = { "KiB/s", "MiB/s", "GiB/s", "TiB/s" }, 1, bytes / 1024
  while unit < #units and value >= 1023.95 do
    value, unit = value / 1024, unit + 1
  end
  if value >= 9999.95 then return ">9999 " .. units[unit] end
  return string.format("%.1f %s", value, units[unit])
end

return M
