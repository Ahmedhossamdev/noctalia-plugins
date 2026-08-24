import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

// Timezone Hub - Panel
//
// Two views toggled in place:
//  - Timeline: device timezone pinned as the first row, then every comparison
//    city, each rendered as a horizontally scrollable strip of hour cells
//    (shared Flickable so every row scrolls together) with a "now" line and
//    day-boundary / work-hour highlighting.
//  - Picker: the shared TimezonePicker, used both to add a comparison city
//    and to change the device timezone.
Item {
  id: root

  property var pluginApi: null
  readonly property var geometryPlaceholder: panelContainer
  readonly property bool allowAttach: true

  readonly property var main: pluginApi?.mainInstance ?? null

  // Force re-evaluation of everything below whenever Main.qml bumps its
  // revision counter (new offsets, settings change, clock tick).
  readonly property int rev: root.main ? root.main.revision : 0
  readonly property var rows: { root.rev; return root.main ? root.main.computeRows() : []; }

  property bool showPicker: false
  property string pickerMode: "add"

  function openPicker(mode) {
    root.pickerMode = mode;
    root.showPicker = true;
  }

  // ---------------------------------------------------------------------
  // Display settings
  // ---------------------------------------------------------------------
  readonly property var settings: pluginApi?.pluginSettings ?? ({})
  readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings ?? ({})
  readonly property int hoursBefore: settings.hoursBefore ?? defaults.hoursBefore ?? 3
  readonly property int hoursAfter: settings.hoursAfter ?? defaults.hoursAfter ?? 21
  readonly property bool use24h: (settings.timeFormat ?? defaults.timeFormat ?? "24h") === "24h"
  readonly property int workStart: settings.workHourStart ?? defaults.workHourStart ?? 9
  readonly property int workEnd: settings.workHourEnd ?? defaults.workHourEnd ?? 17
  readonly property bool highlightWork: settings.highlightWorkHours ?? defaults.highlightWorkHours ?? true
  readonly property real sizePercent: settings.panelSize ?? defaults.panelSize ?? 100
  readonly property real sizeScale: root.sizePercent / 100

  readonly property var weekdayNames: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

  readonly property real scale: Style.uiScaleRatio * root.sizeScale
  readonly property real cellWidth: 36 * root.scale
  readonly property real rowHeight: 80 * root.scale
  readonly property real labelColWidth: 144 * root.scale
  readonly property int colCount: root.hoursBefore + root.hoursAfter + 1

  readonly property var columnIndexes: {
    var a = [];
    for (var i = -root.hoursBefore; i <= root.hoursAfter; i++) a.push(i);
    return a;
  }

  readonly property real flooredHourMs: root.main ? Math.floor(root.main.nowMs / 3600000) * 3600000 : 0
  readonly property real nowFraction: root.main ? (root.main.nowMs - root.flooredHourMs) / 3600000 : 0

  readonly property real deviceOffsetMinutes: root.rows.length > 0 ? root.rows[0].offsetMinutes : null

  property real contentPreferredWidth: 620 * root.scale
  property real contentPreferredHeight: {
    if (root.showPicker) return 480 * root.scale;
    return Math.min(720, 190 + root.rows.length * (root.rowHeight / root.scale)) * root.scale;
  }

  // ---------------------------------------------------------------------
  // Time helpers - all pure arithmetic, no shell calls. Given an offset in
  // minutes from UTC we shift the epoch and read the UTC getters back off
  // it; that's the standard trick to read "wall clock in zone X" without a
  // real timezone-aware Date implementation.
  // ---------------------------------------------------------------------
  function nowLocal(offsetMinutes) {
    if (offsetMinutes === null || offsetMinutes === undefined || !root.main) {
      return { hour: 0, minute: 0, day: 0, weekday: 0 };
    }
    var d = new Date(root.main.nowMs + offsetMinutes * 60000);
    return { hour: d.getUTCHours(), minute: d.getUTCMinutes(), day: d.getUTCDate(), weekday: d.getUTCDay() };
  }

  function cellInfo(offsetMinutes, colIndex) {
    if (offsetMinutes === null || offsetMinutes === undefined) {
      return { hour: 0, day: 0, weekday: 0 };
    }
    var colUtcMs = root.flooredHourMs + colIndex * 3600000;
    var d = new Date(colUtcMs + offsetMinutes * 60000);
    return { hour: d.getUTCHours(), day: d.getUTCDate(), weekday: d.getUTCDay() };
  }

  function cellLabel(offsetMinutes, colIndex) {
    var info = root.cellInfo(offsetMinutes, colIndex);
    if (offsetMinutes === null || offsetMinutes === undefined) return "…";
    if (info.hour === 0) return root.weekdayNames[info.weekday] + "\n" + info.day;
    if (root.use24h) return "" + info.hour;
    var h12 = info.hour % 12;
    if (h12 === 0) h12 = 12;
    return "" + h12;
  }

  function cellIsWork(offsetMinutes, colIndex) {
    var info = root.cellInfo(offsetMinutes, colIndex);
    return info.hour >= root.workStart && info.hour < root.workEnd;
  }

  function formatHM(hour, minute) {
    var mm = minute < 10 ? "0" + minute : "" + minute;
    if (root.use24h) {
      var hh = hour < 10 ? "0" + hour : "" + hour;
      return hh + ":" + mm;
    }
    var h12 = hour % 12;
    if (h12 === 0) h12 = 12;
    return h12 + ":" + mm + (hour < 12 ? " AM" : " PM");
  }

  function diffLabel(offsetMinutes) {
    if (offsetMinutes === null || offsetMinutes === undefined || root.deviceOffsetMinutes === null) return "";
    var diff = (offsetMinutes - root.deviceOffsetMinutes) / 60;
    if (diff === 0) return pluginApi?.tr("row.same-time") || "same time";
    var rounded = Math.round(diff * 2) / 2;
    return (rounded > 0 ? "+" : "") + rounded + "h";
  }

  anchors.fill: parent

  Rectangle {
    id: panelContainer
    anchors.fill: parent
    color: Color.mSurface
    radius: Style.radiusL
    border.color: Color.mOutline
    border.width: 1

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginM

      // ----------------------------------------------------------------
      // Timeline view
      // ----------------------------------------------------------------
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.marginM
        visible: !root.showPicker

        NBox {
          Layout.fillWidth: true
          implicitHeight: headerRow.implicitHeight + Style.marginM * 2

          RowLayout {
            id: headerRow
            anchors.fill: parent
            anchors.margins: Style.marginM
            spacing: Style.marginM

            NIcon {
              icon: "world"
              pointSize: Style.fontSizeXXL
              color: Color.mPrimary
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0

              NText {
                text: pluginApi?.tr("panel.title") || "Timezone Hub"
                pointSize: Style.fontSizeL
                font.weight: Font.Medium
                color: Color.mOnSurface
              }

              NText {
                text: root.main?.deviceTz
                      ? ((pluginApi?.tr("panel.subtitle") || "Device timezone:") + " " + root.main.deviceTz)
                      : (pluginApi?.tr("panel.detecting") || "Detecting device timezone…")
                pointSize: Style.fontSizeXS
                color: Color.mOnSurfaceVariant
              }
            }

            RowLayout {
              spacing: Style.marginXS

              NIconButton {
                icon: "pencil"
                baseSize: Style.baseWidgetSize * 0.85
                tooltipText: pluginApi?.tr("row.change-device") || "Change device timezone"
                enabled: !(root.main?.changingDeviceTz ?? false)
                onClicked: root.openPicker("device")
              }

              NIconButton {
                icon: "plus"
                baseSize: Style.baseWidgetSize * 0.85
                tooltipText: pluginApi?.tr("panel.add") || "Add a timezone"
                enabled: (root.rows.length - 1) < 6
                onClicked: root.openPicker("add")
              }
            }
          }
        }

        // ------------------------------------------------------------
        // Timeline body: fixed label column + shared horizontal Flickable
        // ------------------------------------------------------------
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: false
          Layout.preferredHeight: rowsColumn.height
          Layout.alignment: Qt.AlignTop
          spacing: Style.marginS

          ColumnLayout {
            id: labelCol
            Layout.preferredWidth: root.labelColWidth
            Layout.fillHeight: false
            Layout.alignment: Qt.AlignTop
            spacing: 0

            Repeater {
              model: root.rows

              delegate: Item {
                id: labelDelegate
                required property var modelData
                required property int index

                Layout.preferredWidth: root.labelColWidth
                Layout.preferredHeight: root.rowHeight
                clip: true

                readonly property var nl: root.nowLocal(modelData.offsetMinutes)

                Rectangle {
                  anchors.fill: parent
                  color: labelDelegate.index % 2 === 1 ? Qt.alpha(Color.mOnSurface, 0.03) : "transparent"
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: 1
                  color: Color.mOutline
                  opacity: 0.4
                }

                ColumnLayout {
                  anchors.fill: parent
                  anchors.topMargin: Style.marginXS
                  anchors.bottomMargin: Style.marginXS
                  anchors.leftMargin: Style.marginXS
                  anchors.rightMargin: 2
                  spacing: 2

                  NText {
                    text: labelDelegate.modelData.label
                    font.weight: Font.Medium
                    pointSize: Style.fontSizeS
                    color: Color.mOnSurface
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }

                  NText {
                    text: (labelDelegate.modelData.abbrev ? labelDelegate.modelData.abbrev + " · " : "")
                          + root.weekdayNames[labelDelegate.nl.weekday] + " " + labelDelegate.nl.day
                          + (labelDelegate.modelData.isDevice ? "" : " · " + root.diffLabel(labelDelegate.modelData.offsetMinutes))
                    pointSize: Style.fontSizeXS
                    color: Color.mOnSurfaceVariant
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.marginXS

                    NText {
                      Layout.alignment: Qt.AlignVCenter
                      text: root.formatHM(labelDelegate.nl.hour, labelDelegate.nl.minute)
                      pointSize: Style.fontSizeM
                      font.weight: Font.Bold
                      color: labelDelegate.modelData.isDevice ? Color.mPrimary : Color.mOnSurface
                    }

                    Item { Layout.fillWidth: true }

                    NIconButton {
                      Layout.alignment: Qt.AlignVCenter
                      visible: !labelDelegate.modelData.isDevice
                      icon: "pin-filled"
                      baseSize: Style.baseWidgetSize * 0.55
                      tooltipText: pluginApi?.tr("row.set-device") || "Set as device timezone"
                      onClicked: root.main?.setDeviceTimezone(labelDelegate.modelData.tz)
                    }

                    NIconButton {
                      Layout.alignment: Qt.AlignVCenter
                      visible: !labelDelegate.modelData.isDevice
                      icon: "x"
                      baseSize: Style.baseWidgetSize * 0.55
                      tooltipText: pluginApi?.tr("row.remove") || "Remove"
                      onClicked: root.main?.removeComparisonTimezone(labelDelegate.modelData.index)
                    }
                  }
                }
              }
            }
          }

          Flickable {
            id: gridFlick
            Layout.fillWidth: true
            Layout.fillHeight: false
            Layout.preferredHeight: rowsColumn.height
            clip: true
            interactive: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: root.colCount * root.cellWidth
            contentHeight: rowsColumn.height

            Component.onCompleted: {
              gridFlick.contentX = Math.max(0, (root.hoursBefore - 1) * root.cellWidth);
            }

            ColumnLayout {
              id: rowsColumn
              spacing: 0

              Repeater {
                model: root.rows

                delegate: Item {
                  id: gridRowItem
                  required property var modelData
                  required property int index

                  Layout.preferredWidth: root.colCount * root.cellWidth
                  Layout.preferredHeight: root.rowHeight
                  clip: true

                  Rectangle {
                    anchors.fill: parent
                    color: gridRowItem.index % 2 === 1 ? Qt.alpha(Color.mOnSurface, 0.03) : "transparent"
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: Color.mOutline
                    opacity: 0.4
                  }

                  Row {
                    anchors.fill: parent

                    Repeater {
                      model: root.columnIndexes

                      delegate: Rectangle {
                        id: cell
                        required property int modelData
                        width: root.cellWidth
                        height: root.rowHeight
                        color: cell.modelData === 0
                               ? Qt.alpha(Color.mPrimary, 0.18)
                               : (root.highlightWork && root.cellIsWork(gridRowItem.modelData.offsetMinutes, cell.modelData)
                                  ? Qt.alpha(Color.mOnSurface, 0.05)
                                  : "transparent")

                        NText {
                          anchors.centerIn: parent
                          horizontalAlignment: Text.AlignHCenter
                          text: root.cellLabel(gridRowItem.modelData.offsetMinutes, cell.modelData)
                          pointSize: cell.modelData === 0 ? Style.fontSizeS : Style.fontSizeXS
                          font.weight: cell.modelData === 0 ? Font.Bold : Font.Normal
                          color: cell.modelData === 0 ? Color.mPrimary : Color.mOnSurfaceVariant
                        }
                      }
                    }
                  }
                }
              }
            }

            // "Now" indicator line, shared across every row.
            Rectangle {
              width: 2
              color: Color.mPrimary
              y: 0
              height: rowsColumn.height
              x: root.hoursBefore * root.cellWidth + root.nowFraction * root.cellWidth
              opacity: 0.8
            }
          }
        }

        NText {
          Layout.fillWidth: true
          text: pluginApi?.tr("panel.legend") || "Tap the pin icon to make a city your device timezone. Highlighted cells are business hours; the line marks now."
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
          wrapMode: Text.WordWrap
          opacity: 0.8
        }
      }

      // ----------------------------------------------------------------
      // Picker view
      // ----------------------------------------------------------------
      TimezonePicker {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.showPicker
        pluginApi: root.pluginApi
        main: root.main
        mode: root.pickerMode

        onCancelled: root.showPicker = false

        onPicked: (tz, label) => {
          if (root.pickerMode === "device") {
            root.main?.setDeviceTimezone(tz);
          } else {
            root.main?.addComparisonTimezone(tz, label);
          }
          root.showPicker = false;
        }
      }
    }
  }
}
