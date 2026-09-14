--!nonstrict
-- GitHub Feed bar widget — event count and panel launcher.

local items = {}
local showCount = true

local function render()
  barWidget.setGlyph("brand-github")
  if showCount then
    local count = #items
    barWidget.setText(count > 0 and tostring(count) or "")
    barWidget.setTooltip(noctalia.tr("bar.tooltip", { count = count }))
  else
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("panel.title"))
  end
end

function update()
  showCount = noctalia.getConfig("show_count_in_bar") ~= false
  render()
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/github-feed:panel")
end

noctalia.state.watch("github_feed.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)

render()
