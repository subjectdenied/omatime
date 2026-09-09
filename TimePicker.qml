import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Zeit-Picker: Trigger zeigt "HH:MM"; das Popup bietet ein Stundenraster
// (06–23 plus 24:00) und die Minuten im 15er-Schritt. Stunde wählen,
// Minute wählen — Minute bestätigt und schließt.
Item {
  id: root

  property string value: "" // "HH:MM" oder leer
  property string placeholder: "--:--"
  signal changed(string v)

  readonly property bool popupOpen: popup.opened

  property int selHour: -1

  // Feste Trigger-Breite, damit Von-/Bis-Zeile als Spalten fluchten.
  property real triggerWidth: Style.space(72)

  implicitWidth: triggerWidth
  implicitHeight: trigger.implicitHeight

  Button {
    id: trigger
    width: root.triggerWidth
    bordered: true
    text: root.value !== "" ? root.value : root.placeholder
    opacity: root.value !== "" ? 1 : 0.6
    onClicked: {
      var t = Model.parseTimeInput(root.value)
      root.selHour = t ? t.h : -1
      popup.open()
    }
  }

  // Nur das Signal emittieren — `value` ist vom Panel gebunden; eine
  // Selbstzuweisung würde das Binding zerstören.
  function commit(hour, minute) {
    root.changed(hour === 24 ? "24:00" : Model.pad2(hour) + ":" + Model.pad2(minute))
    popup.close()
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
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "Stunde"
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Grid {
        columns: 6
        spacing: Style.space(4)

        Repeater {
          model: 19 // 06..24

          Button {
            required property int index
            readonly property int hour: index + 6
            width: Style.space(40)
            bordered: root.selHour === hour
            selected: root.selHour === hour
            text: hour === 24 ? "24" : Model.pad2(hour)
            // Stunde übernimmt sofort als HH:00 (Popup bleibt für die
            // Minuten offen) — wer nur die Stunde klickt, verliert nichts.
            onClicked: {
              if (hour === 24) { root.commit(24, 0); return }
              root.selHour = hour
              root.changed(Model.pad2(hour) + ":00")
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Minute"
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Row {
        spacing: Style.space(4)

        Repeater {
          model: [0, 15, 30, 45]

          Button {
            required property int modelData
            width: Style.space(60)
            bordered: true
            enabled: root.selHour >= 0 && root.selHour < 24
            opacity: enabled ? 1 : 0.4
            text: ":" + Model.pad2(modelData)
            onClicked: root.commit(root.selHour, modelData)
          }
        }
      }
    }
  }
}
