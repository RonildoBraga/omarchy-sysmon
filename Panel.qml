import QtQuick
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons
import qs.Ui

// System monitor for the Omarchy bar: one icon, and a card with CPU, GPU,
// memory, storage, network and fan readings, plus a temperature history graph.
//
// Nothing in this file is specific to one machine. Per-machine choices (GPU
// source, fan names, disks, which sections to show) come from this widget's
// entry in ~/.config/omarchy/shell.json. See README.md.
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
  readonly property var storage: stats.storage || []
  readonly property var disks: stats.disks || []
  readonly property var net: stats.net || null
  readonly property bool gpuActive: gpu !== null && gpu.state === "active"

  // --- Settings ----------------------------------------------------------------

  readonly property string gpuSource: String(setting("gpu", "auto"))
  readonly property int refreshSec: Math.max(1, Number(setting("refreshIntervalSec", 3)) || 3)
  readonly property int warnTemp: Number(setting("warnTemp", 80)) || 80
  readonly property bool showHistory: setting("showHistory", true) !== false
  readonly property int historyMinutes: Math.min(60, Math.max(1, Number(setting("historyMinutes", 5)) || 5))
  readonly property bool showStorage: setting("showStorage", true) !== false
  readonly property bool showNetwork: setting("showNetwork", true) !== false
  readonly property var diskPaths: {
    var paths = setting("disks", ["/", "/home"])
    return paths && paths.length !== undefined ? paths : ["/", "/home"]
  }
  readonly property var fanConfig: {
    var fans = setting("fans", [])
    return fans && fans.length !== undefined ? fans : []
  }

  // The collector ships inside this plugin folder, wherever it is installed.
  readonly property string collector: decodeURIComponent(String(Qt.resolvedUrl("bin/sysmon-collect")).replace(/^file:\/\//, ""))

  readonly property var collectorCommand: {
    var cmd = [root.collector, "--gpu", root.gpuSource]
    if (root.showStorage) {
      for (var i = 0; i < root.diskPaths.length; i++) cmd.push("--disk", String(root.diskPaths[i]))
    }
    return cmd
  }

  readonly property int peakTemp: Math.max(cpu.temp || 0, gpuActive ? (gpu.temp || 0) : 0)
  readonly property bool hot: peakTemp >= warnTemp

  readonly property string heroNote: {
    var notes = []
    if (stats.fanControl === "active") notes.push("Fan curve active")
    if (gpu !== null && gpu.state === "suspended") notes.push("GPU asleep")
    return notes.join("  ·  ")
  }

  // --- Temperature history -------------------------------------------------------

  // Recent temperatures, oldest first. Kept in memory only, so it starts empty
  // whenever the shell restarts.
  property var history: []
  readonly property int historyCapacity: Math.max(2, Math.ceil(historyMinutes * 60 / refreshSec) + 1)
  readonly property bool gpuSeen: {
    for (var i = 0; i < history.length; i++) {
      if (history[i].gpu !== null) return true
    }
    return false
  }

  function recordHistory(s) {
    var c = s.cpu && s.cpu.temp !== undefined ? s.cpu.temp : null
    var g = s.gpu && s.gpu.state === "active" && s.gpu.temp !== undefined ? s.gpu.temp : null
    if (c === null && g === null) return
    var next = history.concat([{ cpu: c, gpu: g }])
    if (next.length > historyCapacity) next = next.slice(next.length - historyCapacity)
    history = next
  }

  // --- Formatting -------------------------------------------------------------------

  function temp(v) { return (v === undefined || v === null) ? "—" : Math.round(v) + "°C" }
  function pct(v) { return (v === undefined || v === null) ? "—" : Math.round(v) + "%" }
  function gib(v) { return (v === undefined || v === null) ? "—" : Number(v).toFixed(1) }

  function rate(bps) {
    if (bps === undefined || bps === null) return "—"
    var units = ["B/s", "kB/s", "MB/s", "GB/s"]
    var v = bps
    var i = 0
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000
      i++
    }
    return (i === 0 ? Math.round(v) : v.toFixed(v < 10 ? 1 : 0)) + " " + units[i]
  }

  // Both numbers in the unit that suits the total, like the RAM row.
  function sizePair(used, total) {
    if (used === undefined || used === null || !total) return "—"
    var tib = 1099511627776
    var unit = total >= tib ? tib : 1073741824
    var t = total / unit
    var dp = t < 100 ? 1 : 0
    return (used / unit).toFixed(dp) + " / " + t.toFixed(dp) + (unit === tib ? " TiB" : " GiB")
  }

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

  // --- Polling ----------------------------------------------------------------------

  Process {
    id: poll
    command: root.collectorCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.stats = parsed
          root.recordHistory(parsed)
        } catch (e) { }
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

  // --- Bar icon -----------------------------------------------------------------------

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

  // --- Card --------------------------------------------------------------------------------

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

        // Temperature history graph.
        Column {
          id: historySection
          visible: root.showHistory && root.history.length > 1
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: historyTitle.implicitHeight

            Text {
              id: historyTitle
              textFormat: Text.PlainText
              text: "Last " + root.historyMinutes + " min"
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: historyTitle.verticalCenter
              spacing: Style.space(10)
              LegendItem { swatch: Color.accent; caption: "CPU" }
              LegendItem { visible: root.gpuSeen; swatch: root.bar.foreground; swatchOpacity: 0.55; caption: "GPU" }
              LegendItem { swatch: root.bar.urgent; swatchOpacity: 0.5; caption: root.warnTemp + "°C" }
            }
          }

          Item {
            id: graph
            width: parent.width
            height: Style.space(64)

            // From a little below the coolest reading to just above warnTemp, so
            // the warning line always shows how much headroom is left.
            readonly property var range: {
              var lo = Infinity
              var hi = -Infinity
              var h = root.history
              for (var i = 0; i < h.length; i++) {
                if (h[i].cpu !== null) { lo = Math.min(lo, h[i].cpu); hi = Math.max(hi, h[i].cpu) }
                if (h[i].gpu !== null) { lo = Math.min(lo, h[i].gpu); hi = Math.max(hi, h[i].gpu) }
              }
              if (lo === Infinity) { lo = 30; hi = 60 }
              hi = Math.max(hi, root.warnTemp) + 2
              lo = Math.min(lo - 5, hi - 20)
              return { lo: lo, hi: hi }
            }

            function yFor(t) { return height - (t - range.lo) / (range.hi - range.lo) * height }

            // The newest sample sits at the right edge; gaps (a sleeping GPU)
            // split the line into separate segments.
            function segments(key) {
              var h = root.history
              var step = width / (root.historyCapacity - 1)
              var offset = root.historyCapacity - h.length
              var out = []
              var current = []
              for (var i = 0; i < h.length; i++) {
                var t = h[i][key]
                if (t === null) {
                  if (current.length > 1) out.push(current)
                  current = []
                  continue
                }
                current.push(Qt.point((offset + i) * step, yFor(t)))
              }
              if (current.length > 1) out.push(current)
              return out
            }

            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeColor: Qt.rgba(root.bar.urgent.r, root.bar.urgent.g, root.bar.urgent.b, 0.5)
                strokeWidth: 1
                fillColor: "transparent"
                startX: 0
                startY: graph.yFor(root.warnTemp)
                PathLine { x: graph.width; y: graph.yFor(root.warnTemp) }
              }

              ShapePath {
                strokeColor: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.55)
                strokeWidth: 1.5
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                PathMultiline { paths: graph.segments("gpu") }
              }

              ShapePath {
                strokeColor: Color.accent
                strokeWidth: 1.5
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                PathMultiline { paths: graph.segments("cpu") }
              }
            }
          }
        }

        PanelSeparator { width: parent.width; visible: historySection.visible }

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

        PanelSeparator { width: parent.width; visible: storageSection.visible }

        Column {
          id: storageSection
          visible: root.showStorage && (root.storage.length > 0 || root.disks.length > 0)
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: "Storage" }
          Repeater {
            model: root.storage
            delegate: InfoPair {
              label: modelData.label
              value: root.temp(modelData.temp)
              // Past the drive's own warning threshold.
              warn: modelData.max !== null && modelData.temp >= modelData.max
            }
          }
          Repeater {
            model: root.disks
            delegate: InfoPair {
              label: modelData.path === "/" ? "Root" : modelData.path
              value: modelData.pct + "%   " + root.sizePair(modelData.usedBytes, modelData.sizeBytes)
              warn: modelData.pct >= 90
            }
          }
        }

        PanelSeparator { width: parent.width; visible: networkSection.visible }

        Column {
          id: networkSection
          visible: root.showNetwork && root.net !== null
          width: parent.width
          spacing: Style.spacing.labelGap
          PanelSectionHeader { text: "Network" }
          InfoPair { label: "Download"; value: root.rate(root.net ? root.net.rxBps : null) }
          InfoPair { label: "Upload"; value: root.rate(root.net ? root.net.txBps : null) }
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

  // --- Components -------------------------------------------------------------------------

  // A label on the left and a value on the right. A long label (a drive model,
  // say) is shortened with an ellipsis rather than running into the value.
  component InfoPair: Row {
    id: pair
    property string label: ""
    property string value: ""
    property bool warn: false

    width: parent.width
    spacing: Style.space(8)

    InfoLabel {
      text: pair.label
      width: Math.min(implicitWidth, Math.max(0, pair.width - valueText.implicitWidth - pair.spacing * 2))
      elide: Text.ElideRight
    }
    Item {
      width: Math.max(0, pair.width - pair.children[0].width - valueText.implicitWidth - pair.spacing * 2)
      height: 1
    }
    InfoValue { id: valueText; text: pair.value; warn: pair.warn }
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

  component LegendItem: Row {
    id: legend
    property color swatch: "white"
    property real swatchOpacity: 1
    property string caption: ""
    spacing: Style.space(4)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(10)
      height: 2
      radius: 1
      color: legend.swatch
      opacity: legend.swatchOpacity
    }
    Text {
      textFormat: Text.PlainText
      text: legend.caption
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
