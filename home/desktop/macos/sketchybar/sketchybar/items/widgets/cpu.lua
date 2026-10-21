local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")
local style = require("helpers.style")

statwell.watch("cpu", "statwell_cpu")

-- The graph draws inside the item's background, which is otherwise
-- invisible; its height leaves the pill's margin above and below the curve.
local cpu = sbar.add("graph", "widgets.cpu" , 42, {
  position = "right",
  scroll_texts = false,
  graph = { color = colors.blue },
  background = {
    height = settings.pill.height - 8,
    color = colors.transparent,
    border_color = colors.transparent,
    drawing = true,
  },
  icon = { string = icons.cpu, padding_left = settings.pill.inset, padding_right = settings.spacing },
  -- The label cell is only the pill's inset; right-aligned against that
  -- inset, the percentage overlays the graph's top right corner.
  label = style.merge(style.end_cell(0), {
    string = "?%",
    font = style.font.small(),
    y_offset = 4,
  }),
})

statwell.subscribe(cpu, "cpu", "statwell_cpu", function(env)
  local load = statwell.fresh(env) and tonumber(env.total_percent) or nil
  if not load or load ~= load or load < 0 or load > 100 then
    cpu:set({ label = "?%", graph = { color = colors.muted } })
    return
  end
  cpu:push({ load / 100. })

  local color = colors.blue
  if load > 30 then
    if load < 60 then
      color = colors.yellow
    elseif load < 80 then
      color = colors.orange
    else
      color = colors.red
    end
  end

  cpu:set({
    graph = { color = color },
    label = string.format("%.0f%%", load),
  })
end)

cpu:subscribe("mouse.clicked", function(env)
  sbar.exec("open -a 'Activity Monitor'")
end)

style.pill("widgets.cpu.bracket", { cpu.name })
style.gap("widgets.cpu.padding", "right")
