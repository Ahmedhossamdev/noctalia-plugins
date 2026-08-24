--!nonstrict
-- Display Arrange panel — one card per connected output. The primary
-- output is anchored at (0,0); every other output gets a left/right/top/
-- bottom button that positions it relative to the primary.

local outputs = {}
local primary = ""
local pendingSeconds = 0 -- countdown pushed live by the service; 0 = nothing pending

local function findOutput(name)
  for _, o in ipairs(outputs) do
    if o.name == name then
      return o
    end
  end
  return nil
end

local DIR_BTN = 26

local function directionButton(row, glyph, direction, tooltip)
  return ui.button({
    key = "dir-" .. row.name .. "-" .. direction,
    glyph = glyph,
    variant = row.direction == direction and "outline" or "ghost",
    controlSize = "sm",
    width = DIR_BTN,
    height = DIR_BTN,
    selected = row.direction == direction,
    tooltip = tooltip,
    onClick = function()
      noctalia.state.set("display_arrange.cmd", { op = "set_direction", name = row.name, direction = direction })
    end,
  })
end

-- A compass-style pad (matching how every OS display-arrangement UI shows
-- this) instead of four buttons in a row - reads as "where does it sit
-- relative to the primary" much more clearly than a flat button strip.
local function padBlank()
  return ui.column({ width = DIR_BTN, height = DIR_BTN }, {})
end

-- Symmetric 3x3 grid (blank corners) so all three rows are the same total
-- width and up/down land exactly above/below the gap between left/right.
local function directionPad(row)
  return ui.column({ gap = 2, align = "start", justify = "start" }, {
    ui.row({ gap = 2, justify = "start" }, {
      padBlank(),
      directionButton(row, "chevron-up", "top", noctalia.tr("row.direction-top")),
      padBlank(),
    }),
    ui.row({ gap = 2, justify = "start" }, {
      directionButton(row, "chevron-left", "left", noctalia.tr("row.direction-left")),
      padBlank(),
      directionButton(row, "chevron-right", "right", noctalia.tr("row.direction-right")),
    }),
    ui.row({ gap = 2, justify = "start" }, {
      padBlank(),
      directionButton(row, "chevron-down", "bottom", noctalia.tr("row.direction-bottom")),
      padBlank(),
    }),
  })
end

local function outputCard(row)
  local subtitle = row.make ~= "" and (row.make .. " " .. row.model) or row.model
  local geometry = string.format("%d\u{00d7}%d @ %.2gx  \u{00b7}  (%d, %d)", row.width or 0, row.height or 0, row.scale or 1, row.x or 0, row.y or 0)

  local nameRow = { ui.label({ text = row.name, fontWeight = "bold", fontSize = 13 }) }
  if row.isPrimary then
    table.insert(
      nameRow,
      ui.row({ gap = 3, align = "center", justify = "start", paddingH = 6, paddingV = 1, fill = "primary/0.22", radius = 999 }, {
        ui.glyph({ name = "star-filled", size = 9, color = "primary" }),
        ui.label({ text = noctalia.tr("row.primary"), fontSize = 9, fontWeight = "bold", color = "primary" }),
      })
    )
  end

  local infoChildren = { ui.row({ gap = 6, align = "center", justify = "start" }, nameRow) }
  if subtitle ~= "" then
    table.insert(infoChildren, ui.label({ text = subtitle, fontSize = 10, color = "on_surface_variant" }))
  end
  table.insert(infoChildren, ui.label({ text = geometry, fontSize = 9, color = "on_surface_variant" }))

  local info = ui.column({ gap = 2, justify = "start", flexGrow = 1 }, infoChildren)

  local cardChildren = { info }

  if not row.isPrimary then
    table.insert(cardChildren, ui.separator({}))
    table.insert(
      cardChildren,
      ui.row({ gap = 10, align = "center", justify = "start" }, {
        directionPad(row),
        ui.column({ gap = 4, justify = "start", flexGrow = 1 }, {
          ui.label({ text = noctalia.tr("row.direction-hint"), fontSize = 9, color = "on_surface_variant" }),
          ui.button({
            glyph = "star",
            text = noctalia.tr("row.make-primary-short"),
            variant = "ghost",
            controlSize = "sm",
            contentAlign = "start",
            tooltip = noctalia.tr("row.make-primary"),
            onClick = function()
              noctalia.state.set("display_arrange.cmd", { op = "set_primary", name = row.name })
            end,
          }),
        }),
      })
    )
  end

  return ui.column({
    key = "card-" .. row.name,
    gap = 8,
    justify = "start",
    padding = 10,
    fill = row.isPrimary and "primary/0.08" or "surface_variant/0.25",
    radius = 8,
  }, cardChildren)
end

local function confirmBanner()
  if pendingSeconds <= 0 then
    return nil
  end
  return ui.column({
    key = "confirm-banner",
    gap = 6,
    justify = "start",
    padding = 10,
    fill = "primary/0.14",
    radius = 8,
  }, {
    ui.row({ gap = 8, align = "center", justify = "start" }, {
      ui.glyph({ name = "clock", size = 16, color = "primary" }),
      ui.label({
        text = noctalia.tr("panel.confirm-text", { seconds = tostring(pendingSeconds) }),
        fontSize = 11,
        flexGrow = 1,
      }),
    }),
    ui.row({ gap = 6, align = "center", justify = "start" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        glyph = "check",
        text = noctalia.tr("panel.confirm-keep"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          noctalia.state.set("display_arrange.cmd", { op = "confirm_layout" })
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.confirm-revert"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.state.set("display_arrange.cmd", { op = "revert_layout" })
        end,
      }),
    }),
  })
end

local function view()
  local body = {
    ui.row({ gap = 8, align = "center", justify = "start" }, {
      ui.glyph({ name = "device-desktop", size = 20, color = "primary" }),
      ui.column({ gap = 0, justify = "start", flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 14, fontWeight = "bold" }),
        ui.label({ text = noctalia.tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          noctalia.state.set("display_arrange.cmd", { op = "refresh" })
        end,
      }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function()
        panel.close()
      end }),
    }),
    ui.separator({}),
  }

  local banner = confirmBanner()
  if banner ~= nil then
    table.insert(body, banner)
  end

  if #outputs == 0 then
    table.insert(body, ui.label({ text = noctalia.tr("panel.none"), fontSize = 11, color = "on_surface_variant" }))
  else
    local cards = {}
    -- Primary card first, then the rest in the order the service reported them.
    local primaryRow = findOutput(primary)
    if primaryRow ~= nil then
      table.insert(cards, outputCard(primaryRow))
    end
    for _, row in ipairs(outputs) do
      if row.name ~= primary then
        table.insert(cards, outputCard(row))
      end
    end
    table.insert(body, ui.scroll({ flexGrow = 1, gap = 6, align = "stretch", justify = "start" }, cards))
  end

  return ui.column({ flexGrow = 1, gap = 8, padding = 8, justify = "start" }, body)
end

function render()
  panel.render(view())
end

function onOpen(_context)
  panel.setWantsSecondTicks(true)
  noctalia.state.set("display_arrange.cmd", { op = "refresh" })
  render()
end

noctalia.state.watch("display_arrange.outputs", function(value)
  outputs = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("display_arrange.primary", function(value)
  primary = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("display_arrange.pending_seconds", function(value)
  pendingSeconds = type(value) == "number" and value or 0
  render()
end)

render()
