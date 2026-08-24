import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

// Timezone Hub - Bar Widget
// Shows the device's local time (+ zone abbreviation). Click opens the panel.
Item {
  id: root

  property var pluginApi: null

  // Required properties for bar widgets
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property string screenName: screen ? screen.name : ""
  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isVertical: barPosition === "left" || barPosition === "right"
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)

  readonly property var main: pluginApi?.mainInstance ?? null

  property string timeText: "--:--"
  property string abbrevText: ""
  property string cityLabel: ""

  // Empty = mirror the device's own clock. Otherwise, any IANA zone the
  // Settings page lets you pick from your comparison list.
  readonly property string barTz: pluginApi?.pluginSettings?.barWidgetTz || ""

  function updateClock() {
    if (!root.barTz) {
      var d = new Date();
      var hh = d.getHours();
      var mm = d.getMinutes();
      root.timeText = (hh < 10 ? "0" + hh : "" + hh) + ":" + (mm < 10 ? "0" + mm : "" + mm);
      var off = (main && main.deviceTz) ? main.offsets[main.deviceTz] : null;
      root.abbrevText = off ? off.abbrev : "";
      root.cityLabel = "";
      return;
    }

    if (!main) return;
    var zoneOff = main.offsets[root.barTz];
    if (!zoneOff) {
      root.timeText = "--:--";
      root.abbrevText = "";
      root.cityLabel = main.labelForTz(root.barTz);
      return;
    }
    var zd = new Date(main.nowMs + zoneOff.offsetMinutes * 60000);
    var zh = zd.getUTCHours();
    var zm = zd.getUTCMinutes();
    root.timeText = (zh < 10 ? "0" + zh : "" + zh) + ":" + (zm < 10 ? "0" + zm : "" + zm);
    root.abbrevText = zoneOff.abbrev || "";
    root.cityLabel = main.labelForTz(root.barTz);
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.updateClock()
  }

  Connections {
    target: root.main
    function onRevisionChanged() { root.updateClock(); }
  }

  readonly property real visualContentWidth: {
    if (isVertical) return root.capsuleHeight;
    var iconWidth = Style.toOdd(root.capsuleHeight * 0.6);
    var textWidth = timeLabel ? timeLabel.implicitWidth : 60;
    return iconWidth + textWidth + Style.marginM * 2 + Style.marginXS;
  }

  readonly property real contentWidth: isVertical ? root.capsuleHeight : visualContentWidth
  readonly property real contentHeight: root.capsuleHeight

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  Rectangle {
    id: visualCapsule
    x: Style.pixelAlignCenter(parent.width, width)
    y: Style.pixelAlignCenter(parent.height, height)
    width: root.contentWidth
    height: root.contentHeight
    radius: Style.radiusM
    color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    border.color: Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.marginS
      anchors.rightMargin: Style.marginS
      spacing: Style.marginXS
      visible: !isVertical

      NIcon {
        icon: "world"
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        pointSize: Style.toOdd(Style.capsuleHeight * 0.5)
        Layout.alignment: Qt.AlignVCenter
      }

      NText {
        id: timeLabel
        text: root.abbrevText ? (root.timeText + " " + root.abbrevText) : root.timeText
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        pointSize: root.barFontSize
        font.weight: Font.Medium
        applyUiScale: false
        Layout.alignment: Qt.AlignVCenter
      }
    }

    ColumnLayout {
      anchors.centerIn: parent
      visible: isVertical
      spacing: 2

      NIcon {
        icon: "world"
        pointSize: Style.toOdd(root.capsuleHeight * 0.45)
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        Layout.alignment: Qt.AlignHCenter
      }

      NText {
        text: root.timeText
        pointSize: root.barFontSize * 0.65
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        applyUiScale: false
        Layout.alignment: Qt.AlignHCenter
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton

    onClicked: {
      if (pluginApi) pluginApi.togglePanel(root.screen, root);
    }

    onEntered: {
      var text = root.cityLabel
                 ? root.cityLabel + " — " + (pluginApi?.tr("bar.tooltip-click") || "click to compare timezones")
                 : (pluginApi?.tr("bar.tooltip") || "Timezone Hub — click to compare timezones");
      TooltipService.show(root, text, BarService.getTooltipDirection());
    }

    onExited: TooltipService.hide();
  }

  Component.onCompleted: root.updateClock();
}
