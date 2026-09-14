import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// System monitor for the Omarchy bar: one icon, and a card with CPU, GPU,
// memory and fan readings.
//
// Nothing in this file is specific to one machine. Per-machine choices (GPU
// source, fan names, warning temperature) come from this widget's entry in
// ~/.config/omarchy/shell.json. See README.md.
Panel {
  id: root
  // Must match "id" in manifest.json.
  moduleName: "ronildobraga.sysmon"

  implicitWidth: label.implicitWidth + Style.space(17)
  implicitHeight: root.bar ? root.bar.barSize : 26

  // Never call a property `data`: that is Item's default property (its list of
  // children), and shadowing it silently stops the widget from rendering.
  property var stats: ({})

  readonly property var cpu: stats.cpu || ({})
  readonly property var gpu: stats.gpu || null
  readonly property var mem: stats.mem || ({})
  readonly property var swap: stats.swap || ({})
  readonly property bool gpuActive: gpu !== null && gpu.state === "active"

  readonly property string gpuSource: String(setting("gpu", "auto"))
  readonly property int refreshSec: Math.max(1, Number(setting("refreshIntervalSec", 3)) || 3)
  readonly property int warnTemp: Number(setting("warnTemp", 80)) || 80
  readonly property var fanConfig: {
    var fans = setting("fans", [])
    return fans && fans.length !== undefined ? fans : []
  }

  // The collector ships inside this plugin folder, wherever it is installed.
  readonly property string collector: decodeURIComponent(String(Qt.resolvedUrl("bin/sysmon-collect")).replace(/^file:\/\//, ""))

  readonly property int peakTemp: Math.max(cpu.temp || 0, gpuActive ? (gpu.temp || 0) : 0)
  readonly property bool hot: peakTemp >= warnTemp

  readonly property string heroNote: {
    var notes = []
    if (stats.fanControl === "active") notes.push("Fan curve active")
    if (gpu !== null && gpu.state === "suspended") notes.push("GPU asleep")
    return notes.join("  ·  ")
  }

  function temp(v) { return (v === undefined || v === null) ? "—" : Math.round(v) + "°C" }
  function pct(v) { return (v === undefined || v === null) ? "—" : Math.round(v) + "%" }
  function gib(v) { return (v === undefined || v === null) ? "—" : Number(v).toFixed(1) }

  function findReading(list, chip, index) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].index === index && (!chip || list[i].chip === chip)) return list[i]
    }
    return null
  }

  // Named fans (from settings) are always listed, so a stopped pump is
  // visible. Unnamed fans are listed only while spinning, as "chip · fan N",
  // which is exactly what to put in settings to name them.
  readonly property var fanRows: {
    var fans = stats.fans || []
    var pwm = stats.pwm || []
    var rows = []
    var named = {}
    for (var c = 0; c < fanConfig.length; c++) {
      var cfg = fanConfig[c] || {}
      var fan = findReading(fans, cfg.chip, Number(cfg.fan))
      var chip = cfg.chip || (fan ? fan.chip : "")
      var out = (cfg.pwm === undefined || cfg.pwm === null) ? null : findReading(pwm, chip, Number(cfg.pwm))
      if (fan) named[fan.chip + ":" + fan.index] = true
      rows.push({
        label: cfg.label || ("Fan " + (cfg.fan === undefined ? "?" : cfg.fan)),
        rpm: fan ? fan.rpm : null,
        duty: out ? out.duty : null,
        missing: !fan
      })
    }
    for (var j = 0; j < fans.length; j++) {
      var f = fans[j]
      if (f.rpm > 0 && !named[f.chip + ":" + f.index]) {
        rows.push({ label: f.label || (f.chip + " · fan " + f.index), rpm: f.rpm, duty: null, missing: false })
      }
    }
    return rows
  }

  function fanValue(row) {
    if (row.missing) return "not found"
    if (row.rpm === 0) return "stopped"
    return (row.duty === null ? "" : row.duty + "%   ") + row.rpm + " RPM"
  }

  Process {
    id: poll
    command: [root.collector, "--gpu", root.gpuSource]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try { root.stats = JSON.parse(raw) } catch (e) { }
      }
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!poll.running) poll.running = true
  }

  Item {
    id: button
    anchors.fill: parent

    Text {
      id: label
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "\u{F035B}"
      color: root.hot && root.bar ? root.bar.urgent : root.barForeground
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton && root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
        else root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // Hero: the temperatures that matter most.
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "\u{F050F}"
            color: root.hot ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "CPU " + root.temp(root.cpu.temp) + (root.gpuActive ? "   ·   GPU " + root.temp(root.gpu.temp) : "")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              visible: root.heroNote !== ""
              textFormat: Text.PlainText
              text: root.heroNote
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { width: parent.width }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: "Processor" }
          InfoPair { label: "Usage"; value: root.pct(root.cpu.pct) }
          InfoPair { label: "Temperature"; value: root.temp(root.cpu.temp) }
          InfoPair {
            label: "Load average"
            value: root.cpu.load ? root.cpu.load.map(function(x) { return Number(x).toFixed(2) }).join("  ") : "—"
          }
        }

        PanelSeparator { width: parent.width; visible: graphics.visible }

        Column {
          id: graphics
          visible: root.gpu !== null
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: root.gpu && root.gpu.name ? root.gpu.name : "Graphics" }
          InfoPair {
            visible: root.gpu !== null && root.gpu.state === "suspended"
            label: "State"
            value: "Asleep, not polled"
          }
          InfoPair { visible: root.gpuActive; label: "Usage"; value: root.pct(root.gpuActive ? root.gpu.pct : null) }
          InfoPair { visible: root.gpuActive; label: "Temperature"; value: root.temp(root.gpuActive ? root.gpu.temp : null) }
          InfoPair {
            visible: root.gpuActive && !!root.gpu.vramTotalMiB
            label: "Memory"
            value: visible ? (root.gpu.vramUsedMiB / 1024).toFixed(1) + " / " + (root.gpu.vramTotalMiB / 1024).toFixed(1) + " GiB" : ""
          }
          InfoPair {
            visible: root.gpuActive && root.gpu.watts !== null && root.gpu.watts !== undefined
            label: "Power draw"
            value: visible ? Math.round(root.gpu.watts) + " W" : ""
          }
        }

        PanelSeparator { width: parent.width }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: "Memory" }
          InfoPair {
            label: "RAM"
            value: root.pct(root.mem.pct) + "   " + root.gib(root.mem.usedGiB) + " / " + root.gib(root.mem.totalGiB) + " GiB"
          }
          InfoPair {
            visible: (root.swap.totalGiB || 0) > 0
            label: "Swap"
            value: root.pct(root.swap.pct) + "   " + root.gib(root.swap.usedGiB) + " / " + root.gib(root.swap.totalGiB) + " GiB"
          }
        }

        PanelSeparator { width: parent.width; visible: cooling.visible }

        Column {
          id: cooling
          visible: root.fanRows.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: "Cooling" }
          Repeater {
            model: root.fanRows
            delegate: InfoPair {
              label: modelData.label
              value: root.fanValue(modelData)
              warn: modelData.missing || modelData.rpm === 0
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property bool warn: false

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    InfoValue { text: value; warn: parent.warn }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    property bool warn: false
    textFormat: Text.PlainText
    color: warn ? root.bar.urgent : root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
