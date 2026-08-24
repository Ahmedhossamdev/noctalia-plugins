--!nonstrict
-- Timezone Hub bar widget — shows the device's local time (or, if chosen
-- in the panel, a comparison city's time instead) with its zone
-- abbreviation. Click opens the panel.

local rows = {}
local barTz = ""

local function findRow(tz)
  for _, row in ipairs(rows) do
    if row.tz == tz then
      return row
    end
  end
  return nil
end

local function render()
  local row = barTz ~= "" and findRow(barTz) or rows[1]
  if row == nil then
    barWidget.setGlyph("world")
    barWidget.setText("--:--")
    return
  end
  barWidget.setGlyph("world")
  local text = row.timeText or "--:--"
  if row.abbrev and row.abbrev ~= "" then
    text = text .. " " .. row.abbrev
  end
  barWidget.setText(text)
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/timezone-hub:panel")
end

noctalia.state.watch("timezone_hub.rows", function(value)
  rows = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("timezone_hub.bar_tz", function(value)
  barTz = type(value) == "string" and value or ""
  render()
end)

render()
