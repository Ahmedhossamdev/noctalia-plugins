--!nonstrict
-- Display Arrange service — reads connected niri outputs, lets one be
-- "primary" (always anchored at 0,0), and positions every other output
-- relative to it (left/right/top/bottom, or a manual x/y). niri forgets
-- `niri msg output ... position` changes on restart/config-reload, so this
-- service just re-applies the saved layout on load and whenever the set of
-- connected outputs changes, instead of touching the user's config.kdl.
--
-- Persistence: pluginDataDir()/data.json -> { primary = "eDP-1",
--   rules = { [name] = { direction = "left"|"right"|"top"|"bottom" } } }
-- State:
--   display_arrange.outputs         -> { { name, make, model, width, height,
--                                           scale, x, y, isPrimary,
--                                           direction }, ... }
--   display_arrange.primary         -> string
--   display_arrange.applying        -> bool
--   display_arrange.pending_deadline -> number (ms epoch; 0 = no pending change)
-- Commands (display_arrange.cmd):
--   { op = "set_primary", name = ... }
--   { op = "set_direction", name = ..., direction = "left"|"right"|"top"|"bottom" }
--   { op = "clear_rule", name = ... }
--   { op = "confirm_layout" }  -- keep the pending change
--   { op = "revert_layout" }  -- undo the pending change now, instead of waiting
--   { op = "refresh" }
--
-- Every set_primary/set_direction starts a 30s confirmation window
-- (display_arrange.pending_deadline, ms epoch): if it's not confirmed in
-- time, the change is undone automatically - a bad guess (e.g. a display
-- placed somewhere the mouse can't reach) can't strand the user.

local CONFIRM_WINDOW_MS = 30000

local userIntervalMs = (noctalia.getConfig("refresh_interval") or 10) * 1000
noctalia.setUpdateInterval(userIntervalMs)

local primary = nil
local rules = {} -- [name] = { direction = "left"|"right"|"top"|"bottom" }
local applying = false
local lastConnectedKey = ""
local pendingConfirm = nil -- { deadlineMs, prevPrimary, prevRules }

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
  local encoded = noctalia.json.encode({ primary = primary, rules = rules })
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
end

-- ---------------------------------------------------------------------
-- niri IPC
-- ---------------------------------------------------------------------
local function fetchOutputs(callback)
  noctalia.runAsync({ "niri", "msg", "--json", "outputs" }, function(result)
    local list = {}
    if result.exitCode == 0 and result.stdout then
      local decoded = noctalia.json.decode(result.stdout)
      if type(decoded) == "table" then
        for name, o in pairs(decoded) do
          if type(o) == "table" and type(o.logical) == "table" then
            table.insert(list, {
              name = name,
              make = o.make or "",
              model = o.model or "",
              width = o.logical.width,
              height = o.logical.height,
              scale = o.logical.scale,
              x = o.logical.x,
              y = o.logical.y,
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

local function setPosition(name, x, y)
  -- niri's CLI (clap) treats a leading "-123" as an unrecognized flag, not a
  -- value, unless "--" tells it to stop parsing options - without this,
  -- every negative x/y (i.e. every "left" or "top" placement relative to a
  -- primary at 0,0) silently failed to apply.
  noctalia.runAsync({
    "niri", "msg", "output", name, "position", "set", "--",
    tostring(math.floor(x)), tostring(math.floor(y)),
  }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("DisplayArrange: failed to position " .. name .. ": " .. (result.stderr or ""))
    end
  end)
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
  -- Prefer whatever niri already anchored at the origin; else alphabetically first.
  local pick = nil
  for _, o in ipairs(list) do
    if o.x == 0 and o.y == 0 then
      pick = o.name
      break
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

local function applyLayout()
  applying = true
  fetchOutputs(function(list)
    ensureDefaultPrimary(list)
    local primaryOut = primary ~= nil and findOutput(list, primary) or nil
    if primaryOut ~= nil then
      setPosition(primaryOut.name, 0, 0)
      primaryOut.x = 0
      primaryOut.y = 0
      for _, entry in ipairs(list) do
        if entry.name ~= primary then
          local rule = rules[entry.name]
          if rule ~= nil then
            local x, y = targetFor(entry, primaryOut, rule)
            setPosition(entry.name, x, y)
            entry.x = x
            entry.y = y
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
  pendingConfirm = { deadlineMs = noctalia.nowMs() + CONFIRM_WINDOW_MS, prevPrimary = primary, prevRules = copyRules() }
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
    connectedKey = connectedKey .. o.name .. ";"
    local rule = rules[o.name]
    table.insert(outRows, {
      name = o.name,
      make = o.make,
      model = o.model,
      width = o.width,
      height = o.height,
      scale = o.scale,
      x = o.x,
      y = o.y,
      isPrimary = o.name == primary,
      direction = rule and rule.direction or "",
    })
  end
  lastConnectedKey = connectedKey
  noctalia.state.set("display_arrange.outputs", outRows)
  noctalia.state.set("display_arrange.primary", primary or "")
  noctalia.state.set("display_arrange.applying", applying)
  -- Pushed as a live countdown (not a raw deadline) so the panel just
  -- renders the number it's given each tick, with no clock of its own.
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
      rules[cmd.name] = nil -- the new primary can't also carry a direction rule
      primary = cmd.name
      saveData()
      applyLayout()
    end
  elseif op == "set_direction" and type(cmd.name) == "string" and type(cmd.direction) == "string" then
    armConfirm()
    rules[cmd.name] = { direction = cmd.direction }
    saveData()
    applyLayout()
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
