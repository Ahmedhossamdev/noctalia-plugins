--!nonstrict
-- Display Arrange service — reads connected outputs from the running
-- compositor (niri or Hyprland), lets one be "primary" (always anchored
-- at 0,0), and positions every other output relative to it
-- (left/right/top/bottom, or a manual x/y). Also persists and re-applies
-- mode (resolution + refresh rate) and scale per output.
-- Compositors may forget runtime changes on restart/config-reload, so
-- this service re-applies the saved layout on load and whenever the set
-- of connected outputs changes.
--
-- Persistence: pluginDataDir()/data.json -> { primary = "eDP-1",
--   rules = { [name] = { direction = "left"|"right"|"top"|"bottom",
--                         mode = { width, height, refreshRate },
--                         scale = 2.0 } } }
-- State:
--   display_arrange.outputs         -> { { name, make, model, width, height,
--                                           scale, x, y, isPrimary,
--                                           direction, modes,
--                                           currentModeWidth,
--                                           currentModeHeight,
--                                           currentModeRefreshRate }, ... }
--   display_arrange.primary         -> string
--   display_arrange.applying        -> bool
--   display_arrange.pending_deadline -> number (ms epoch; 0 = no pending change)
-- Commands (display_arrange.cmd):
--   { op = "set_primary", name = ... }
--   { op = "set_direction", name = ..., direction = "left"|"right"|"top"|"bottom" }
--   { op = "set_mode", name = ..., width, height, refreshRate (mHz) }
--   { op = "set_scale", name = ..., scale = 2.0 }
--   { op = "clear_rule", name = ... }
--   { op = "confirm_layout" }  -- keep the pending change
--   { op = "revert_layout" }  -- undo the pending change now, instead of waiting
--   { op = "refresh" }
--
-- Every set_primary/set_direction/set_mode/set_scale starts a 30s
-- confirmation window: if not confirmed in time, the change is undone
-- automatically so a bad guess can't strand the user.

local CONFIRM_WINDOW_MS = 30000

local userIntervalMs = (noctalia.getConfig("refresh_interval") or 10) * 1000
noctalia.setUpdateInterval(userIntervalMs)

-- ---------------------------------------------------------------------
-- Compositor detection
-- ---------------------------------------------------------------------
local compositor = "unknown"
if os.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil then
  compositor = "hyprland"
elseif os.getenv("NIRI_SOCKET") ~= nil then
  compositor = "niri"
end

local primary = nil
local rules = {} -- [name] = { direction = "left"|"right"|"top"|"bottom" }
local displayMode = "extend" -- "extend"|"duplicate"|"primary-only"|"second-only"
local applying = false
local lastConnectedKey = ""
local pendingConfirm = nil -- { deadlineMs, prevPrimary, prevRules, prevMode }

-- ---------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------
local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/data.json"
end

local function saveData()
  local path = dataPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode({ primary = primary, rules = rules, displayMode = displayMode })
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  local path = dataPath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  if type(decoded.primary) == "string" then
    primary = decoded.primary
  end
  if type(decoded.rules) == "table" then
    rules = decoded.rules
  end
  if type(decoded.displayMode) == "string" then
    displayMode = decoded.displayMode
  end
end

-- ---------------------------------------------------------------------
-- Compositor adapter — abstracts IPC differences between niri and Hyprland.
-- Each adapter provides: fetchOutputs, setOutputEnabled, setOutputConfig.
-- setOutputConfig applies mode + scale + position atomically (required for
-- Hyprland's monolithic "monitor" keyword; niri handles them independently).
-- ---------------------------------------------------------------------
local adapter = {}

-- =====================================================================
-- niri adapter
-- =====================================================================
if compositor == "niri" then
  adapter.fetchOutputs = function(callback)
    noctalia.runAsync({ "niri", "msg", "--json", "outputs" }, function(result)
      local list = {}
      if result.exitCode == 0 and result.stdout then
        local decoded = noctalia.json.decode(result.stdout)
        if type(decoded) == "table" then
          for name, o in pairs(decoded) do
            if type(o) == "table" then
              local enabled = type(o.logical) == "table"
              local log = enabled and o.logical or {}
              local modesRaw = type(o.modes) == "table" and o.modes or {}
              local modes = {}
              for _, m in ipairs(modesRaw) do
                if type(m) == "table" and m.width and m.height and m.refresh_rate then
                  table.insert(modes, { width = m.width, height = m.height, refreshRate = m.refresh_rate, isPreferred = m.is_preferred == true })
                end
              end
              table.sort(modes, function(a, b)
                local aPixels = a.width * a.height
                local bPixels = b.width * b.height
                if aPixels ~= bPixels then return aPixels < bPixels end
                return a.refreshRate < b.refreshRate
              end)
              local cm = type(o.current_mode) == "table" and o.current_mode or nil
              table.insert(list, {
                name = name,
                make = o.make or "",
                model = o.model or "",
                enabled = enabled,
                width = log.width or 0,
                height = log.height or 0,
                scale = log.scale or 1,
                x = log.x or 0,
                y = log.y or 0,
                modes = modes,
                currentModeWidth = cm and cm.width or nil,
                currentModeHeight = cm and cm.height or nil,
                currentModeRefreshRate = cm and cm.refresh_rate or nil,
              })
            end
          end
        end
      end
      table.sort(list, function(a, b)
        return a.name < b.name
      end)
      callback(list)
    end)
  end

  adapter.setOutputEnabled = function(name, enabled)
    noctalia.runAsync({
      "niri", "msg", "output", name, enabled and "on" or "off",
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("DisplayArrange: failed to set output " .. name .. " " .. (enabled and "on" or "off") .. ": " .. (result.stderr or ""))
      end
    end)
  end

  adapter.setOutputConfig = function(name, entry, modeW, modeH, modeHz, scale, x, y)
    -- niri: apply mode, scale, and position as separate commands.
    if modeW ~= nil and modeH ~= nil and modeHz ~= nil then
      local hz = math.floor(modeHz / 1000 + 0.5)
      noctalia.runAsync({
        "niri", "msg", "output", name, "mode",
        string.format("%dx%d@%d", modeW, modeH, hz),
      }, function(result)
        if result.exitCode ~= 0 then
          noctalia.log("DisplayArrange: failed to set mode for " .. name .. ": " .. (result.stderr or ""))
        end
      end)
    end
    if scale ~= nil then
      noctalia.runAsync({
        "niri", "msg", "output", name, "scale", tostring(scale),
      }, function(result)
        if result.exitCode ~= 0 then
          noctalia.log("DisplayArrange: failed to set scale for " .. name .. ": " .. (result.stderr or ""))
        end
      end)
    end
    if x ~= nil and y ~= nil then
      -- niri's CLI (clap) treats a leading "-123" as an unrecognized flag,
      -- unless "--" tells it to stop parsing options.
      noctalia.runAsync({
        "niri", "msg", "output", name, "position", "set", "--",
        tostring(math.floor(x)), tostring(math.floor(y)),
      }, function(result)
        if result.exitCode ~= 0 then
          noctalia.log("DisplayArrange: failed to position " .. name .. ": " .. (result.stderr or ""))
        end
      end)
    end
  end

-- =====================================================================
-- Hyprland adapter
-- =====================================================================
elseif compositor == "hyprland" then
  -- Cache last-known state per output for building "monitor" keyword strings.
  -- Hyprland's "monitor" keyword is monolithic: NAME,MODE,SCALE,OFFSET
  -- so changing any one property requires the current values of the others.
  local hyprCache = {} -- [name] = { modeStr, scale, x, y, enabled }

  -- Parse "WxH@RATE" mode string into { width, height, refreshRate (Hz float) }
  local function parseHyprMode(modeStr)
    local w, h, r = modeStr:match("(%d+)x(%d+)@([%d%.]+)")
    if w and h and r then
      return { width = tonumber(w), height = tonumber(h), refreshRate = tonumber(r) }
    end
    return nil
  end

  -- Build a "WxH@RATE" mode string from numeric values.
  local function buildModeStr(width, height, refreshRateMhz)
    if refreshRateMhz ~= nil then
      local hz = refreshRateMhz / 1000
      return string.format("%dx%d@%.5f", width, height, hz)
    end
    return nil
  end

  adapter.fetchOutputs = function(callback)
    noctalia.runAsync({ "hyprctl", "monitors", "-j" }, function(result)
      local list = {}
      if result.exitCode == 0 and result.stdout then
        local decoded = noctalia.json.decode(result.stdout)
        if type(decoded) == "table" then
          for _, o in ipairs(decoded) do
            if type(o) == "table" then
              local enabled = o.disabled ~= true
              local modesRaw = type(o.availableModes) == "table" and o.availableModes or {}
              local modes = {}
              for _, modeStr in ipairs(modesRaw) do
                if type(modeStr) == "string" then
                  local parsed = parseHyprMode(modeStr)
                  if parsed ~= nil then
                    table.insert(modes, {
                      width = parsed.width,
                      height = parsed.height,
                      refreshRate = parsed.refreshRate * 1000, -- store as mHz for internal use
                      isPreferred = false,
                    })
                  end
                end
              end
              table.sort(modes, function(a, b)
                local aPixels = a.width * a.height
                local bPixels = b.width * b.height
                if aPixels ~= bPixels then return aPixels < bPixels end
                return a.refreshRate < b.refreshRate
              end)

              local cmStr = nil
              if enabled then
                cmStr = string.format("%dx%d@%.5f", o.width, o.height, o.refreshRate)
              end

              local entry = {
                name = o.name,
                make = o.make or "",
                model = o.model or "",
                enabled = enabled,
                width = enabled and o.width or 0,
                height = enabled and o.height or 0,
                scale = o.scale or 1,
                x = enabled and o.x or 0,
                y = enabled and o.y or 0,
                modes = modes,
                currentModeWidth = enabled and o.width or nil,
                currentModeHeight = enabled and o.height or nil,
                currentModeRefreshRate = enabled and (o.refreshRate * 1000) or nil,
              }

              -- Update cache with live state
              hyprCache[o.name] = {
                modeStr = cmStr,
                scale = o.scale or 1,
                x = enabled and o.x or 0,
                y = enabled and o.y or 0,
                enabled = enabled,
              }

              table.insert(list, entry)
            end
          end
        end
      end
      table.sort(list, function(a, b)
        return a.name < b.name
      end)
      callback(list)
    end)
  end

  adapter.setOutputEnabled = function(name, enabled)
    if enabled then
      -- Use cached values if available, otherwise preferred/auto defaults.
      local cached = hyprCache[name]
      if cached ~= nil and cached.modeStr ~= nil then
        local offset = string.format("%dx%d", cached.x, cached.y)
        noctalia.runAsync({
          "hyprctl", "keyword", "monitor",
          name .. "," .. cached.modeStr .. "," .. cached.scale .. "," .. offset,
        }, function(result)
          if result.exitCode ~= 0 then
            noctalia.log("DisplayArrange: failed to enable " .. name .. ": " .. (result.stderr or ""))
          end
        end)
      else
        noctalia.runAsync({
          "hyprctl", "keyword", "monitor",
          name .. ",preferred,auto,0",
        }, function(result)
          if result.exitCode ~= 0 then
            noctalia.log("DisplayArrange: failed to enable " .. name .. ": " .. (result.stderr or ""))
          end
        end)
      end
    else
      noctalia.runAsync({
        "hyprctl", "keyword", "monitor",
        name .. ",disable",
      }, function(result)
        if result.exitCode ~= 0 then
          noctalia.log("DisplayArrange: failed to disable " .. name .. ": " .. (result.stderr or ""))
        end
      end)
    end
  end

  adapter.setOutputConfig = function(name, entry, modeW, modeH, modeHz, scale, x, y)
    -- Build the full mode string, preferring explicit values, then cached,
    -- then entry values, then "preferred" as final fallback.
    local modeStr = nil
    if modeW ~= nil and modeH ~= nil and modeHz ~= nil then
      modeStr = buildModeStr(modeW, modeH, modeHz)
    end
    if modeStr == nil then
      local cached = hyprCache[name]
      if cached ~= nil then
        modeStr = cached.modeStr
      end
    end
    if modeStr == nil and entry ~= nil and entry.currentModeWidth ~= nil then
      modeStr = buildModeStr(entry.currentModeWidth, entry.currentModeHeight, entry.currentModeRefreshRate)
    end
    if modeStr == nil then
      modeStr = "preferred"
    end

    local useScale = scale
    if useScale == nil then
      local cached = hyprCache[name]
      useScale = cached ~= nil and cached.scale or (entry ~= nil and entry.scale) or 1
    end

    local useX = x
    local useY = y
    if useX == nil or useY == nil then
      local cached = hyprCache[name]
      useX = useX or (cached ~= nil and cached.x) or (entry ~= nil and entry.x) or 0
      useY = useY or (cached ~= nil and cached.y) or (entry ~= nil and entry.y) or 0
    end

    local offset = string.format("%dx%d", math.floor(useX), math.floor(useY))
    local keyword = name .. "," .. modeStr .. "," .. useScale .. "," .. offset

    -- Update cache
    hyprCache[name] = {
      modeStr = modeStr ~= "preferred" and modeStr or nil,
      scale = useScale,
      x = math.floor(useX),
      y = math.floor(useY),
      enabled = true,
    }

    noctalia.runAsync({
      "hyprctl", "keyword", "monitor", keyword,
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("DisplayArrange: failed to configure " .. name .. ": " .. (result.stderr or ""))
      end
    end)
  end

else
  -- Fallback: no supported compositor detected.
  noctalia.log("DisplayArrange: no supported compositor detected (expected niri or Hyprland)")
  adapter.fetchOutputs = function(callback) callback({}) end
  adapter.setOutputEnabled = function() end
  adapter.setOutputConfig = function() end
end

-- Local wrapper so the rest of the code can call fetchOutputs(callback)
-- without knowing which compositor adapter is active.
local function fetchOutputs(callback)
  adapter.fetchOutputs(callback)
end

-- ---------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------
local function findOutput(list, name)
  for _, o in ipairs(list) do
    if o.name == name then
      return o
    end
  end
  return nil
end

local function ensureDefaultPrimary(list)
  if primary ~= nil and findOutput(list, primary) ~= nil then
    return
  end
  -- Prefer whatever the compositor already anchored at the origin among enabled outputs;
  -- fall back to any enabled output, then any output alphabetically.
  local pick = nil
  for _, o in ipairs(list) do
    if o.enabled and o.x == 0 and o.y == 0 then
      pick = o.name
      break
    end
  end
  if pick == nil then
    for _, o in ipairs(list) do
      if o.enabled then pick = o.name; break end
    end
  end
  if pick == nil and list[1] ~= nil then
    pick = list[1].name
  end
  primary = pick
  saveData()
end

-- Direction is always relative to the primary's current geometry, so
-- switching primaries recomputes every direction rule automatically -
-- nothing to migrate by hand.
local function targetFor(entry, primaryOut, rule)
  if rule.direction == "left" then
    return primaryOut.x - entry.width, primaryOut.y
  elseif rule.direction == "right" then
    return primaryOut.x + primaryOut.width, primaryOut.y
  elseif rule.direction == "top" then
    return primaryOut.x, primaryOut.y - entry.height
  elseif rule.direction == "bottom" then
    return primaryOut.x, primaryOut.y + primaryOut.height
  end
  return entry.x, entry.y
end

local function applyModeAndScale(entry)
  local rule = rules[entry.name]
  local modeW, modeH, modeHz, scale
  if rule ~= nil then
    if rule.mode ~= nil then
      modeW = rule.mode.width
      modeH = rule.mode.height
      modeHz = rule.mode.refreshRate
    end
    if rule.scale ~= nil then
      scale = rule.scale
    end
  end
  adapter.setOutputConfig(entry.name, entry, modeW, modeH, modeHz, scale, nil, nil)
  -- Return updated entry so callers can use the resolved values.
  if modeW ~= nil then entry.currentModeWidth = modeW; entry.currentModeHeight = modeH; entry.currentModeRefreshRate = modeHz end
  if scale ~= nil then entry.scale = scale end
  return entry
end

local function applyLayout()
  applying = true
  fetchOutputs(function(list)
    ensureDefaultPrimary(list)

    if displayMode == "primary-only" then
      -- Keep only the primary on; disable everything else.
      for _, entry in ipairs(list) do
        if entry.name == primary then
          adapter.setOutputEnabled(entry.name, true)
          applyModeAndScale(entry)
          adapter.setOutputConfig(entry.name, entry, nil, nil, nil, nil, 0, 0)
          entry.x = 0; entry.y = 0
        else
          adapter.setOutputEnabled(entry.name, false)
          entry.enabled = false
        end
      end

    elseif displayMode == "second-only" then
      -- Disable the primary; bring the first non-primary to the origin.
      local placedFirst = false
      for _, entry in ipairs(list) do
        if entry.name == primary then
          adapter.setOutputEnabled(entry.name, false)
          entry.enabled = false
        else
          adapter.setOutputEnabled(entry.name, true)
          applyModeAndScale(entry)
          if not placedFirst then
            adapter.setOutputConfig(entry.name, entry, nil, nil, nil, nil, 0, 0)
            entry.x = 0; entry.y = 0
            placedFirst = true
          end
        end
      end

    else -- "extend" (default)
      -- Enable everything and arrange per direction rules.
      for _, entry in ipairs(list) do
        adapter.setOutputEnabled(entry.name, true)
        applyModeAndScale(entry)
      end
      local primaryOut = primary ~= nil and findOutput(list, primary) or nil
      if primaryOut ~= nil then
        adapter.setOutputConfig(primaryOut.name, primaryOut, nil, nil, nil, nil, 0, 0)
        primaryOut.x = 0; primaryOut.y = 0
        for _, entry in ipairs(list) do
          -- Skip outputs that were disabled before this apply; their geometry
          -- is 0x0 until the compositor confirms the re-enable. The next
          -- update() tick will reposition them correctly once they have valid
          -- dimensions.
          if entry.name ~= primary and entry.enabled then
            local rule = rules[entry.name]
            if rule ~= nil and rule.direction ~= nil then
              local x, y = targetFor(entry, primaryOut, rule)
              adapter.setOutputConfig(entry.name, entry, nil, nil, nil, nil, x, y)
              entry.x = x; entry.y = y
            end
          end
        end
      end
    end

    applying = false
    publish(list)
  end)
end

-- ---------------------------------------------------------------------
-- Pending-change confirmation
-- ---------------------------------------------------------------------
local function copyRules()
  local c = {}
  for name, rule in pairs(rules) do
    c[name] = rule
  end
  return c
end

-- Snapshots the layout before a user-initiated change so it can be undone,
-- and switches to a 1s tick so the countdown/auto-revert are responsive
-- regardless of the configured (usually much slower) refresh interval.
local function armConfirm()
  pendingConfirm = { deadlineMs = noctalia.nowMs() + CONFIRM_WINDOW_MS, prevPrimary = primary, prevRules = copyRules(), prevMode = displayMode }
  noctalia.setUpdateInterval(1000)
end

local function clearConfirm()
  pendingConfirm = nil
  noctalia.setUpdateInterval(userIntervalMs)
end

local function revertPending()
  if pendingConfirm == nil then
    return
  end
  primary = pendingConfirm.prevPrimary
  rules = pendingConfirm.prevRules
  displayMode = pendingConfirm.prevMode
  clearConfirm()
  saveData()
  applyLayout()
end

-- ---------------------------------------------------------------------
-- Publish
-- ---------------------------------------------------------------------
function publish(list)
  local connectedKey = ""
  local outRows = {}
  for _, o in ipairs(list) do
    -- connectedKey tracks ALL physically connected outputs (for hotplug
    -- detection), regardless of whether we've enabled or disabled them.
    connectedKey = connectedKey .. o.name .. ";"
    -- Only send enabled outputs to the panel; disabled ones have no
    -- meaningful geometry to show and would confuse the UI.
    if o.enabled then
      local rule = rules[o.name]
      -- Use rule values as optimistic overrides so the panel reflects a
      -- just-applied change before the compositor confirms it on the next fetch.
      local displayScale = (rule and rule.scale) or o.scale
      local displayModeW  = (rule and rule.mode and rule.mode.width)        or o.currentModeWidth
      local displayModeH  = (rule and rule.mode and rule.mode.height)       or o.currentModeHeight
      local displayModeHz = (rule and rule.mode and rule.mode.refreshRate)  or o.currentModeRefreshRate
      table.insert(outRows, {
        name = o.name,
        make = o.make,
        model = o.model,
        width = o.width,
        height = o.height,
        scale = displayScale,
        x = o.x,
        y = o.y,
        isPrimary = o.name == primary,
        direction = rule and rule.direction or "",
        modes = o.modes or {},
        currentModeWidth = displayModeW,
        currentModeHeight = displayModeH,
        currentModeRefreshRate = displayModeHz,
      })
    end
  end
  lastConnectedKey = connectedKey
  noctalia.state.set("display_arrange.outputs", outRows)
  noctalia.state.set("display_arrange.primary", primary or "")
  noctalia.state.set("display_arrange.mode", displayMode)
  noctalia.state.set("display_arrange.applying", applying)
  local pendingSeconds = 0
  if pendingConfirm ~= nil then
    pendingSeconds = math.max(0, math.ceil((pendingConfirm.deadlineMs - noctalia.nowMs()) / 1000))
  end
  noctalia.state.set("display_arrange.pending_seconds", pendingSeconds)
end

-- ---------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------
noctalia.state.watch("display_arrange.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "set_primary" and type(cmd.name) == "string" then
    if cmd.name ~= primary then
      armConfirm()
      -- The new primary has no direction, but keep any mode/scale rules for it.
      local existing = rules[cmd.name] or {}
      if existing.mode ~= nil or existing.scale ~= nil then
        rules[cmd.name] = { mode = existing.mode, scale = existing.scale }
      else
        rules[cmd.name] = nil
      end
      primary = cmd.name
      saveData()
      applyLayout()
    end
  elseif op == "set_direction" and type(cmd.name) == "string" and type(cmd.direction) == "string" then
    armConfirm()
    -- Preserve any existing mode/scale when updating direction.
    local existing = rules[cmd.name] or {}
    rules[cmd.name] = { direction = cmd.direction, mode = existing.mode, scale = existing.scale }
    saveData()
    applyLayout()
  elseif op == "set_mode" and type(cmd.name) == "string" and type(cmd.width) == "number" then
    armConfirm()
    local existing = rules[cmd.name] or {}
    rules[cmd.name] = { direction = existing.direction, scale = existing.scale,
      mode = { width = cmd.width, height = cmd.height, refreshRate = cmd.refreshRate } }
    saveData()
    applyLayout()
  elseif op == "set_scale" and type(cmd.name) == "string" and type(cmd.scale) == "number" then
    armConfirm()
    local existing = rules[cmd.name] or {}
    rules[cmd.name] = { direction = existing.direction, mode = existing.mode, scale = cmd.scale }
    saveData()
    applyLayout()
  elseif op == "set_display_mode" and type(cmd.mode) == "string" then
    local validModes = { extend = true, ["primary-only"] = true, ["second-only"] = true }
    if validModes[cmd.mode] and cmd.mode ~= displayMode then
      armConfirm()
      displayMode = cmd.mode
      saveData()
      applyLayout()
    end
  elseif op == "clear_rule" and type(cmd.name) == "string" then
    rules[cmd.name] = nil
    saveData()
    fetchOutputs(publish)
  elseif op == "confirm_layout" then
    clearConfirm()
    fetchOutputs(publish)
  elseif op == "revert_layout" then
    revertPending()
  elseif op == "refresh" then
    fetchOutputs(publish)
  end
  noctalia.state.set("display_arrange.cmd", nil)
end)

function update()
  if pendingConfirm ~= nil and noctalia.nowMs() >= pendingConfirm.deadlineMs then
    revertPending()
    return
  end
  fetchOutputs(function(list)
    local connectedKey = ""
    for _, o in ipairs(list) do
      connectedKey = connectedKey .. o.name .. ";"
    end
    if connectedKey ~= lastConnectedKey then
      local autoReapply = noctalia.getConfig("auto_reapply")
      if autoReapply == nil then
        autoReapply = true
      end
      if autoReapply then
        ensureDefaultPrimary(list)
        applyLayout()
        return
      end
    end
    publish(list)
  end)
end

loadData()
applyLayout()
