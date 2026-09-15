--!nonstrict
-- GitHub Feed panel — watched users plus the merged activity feed.
-- Cards show who did what, in which repo, and how long ago; clicking a
-- card opens it on github.com.

local items = {}
local watched = {}
local hasAuth = false
local meLogin = ""
local meAvatar = ""
local loading = false
local fetchError = ""
local updatedMs = 0
local search = ""
local searchKey = 0
local newUser = ""
local newUserKey = 0

local function ago(epochSeconds)
  if epochSeconds == nil or epochSeconds <= 0 then return "" end
  local diff = math.floor(noctalia.nowMs() / 1000) - epochSeconds
  if diff < 0 then diff = 0 end
  if diff < 60 then
    return noctalia.tr("feed.just-now", "just now")
  end
  local minutes = math.floor(diff / 60)
  if minutes < 60 then
    return noctalia.tr("feed.minutes-ago", { count = minutes })
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return noctalia.tr("feed.hours-ago", { count = hours })
  end
  local days = math.floor(hours / 24)
  if days < 7 then
    return noctalia.tr("feed.days-ago", { count = days })
  end
  return noctalia.tr("feed.weeks-ago", { count = math.floor(days / 7) })
end

local function updatedLabel()
  if loading then
    return noctalia.tr("panel.loading", "Refreshing…")
  end
  if updatedMs <= 0 then
    return noctalia.tr("panel.never-updated", "Not fetched yet")
  end
  local diff = math.floor((noctalia.nowMs() - updatedMs) / 60000)
  if diff < 1 then
    return noctalia.tr("panel.updated-now", "Updated just now")
  end
  return noctalia.tr("panel.updated-ago", { count = diff })
end

local function subtitle()
  local updated = updatedLabel()
  if meLogin ~= "" then
    return "@" .. meLogin .. " · " .. updated
  end
  return updated
end

local function avatarControl(path, key, size, glyphName)
  if path ~= "" and noctalia.fileExists(path) then
    return ui.image({ key = key, path = path, width = size, height = size,
      radius = math.floor(size / 2), fit = "cover" })
  end
  -- Same key as the image branch so the shell swaps the node in place
  -- instead of treating it as a new row (which overlaps text mid-layout).
  return ui.column({ key = key, width = size, height = size, align = "center", justify = "center",
    fill = "surface_variant", radius = math.floor(size / 2) }, {
    ui.glyph({ name = glyphName or "brand-github", size = math.floor(size / 2), color = "primary" }),
  })
end

local function openUrl(url)
  if type(url) == "string" and url:match("^https://[^%s]+$") then
    noctalia.runAsync({ "xdg-open", url })
  end
end

local function filteredItems()
  local q = noctalia.string.trim(search):lower()
  if q == "" then return items end
  local out = {}
  for _, entry in ipairs(items) do
    local hay = ((entry.actor or "") .. " " .. (entry.repo or "") .. " " .. (entry.summary or "") .. " " .. (entry.type or "")):lower()
    if hay:find(q, 1, true) ~= nil then
      table.insert(out, entry)
    end
  end
  return out
end

local function eventCard(entry)
  local context = entry.repo or ""
  local when = ago(entry.epoch)
  if when ~= "" then
    context = context .. " · " .. when
  end
  return ui.column({
    key = "event-" .. tostring(entry.id),
    gap = 8,
    padding = 12,
    fill = "surface_variant/0.25",
    radius = 10,
  }, {
    ui.row({ gap = 10, align = "center", justify = "start", onClick = function()
      openUrl(entry.url)
    end }, {
      avatarControl(entry.avatar or "", "avatar-" .. tostring(entry.id), 44, entry.glyph or "brand-github"),
      ui.column({ gap = 2, justify = "start", flexGrow = 1 }, {
        ui.label({ text = entry.actor or "", fontWeight = "bold", fontSize = 14, maxLines = 1 }),
        ui.label({ text = context, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.glyph({ name = entry.glyph or "brand-github", size = 18, color = "primary" }),
    }),
    ui.label({ text = entry.summary or "", fontSize = 13, maxLines = 4 }),
  })
end

local function watchedSection()
  local addRow = ui.row({ gap = 6, align = "center", justify = "start" }, {
    ui.input({
      key = "add-user-" .. tostring(newUserKey),
      value = newUser,
      placeholder = noctalia.tr("panel.add-placeholder", "Watch a user… Ahmedhossamdev"),
      submitOnEnter = true,
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value)
        newUser = value
      end,
      onSubmit = "onAddUserSubmit",
    }),
    ui.button({
      glyph = "plus",
      variant = "outline",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.add", "Watch user"),
      onClick = function()
        noctalia.state.set("github_feed.cmd", { op = "add_user", user = newUser })
        newUser = ""
        newUserKey += 1
        render()
      end,
    }),
  })

  local chips = {}
  for _, user in ipairs(watched) do
    table.insert(chips, ui.button({
      key = "watch-" .. user,
      text = user,
      glyph = "close",
      variant = "outline",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.remove-user", "Stop watching {user}"),
      onClick = function()
        noctalia.state.set("github_feed.cmd", { op = "remove_user", user = user })
      end,
    }))
  end

  if #chips == 0 then
    return ui.column({ gap = 6, justify = "start" }, { addRow })
  end
  return ui.column({ gap = 6, justify = "start" }, {
    addRow,
    ui.column({ gap = 4, justify = "start" }, chips),
  })
end

function onAddUserSubmit(_value)
  if noctalia.string.trim(newUser) ~= "" then
    noctalia.state.set("github_feed.cmd", { op = "add_user", user = newUser })
    newUser = ""
    newUserKey += 1
    render()
  end
end

function onSearchSubmit(_value)
end

local function feedBody()
  local body = {}

  table.insert(body, ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 10, align = "center", justify = "start", flexGrow = 1 }, {
      avatarControl(meAvatar, "me-avatar", 36, "brand-github"),
      ui.column({ gap = 2, justify = "start" }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
        ui.label({ text = subtitle(), fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ gap = 2, justify = "start" }, {
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh", "Refresh now"),
        enabled = not loading,
        onClick = function()
          noctalia.state.set("github_feed.cmd", { op = "refresh" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.open-settings", "Open plugin settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function()
        panel.close()
      end }),
    }),
  }))

  table.insert(body, ui.separator({}))
  table.insert(body, watchedSection())

  table.insert(body, ui.input({
    key = "search-" .. tostring(searchKey),
    value = search,
    placeholder = noctalia.tr("panel.search-placeholder", "Filter by user, repo, or keyword…"),
    submitOnEnter = true,
    controlSize = "sm",
    onChange = function(value)
      search = value
      render()
    end,
    onSubmit = "onSearchSubmit",
  }))

  if fetchError ~= "" then
    table.insert(body, ui.label({ text = fetchError, fontSize = 11, color = "error" }))
  end

  if not hasAuth and #watched == 0 then
    table.insert(body, ui.column({ gap = 6, padding = 12, fill = "surface_variant/0.25", radius = 10 }, {
      ui.label({ text = noctalia.tr("panel.empty-title", "No feed yet"), fontWeight = "bold", fontSize = 13 }),
      ui.label({
        text = noctalia.tr("panel.empty-hint", "Log in with gh auth login (or set your username + token in settings) for your full homepage feed, or watch a user above."),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 4,
      }),
    }))
  else
    local entries = filteredItems()
    if #entries == 0 then
      table.insert(body, ui.label({
        text = #items == 0
          and noctalia.tr("panel.no-events", "No activity yet — hit refresh.")
          or noctalia.tr("panel.no-results", "No events match this filter."),
        fontSize = 12,
        color = "on_surface_variant",
      }))
    else
      local cards = {}
      for _, entry in ipairs(entries) do
        table.insert(cards, eventCard(entry))
      end
      table.insert(body, ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, cards))
    end
  end

  return ui.column({ flexGrow = 1, gap = 8, padding = 10, justify = "start" }, body)
end

function render()
  panel.render(feedBody())
end

function onOpen(_context)
  search = ""
  searchKey += 1
  newUser = ""
  newUserKey += 1
  panel.setWantsSecondTicks(false)
  render()
end

local lastItemsSig = ""

noctalia.state.watch("github_feed.items", function(value)
  items = type(value) == "table" and value or {}
  -- The service re-publishes unchanged items (loading flips, avatar cache
  -- hits, minute ticks). Re-rendering identical content is what stacked
  -- rows on top of each other mid-refresh, so skip it.
  local parts = {}
  for _, entry in ipairs(items) do
    table.insert(parts, tostring(entry.id) .. "=" .. tostring(entry.avatar or ""))
  end
  local sig = #parts .. "|" .. table.concat(parts, "|")
  if sig ~= lastItemsSig then
    lastItemsSig = sig
    render()
  end
end)

noctalia.state.watch("github_feed.watched", function(value)
  watched = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("github_feed.has_auth", function(value)
  hasAuth = value == true
  render()
end)

noctalia.state.watch("github_feed.me", function(value)
  local info = type(value) == "table" and value or {}
  meLogin = type(info.login) == "string" and info.login or ""
  meAvatar = type(info.avatar) == "string" and info.avatar or ""
  render()
end)

noctalia.state.watch("github_feed.loading", function(value)
  local isLoading = value == true
  if isLoading ~= loading then
    loading = isLoading
    render()
  end
end)

noctalia.state.watch("github_feed.error", function(value)
  local message = type(value) == "string" and value or ""
  if message ~= fetchError then
    fetchError = message
    render()
  end
end)

noctalia.state.watch("github_feed.updated", function(value)
  local stamp = tonumber(value) or 0
  if stamp ~= updatedMs then
    updatedMs = stamp
    render()
  end
end)
