-- Fetch complete snapshots ahead of hover; one bounded request at a time.
local M = {}
function M.new(load, render, visible, unavailable)
  local value, checked, pending, generation = nil, 0, false, 0
  local cache = {}
  function cache.refresh(force)
    if pending or (not force and value and os.time() - checked < 15) then return end
    pending = true
    generation = generation + 1
    local request = generation
    local function finish(snapshot)
      if request ~= generation or not pending then return end
      pending = false
      value, checked = {}, os.time()
      for key, field in pairs(snapshot) do value[key] = field end
      if visible() then render(value) end
    end
    sbar.delay(3, function() finish(unavailable) end)
    load(finish)
  end
  function cache.show()
    render(value)
    cache.refresh()
  end
  function cache.invalidate()
    generation = generation + 1
    pending, value = false, nil
    if visible() then render(nil) end
    cache.refresh(true)
  end
  return cache
end
return M
