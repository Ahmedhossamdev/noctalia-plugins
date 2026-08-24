import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

// Timezone Hub - shared searchable IANA timezone picker.
// Used both by Panel.qml (add a comparison city / change device zone) and
// Settings.qml, so the search + list behaviour only lives in one place.
ColumnLayout {
  id: root
  spacing: Style.marginS

  property var pluginApi: null
  property var main: null
  // "add" -> picking a comparison timezone, "device" -> changing the device timezone
  property string mode: "add"

  signal picked(string tz, string label)
  signal cancelled()

  property string query: ""

  readonly property var allZones: main?.allTimezones ?? []
  readonly property var filtered: {
    var q = root.query.trim().toLowerCase();
    var zones = root.allZones;
    var out = [];
    for (var i = 0; i < zones.length; i++) {
      var z = zones[i];
      if (q === "" || z.toLowerCase().indexOf(q) !== -1) {
        out.push(z);
        if (out.length >= 100) break;
      }
    }
    return out;
  }

  Component.onCompleted: {
    if (root.main) root.main.ensureAllTimezonesLoaded();
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginS

    NIconButton {
      icon: "arrow-left"
      baseSize: Style.baseWidgetSize * 0.8
      tooltipText: pluginApi?.tr("picker.back") || "Back"
      onClicked: root.cancelled()
    }

    NText {
      text: root.mode === "device"
            ? (pluginApi?.tr("picker.title-device") || "Set device timezone")
            : (pluginApi?.tr("picker.title-add") || "Add a timezone")
      pointSize: Style.fontSizeM
      font.weight: Font.Medium
      color: Color.mOnSurface
      Layout.fillWidth: true
      elide: Text.ElideRight
    }
  }

  NTextInput {
    id: searchField
    Layout.fillWidth: true
    label: ""
    description: ""
    inputIconName: "search"
    showClearButton: true
    placeholderText: pluginApi?.tr("picker.search-placeholder") || "Search city or region…"
    text: root.query
    onTextChanged: root.query = text
  }

  NText {
    Layout.fillWidth: true
    visible: !(root.main?.allTimezonesLoaded ?? false)
    text: pluginApi?.tr("picker.loading") || "Loading timezone database…"
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
  }

  Item {
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.minimumHeight: 220 * Style.uiScaleRatio

    ListView {
      id: listView
      anchors.fill: parent
      clip: true
      spacing: 2
      model: root.filtered

      delegate: Rectangle {
        id: rowDelegate
        required property string modelData
        width: listView.width
        height: 38 * Style.uiScaleRatio
        radius: Style.radiusS
        color: rowMouse.containsMouse ? Color.mHover : "transparent"

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.marginS
          anchors.rightMargin: Style.marginS
          spacing: Style.marginS

          NIcon {
            icon: "pin-filled"
            pointSize: Style.fontSizeS
            color: rowMouse.containsMouse ? Color.mOnHover : Color.mOnSurfaceVariant
          }

          NText {
            text: rowDelegate.modelData.replace(/_/g, " ")
            pointSize: Style.fontSizeS
            color: rowMouse.containsMouse ? Color.mOnHover : Color.mOnSurface
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            var label = rowDelegate.modelData.split("/").pop().replace(/_/g, " ");
            root.picked(rowDelegate.modelData, label);
          }
        }
      }
    }

    NText {
      anchors.centerIn: parent
      visible: (root.main?.allTimezonesLoaded ?? false) && listView.count === 0
      text: pluginApi?.tr("picker.empty") || "No matching timezones"
      pointSize: Style.fontSizeS
      color: Color.mOnSurfaceVariant
    }
  }
}
