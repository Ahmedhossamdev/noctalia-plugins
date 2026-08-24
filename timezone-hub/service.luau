--!nonstrict
-- Timezone Hub service — owns the device timezone, the comparison-city
-- list, and the bar-widget zone choice. Publishes computed rows every
-- second so the bar widget and panel stay thin clients of this state.
--
-- Persistence: pluginDataDir()/data.json -> { comparisons = {...}, barTz = "" }
-- State:
--   timezone_hub.device_tz          -> string
--   timezone_hub.changing_device_tz -> bool
--   timezone_hub.rows               -> { { key, label, tz, isDevice, index,
--                                          timeText, offsetMinutes, abbrev }, ... }
--   timezone_hub.bar_tz             -> string (mirrors comparisons[].tz, or "" for device)
--   timezone_hub.all_zones          -> { "Area/City", ... }
--   timezone_hub.all_zones_loaded   -> bool
-- Commands (timezone_hub.cmd): { op = "add"|"remove"|"reorder"|"set_device"|"set_bar_zone"|"load_zones", ... }

noctalia.setUpdateInterval(1000)

local FALLBACK_ZONES = {
  "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
  "America/Sao_Paulo", "America/Mexico_City", "America/Toronto", "America/Vancouver",
  "America/Bogota", "America/Lima", "America/Argentina/Buenos_Aires",
  "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
  "Europe/Amsterdam", "Europe/Zurich", "Europe/Stockholm", "Europe/Athens",
  "Europe/Istanbul", "Europe/Moscow", "Europe/Warsaw", "Europe/Dublin",
  "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos", "Africa/Nairobi",
  "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata", "Asia/Dhaka", "Asia/Bangkok",
  "Asia/Jakarta", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai",
  "Asia/Manila", "Asia/Seoul", "Asia/Tokyo",
  "Australia/Perth", "Australia/Brisbane", "Australia/Sydney", "Australia/Melbourne",
  "Pacific/Auckland", "Pacific/Honolulu", "UTC",
}

local deviceTz = ""
local changingDeviceTz = false
local comparisons = {} -- ordered { { tz, label }, ... }
local barTz = ""
local allZones = {}
local allZonesLoaded = false
local allZonesLoading = false
local allZonesLoadStartedMs = nil
local ZONES_LOAD_TIMEOUT_MS = 8000

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
  local encoded = noctalia.json.encode({ comparisons = comparisons, barTz = barTz })
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  comparisons = {}
  barTz = ""
  local path = dataPath()
  if path ~= nil then
    local raw = noctalia.readFile(path)
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        if type(decoded.comparisons) == "table" then
          for _, entry in ipairs(decoded.comparisons) do
            if type(entry) == "table" and type(entry.tz) == "string" and entry.tz ~= "" then
              table.insert(comparisons, { tz = entry.tz, label = entry.label or entry.tz })
            end
          end
        end
        if type(decoded.barTz) == "string" then
          barTz = decoded.barTz
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function shortLabel(zone)
  local slash = zone:match(".*/(.*)$")
  if slash ~= nil then
    return (slash:gsub("_", " "))
  end
  return zone
end

local function indexOfComparison(zone)
  for i, entry in ipairs(comparisons) do
    if entry.tz == zone then
      return i
    end
  end
  return nil
end

-- "+0200" -> 120, "-0930" -> -570
local function parseOffsetMinutes(z)
  if type(z) ~= "string" or #z < 5 then
    return nil
  end
  local sign = z:sub(1, 1) == "-" and -1 or 1
  local hh = tonumber(z:sub(2, 3)) or 0
  local mm = tonumber(z:sub(4, 5)) or 0
  return sign * (hh * 60 + mm)
end

local function timeText(zone)
  local raw = noctalia.formatTime("%H|%M", nil, zone)
  local hh, mm = raw:match("(%d+)|(%d+)")
  if hh == nil then
    return "--:--"
  end
  if noctalia.getConfig("time_format") == "12h" then
    local h12 = tonumber(hh) % 12
    if h12 == 0 then
      h12 = 12
    end
    return string.format("%d:%s %s", h12, mm, tonumber(hh) < 12 and "AM" or "PM")
  end
  return hh .. ":" .. mm
end

-- ---------------------------------------------------------------------
-- Row computation + publish
-- ---------------------------------------------------------------------
local function computeRows()
  local rows = {}
  table.insert(rows, {
    key = "__device__",
    label = noctalia.tr("device.label"),
    tz = deviceTz,
    isDevice = true,
    index = -1,
    timeText = deviceTz ~= "" and timeText(deviceTz) or "--:--",
    offsetMinutes = deviceTz ~= "" and parseOffsetMinutes(noctalia.formatTime("%z", nil, deviceTz)) or nil,
    abbrev = deviceTz ~= "" and noctalia.formatTime("%Z", nil, deviceTz) or "",
  })

  for i, entry in ipairs(comparisons) do
    if entry.tz ~= deviceTz then
      table.insert(rows, {
        key = entry.tz .. "#" .. i,
        label = entry.label or entry.tz,
        tz = entry.tz,
        isDevice = false,
        index = i,
        timeText = timeText(entry.tz),
        offsetMinutes = parseOffsetMinutes(noctalia.formatTime("%z", nil, entry.tz)),
        abbrev = noctalia.formatTime("%Z", nil, entry.tz),
      })
    end
  end
  return rows
end

local function publish()
  noctalia.state.set("timezone_hub.device_tz", deviceTz)
  noctalia.state.set("timezone_hub.changing_device_tz", changingDeviceTz)
  noctalia.state.set("timezone_hub.bar_tz", barTz)
  noctalia.state.set("timezone_hub.rows", computeRows())
  -- Raw ordered comparison list (distinct from `rows`, which hides an
  -- entry that currently matches the device zone) so the panel can index
  -- drag-reorder positions and dedupe against the real underlying list.
  noctalia.state.set("timezone_hub.comparisons", comparisons)
end

-- ---------------------------------------------------------------------
-- Device timezone: detect + change
-- ---------------------------------------------------------------------
local function detectDeviceTimezone()
  noctalia.runAsync({ "timedatectl", "show", "-p", "Timezone", "--value" }, function(result)
    local tz = result.stdout and noctalia.string.trim(result.stdout) or ""
    if tz == "" then
      noctalia.runAsync(
        { "sh", "-c", "readlink -f /etc/localtime | sed 's#.*/zoneinfo/##'" },
        function(fallback)
          local fbTz = fallback.stdout and noctalia.string.trim(fallback.stdout) or ""
          if fbTz ~= "" then
            deviceTz = fbTz
            publish()
          else
            noctalia.log("TimezoneHub: could not detect the device timezone")
          end
        end
      )
      return
    end
    deviceTz = tz
    publish()
  end)
end

local function setDeviceTimezone(tz)
  if tz == nil or tz == "" or changingDeviceTz or tz == deviceTz then
    return
  end
  changingDeviceTz = true
  publish()
  noctalia.runAsync({ "pkexec", "timedatectl", "set-timezone", tz }, function(result)
    changingDeviceTz = false
    if result.exitCode == 0 then
      -- Swap, don't just overwrite: drop the newly-promoted zone out of the
      -- comparison list (it's about to be the device row, not a comparison
      -- row) and put the outgoing device zone back into the list in its
      -- place, so switching devices never silently loses or duplicates a
      -- zone.
      local oldDeviceTz = deviceTz
      local promotedIdx = indexOfComparison(tz)
      if promotedIdx ~= nil then
        table.remove(comparisons, promotedIdx)
        if oldDeviceTz ~= "" then
          table.insert(comparisons, promotedIdx, { tz = oldDeviceTz, label = shortLabel(oldDeviceTz) })
        end
      elseif oldDeviceTz ~= "" and indexOfComparison(oldDeviceTz) == nil then
        table.insert(comparisons, 1, { tz = oldDeviceTz, label = shortLabel(oldDeviceTz) })
      end
      if barTz == tz then
        barTz = ""
      end
      deviceTz = tz
      saveData()
      publish()
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.device-changed") .. " " .. tz)
    else
      publish()
      noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.device-change-failed"))
    end
  end)
end

-- ---------------------------------------------------------------------
-- Full IANA zone list (lazy, for the picker)
-- ---------------------------------------------------------------------
local function loadAllZones()
  if allZonesLoaded or allZonesLoading then
    return
  end
  allZonesLoading = true
  allZonesLoadStartedMs = noctalia.nowMs()
  noctalia.runAsync({ "timedatectl", "list-timezones" }, function(result)
    allZonesLoading = false
    allZonesLoadStartedMs = nil
    local list = {}
    if result.exitCode == 0 and result.stdout then
      for line in result.stdout:gmatch("[^\r\n]+") do
        local trimmed = noctalia.string.trim(line)
        if trimmed ~= "" then
          table.insert(list, trimmed)
        end
      end
    end
    allZones = #list > 0 and list or FALLBACK_ZONES
    allZonesLoaded = true
    noctalia.state.set("timezone_hub.all_zones", allZones)
    noctalia.state.set("timezone_hub.all_zones_loaded", true)
  end)
end

-- ---------------------------------------------------------------------
-- Comparison list mutations
-- ---------------------------------------------------------------------
local function addComparison(tz, label)
  tz = noctalia.string.trim(tz or "")
  if tz == "" or tz == deviceTz then
    return false, "invalid"
  end
  if not noctalia.isValidTimezone(tz) then
    return false, "invalid"
  end
  if indexOfComparison(tz) ~= nil then
    return false, "duplicate"
  end
  table.insert(comparisons, { tz = tz, label = (label and label ~= "") and label or shortLabel(tz) })
  saveData()
  publish()
  return true
end

local function removeComparison(tz)
  local idx = indexOfComparison(tz)
  if idx == nil then
    return false
  end
  table.remove(comparisons, idx)
  if barTz == tz then
    barTz = ""
  end
  saveData()
  publish()
  return true
end

-- Move `tz` so it ends up at 1-based `index` in the final list.
local function reorderComparison(tz, index)
  local fromIdx = indexOfComparison(tz)
  local insertAt = tonumber(index)
  if fromIdx == nil or insertAt == nil then
    return false
  end
  local entry = table.remove(comparisons, fromIdx)
  if fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #comparisons + 1))
  table.insert(comparisons, insertAt, entry)
  saveData()
  publish()
  return true
end

local function setBarZone(tz)
  barTz = tz or ""
  saveData()
  publish()
end

-- ---------------------------------------------------------------------
-- Commands from the panel
-- ---------------------------------------------------------------------
noctalia.state.watch("timezone_hub.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add" then
    local ok, reason = addComparison(cmd.tz, cmd.label)
    if not ok then
      if reason == "invalid" then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("ipc.invalid-zone", { zone = cmd.tz or "" }))
      elseif reason == "duplicate" then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("ipc.duplicate-zone", { zone = cmd.tz or "" }))
      end
    end
  elseif op == "remove" then
    removeComparison(cmd.tz)
  elseif op == "reorder" then
    reorderComparison(cmd.tz, cmd.index)
  elseif op == "set_device" then
    setDeviceTimezone(cmd.tz)
  elseif op == "set_bar_zone" then
    setBarZone(cmd.tz)
  elseif op == "load_zones" then
    loadAllZones()
  end
  noctalia.state.set("timezone_hub.cmd", nil)
end)

function onIpc(event, payload)
  if event == "add" then
    addComparison(payload or "")
  elseif event == "remove" then
    removeComparison(payload or "")
  elseif event == "list" then
    local names = {}
    for _, entry in ipairs(comparisons) do
      table.insert(names, entry.tz)
    end
    local body = table.concat(names, "\n")
    noctalia.notify(noctalia.tr("toast.title"), body ~= "" and body or noctalia.tr("ipc.empty-list"))
  end
end

function update()
  -- Self-heal: if the zone-list fetch never came back (its runAsync
  -- callback silently never fired), don't stay stuck forever - clear the
  -- in-flight flag and retry so a picker left open on "Loading..." recovers
  -- on its own instead of needing the plugin restarted.
  if allZonesLoading and allZonesLoadStartedMs ~= nil and (noctalia.nowMs() - allZonesLoadStartedMs) > ZONES_LOAD_TIMEOUT_MS then
    noctalia.log("TimezoneHub: zone list load timed out, retrying")
    allZonesLoading = false
    allZonesLoadStartedMs = nil
    loadAllZones()
  end
  publish()
end

loadData()
detectDeviceTimezone()
publish()
