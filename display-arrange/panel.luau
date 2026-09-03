--!nonstrict
-- Display Arrange panel — one card per connected output. The primary
-- output is anchored at (0,0); every other output gets a compass pad to
-- position it relative to the primary. Each output also has separate
-- resolution, refresh-rate, and scale controls.

local outputs = {}
local primary = ""
local pendingSeconds = 0 -- countdown pushed live by the service; 0 = nothing pending
local displayMode = "extend"

local MODE_OPTIONS = {
  { id = "primary-only", glyph = "device-laptop",  labelKey = "mode.primary-only", descKey = "mode.primary-only-desc" },
  { id = "duplicate",    glyph = "copy",            labelKey = "mode.duplicate",    descKey = "mode.duplicate-unavailable-desc", unavailable = true },
  { id = "extend",       glyph = "columns",         labelKey = "mode.extend",       descKey = "mode.extend-desc" },
  { id = "second-only",  glyph = "device-desktop",  labelKey = "mode.second-only",  descKey = "mode.second-only-desc" },
}

-- Scale presets: 0.5× … 3× matching common HiDPI steps.
local SCALE_PRESETS = { 0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 }

-- Windows-style orientation: Landscape, Portrait, flipped variants.
local ORIENTATION_OPTIONS = {
  { id = "normal", labelKey = "row.orientation-landscape", fallback = "Landscape" },
  { id = "90",     labelKey = "row.orientation-portrait", fallback = "Portrait" },
  { id = "180",    labelKey = "row.orientation-landscape-flipped", fallback = "Landscape (flipped)" },
  { id = "270",    labelKey = "row.orientation-portrait-flipped", fallback = "Portrait (flipped)" },
}

local function trOr(key, fallback)
  local ok, val = pcall(noctalia.tr, key)
  if ok and type(val) == "string" and val ~= "" and val ~= key then
    return val
  end
  return fallback
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function findScaleIndex(scale)
  local best, bestDist = 1, math.huge
  for i, s in ipairs(SCALE_PRESETS) do
    local d = math.abs(s - (scale or 1.0))
    if d < bestDist then bestDist = d; best = i end
  end
  return best
end

-- Returns unique resolutions in the order they appear in modes (lowest first).
local function uniqueResolutions(modes)
  local seen = {}
  local result = {}
  for _, m in ipairs(modes) do
    local key = m.width .. "x" .. m.height
    if not seen[key] then
      seen[key] = true
      table.insert(result, { width = m.width, height = m.height })
    end
  end
  return result
end

-- Returns all modes for a given resolution, already sorted by Hz (lowest first).
local function modesForResolution(modes, width, height)
  local result = {}
  for _, m in ipairs(modes) do
    if m.width == width and m.height == height then
      table.insert(result, m)
    end
  end
  return result
end

-- Finds the current resolution index. Falls back to the preferred mode's
-- resolution, then to the first entry.
local function resolvedResIdx(row)
  local modes = row.modes or {}
  local resolutions = uniqueResolutions(modes)
  if #resolutions == 0 then return 1, resolutions end
  -- Exact match via current_mode
  if row.currentModeWidth ~= nil then
    for i, r in ipairs(resolutions) do
      if r.width == row.currentModeWidth and r.height == row.currentModeHeight then
        return i, resolutions
      end
    end
  end
  -- Fallback: preferred mode's resolution
  for _, m in ipairs(modes) do
    if m.isPreferred then
      for i, r in ipairs(resolutions) do
        if r.width == m.width and r.height == m.height then
          return i, resolutions
        end
      end
    end
  end
  return 1, resolutions
end

-- Finds the current Hz index within the modes for a given resolution.
-- Falls back to the preferred mode for that resolution, then highest Hz.
local function resolvedHzIdx(row, forWidth, forHeight)
  local modes = row.modes or {}
  local compatModes = modesForResolution(modes, forWidth, forHeight)
  if #compatModes == 0 then return 1, compatModes end
  -- Exact match
  if row.currentModeRefreshRate ~= nil
    and row.currentModeWidth == forWidth
    and row.currentModeHeight == forHeight
  then
    for i, m in ipairs(compatModes) do
      if m.refreshRate == row.currentModeRefreshRate then
        return i, compatModes
      end
    end
  end
  -- Fallback: preferred mode within this resolution
  for i, m in ipairs(compatModes) do
    if m.isPreferred then return i, compatModes end
  end
  -- Last resort: highest Hz (last entry since list is sorted ascending)
  return #compatModes, compatModes
end

local function findOutput(name)
  for _, o in ipairs(outputs) do
    if o.name == name then return o end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- Direction pad (compass-style 3×3 grid)
-- ---------------------------------------------------------------------
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

local function padBlank()
  return ui.column({ width = DIR_BTN, height = DIR_BTN }, {})
end

-- Symmetric 3×3 grid (blank corners) so all three rows are the same total
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

-- ---------------------------------------------------------------------
-- Output card
-- ---------------------------------------------------------------------
local function outputCard(row)
  local subtitle = row.make ~= "" and (row.make .. " " .. row.model) or row.model
  local geometry = string.format("%d\u{00d7}%d @ %.4gx  \u{00b7}  (%d, %d)",
    row.width or 0, row.height or 0, row.scale or 1, row.x or 0, row.y or 0)

  -- ── Header ──────────────────────────────────────────────────────────
  local nameRow = { ui.label({ text = row.name, fontWeight = "bold", fontSize = 13 }) }
  if row.isPrimary then
    table.insert(nameRow, ui.row({
      gap = 3, align = "center", justify = "start",
      paddingH = 6, paddingV = 1, fill = "primary/0.22", radius = 999,
    }, {
      ui.glyph({ name = "star-filled", size = 9, color = "primary" }),
      ui.label({ text = noctalia.tr("row.primary"), fontSize = 9, fontWeight = "bold", color = "primary" }),
    }))
  end

  local infoChildren = { ui.row({ gap = 6, align = "center", justify = "start" }, nameRow) }
  if subtitle ~= "" then
    table.insert(infoChildren, ui.label({ text = subtitle, fontSize = 10, color = "on_surface_variant" }))
  end
  table.insert(infoChildren, ui.label({ text = geometry, fontSize = 9, color = "on_surface_variant" }))

  local info = ui.column({ gap = 2, justify = "start", flexGrow = 1 }, infoChildren)

  -- ── Resolution + Refresh rate (two-column selector boxes) ────────────
  local modes = row.modes or {}
  local resHzRow = nil

  if #modes > 0 then
    local resIdx, resolutions = resolvedResIdx(row)
    local curRes = resolutions[resIdx]

    if curRes ~= nil then
      local hzIdx, compatModes = resolvedHzIdx(row, curRes.width, curRes.height)
      local curMode = compatModes[hzIdx]

      local prevRes  = resIdx > 1          and resolutions[resIdx - 1]   or nil
      local nextRes  = resIdx < #resolutions and resolutions[resIdx + 1] or nil
      local prevMode = hzIdx > 1           and compatModes[hzIdx - 1]    or nil
      local nextMode = hzIdx < #compatModes  and compatModes[hzIdx + 1]  or nil

      local resText = string.format("%d\u{00d7}%d", curRes.width, curRes.height)
      local hz      = curMode and math.floor(curMode.refreshRate / 1000 + 0.5) or 0
      local hzText  = curMode and string.format("%d Hz", hz) or "\u{2014}"

      -- Styled box that mimics a dropdown: value on the left, arrows on the right.
      local function selBox(labelKey, val, hasPrev, hasNext, prevFn, nextFn)
        return ui.column({ gap = 4, justify = "start", flexGrow = 1 }, {
          ui.label({ text = noctalia.tr(labelKey), fontSize = 9, color = "on_surface_variant" }),
          ui.row({
            gap = 2, align = "center",
            fill = "on_surface/0.08", radius = 6, paddingH = 8, paddingV = 5,
          }, {
            ui.label({ text = val, fontSize = 11, flexGrow = 1 }),
            ui.button({ glyph = "chevron-left",  variant = "ghost", controlSize = "sm", enabled = hasPrev, onClick = prevFn }),
            ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm", enabled = hasNext, onClick = nextFn }),
          }),
        })
      end

      resHzRow = ui.row({ gap = 8, align = "end", justify = "start" }, {
        selBox("row.resolution", resText, prevRes ~= nil, nextRes ~= nil,
          function()
            if prevRes == nil then return end
            local nm = modesForResolution(modes, prevRes.width, prevRes.height)
            local best = nm[#nm]  -- highest Hz for that resolution
            if best ~= nil then
              noctalia.state.set("display_arrange.cmd", { op = "set_mode", name = row.name,
                width = best.width, height = best.height, refreshRate = best.refreshRate })
            end
          end,
          function()
            if nextRes == nil then return end
            local nm = modesForResolution(modes, nextRes.width, nextRes.height)
            local best = nm[#nm]
            if best ~= nil then
              noctalia.state.set("display_arrange.cmd", { op = "set_mode", name = row.name,
                width = best.width, height = best.height, refreshRate = best.refreshRate })
            end
          end
        ),
        selBox("row.refresh-rate", hzText, prevMode ~= nil, nextMode ~= nil,
          function()
            if prevMode == nil then return end
            noctalia.state.set("display_arrange.cmd", { op = "set_mode", name = row.name,
              width = prevMode.width, height = prevMode.height, refreshRate = prevMode.refreshRate })
          end,
          function()
            if nextMode == nil then return end
            noctalia.state.set("display_arrange.cmd", { op = "set_mode", name = row.name,
              width = nextMode.width, height = nextMode.height, refreshRate = nextMode.refreshRate })
          end
        ),
      })
    end
  end

  -- ── Scale ───────────────────────────────────────────────────────────
  -- Segmented progress track (one pill per preset, filled = primary up to
  -- the current index) + ghost tick buttons beneath it so the selected
  -- state is shown by the runtime's subtle ghost-selected highlight rather
  -- than a heavy outline border.
  local scaleIdx = findScaleIndex(row.scale)

  local trackSegs = {}
  for i = 1, #SCALE_PRESETS do
    table.insert(trackSegs, ui.column({
      key = "track-" .. row.name .. "-" .. i,
      flexGrow = 1,
      height = 3,
      radius = 2,
      fill = i <= scaleIdx and "primary" or "on_surface/0.12",
    }, {}))
  end

  local scaleTicks = {}
  for i, s in ipairs(SCALE_PRESETS) do
    table.insert(scaleTicks, ui.button({
      key = "scale-" .. row.name .. "-" .. i,
      text = string.format("%.4g\u{00d7}", s),
      variant = "ghost",
      selected = i == scaleIdx,
      controlSize = "sm",
      fontSize = 9,
      flexGrow = 1,
      onClick = function()
        noctalia.state.set("display_arrange.cmd", { op = "set_scale", name = row.name, scale = s })
      end,
    }))
  end

  local scaleSection = ui.column({ gap = 3, justify = "start" }, {
    ui.row({ gap = 4, align = "center" }, {
      ui.label({ text = noctalia.tr("row.scale"), fontSize = 9, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = string.format("%.4g\u{00d7}", SCALE_PRESETS[scaleIdx]), fontSize = 12, fontWeight = "bold", color = "primary" }),
    }),
    ui.row({ gap = 2, align = "center" }, trackSegs),
    ui.row({ gap = 2, align = "center" }, scaleTicks),
  })

  -- ── Orientation (Windows-style rotation) ──────────────────────────
  -- Single selector box (same pattern as resolution) to avoid overflow
  -- from long "Landscape (flipped)" labels in a 2-button row.
  local curTransform = row.transform or "normal"
  local orientIdx = 1
  for i, opt in ipairs(ORIENTATION_OPTIONS) do
    if opt.id == curTransform then orientIdx = i; break end
  end
  local curOrient = ORIENTATION_OPTIONS[orientIdx]
  local function cycleOrient(dir)
    local n = #ORIENTATION_OPTIONS
    local nextIdx = ((orientIdx - 1 + dir) % n) + 1
    local next = ORIENTATION_OPTIONS[nextIdx]
    noctalia.state.set("display_arrange.cmd", { op = "set_transform", name = row.name, transform = next.id })
  end
  local orientationSection = ui.column({ gap = 4, justify = "start", flexGrow = 1 }, {
    ui.label({ text = trOr("row.orientation", "Orientation"), fontSize = 9, color = "on_surface_variant" }),
    ui.row({
      gap = 2, align = "center",
      fill = "on_surface/0.08", radius = 6, paddingH = 8, paddingV = 5,
    }, {
      ui.label({ text = trOr(curOrient.labelKey, curOrient.fallback), fontSize = 11, flexGrow = 1 }),
      ui.button({ glyph = "chevron-left",  variant = "ghost", controlSize = "sm", onClick = function() cycleOrient(-1) end }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm", onClick = function() cycleOrient(1) end }),
    }),
  })

  -- ── Assemble card ───────────────────────────────────────────────────
  local cardChildren = { info, ui.separator({}) }
  if resHzRow ~= nil then
    table.insert(cardChildren, resHzRow)
  end
  table.insert(cardChildren, scaleSection)
  table.insert(cardChildren, orientationSection)

  if not row.isPrimary then
    table.insert(cardChildren, ui.separator({}))
    table.insert(cardChildren, ui.row({ gap = 10, align = "center", justify = "start" }, {
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
    }))
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

-- ---------------------------------------------------------------------
-- Display mode bar (Windows-style: PC only / Duplicate / Extend / 2nd only)
-- ---------------------------------------------------------------------
local function displayModeBar()
  local row1 = {}
  local row2 = {}
  for i, opt in ipairs(MODE_OPTIONS) do
    local isSelected = displayMode == opt.id
    local btn = ui.button({
      key = "mode-" .. opt.id,
      glyph = opt.glyph,
      text = noctalia.tr(opt.labelKey),
      variant = isSelected and "outline" or "ghost",
      selected = isSelected,
      enabled = not opt.unavailable,
      controlSize = "sm",
      fontSize = 10,
      flexGrow = 1,
      tooltip = noctalia.tr(opt.descKey),
      onClick = function()
        noctalia.state.set("display_arrange.cmd", { op = "set_display_mode", mode = opt.id })
      end,
    })
    if i <= 2 then
      table.insert(row1, btn)
    else
      table.insert(row2, btn)
    end
  end
  return ui.column({ gap = 4, justify = "start" }, {
    ui.label({ text = noctalia.tr("mode.section"), fontSize = 9, color = "on_surface_variant" }),
    ui.column({
      gap = 2,
      fill = "on_surface/0.05",
      radius = 8,
      padding = 4,
    }, {
      ui.row({ gap = 4, align = "center" }, row1),
      ui.row({ gap = 4, align = "center" }, row2),
    }),
  })
end

-- ---------------------------------------------------------------------
-- Confirm banner
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------
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

  if #outputs > 0 then
    table.insert(body, displayModeBar())
    table.insert(body, ui.separator({}))
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

noctalia.state.watch("display_arrange.mode", function(value)
  displayMode = type(value) == "string" and value or "extend"
  render()
end)

render()
