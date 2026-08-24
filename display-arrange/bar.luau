--!nonstrict
-- Display Arrange bar widget — shows how many displays are connected.
-- Click opens the panel.

local outputs = {}

local function render()
  barWidget.setGlyph("device-desktop")
  barWidget.setText(tostring(#outputs))
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/display-arrange:panel")
end

noctalia.state.watch("display_arrange.outputs", function(value)
  outputs = type(value) == "table" and value or {}
  render()
end)

render()
