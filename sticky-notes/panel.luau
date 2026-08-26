--!nonstrict
-- Sticky Notes panel — scrollable list + full-width edit view.

local DRAG_TYPE = "sticky-notes-note"

local NOTE_COLORS = {
  { id = "yellow", hex = "#FFF59D", labelKey = "settings.color-yellow" },
  { id = "pink",   hex = "#F8BBD9", labelKey = "settings.color-pink"   },
  { id = "red",    hex = "#EF5350", labelKey = "settings.color-red"    },
  { id = "blue",   hex = "#B3E5FC", labelKey = "settings.color-blue"   },
  { id = "green",  hex = "#DCEDC8", labelKey = "settings.color-green"  },
  { id = "orange", hex = "#FFA726", labelKey = "settings.color-orange" },
  { id = "purple", hex = "#E1BEE7", labelKey = "settings.color-purple" },
}

local notes = {}
local blurred = false
local editingId = nil
local pendingDeleteId = nil
local editKey = 0
-- -1 so the first state-watch fire (initial load) does not trigger auto-open.
local prevNoteCount = -1

-- -------------------------------------------------------------------------
local function colorHex(id)
  for _, c in ipairs(NOTE_COLORS) do
    if c.id == id then return c.hex end
  end
  return "#FFF59D"
end

local function formatDate(ts)
  if type(ts) ~= "number" or ts <= 0 then return "" end
  local ok, result = pcall(os.date, "%b %d, %H:%M", ts)
  if ok and type(result) == "string" then return result end
  return ""
end

local function findNote(id)
  for _, n in ipairs(notes) do
    if n.id == id then return n end
  end
  return nil
end

local function sendCmd(cmd)
  noctalia.state.set("sticky_notes.cmd", cmd)
end

-- Auto-delete empty note and return to list (or just return to list).
-- Called from both the Back button and the Done button.
local function leaveEdit()
  local note = editingId ~= nil and findNote(editingId) or nil
  if note ~= nil and noctalia.string.trim(note.content or "") == "" then
    local id = editingId
    editingId = nil
    pendingDeleteId = nil
    sendCmd({ op = "remove", id = id })
    -- The notes-watcher will call render() once the delete is processed.
  else
    editingId = nil
    pendingDeleteId = nil
    render()
  end
end

-- -------------------------------------------------------------------------
-- Color picker
-- Each swatch = outer "halo" wrapper (fill = primary when selected, surface
-- when not) → inner coloured column (fill = hex, always the real color) →
-- ghost button click target. The wrapper's fill provides an unmissable
-- selection ring without touching the swatch's own fill.
-- IMPORTANT: never pass selected = true on the inner button — its theme
-- background paints over the column's fill (the swatch would appear blue).
-- -------------------------------------------------------------------------
local function colorPicker(note)
  local swatches = {}
  for _, c in ipairs(NOTE_COLORS) do
    local isSelected = note.color == c.id
    table.insert(swatches, ui.column({
      key     = "wrap-" .. c.id,
      fill    = isSelected and "primary" or "surface",
      padding = 3,
      radius  = 10,
      align   = "stretch",
      justify = "stretch",
    }, {
      ui.column({
        key     = "sw-" .. c.id,
        fill    = c.hex,
        width   = 26,
        height  = 26,
        radius  = 7,
        align   = "stretch",
        justify = "center",
      }, {
        ui.button({
          key      = "sw-btn-" .. c.id,
          variant  = "ghost",
          flexGrow = 1,
          tooltip  = noctalia.tr(c.labelKey),
          onClick  = function()
            sendCmd({ op = "update", id = note.id, color = c.id })
          end,
        }),
      }),
    }))
  end
  return ui.row({ gap = 6, align = "center", justify = "center", paddingV = 4 }, swatches)
end

-- -------------------------------------------------------------------------
-- Blur overlay
-- -------------------------------------------------------------------------
local function blurOverlay()
  local strength = noctalia.getConfig("blur_strength") or "medium"
  -- The overlay renders on top of the note card's pastel fill, so use the
  -- theme's "surface" color (dark in dark themes) rather than the muted
  -- "on_surface_variant" which is near-invisible on light backgrounds.
  local items = { ui.glyph({ name = "eye-off", size = 32, color = "surface" }) }
  if strength ~= "heavy" then
    table.insert(items, ui.label({
      text = noctalia.tr("panel.blurred-hint"),
      fontSize = 11, color = "surface", textAlign = "center",
    }))
  end
  return ui.column({ gap = 8, align = "center", justify = "center", padding = 16 }, items)
end

-- -------------------------------------------------------------------------
-- List view
-- -------------------------------------------------------------------------
-- -------------------------------------------------------------------------
-- Drag & drop reorder — mirrors the timezone-hub grip-handle pattern.
-- Zone value is encoded as "<group>:<index>" (e.g. "p:2", "u:1") so a drop
-- carries both the target group (pinned/unpinned) and the insertion index
-- within that group. Dragging a note into the other group's zone toggles
-- its pinned state on the service side.
-- -------------------------------------------------------------------------
local function insertionZone(group, index)
  return ui.dropZone({
    key          = "zone-" .. group .. "-" .. index,
    accepts      = { DRAG_TYPE },
    value        = group .. ":" .. index,
    onDrop       = "onZoneDropped",
    height       = 3,
    radius       = 4,
    expandOnDrag = true,
    hitSlop      = 20,
  })
end

function onZoneDropped(payload, value)
  if type(payload) ~= "string" or payload == "" then return end
  if type(value) ~= "string" then return end
  local group, indexStr = value:match("^([pu]):(%d+)$")
  if group == nil then return end
  local index = tonumber(indexStr)
  if index == nil then return end
  sendCmd({ op = "move", id = payload, group = group, index = index })
end

-- Ctrl+Enter in the edit view's multiline input fires this. Gated on the
-- `save_shortcut` setting so users can turn it off.
function onEditSubmit(_value)
  if noctalia.getConfig("save_shortcut") == false then return end
  if editingId ~= nil then leaveEdit() end
end

local function notePreviewCard(note)
  local hex = colorHex(note.color)
  local fontSize = noctalia.getConfig("font_size") or 13
  local dateText = formatDate(note.createdAt)
  local isPinned = note.pinned == true

  local body
  if blurred then
    body = blurOverlay()
  else
    local preview = note.content ~= "" and note.content or noctalia.tr("panel.empty-preview")
    -- "surface" = dark bg colour in dark themes → readable on light pastels.
    body = ui.label({ text = preview, fontSize = fontSize, color = "surface", maxLines = 4 })
  end

  if pendingDeleteId == note.id then
    return ui.column({
      key = "card-" .. note.id, fill = hex, radius = 8, padding = 10, gap = 6,
    }, {
      body,
      ui.separator({}),
      ui.row({ gap = 6, align = "center", justify = "center" }, {
        ui.label({ text = noctalia.tr("panel.confirm-delete"), fontSize = 11, color = "surface" }),
        ui.button({
          glyph = "check", text = noctalia.tr("panel.delete-yes"),
          variant = "destructive", controlSize = "sm",
          onClick = function()
            local id = note.id; pendingDeleteId = nil
            sendCmd({ op = "remove", id = id })
          end,
        }),
        ui.button({
          glyph = "close", variant = "outline", controlSize = "sm",
          onClick = function() pendingDeleteId = nil; render() end,
        }),
      }),
    })
  end

  return ui.column({
    key = "card-" .. note.id, fill = hex, radius = 8, padding = 10, gap = 6,
  }, {
    body,
    ui.separator({}),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.dragSource({
          key             = "grip-" .. note.id,
          dragType        = DRAG_TYPE,
          payload         = note.id,
          -- Preview = the leading row (grip + date) so it stays inside the
          -- panel. liftFromLayout MUST be false here: the drag source's
          -- ancestor 1 has a sibling (the trailing action row), so lifting
          -- it collapses the card's outer row and leaves the leading row
          -- misplaced when the drag ends without a valid drop.
          previewAncestor = 1,
          liftFromLayout  = false,
          width           = 20,
          height          = 20,
          align           = "center",
          justify         = "center",
          tooltip         = noctalia.tr("panel.drag-hint"),
        }, {
          ui.glyph({ name = "menu-2", size = 12, color = "surface" }),
        }),
        ui.label({ text = dateText, fontSize = 10, color = "surface" }),
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({
          glyph = isPinned and "star-filled" or "star",
          variant = "outline", controlSize = "sm",
          tooltip = isPinned and noctalia.tr("panel.unpin") or noctalia.tr("panel.pin"),
          onClick = function() sendCmd({ op = "toggle_pin", id = note.id }) end,
        }),
        ui.button({
          glyph = "pencil", variant = "outline", controlSize = "sm",
          enabled = not blurred, tooltip = noctalia.tr("panel.edit"),
          onClick = function()
            editingId = note.id; pendingDeleteId = nil; editKey += 1; render()
          end,
        }),
        ui.button({
          glyph = "trash", variant = "outline", controlSize = "sm",
          tooltip = noctalia.tr("panel.delete"),
          onClick = function() pendingDeleteId = note.id; render() end,
        }),
      }),
    }),
  })
end

local function listView()
  if #notes == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 14 }, {
      ui.glyph({ name = "note", size = 48, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.empty"), fontSize = 13,
                  color = "on_surface_variant", textAlign = "center" }),
      ui.button({
        text = noctalia.tr("panel.add-first"), glyph = "plus", variant = "outline",
        onClick = function() sendCmd({ op = "add" }) end,
      }),
    })
  end
  -- Storage is already in display order (pinned first, newest-first within
  -- each group — the service enforces this on load and on every mutation).
  local pinned, unpinned = {}, {}
  for _, n in ipairs(notes) do
    if n.pinned then
      table.insert(pinned, n)
    else
      table.insert(unpinned, n)
    end
  end

  local items = {}

  -- Pinned group: one drop zone before each card, one after the last card.
  -- Always emit at least the leading zone so an empty pinned group is a
  -- valid drop target (drag any note into it to pin it).
  table.insert(items, insertionZone("p", 1))
  for i, note in ipairs(pinned) do
    table.insert(items, notePreviewCard(note))
    table.insert(items, insertionZone("p", i + 1))
  end

  if #pinned > 0 and #unpinned > 0 then
    table.insert(items, ui.separator({}))
  end

  table.insert(items, insertionZone("u", 1))
  for i, note in ipairs(unpinned) do
    table.insert(items, notePreviewCard(note))
    table.insert(items, insertionZone("u", i + 1))
  end

  return ui.scroll({ flexGrow = 1, gap = 4, align = "stretch", justify = "start" }, items)
end

-- -------------------------------------------------------------------------
-- Edit view — coloured card (fill) + footer outside the card.
-- -------------------------------------------------------------------------
local function editView(note)
  local hex = colorHex(note.color)
  local fontSize = noctalia.getConfig("font_size") or 13

  local card = ui.column({
    flexGrow = 1, fill = hex, radius = 8, padding = 10, gap = 6,
    align    = "stretch",
  }, {
    colorPicker(note),
    ui.separator({}),
    ui.input({
      key           = "inp-" .. note.id .. "-" .. tostring(editKey),
      value         = note.content,
      placeholder   = noctalia.tr("panel.placeholder"),
      multiline     = true,
      flexGrow      = 1,
      fontSize      = fontSize,
      -- On a multiline input Qt fires the submit signal for Ctrl+Enter;
      -- plain Enter keeps inserting newlines. The handler still gates on
      -- the save_shortcut setting so the user can disable it.
      submitOnEnter = true,
      onSubmit      = "onEditSubmit",
      onChange      = function(value)
        sendCmd({ op = "update", id = note.id, content = value })
      end,
    }),
  })

  -- Footer sits OUTSIDE the coloured card so ghost buttons stay visible.
  local footer
  if pendingDeleteId == note.id then
    footer = ui.row({ gap = 6, align = "center", justify = "center" }, {
      ui.label({ text = noctalia.tr("panel.confirm-delete"), fontSize = 11, color = "on_surface_variant" }),
      ui.button({
        glyph = "check", text = noctalia.tr("panel.delete-yes"),
        variant = "destructive", controlSize = "sm",
        onClick = function()
          local id = note.id; pendingDeleteId = nil; editingId = nil
          sendCmd({ op = "remove", id = id })
        end,
      }),
      ui.button({
        glyph = "close", variant = "ghost", controlSize = "sm",
        onClick = function() pendingDeleteId = nil; render() end,
      }),
    })
  else
    local shortcutOn = noctalia.getConfig("save_shortcut") ~= false
    footer = ui.row({ align = "center", justify = "space_between" }, {
      ui.button({
        glyph = "check", text = noctalia.tr("panel.done"),
        variant = "ghost", controlSize = "sm",
        tooltip = shortcutOn and noctalia.tr("panel.done-tooltip") or noctalia.tr("panel.done"),
        onClick = function() leaveEdit() end,
      }),
      ui.button({
        glyph = "trash", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.delete"),
        onClick = function() pendingDeleteId = note.id; render() end,
      }),
    })
  end

  return ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, { card, footer })
end

-- -------------------------------------------------------------------------
-- Render
-- -------------------------------------------------------------------------
function render()
  local editNote = editingId ~= nil and findNote(editingId) or nil
  -- If the note we were editing was deleted, fall back to list.
  if editingId ~= nil and editNote == nil then
    editingId = nil; pendingDeleteId = nil
  end
  local inEdit = editNote ~= nil

  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      inEdit
        and ui.button({
          glyph = "arrow-left", variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("panel.back"),
          onClick = function() leaveEdit() end,
        })
        or ui.glyph({ name = "note", size = 20, color = "primary" }),
      ui.label({ text = inEdit and noctalia.tr("panel.editing") or noctalia.tr("panel.title"),
                  fontSize = 14, fontWeight = "bold" }),
    }),
    ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = blurred and "eye" or "eye-off",
        variant = blurred and "outline" or "ghost",
        selected = blurred, controlSize = "sm",
        tooltip = blurred and noctalia.tr("panel.unblur") or noctalia.tr("panel.blur"),
        onClick = function() sendCmd({ op = "toggle_blur" }) end,
      }),
      not inEdit and ui.button({
        glyph = "plus", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.add"),
        onClick = function()
          -- If there is already an empty note, navigate to it instead of
          -- creating another one (prevents unlimited empty-note pile-up).
          for _, n in ipairs(notes) do
            if noctalia.string.trim(n.content or "") == "" then
              editingId = n.id; pendingDeleteId = nil; editKey += 1; render()
              return
            end
          end
          sendCmd({ op = "add" })
        end,
      }) or ui.row({}, {}),
      ui.button({
        glyph = "close", variant = "ghost", controlSize = "sm",
        onClick = function() panel.close() end,
      }),
    }),
  })

  local body = inEdit and editView(editNote) or listView()

  panel.render(ui.column({
    flexGrow = 1, gap = 8, padding = 8, justify = "start", align = "stretch",
  }, { header, ui.separator({}), body }))
end

-- -------------------------------------------------------------------------
-- State watches
-- -------------------------------------------------------------------------
noctalia.state.watch("sticky_notes.notes", function(value)
  local newNotes = type(value) == "table" and value or {}
  -- Jump to a newly added note (not on initial load). Storage no longer
  -- appends new notes at the tail (addNote inserts at the top of the
  -- unpinned group), so find the one whose id wasn't in the old list.
  if prevNoteCount >= 0 and #newNotes > prevNoteCount then
    local prevIds = {}
    for _, n in ipairs(notes) do prevIds[n.id] = true end
    for _, n in ipairs(newNotes) do
      if not prevIds[n.id] then
        editingId = n.id; pendingDeleteId = nil; editKey += 1
        break
      end
    end
  end
  prevNoteCount = #newNotes
  notes = newNotes
  render()
end)

-- Only exit the edit view on a false → true transition of blurred, not on
-- every re-publish. The service re-publishes both `notes` AND `blurred` on
-- every keystroke (via updateNote → publish), so an unconditional
-- `editingId = nil` would kick the user out of the editor after every
-- character while blur is on.
local prevBlurred = false
noctalia.state.watch("sticky_notes.blurred", function(value)
  local newBlurred = value == true
  if newBlurred and not prevBlurred then editingId = nil end
  prevBlurred = newBlurred
  blurred = newBlurred
  render()
end)

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------
function onOpen(_context)
  editingId = nil; pendingDeleteId = nil
  local autoBlur = noctalia.getConfig("auto_blur")
  if autoBlur == true and not blurred then
    sendCmd({ op = "toggle_blur" })
  end
  render()
end
