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

  function updateClock() {
    var d = new Date();
    var hh = d.getHours();
    var mm = d.getMinutes();
    var hhStr = hh < 10 ? "0" + hh : "" + hh;
    var mmStr = mm < 10 ? "0" + mm : "" + mm;
    root.timeText = hhStr + ":" + mmStr;

    var off = (main && main.deviceTz) ? main.offsets[main.deviceTz] : null;
    root.abbrevText = off ? off.abbrev : "";
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
      TooltipService.show(root, pluginApi?.tr("bar.tooltip") || "Timezone Hub — click to compare timezones", BarService.getTooltipDirection());
    }

    onExited: TooltipService.hide();
  }

  Component.onCompleted: root.updateClock();
}
