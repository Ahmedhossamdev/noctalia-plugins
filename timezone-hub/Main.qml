import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

// Timezone Hub - background service
//
// Owns all shell/process work and the derived data model so BarWidget.qml,
// Panel.qml and Settings.qml can stay dumb views. Device timezone detection,
// timezone-database listing and per-zone UTC offsets all go through the
// `date`/`timedatectl` CLIs via Quickshell.Io.Process, following the same
// pattern as the official world-clock plugin - QML's JS engine here does not
// reliably resolve arbitrary IANA zones on its own.
Singleton {
  id: root

  property var pluginApi: null

  // ---------------------------------------------------------------------
  // Device timezone
  // ---------------------------------------------------------------------
  property string deviceTz: ""
  property bool changingDeviceTz: false

  // ---------------------------------------------------------------------
  // Timezone database (for the picker)
  // ---------------------------------------------------------------------
  property var allTimezones: []
  property bool allTimezonesLoaded: false

  readonly property var fallbackTimezones: [
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
    "Pacific/Auckland", "Pacific/Honolulu", "UTC"
  ]

  // ---------------------------------------------------------------------
  // Offsets cache: { "Europe/Zurich": { offsetMinutes: 120, abbrev: "CEST" } }
  // ---------------------------------------------------------------------
  property var offsets: ({})

  // ---------------------------------------------------------------------
  // Clock + change notifications
  // ---------------------------------------------------------------------
  property real nowMs: Date.now()
  property int revision: 0

  function bump() {
    root.revision = root.revision + 1;
  }

  readonly property var settings: pluginApi?.pluginSettings ?? ({})
  readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings ?? ({})
  readonly property var comparisonList: settings.timezones ?? defaults.timezones ?? []

  // Row model consumed by the UI: device row first, then user comparisons.
  function computeRows() {
    var list = [];
    var devOff = root.offsets[root.deviceTz];
    list.push({
      key: "__device__",
      label: pluginApi?.tr("device.label") || "This Device",
      tz: root.deviceTz,
      isDevice: true,
      index: -1,
      offsetMinutes: devOff ? devOff.offsetMinutes : -(new Date()).getTimezoneOffset(),
      abbrev: devOff ? devOff.abbrev : ""
    });

    for (var i = 0; i < root.comparisonList.length; i++) {
      var entry = root.comparisonList[i];
      var off = root.offsets[entry.tz];
      list.push({
        key: entry.tz + "#" + i,
        label: entry.label || entry.tz,
        tz: entry.tz,
        isDevice: false,
        index: i,
        offsetMinutes: off ? off.offsetMinutes : null,
        abbrev: off ? off.abbrev : ""
      });
    }
    return list;
  }

  function zonesToRefresh() {
    var set = ({});
    if (root.deviceTz) set[root.deviceTz] = true;
    for (var i = 0; i < root.comparisonList.length; i++) {
      if (root.comparisonList[i].tz) set[root.comparisonList[i].tz] = true;
    }
    return Object.keys(set);
  }

  // ---------------------------------------------------------------------
  // Detect the device timezone
  // ---------------------------------------------------------------------
  function refreshDeviceTimezone() {
    detectTzProcess.running = true;
  }

  Process {
    id: detectTzProcess
    command: ["sh", "-c", "timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime | sed 's#.*/zoneinfo/##'"]
    stdout: StdioCollector {}
    onExited: exitCode => {
      var tz = detectTzProcess.stdout.text.trim();
      if (tz) {
        root.deviceTz = tz;
        root.refreshOffsets();
      } else {
        Logger.w("TimezoneHub", "Could not detect the device timezone");
      }
    }
  }

  // ---------------------------------------------------------------------
  // Full IANA timezone list, loaded lazily when the picker is first opened
  // ---------------------------------------------------------------------
  function ensureAllTimezonesLoaded() {
    if (root.allTimezonesLoaded || listTzProcess.running) return;
    listTzProcess.running = true;
  }

  Process {
    id: listTzProcess
    command: ["timedatectl", "list-timezones"]
    stdout: StdioCollector {}
    onExited: exitCode => {
      var text = listTzProcess.stdout.text || "";
      var list = text.split("\n").map(s => s.trim()).filter(s => s.length > 0);
      root.allTimezones = (exitCode === 0 && list.length > 0) ? list : root.fallbackTimezones;
      root.allTimezonesLoaded = true;
    }
  }

  // ---------------------------------------------------------------------
  // Batched offset lookup: one process call handles every configured zone.
  // Zone names are passed as argv, never interpolated into the script
  // string, so this stays safe even though we build the command dynamically.
  // ---------------------------------------------------------------------
  Process {
    id: offsetsProcess
    property var zoneOrder: []
    stdout: StdioCollector {}
    onExited: exitCode => {
      if (exitCode !== 0) return;
      var lines = offsetsProcess.stdout.text.split("\n");
      var next = ({});
      for (var k in root.offsets) next[k] = root.offsets[k];

      for (var i = 0; i < offsetsProcess.zoneOrder.length && i < lines.length; i++) {
        var parts = lines[i].split("|");
        if (parts.length < 2) continue;
        var offStr = parts[0].trim();
        var abbrev = parts[1].trim();
        if (offStr.length < 5) continue;
        var sign = offStr.charAt(0) === "-" ? -1 : 1;
        var hh = parseInt(offStr.substring(1, 3), 10) || 0;
        var mm = parseInt(offStr.substring(3, 5), 10) || 0;
        next[offsetsProcess.zoneOrder[i]] = { offsetMinutes: sign * (hh * 60 + mm), abbrev: abbrev };
      }
      root.offsets = next;
      root.bump();
    }
  }

  function refreshOffsets() {
    var zones = root.zonesToRefresh();
    if (zones.length === 0) return;
    if (offsetsProcess.running) return;
    offsetsProcess.zoneOrder = zones;
    var script = 'for tz in "$@"; do TZ="$tz" date +"%z|%Z"; done';
    offsetsProcess.command = ["sh", "-c", script, "_"].concat(zones);
    offsetsProcess.running = true;
  }

  // ---------------------------------------------------------------------
  // Change the device timezone (requires polkit authorization)
  // ---------------------------------------------------------------------
  function setDeviceTimezone(tz) {
    if (!tz || root.changingDeviceTz || tz === root.deviceTz) return;
    root.changingDeviceTz = true;
    setTzProcess.targetTz = tz;
    setTzProcess.command = ["pkexec", "timedatectl", "set-timezone", tz];
    setTzProcess.running = true;
  }

  Process {
    id: setTzProcess
    property string targetTz: ""
    stderr: StdioCollector {}
    onExited: exitCode => {
      root.changingDeviceTz = false;
      if (exitCode === 0) {
        root.deviceTz = setTzProcess.targetTz;
        root.pruneComparisonTimezone(setTzProcess.targetTz);
        root.refreshOffsets();
        ToastService.showNotice(
          pluginApi?.tr("toast.title") || "Timezone Hub",
          (pluginApi?.tr("toast.device-changed") || "Device timezone set to") + " " + setTzProcess.targetTz,
          "world"
        );
      } else {
        Logger.w("TimezoneHub", "set-timezone failed: " + setTzProcess.stderr.text);
        ToastService.showError(
          pluginApi?.tr("toast.title") || "Timezone Hub",
          pluginApi?.tr("toast.device-change-failed") || "Failed to change the device timezone. Authorization was denied or timedatectl is unavailable.",
          "alert-circle"
        );
      }
    }
  }

  // ---------------------------------------------------------------------
  // Comparison list mutation helpers
  // ---------------------------------------------------------------------
  function addComparisonTimezone(tz, label) {
    if (!pluginApi || !tz || tz === root.deviceTz) return;
    var list = (pluginApi.pluginSettings.timezones || []).slice();
    for (var i = 0; i < list.length; i++) {
      if (list[i].tz === tz) return;
    }
    list.push({ tz: tz, label: label || tz.split("/").pop().replace(/_/g, " ") });
    pluginApi.pluginSettings.timezones = list;
    pluginApi.saveSettings();
    root.refreshOffsets();
    root.bump();
  }

  // Drop a comparison entry that now duplicates the device timezone (called
  // right after a successful device timezone change, so promoting a city to
  // "device" doesn't leave it behind as a redundant "same time" row).
  function pruneComparisonTimezone(tz) {
    if (!pluginApi) return;
    var list = pluginApi.pluginSettings.timezones || [];
    var next = list.filter(entry => entry.tz !== tz);
    if (next.length === list.length) return;
    pluginApi.pluginSettings.timezones = next;
    pluginApi.saveSettings();
    root.bump();
  }

  function removeComparisonTimezone(index) {
    if (!pluginApi) return;
    var list = (pluginApi.pluginSettings.timezones || []).slice();
    if (index < 0 || index >= list.length) return;
    list.splice(index, 1);
    pluginApi.pluginSettings.timezones = list;
    pluginApi.saveSettings();
    root.bump();
  }

  // ---------------------------------------------------------------------
  // Timers
  // ---------------------------------------------------------------------
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now();
      root.bump();
    }
  }

  Timer {
    interval: 120000
    running: true
    repeat: true
    onTriggered: root.refreshOffsets()
  }

  Component.onCompleted: {
    Logger.i("TimezoneHub", "Main initialized");
    root.refreshDeviceTimezone();
  }
}
