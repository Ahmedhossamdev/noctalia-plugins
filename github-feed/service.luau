--!nonstrict
-- GitHub Feed service — fetches the same activity you see on github.com.
--
-- With a username + personal access token configured, it polls your
-- dashboard feed (users/{you}/received_events: everything from people you
-- follow). Watched users added from the panel are always polled via their
-- public events, so the plugin also works with no token at all.
--
-- Persistence: pluginDataDir()/data.json -> { watched = { "torvalds", ... } }
-- State:
--   github_feed.items    -> { { id, type, glyph, actor, repo, summary, url,
--                               createdAt, epoch }, ... } newest first
--   github_feed.loading  -> bool
--   github_feed.error    -> string
--   github_feed.updated  -> number (epoch ms of last successful fetch, 0 = never)
--   github_feed.watched  -> { "user", ... }
--   github_feed.has_auth -> bool
-- Commands (github_feed.cmd):
--   { op = "refresh" } | { op = "add_user", user = "..." } |
--   { op = "remove_user", user = "..." }

noctalia.setUpdateInterval(60000)

local MAX_WATCHED = 20

local items = {}
local watched = {}
local loading = false
local lastError = ""
local lastUpdatedMs = 0
local lastSig = ""
local lastFetchMs = 0
local pending = 0
local succeeded = 0
local bucket = {}

-- ---------------------------------------------------------------------
-- Config + persistence
-- ---------------------------------------------------------------------
local function trim(value)
  return noctalia.string.trim(type(value) == "string" and value or "")
end

local function cfgUsername()
  return trim(noctalia.getConfig("github_username"))
end

local function cfgToken()
  return trim(noctalia.getConfig("github_token"))
end

local function cfgIntervalMs()
  local minutes = tonumber(noctalia.getConfig("refresh_interval")) or 30
  minutes = math.max(5, math.min(240, minutes))
  return minutes * 60000
end

local function cfgMaxItems()
  local n = tonumber(noctalia.getConfig("max_items")) or 30
  return math.max(10, math.min(100, n))
end

local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then return nil end
  return dir .. "/data.json"
end

local function saveData()
  local path = dataPath()
  if path == nil then return end
  local encoded = noctalia.json.encode({ watched = watched })
  if encoded ~= nil then noctalia.writeFile(path, encoded) end
end

local function validUsername(value)
  return type(value) == "string"
    and #value >= 1 and #value <= 39
    and value:match("^[%w-]+$") ~= nil
end

local function cleanUsername(raw)
  local value = trim(raw or "")
  value = value:gsub("^https://github%.com/", ""):gsub("^github%.com/", ""):gsub("^@", "")
  value = value:gsub("/.*$", "")
  return value
end

local function indexOfWatched(value)
  local key = value:lower()
  for i, entry in ipairs(watched) do
    if entry:lower() == key then return i end
  end
  return nil
end

local function loadData()
  watched = {}
  local path = dataPath()
  if path == nil then return end
  local raw = noctalia.readFile(path)
  if raw == nil then return end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.watched) ~= "table" then return end
  for _, entry in ipairs(decoded.watched) do
    local user = cleanUsername(entry)
    if validUsername(user) and indexOfWatched(user) == nil and #watched < MAX_WATCHED then
      table.insert(watched, user)
    end
  end
end

-- ---------------------------------------------------------------------
-- Time helpers (GitHub timestamps are always UTC ISO-8601)
-- ---------------------------------------------------------------------
local function isLeap(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isoToEpoch(value)
  if type(value) ~= "string" then return 0 end
  local y, mo, d, h, mi, s = value:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
  if y == nil then return 0 end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  local days = 0
  for year = 1970, y - 1 do
    days += isLeap(year) and 366 or 365
  end
  for month = 1, mo - 1 do
    days += MONTH_DAYS[month]
    if month == 2 and isLeap(y) then days += 1 end
  end
  days += (d - 1)
  return days * 86400 + h * 3600 + mi * 60 + s
end

-- ---------------------------------------------------------------------
-- Event normalization
-- ---------------------------------------------------------------------
local TYPE_GLYPHS = {
  PushEvent = "git-commit",
  PullRequestEvent = "git-pull-request",
  PullRequestReviewEvent = "eye",
  PullRequestReviewCommentEvent = "message",
  IssuesEvent = "alert-circle",
  IssueCommentEvent = "message",
  ReleaseEvent = "tag",
  WatchEvent = "star",
  ForkEvent = "git-fork",
  CreateEvent = "plus",
  DeleteEvent = "trash",
  MemberEvent = "user-plus",
  DiscussionEvent = "messages",
  PublicEvent = "world",
  SponsorEvent = "heart",
}

local function humanizeType(eventType)
  local short = (eventType or ""):gsub("Event$", "")
  short = short:gsub("(%l)(%u)", "%1 %2")
  if short == "" then return "activity" end
  return short
end

local function repoUrl(repo)
  if repo ~= "" then return "https://github.com/" .. repo end
  return "https://github.com"
end

local function normalizeEvent(raw)
  if type(raw) ~= "table" then return nil end
  local eventType = type(raw.type) == "string" and raw.type or "Event"
  local actor = (type(raw.actor) == "table" and type(raw.actor.login) == "string") and raw.actor.login or ""
  local repo = (type(raw.repo) == "table" and type(raw.repo.name) == "string") and raw.repo.name or ""
  local createdAt = type(raw.created_at) == "string" and raw.created_at or ""
  local payload = type(raw.payload) == "table" and raw.payload or {}
  if actor == "" and repo == "" then return nil end

  local summary = ""
  local url = repoUrl(repo)

  if eventType == "PushEvent" then
    local commits = type(payload.commits) == "table" and #payload.commits or 0
    if commits == 0 and tonumber(payload.size) ~= nil then commits = tonumber(payload.size) end
    local branch = type(payload.ref) == "string" and payload.ref:gsub("^refs/heads/", "") or ""
    local count = commits == 1 and "1 commit" or (tostring(commits) .. " commits")
    summary = "pushed " .. count .. (branch ~= "" and (" to " .. branch) or "")
    if branch ~= "" and repo ~= "" then url = url .. "/commits/" .. branch end
  elseif eventType == "PullRequestEvent" then
    local action = type(payload.action) == "string" and payload.action or "updated"
    local pr = type(payload.pull_request) == "table" and payload.pull_request or {}
    local number = tonumber(payload.number) or tonumber(pr.number) or 0
    local title = type(pr.title) == "string" and pr.title or ""
    summary = action .. " pull request" .. (number > 0 and (" #" .. tostring(number)) or "")
    if title ~= "" then summary ..= ": " .. title end
    if type(pr.html_url) == "string" and pr.html_url ~= "" then url = pr.html_url end
  elseif eventType == "IssuesEvent" then
    local action = type(payload.action) == "string" and payload.action or "updated"
    local issue = type(payload.issue) == "table" and payload.issue or {}
    local number = tonumber(payload.issue and payload.issue.number) or tonumber(issue.number) or 0
    local title = type(issue.title) == "string" and issue.title or ""
    summary = action .. " issue" .. (number > 0 and (" #" .. tostring(number)) or "")
    if title ~= "" then summary ..= ": " .. title end
    if type(issue.html_url) == "string" and issue.html_url ~= "" then url = issue.html_url end
  elseif eventType == "IssueCommentEvent" then
    local issue = type(payload.issue) == "table" and payload.issue or {}
    local number = tonumber(issue.number) or 0
    summary = "commented on issue" .. (number > 0 and (" #" .. tostring(number)) or "")
    if type(payload.comment) == "table" and type(payload.comment.html_url) == "string" then
      url = payload.comment.html_url
    elseif type(issue.html_url) == "string" and issue.html_url ~= "" then
      url = issue.html_url
    end
  elseif eventType == "PullRequestReviewEvent" then
    local review = type(payload.review) == "table" and payload.review or {}
    local state = type(review.state) == "string" and review.state:gsub("_", " ") or "reviewed"
    summary = state .. " a pull request"
    if type(review.html_url) == "string" and review.html_url ~= "" then url = review.html_url end
  elseif eventType == "ReleaseEvent" then
    local release = type(payload.release) == "table" and payload.release or {}
    local tag = type(release.tag_name) == "string" and release.tag_name or ""
    local name = type(release.name) == "string" and release.name or ""
    summary = "released" .. (tag ~= "" and (" " .. tag) or "") .. (name ~= "" and name ~= tag and (" · " .. name) or "")
    if type(release.html_url) == "string" and release.html_url ~= "" then url = release.html_url end
  elseif eventType == "WatchEvent" then
    summary = "starred this repository"
  elseif eventType == "ForkEvent" then
    local forkee = type(payload.forkee) == "table" and payload.forkee or {}
    local name = type(forkee.full_name) == "string" and forkee.full_name or ""
    summary = "forked" .. (name ~= "" and (" to " .. name) or " this repository")
    if name ~= "" then url = "https://github.com/" .. name end
  elseif eventType == "CreateEvent" then
    local refType = type(payload.ref_type) == "string" and payload.ref_type or ""
    local ref = type(payload.ref) == "string" and payload.ref or ""
    summary = "created " .. (refType ~= "" and (refType .. " ") or "") .. (ref ~= "" and ref or "something")
  elseif eventType == "DeleteEvent" then
    local refType = type(payload.ref_type) == "string" and payload.ref_type or ""
    local ref = type(payload.ref) == "string" and payload.ref or ""
    summary = "deleted " .. (refType ~= "" and (refType .. " ") or "") .. (ref ~= "" and ref or "something")
  elseif eventType == "MemberEvent" then
    local member = type(payload.member) == "table" and payload.member or {}
    local name = type(member.login) == "string" and member.login or ""
    summary = "added " .. (name ~= "" and name or "a collaborator")
  elseif eventType == "DiscussionEvent" then
    local discussion = type(payload.discussion) == "table" and payload.discussion or {}
    local title = type(discussion.title) == "string" and discussion.title or ""
    summary = (type(payload.action) == "string" and payload.action or "updated") .. " a discussion"
    if title ~= "" then summary ..= ": " .. title end
    if type(discussion.html_url) == "string" and discussion.html_url ~= "" then url = discussion.html_url end
  elseif eventType == "PublicEvent" then
    summary = "open-sourced this repository"
  else
    summary = humanizeType(eventType):lower() .. " on this repository"
  end

  local id = type(raw.id) == "string" and raw.id or (actor .. "|" .. repo .. "|" .. createdAt .. "|" .. eventType)
  return {
    id = id,
    type = eventType,
    glyph = TYPE_GLYPHS[eventType] or "brand-github",
    actor = actor,
    repo = repo,
    summary = summary,
    url = url,
    createdAt = createdAt,
    epoch = isoToEpoch(createdAt),
  }
end

-- ---------------------------------------------------------------------
-- Fetching
-- ---------------------------------------------------------------------
local function publish()
  noctalia.state.set("github_feed.items", items)
  noctalia.state.set("github_feed.loading", loading)
  noctalia.state.set("github_feed.error", lastError)
  noctalia.state.set("github_feed.updated", lastUpdatedMs)
  noctalia.state.set("github_feed.watched", watched)
  noctalia.state.set("github_feed.has_auth", cfgToken() ~= "" and cfgUsername() ~= "")
end

local function finishFetch()
  pending = 0
  loading = false
  if #bucket == 0 and succeeded == 0 then
    if lastError == "" then
      lastError = noctalia.tr("errors.fetch", "Could not reach GitHub. Check your connection and try again.")
    end
  else
    table.sort(bucket, function(a, b)
      if (a.epoch or 0) ~= (b.epoch or 0) then return (a.epoch or 0) > (b.epoch or 0) end
      return tostring(a.id) > tostring(b.id)
    end)
    local seen, deduped = {}, {}
    for _, entry in ipairs(bucket) do
      if not seen[entry.id] then
        seen[entry.id] = true
        table.insert(deduped, entry)
        if #deduped >= cfgMaxItems() then break end
      end
    end
    items = deduped
    lastUpdatedMs = noctalia.nowMs()
  end
  bucket = {}
  publish()
end

local function fetchUrl(url, token)
  local headers = {
    "User-Agent: NoctaliaGitHubFeed/1.0",
    "Accept: application/vnd.github+json",
  }
  if token ~= "" then
    table.insert(headers, "Authorization: Bearer " .. token)
  end
  local started = noctalia.http({ url = url, method = "GET", follow_redirects = true, headers = headers }, function(response)
    if pending <= 0 then return end
    pending -= 1
    if response.ok and response.status >= 200 and response.status < 300 and type(response.body) == "string" then
      local decoded = noctalia.json.decode(response.body)
      if type(decoded) == "table" then
        succeeded += 1
        for _, raw in ipairs(decoded) do
          local entry = normalizeEvent(raw)
          if entry ~= nil then table.insert(bucket, entry) end
        end
      end
      if pending == 0 then finishFetch() end
    else
      if response.status == 401 or response.status == 403 then
        lastError = noctalia.tr("errors.auth", "GitHub rejected the request. Check your username and token.")
      elseif response.status == 404 then
        lastError = noctalia.tr("errors.not-found", "A watched user was not found on GitHub.")
      elseif lastError == "" then
        lastError = noctalia.tr("errors.fetch", "Could not reach GitHub. Check your connection and try again.")
      end
      if pending == 0 then finishFetch() end
    end
  end)
  if not started then
    pending -= 1
    if lastError == "" then
      lastError = noctalia.tr("errors.fetch", "Could not reach GitHub. Check your connection and try again.")
    end
    if pending <= 0 then finishFetch() end
    return false
  end
  return true
end

local function refresh(manual)
  if loading then return end
  local username = cfgUsername()
  local token = cfgToken()
  local perPage = cfgMaxItems()
  if perPage > 100 then perPage = 100 end

  local urls = {}
  if token ~= "" and username ~= "" then
    table.insert(urls, "https://api.github.com/users/" .. username .. "/received_events?per_page=" .. tostring(perPage))
  end
  for _, user in ipairs(watched) do
    table.insert(urls, "https://api.github.com/users/" .. user .. "/events/public?per_page=" .. tostring(perPage))
  end
  if username ~= "" and token == "" and indexOfWatched(username) == nil then
    table.insert(urls, "https://api.github.com/users/" .. username .. "/events/public?per_page=" .. tostring(perPage))
  end

  if #urls == 0 then
    items = {}
    lastError = ""
    lastFetchMs = noctalia.nowMs()
    publish()
    return
  end

  loading = true
  lastError = ""
  bucket = {}
  succeeded = 0
  pending = #urls
  publish()
  for _, url in ipairs(urls) do
    fetchUrl(url, token)
  end
  lastFetchMs = noctalia.nowMs()
  if manual then publish() end
end

-- ---------------------------------------------------------------------
-- Watched-user mutations
-- ---------------------------------------------------------------------
local function addUser(raw)
  local user = cleanUsername(raw)
  if not validUsername(user) then
    noctalia.notifyError(noctalia.tr("toast.title", "GitHub Feed"), noctalia.tr("errors.invalid-user", "Enter a valid GitHub username."))
    return false
  end
  if indexOfWatched(user) ~= nil then
    noctalia.notifyError(noctalia.tr("toast.title", "GitHub Feed"), noctalia.tr("errors.duplicate-user", "That user is already watched."))
    return false
  end
  if #watched >= MAX_WATCHED then
    noctalia.notifyError(noctalia.tr("toast.title", "GitHub Feed"), noctalia.tr("errors.max-watched", "You can watch up to 20 users."))
    return false
  end
  table.insert(watched, user)
  saveData()
  publish()
  lastFetchMs = 0
  refresh(false)
  return true
end

local function removeUser(raw)
  local user = cleanUsername(raw)
  local idx = indexOfWatched(user)
  if idx == nil then return false end
  table.remove(watched, idx)
  local kept = {}
  for _, entry in ipairs(items) do
    if entry.actor:lower() ~= user:lower() then table.insert(kept, entry) end
  end
  items = kept
  saveData()
  publish()
  return true
end

-- ---------------------------------------------------------------------
-- Commands + lifecycle
-- ---------------------------------------------------------------------
noctalia.state.watch("github_feed.cmd", function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.op == "refresh" then
    lastFetchMs = 0
    refresh(true)
  elseif cmd.op == "add_user" then
    addUser(cmd.user)
  elseif cmd.op == "remove_user" then
    removeUser(cmd.user)
  end
  noctalia.state.set("github_feed.cmd", nil)
end)

function onIpc(event, payload)
  if event == "refresh" then
    lastFetchMs = 0
    refresh(true)
  elseif event == "add_user" then
    addUser(payload or "")
  elseif event == "remove_user" then
    removeUser(payload or "")
  elseif event == "list" then
    local names = {}
    for _, entry in ipairs(items) do
      table.insert(names, entry.actor .. " " .. entry.summary .. " (" .. entry.repo .. ")")
    end
    local body = table.concat(names, "\n")
    noctalia.notify(noctalia.tr("toast.title", "GitHub Feed"), body ~= "" and body or noctalia.tr("errors.empty", "No feed items yet."))
  end
end

function update()
  local sig = cfgUsername() .. "|" .. cfgToken() .. "|" .. table.concat(watched, ",") .. "|" .. tostring(cfgMaxItems())
  if sig ~= lastSig then
    lastSig = sig
    lastFetchMs = 0
  end
  if noctalia.nowMs() - lastFetchMs >= cfgIntervalMs() then
    refresh(false)
  end
end

loadData()
publish()
refresh(false)
