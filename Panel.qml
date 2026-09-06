import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// Port Manager — one bar icon and one panel for every socket listening on
// this machine.
//
// The panel answers three questions in the order you actually ask them:
// what is running, is it reachable from outside, and how do I stop it. Dev
// servers you own lead; your other sockets and the system's sit collapsed
// underneath, present but out of the way.
//
// Stopping is armed rather than confirmed in a modal: `x` once arms the row
// for three seconds, `x` again sends the signal. That keeps the whole panel
// on the keyboard without a dialog stealing focus mid-flow.
Panel {
  id: root
  moduleName: "io.github.adembenabdallah.port-manager"
  ipcTarget: "port-manager"
  manageIpc: false

  // ------------------------------------------------------------------ state
  property var ports: []
  property string filterText: ""
  property string statusText: ""
  property bool statusIsError: false
  property bool showOther: false
  property bool showSystem: false
  property int cursorIndex: 0
  property bool cursorActive: false
  property string armedKey: ""
  property bool armedForce: false
  property real armProgress: 0
  property bool loaded: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var rows: Model.visibleRows(ports, filterText, showOther, showSystem)
  readonly property var devRows: Model.inGroup(Model.filtered(ports, filterText), Model.GROUP_DEV)
  readonly property var otherRows: Model.inGroup(Model.filtered(ports, filterText), Model.GROUP_OTHER)
  readonly property var systemRows: Model.inGroup(Model.filtered(ports, filterText), Model.GROUP_SYSTEM)
  readonly property int devCount: Model.inGroup(ports, Model.GROUP_DEV).length
  readonly property int exposedCount: Model.countExposed(ports)
  readonly property var currentRow: cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex] : null

  readonly property int refreshIntervalSec: Math.max(5, setting("refreshIntervalSec", 20))
  readonly property bool showCountInBar: setting("showCount", true)

  readonly property string script: Qt.resolvedUrl("port-manager.py").toString().replace("file://", "")

  // ------------------------------------------------------------------ actions
  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function rowKey(row) {
    return row ? row.pid + ":" + row.port + ":" + row.protocol : ""
  }

  function setStatus(text, isError) {
    statusText = text
    statusIsError = isError === true
    statusClear.restart()
  }

  function moveCursor(delta) {
    cursorActive = true
    if (rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + delta))
    disarm()
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    if (index !== cursorIndex) disarm()
    cursorIndex = index
  }

  function openRow(row) {
    if (!row || !Model.canOpen(row)) {
      setStatus("Nothing to open — that socket does not speak HTTP.", false)
      return
    }
    Quickshell.execDetached(["xdg-open", row.url])
    setStatus("Opened " + row.url, false)
  }

  function copyRow(row) {
    if (!row) return
    var value = row.url || String(row.port)
    Quickshell.execDetached(["wl-copy", "--", value])
    setStatus("Copied " + value, false)
  }

  function copyCommand(row) {
    if (!row || !row.cmdline) return
    Quickshell.execDetached(["wl-copy", "--", row.cmdline])
    setStatus("Copied the command line.", false)
  }

  function revealProject(row) {
    if (!row || !row.projectPath) {
      setStatus("No project directory for that process.", false)
      return
    }
    Quickshell.execDetached(["xdg-open", row.projectPath])
  }

  // Arm, then fire. The first press marks the row; the second press within
  // the arm window actually signals it.
  function requestStop(row, force) {
    if (!row) return
    if (!row.canStop) {
      setStatus("Only processes owned by your user can be stopped.", true)
      return
    }
    var key = rowKey(row)
    if (armedKey === key && armedForce === force) {
      stop(row, force)
      return
    }
    armedKey = key
    armedForce = force
    armProgress = 1
    armCountdown.restart()
    armTimer.restart()
    setStatus(force
      ? "Force kill " + row.process + "? Press X again."
      : "Stop " + row.process + "? Press x again.", false)
  }

  function disarm() {
    armedKey = ""
    armedForce = false
    armTimer.stop()
    armCountdown.stop()
    armProgress = 0
  }

  function stop(row, force) {
    disarm()
    stopProc.pendingName = row.process
    stopProc.pendingForce = force
    stopProc.command = force
      ? ["python3", root.script, "stop", String(row.pid), "--force"]
      : ["python3", root.script, "stop", String(row.pid)]
    stopProc.running = true
  }

  function toggleOther() { showOther = !showOther; clampCursor() }
  function toggleSystem() { showSystem = !showSystem; clampCursor() }

  function clampCursor() {
    if (rows.length === 0) { cursorIndex = 0; return }
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex))
  }

  function focusSearch(seed) {
    if (seed !== undefined && seed !== "") search.text = seed
    search.forceActiveFocus()
    search.cursorPosition = search.text.length
  }

  function leaveSearch() {
    keyCatcher.forceActiveFocus()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    var sections = [devColumn, otherColumn, systemColumn]
    for (var i = 0; i < sections.length; i++) {
      var s = sections[i]
      var local = cursorIndex - s.indexOffset
      if (local >= 0 && local < s.rowModel.length && local < s.children.length) {
        scrollItemIntoView(s.children[local])
        return
      }
    }
  }

  function handleTextKey(text) {
    if (text === "/") { focusSearch(""); return }
    if (text >= "0" && text <= "9") { focusSearch(search.text + text); return }
    if (text === "r" || text === "R") { refresh(); setStatus("Refreshed.", false); return }
    if (text === "o") { openRow(currentRow); return }
    if (text === "y") { copyRow(currentRow); return }
    if (text === "c") { copyCommand(currentRow); return }
    if (text === "e") { revealProject(currentRow); return }
    if (text === "X") { requestStop(currentRow, true); return }
    if (text === "a" || text === "A") { toggleOther(); return }
    if (text === "s" || text === "S") { toggleSystem(); return }
  }

  // ------------------------------------------------------------------ process
  Process {
    id: listProc
    command: ["python3", root.script]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseResult(text)
        root.loaded = true
        if (result.ok) {
          root.ports = result.ports || []
          root.clampCursor()
        } else {
          root.ports = []
          root.setStatus(result.error || "Unable to read listening ports.", true)
        }
      }
    }
  }

  Process {
    id: stopProc
    property string pendingName: ""
    property bool pendingForce: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseResult(text)
        root.setStatus(Model.stopResultText(result, stopProc.pendingName, stopProc.pendingForce), !result.ok)
        root.refresh()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.opened ? 2500 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer { id: armTimer; interval: 3000; onTriggered: root.disarm() }
  Timer { id: statusClear; interval: 4000; onTriggered: root.statusText = "" }

  NumberAnimation {
    id: armCountdown
    target: root
    property: "armProgress"
    from: 1
    to: 0
    duration: 3000
  }

  IpcHandler {
    target: "port-manager"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function ports(): string { return JSON.stringify(root.ports) }
  }

  // ------------------------------------------------------------------ bar
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    disarm()
    search.text = ""
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    disarm()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The count is the whole point of a glance: how many servers are up
    // right now. A vertical bar has no room for it, so the glyph stands alone
    // there and the tooltip carries the number.
    text: root.vertical || !root.showCountInBar || root.devCount === 0
      ? "󰒍"
      : "󰒍 " + root.devCount
    tooltipText: root.loaded
      ? "Port Manager — " + Model.headline(root.ports)
      : "Port Manager"
    useActiveColor: true
    active: root.exposedCount > 0
    horizontalMargin: 8.5
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    bar: root.bar
    anchorItem: button
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: search.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        }
      }
      onActivateRequested: root.openRow(root.currentRow)
      onDeleteRequested: root.requestStop(root.currentRow, false)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            id: hero
            width: parent.width
            title: "Port Manager"
            meta: root.loaded ? Model.heroMeta(root.ports) : "Reading sockets"
            detail: root.exposedCount > 0 ? String(root.exposedCount) + " exposed" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰒍"
                color: root.exposedCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          Ui.TextField {
            id: search
            width: parent.width
            placeholderText: "Filter by port, project, stack, or PID…"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            onTextChanged: {
              root.filterText = text
              root.cursorIndex = 0
              root.disarm()
            }
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else root.leaveSearch()
            }
            Keys.onDownPressed: { root.leaveSearch(); root.cursorActive = true }
            Keys.onReturnPressed: { root.leaveSearch(); root.cursorActive = true; root.openRow(root.currentRow) }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- dev servers -------------------------------------------------
          // Each section owns its own heading and its own Repeater, but they
          // all index into one flat cursor array (`root.rows`) via
          // `indexOffset` — so j/k walks the whole panel while the headings
          // stay where they belong.
          PanelSectionHeader {
            text: "DEV SERVERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.devRows.length === 0
            width: parent.width
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            text: !root.loaded
              ? "Reading sockets…"
              : (root.filterText !== ""
                ? "Nothing matches “" + root.filterText + "”."
                : "Nothing of yours is listening. The machine is quiet.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          RowSection {
            id: devColumn
            width: parent.width
            rowModel: root.devRows
            indexOffset: 0
          }

          // ---- your other sockets -------------------------------------------
          SectionToggle {
            width: parent.width
            visible: root.otherRows.length > 0
            label: "OTHER SOCKETS YOU OWN"
            count: root.otherRows.length
            expanded: root.showOther
            hint: "a"
            onToggled: root.toggleOther()
          }

          RowSection {
            id: otherColumn
            width: parent.width
            rowModel: root.showOther ? root.otherRows : []
            indexOffset: root.devRows.length
          }

          // ---- everything the system owns -----------------------------------
          SectionToggle {
            width: parent.width
            visible: root.systemRows.length > 0
            label: "SYSTEM SOCKETS"
            count: root.systemRows.length
            expanded: root.showSystem
            hint: "s"
            onToggled: root.toggleSystem()
          }

          RowSection {
            id: systemColumn
            width: parent.width
            rowModel: root.showSystem ? root.systemRows : []
            indexOffset: root.devRows.length + (root.showOther ? root.otherRows.length : 0)
          }

          PanelSeparator { foreground: root.foreground }

          // ---- key legend ---------------------------------------------------
          Flow {
            width: parent.width
            spacing: Style.space(10)

            KeyHint { keyLabel: "↑↓"; action: "move" }
            KeyHint { keyLabel: "⏎"; action: "open" }
            KeyHint { keyLabel: "y"; action: "copy URL" }
            KeyHint { keyLabel: "x"; action: "stop" }
            KeyHint { keyLabel: "X"; action: "force" }
            KeyHint { keyLabel: "/"; action: "filter" }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ pieces

  // One group of rows. `indexOffset` is where this group starts in the flat
  // cursor array, so a delegate can work out its own global index.
  component RowSection: Column {
    id: section
    property var rowModel: []
    property int indexOffset: 0

    spacing: Style.space(4)

    Repeater {
      model: section.rowModel
      PortRow {
        required property var modelData
        required property int index
        width: section.width
        row: modelData
        rowIndex: section.indexOffset + index
      }
    }
  }

  // One listening socket. The port number is the anchor — it is what you
  // scanned the list for — so it gets its own typographic column, and the
  // rail beside it carries exposure at a glance.
  component PortRow: CursorSurface {
    id: portRow
    property var row: null
    property int rowIndex: 0

    readonly property bool armed: root.armedKey === root.rowKey(row)
    readonly property bool isSystem: row && row.group === Model.GROUP_SYSTEM

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    accent: root.accent
    opacity: isSystem ? 0.66 : 1.0
    implicitHeight: rowBody.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onEntered: root.setCursor(portRow.rowIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.copyRow(portRow.row)
        else root.openRow(portRow.row)
      }
    }

    RowLayout {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      // Exposure rail: quiet when the socket is loopback-only, urgent when
      // anything on the network can reach it.
      Rectangle {
        Layout.preferredWidth: Style.space(3)
        Layout.preferredHeight: rowBody.implicitHeight
        radius: width
        color: portRow.row && portRow.row.exposed ? root.urgent : root.accent
        opacity: portRow.row && portRow.row.exposed ? 0.9 : 0.45
      }

      ColumnLayout {
        Layout.preferredWidth: Style.space(58)
        spacing: 0

        Text {
          textFormat: Text.PlainText
          text: portRow.row ? String(portRow.row.port) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          text: portRow.row ? Model.rowProtocol(portRow.row) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.0
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            text: portRow.row ? (portRow.row.glyph || "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: portRow.row ? Model.rowTitle(portRow.row) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          ExposurePill {
            visible: portRow.row && portRow.row.exposed && portRow.row.mine
            text: "EXPOSED"
            tint: root.urgent
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: portRow.row ? Model.rowMeta(portRow.row) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Actions surface with the cursor so an idle list stays calm.
      RowLayout {
        spacing: Style.space(2)
        opacity: portRow.hasCursor || portRow.armed ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 90 } }

        PanelActionButton {
          visible: portRow.row && Model.canOpen(portRow.row)
          iconText: "󰖟"
          tooltipText: "Open " + (portRow.row ? portRow.row.url : "") + " (⏎)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openRow(portRow.row)
        }

        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy URL (y)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.copyRow(portRow.row)
        }

        PanelActionButton {
          visible: portRow.row && portRow.row.canStop
          iconText: portRow.armed ? "󰅗" : "󰐥"
          tooltipText: portRow.armed
            ? "Click again to " + (root.armedForce ? "force kill" : "stop")
            : "Stop this process (x)"
          foreground: portRow.armed ? root.urgent : root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.requestStop(portRow.row, false)
        }
      }
    }

    // Arm window. The bar drains over three seconds and the row disarms with
    // it, so a stray keypress never becomes a kill.
    Rectangle {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(8)
      visible: portRow.armed
      height: Style.space(2)
      radius: height
      width: Math.max(0, (parent.width - Style.space(16)) * root.armProgress)
      color: root.urgent
    }
  }

  component ExposurePill: Item {
    property alias text: pillText.text
    property color tint: root.urgent

    implicitWidth: pillText.implicitWidth + Style.space(10)
    implicitHeight: pillText.implicitHeight + Style.space(3)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.cornerRadius : height / 2
      color: Qt.rgba(parent.tint.r, parent.tint.g, parent.tint.b, 0.16)
      border.width: Style.space(1)
      border.color: Qt.rgba(parent.tint.r, parent.tint.g, parent.tint.b, 0.5)
    }

    Text {
      id: pillText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.8
    }
  }

  component SectionToggle: Item {
    id: sectionToggle
    property string label: ""
    property int count: 0
    property bool expanded: false
    property string hint: ""
    signal toggled()

    implicitHeight: toggleRow.implicitHeight + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: sectionToggle.toggled()
    }

    RowLayout {
      id: toggleRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: sectionToggle.expanded ? "󰅀" : "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSectionHeader {
        text: sectionToggle.label + "  (" + sectionToggle.count + ")"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Item { Layout.fillWidth: true }

      Text {
        textFormat: Text.PlainText
        text: sectionToggle.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.7
      }
    }
  }

  component KeyHint: Row {
    property string keyLabel: ""
    property string action: ""
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: parent.keyLabel
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: parent.action
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
