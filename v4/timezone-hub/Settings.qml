import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

// Timezone Hub - Settings
ColumnLayout {
  id: root
  spacing: Style.marginM

  property var pluginApi: null
  readonly property var main: pluginApi?.mainInstance ?? null
  readonly property int rev: root.main ? root.main.revision : 0

  property var cfg: pluginApi?.pluginSettings ?? ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings ?? ({})

  readonly property var comparisonList: { root.rev; return root.cfg.timezones ?? root.defaults.timezones ?? []; }

  property bool showPicker: false
  property string pickerMode: "add"

  function openPicker(mode) {
    root.pickerMode = mode;
    root.showPicker = true;
  }

  // Every field on this page already saves itself immediately on change.
  // This exists purely so the shell's settings popup recognizes an "Apply"
  // action is available - it calls this (then shows its own confirmation
  // toast) when you click Apply. "Close" is what dismisses the popup;
  // "Apply" intentionally does not, so you can keep tweaking things.
  function saveSettings() {}

  // ---- Header ----
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginM
    visible: !root.showPicker

    NIcon {
      icon: "world"
      pointSize: Style.fontSizeXL
      color: Color.mPrimary
    }

    NText {
      text: pluginApi?.tr("panel.title") || "Timezone Hub"
      pointSize: Style.fontSizeL
      font.weight: Font.Medium
      color: Color.mOnSurface
    }

    Item { Layout.fillWidth: true }
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginM
    visible: !root.showPicker

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Color.mOutline }

    // ---- Device timezone ----
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        NText {
          text: pluginApi?.tr("settings.device-timezone") || "Device timezone"
          pointSize: Style.fontSizeM
          font.weight: Font.Medium
          color: Color.mOnSurface
        }

        NText {
          text: root.main?.deviceTz || (pluginApi?.tr("panel.detecting") || "Detecting…")
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }
      }

      NButton {
        text: pluginApi?.tr("row.change-device") || "Change"
        icon: "pencil"
        enabled: !(root.main?.changingDeviceTz ?? false)
        onClicked: root.openPicker("device")
      }
    }

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Color.mOutline }

    // ---- Bar widget ----
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.bar-shows") || "Bar widget shows"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NComboBox {
        model: {
          root.rev;
          var m = [{ key: "", name: pluginApi?.tr("device.label") || "This Device" }];
          for (var i = 0; i < root.comparisonList.length; i++) {
            var e = root.comparisonList[i];
            m.push({ key: e.tz, name: e.label || e.tz });
          }
          return m;
        }
        currentKey: root.cfg.barWidgetTz ?? root.defaults.barWidgetTz ?? ""
        onSelected: key => {
          if (pluginApi) {
            pluginApi.pluginSettings.barWidgetTz = key;
            pluginApi.saveSettings();
            root.main?.refreshOffsets();
            root.main?.bump();
          }
        }
      }
    }

    NText {
      Layout.fillWidth: true
      visible: root.comparisonList.length === 0
      text: pluginApi?.tr("settings.bar-shows-hint") || "Add a comparison city below to pick it here."
      pointSize: Style.fontSizeXS
      color: Color.mOnSurfaceVariant
      wrapMode: Text.WordWrap
    }

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Color.mOutline }

    // ---- Display options ----
    NText {
      text: pluginApi?.tr("settings.display") || "Display"
      pointSize: Style.fontSizeM
      font.weight: Font.Medium
      color: Color.mOnSurface
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.time-format") || "Time format"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NComboBox {
        model: [
          { "key": "24h", "name": pluginApi?.tr("settings.format-24h") || "24-hour" },
          { "key": "12h", "name": pluginApi?.tr("settings.format-12h") || "12-hour" }
        ]
        currentKey: root.cfg.timeFormat ?? root.defaults.timeFormat ?? "24h"
        onSelected: key => {
          if (pluginApi) {
            pluginApi.pluginSettings.timeFormat = key;
            pluginApi.saveSettings();
          }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.hours-before") || "Hours shown before now"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NSpinBox {
        from: 0
        to: 12
        value: root.cfg.hoursBefore ?? root.defaults.hoursBefore ?? 3
        onValueChanged: {
          if (pluginApi) {
            pluginApi.pluginSettings.hoursBefore = value;
            pluginApi.saveSettings();
          }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.hours-after") || "Hours shown after now"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NSpinBox {
        from: 6
        to: 47
        value: root.cfg.hoursAfter ?? root.defaults.hoursAfter ?? 21
        onValueChanged: {
          if (pluginApi) {
            pluginApi.pluginSettings.hoursAfter = value;
            pluginApi.saveSettings();
          }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.highlight-work-hours") || "Highlight work hours"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NToggle {
        checked: root.cfg.highlightWorkHours ?? root.defaults.highlightWorkHours ?? true
        onToggled: checked => {
          if (pluginApi) {
            pluginApi.pluginSettings.highlightWorkHours = checked;
            pluginApi.saveSettings();
          }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM
      visible: root.cfg.highlightWorkHours ?? root.defaults.highlightWorkHours ?? true

      NText {
        text: pluginApi?.tr("settings.work-hours-range") || "Work hours"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NSpinBox {
        from: 0
        to: 23
        value: root.cfg.workHourStart ?? root.defaults.workHourStart ?? 9
        onValueChanged: {
          if (pluginApi) {
            pluginApi.pluginSettings.workHourStart = value;
            pluginApi.saveSettings();
          }
        }
      }

      NText { text: "–"; color: Color.mOnSurfaceVariant }

      NSpinBox {
        from: 1
        to: 24
        value: root.cfg.workHourEnd ?? root.defaults.workHourEnd ?? 17
        onValueChanged: {
          if (pluginApi) {
            pluginApi.pluginSettings.workHourEnd = value;
            pluginApi.saveSettings();
          }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NText {
        text: pluginApi?.tr("settings.panel-size") || "Panel size"
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        Layout.fillWidth: true
      }

      NSpinBox {
        from: 70
        to: 140
        stepSize: 10
        suffix: " %"
        value: root.cfg.panelSize ?? root.defaults.panelSize ?? 100
        onValueChanged: {
          if (pluginApi) {
            pluginApi.pluginSettings.panelSize = value;
            pluginApi.saveSettings();
          }
        }
      }
    }

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Color.mOutline }

    // ---- Comparison timezones ----
    RowLayout {
      Layout.fillWidth: true

      NText {
        text: pluginApi?.tr("settings.comparison-timezones") || "Comparison timezones"
        pointSize: Style.fontSizeM
        font.weight: Font.Medium
        color: Color.mOnSurface
      }

      Item { Layout.fillWidth: true }

      NButton {
        text: pluginApi?.tr("panel.add") || "Add"
        icon: "plus"
        enabled: root.comparisonList.length < 6
        onClicked: root.openPicker("add")
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      Repeater {
        model: root.comparisonList

        delegate: Rectangle {
          required property int index
          required property var modelData

          Layout.fillWidth: true
          Layout.preferredHeight: 44 * Style.uiScaleRatio
          color: Color.mSurfaceVariant
          radius: Style.radiusM
          border.color: Color.mOutline
          border.width: 1

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.marginS
            spacing: Style.marginS

            NText {
              text: modelData.label + "  ·  " + modelData.tz
              pointSize: Style.fontSizeS
              color: Color.mOnSurface
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            NIconButton {
              icon: "trash"
              baseSize: Style.baseWidgetSize * 0.7
              onClicked: root.main?.removeComparisonTimezone(index)
            }
          }
        }
      }

      NText {
        Layout.fillWidth: true
        visible: root.comparisonList.length === 0
        text: pluginApi?.tr("settings.no-comparisons") || "No comparison timezones yet — add one above."
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
      }
    }
  }

  // ---- Picker view ----
  TimezonePicker {
    Layout.fillWidth: true
    Layout.preferredHeight: 360 * Style.uiScaleRatio
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

  Item { Layout.fillHeight: true }
}
