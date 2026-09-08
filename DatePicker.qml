import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kalender-Popup im Panel-Stil: Trigger-Button zeigt das gewählte Datum,
// Klick öffnet einen zentrierten Monatskalender (Qt MonthGrid).
Item {
  id: root

  property var selectedDate: new Date()
  signal picked(var d)

  readonly property bool popupOpen: popup.opened

  property int viewMonth: selectedDate.getMonth()
  property int viewYear: selectedDate.getFullYear()

  // Feste Trigger-Breite, damit Von-/Bis-Zeile als Spalten fluchten.
  property real triggerWidth: Style.space(104)

  implicitWidth: triggerWidth
  implicitHeight: trigger.implicitHeight

  function monthLabel() {
    return Qt.locale("de_DE").monthName(viewMonth, Locale.LongFormat) + " " + viewYear
  }

  function shiftMonth(delta) {
    var m = viewMonth + delta
    viewYear += Math.floor(m / 12)
    viewMonth = ((m % 12) + 12) % 12
  }

  Button {
    id: trigger
    width: root.triggerWidth
    bordered: true
    text: Model.fmtDayDate(root.selectedDate)
    onClicked: {
      root.viewMonth = root.selectedDate.getMonth()
      root.viewYear = root.selectedDate.getFullYear()
      popup.open()
    }
  }

  Popup {
    id: popup
    x: 0
    y: trigger.height + Style.spacing.xxs
    padding: Style.space(10)

    background: Rectangle {
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: 1
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Row {
        width: parent.width
        height: Style.spacing.controlHeight

        Button {
          width: Style.space(28)
          text: "‹"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.shiftMonth(-1)
        }
        Text {
          width: parent.width - Style.space(56)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.monthLabel()
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Button {
          width: Style.space(28)
          text: "›"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.shiftMonth(1)
        }
      }

      DayOfWeekRow {
        locale: Qt.locale("de_DE")
        width: grid.width
        delegate: Text {
          required property var model
          text: model.shortName
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      MonthGrid {
        id: grid
        month: root.viewMonth
        year: root.viewYear
        locale: Qt.locale("de_DE")
        width: Style.space(238)
        spacing: 0

        // MonthGrid nimmt beim Drücken den exklusiven Maus-Grab — ein
        // TapHandler in den Tag-Zellen wird dadurch abgebrochen und feuert
        // nie. Die Auswahl muss über das control-eigene Signal laufen.
        onClicked: function(date) {
          root.picked(date)
          popup.close()
        }

        delegate: Item {
          required property var model
          readonly property bool isSelected: Model.sameDay(model.date, root.selectedDate)
          readonly property bool inMonth: model.month === grid.month

          width: Style.space(34)
          height: Style.space(30)

          Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Style.cornerRadius
            color: parent.isSelected ? Style.selectionFillFor(Color.popups.text, Color.accent)
              : dayHover.hovered ? Style.hoverFillFor(Color.popups.text, Color.accent)
              : "transparent"
            border.color: model.today ? Color.accent : "transparent"
            border.width: model.today ? 1 : 0
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: model.day
            color: parent.inMonth ? Color.popups.text : Qt.darker(Color.popups.text, 2.0)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          HoverHandler {
            id: dayHover
            cursorShape: Qt.PointingHandCursor
          }
        }
      }
    }
  }
}
