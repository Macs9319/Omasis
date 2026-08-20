import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omasis: a browser for the community Omarchy plugin registry that backs
// omarchyplugins.com. Fetches a flattened snapshot of the registry via
// omasis.sh, caches it under ~/.local/state/omarchy/omasis/, and lets the
// user search, filter by category, and install a plugin with one click by
// shelling out to the existing `omarchy plugin add` CLI (which already
// handles clone/validate/dedup/enable — this plugin never touches git or
// the plugin directory itself).
Panel {
  id: root
  moduleName: "omasis"
  ipcTarget: "omasis"

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/omasis/omasis.sh"
  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/omarchy/omasis/registry.json"
  readonly property int refreshHours: Math.max(1, parseInt(setting("refreshHours", 1), 10) || 1)

  readonly property string icon: "🧩"

  property var allEntries: []
  property var installedIds: ({})
  property string searchText: ""
  property string activeCategory: ""
  property bool loading: false
  property string statusMessage: ""
  property bool statusIsError: false
  property var installingIds: ({})
  property double lastFetchedAtMs: 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (root.opened) {
      root.checkInstalled()
      root.maybeRefresh()
    }
  }

  // ---------- helpers ----------

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function humanize(id) {
    var words = String(id).split(/[.\-_]+/).filter(function (w) { return w.length > 0 })
    return words.map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
  }

  function displayName(e) {
    return e.name ? e.name : root.humanize(e.id)
  }

  function authorFor(e) {
    if (e.author) return e.author
    var m = /github\.com\/([^\/]+)\//.exec(e.repo || "")
    return m ? m[1] : ""
  }

  readonly property var accentPalette: ({
    amber: "#d9a441",
    coral: "#e08a72",
    lime: "#9bc158",
    rose: "#d97b9c",
    violet: "#9a7fd1",
    teal: "#5aa9a3"
  })

  function accentColorFor(e) {
    if (e.accent && root.accentPalette[e.accent]) return root.accentPalette[e.accent]
    var keys = Object.keys(root.accentPalette)
    var h = 0
    var idStr = String(e.id || "")
    for (var i = 0; i < idStr.length; i++) h = (h * 31 + idStr.charCodeAt(i)) >>> 0
    return root.accentPalette[keys[h % keys.length]]
  }

  function initialsFor(e) {
    if (e.initials) return e.initials
    var parts = String(e.id || "?").split(/[.\-_]+/).filter(function (p) { return p.length > 0 })
    var a = (parts[0] || "?").charAt(0)
    var b = (parts[1] || "").charAt(0)
    return (a + b).toUpperCase()
  }

  function setStatus(msg, isError) {
    root.statusMessage = msg
    root.statusIsError = !!isError
    statusClearTimer.restart()
  }

  // ---------- registry fetch + cache ----------

  function maybeRefresh() {
    if (root.allEntries.length === 0 || (Date.now() - root.lastFetchedAtMs) > root.refreshHours * 3600 * 1000) {
      root.refresh()
    }
  }

  function refresh() {
    if (fetchProc.running) return
    root.loading = true
    fetchProc.command = ["bash", root.scriptPath, "poll"]
    fetchProc.running = true
  }

  FileView {
    id: cacheFileView
    path: root.cachePath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var obj = JSON.parse(String(text() || "{}"))
        root.allEntries = Array.isArray(obj.entries) ? obj.entries : []
        root.lastFetchedAtMs = obj.fetchedAtMs || 0
      } catch (e) {
        root.allEntries = []
        root.lastFetchedAtMs = 0
      }
      root.maybeRefresh()
    }
    onLoadFailed: root.refresh()
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        try {
          var arr = JSON.parse(String(text || "").trim())
          root.allEntries = Array.isArray(arr) ? arr : []
          root.lastFetchedAtMs = Date.now()
          cacheFileView.setText(JSON.stringify({ entries: root.allEntries, fetchedAtMs: root.lastFetchedAtMs }))
        } catch (e) {
          root.setStatus("Couldn't reach the plugin registry", true)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.warn("omasis/fetch:", t)
      }
    }
  }

  Timer {
    interval: root.refreshHours * 3600 * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusClearTimer
    interval: 6000
    onTriggered: root.statusMessage = ""
  }

  // ---------- installed-state tracking ----------

  function checkInstalled() {
    if (installedProc.running) return
    installedProc.command = ["bash", "-c", "omarchy plugin list --json"]
    installedProc.running = true
  }

  Process {
    id: installedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "").trim())
          var map = {}
          if (Array.isArray(arr)) {
            for (var i = 0; i < arr.length; i++) map[arr[i].id] = arr[i]
          }
          root.installedIds = map
        } catch (e) {
          // keep the previous installedIds on parse failure
        }
      }
    }
  }

  // ---------- install action ----------

  function installEntry(entry) {
    if (root.installingIds[entry.id]) return
    var installing = {}
    for (var k in root.installingIds) installing[k] = root.installingIds[k]
    installing[entry.id] = true
    root.installingIds = installing

    root.setStatus("Installing " + root.displayName(entry) + "…", false)
    installProc.entryId = entry.id
    installProc.entryName = root.displayName(entry)
    installProc.command = ["bash", "-c", "omarchy plugin add " + root.shellQuote(entry.repo) + " --yes --enable"]
    installProc.running = true
  }

  function clearInstalling(id) {
    var installing = {}
    for (var k in root.installingIds) if (k !== id) installing[k] = root.installingIds[k]
    root.installingIds = installing
  }

  function showManualInfo(entry) {
    var note = entry.installNote || "This plugin needs manual setup — see the repo for instructions."
    var cmd = entry.installCommand ? (" Run: " + entry.installCommand) : ""
    root.setStatus(root.displayName(entry) + " — " + note + cmd, false)
    Qt.openUrlExternally(entry.repo)
  }

  Process {
    id: installProc
    property string entryId: ""
    property string entryName: ""
    property string _stderrText: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: installProc._stderrText = String(text || "")
    }
    onExited: function (exitCode) {
      var finishedId = installProc.entryId
      var finishedName = installProc.entryName
      root.clearInstalling(finishedId)

      if (exitCode === 0) {
        root.setStatus("Installed " + finishedName, false)
        root.checkInstalled()
        notifyProc.command = ["notify-send", "-a", "Omasis", "Installed", finishedName]
        notifyProc.running = true
        return
      }

      var msg = installProc._stderrText.trim().replace(/^omarchy-plugin-add:\s*/, "")
      if (msg.indexOf("already installed") !== -1) {
        root.checkInstalled()
        root.setStatus(finishedName + " is already installed", false)
        return
      }
      root.setStatus("Failed to install " + finishedName + (msg ? ": " + msg : ""), true)
      notifyProc.command = ["notify-send", "-a", "Omasis", "-u", "critical", "Install failed", finishedName + (msg ? " — " + msg : "")]
      notifyProc.running = true
    }
  }

  Process { id: notifyProc }

  // ---------- search + filter ----------

  readonly property var categoryCounts: {
    var counts = {}
    root.allEntries.forEach(function (e) {
      var c = e.category || "Other"
      counts[c] = (counts[c] || 0) + 1
    })
    return counts
  }

  readonly property var categoryOptions: {
    var opts = [{ value: "", label: "All" }]
    Object.keys(root.categoryCounts).sort().forEach(function (c) {
      opts.push({ value: c, label: c })
    })
    return opts
  }

  readonly property var filteredEntries: {
    var q = root.searchText.trim().toLowerCase()
    return root.allEntries.filter(function (e) {
      if (root.activeCategory !== "" && e.category !== root.activeCategory) return false
      if (q === "") return true
      var hay = (root.displayName(e) + " " + root.authorFor(e) + " " + (e.category || "") + " " + (e.tags || []).join(" ")).toLowerCase()
      return hay.indexOf(q) !== -1
    })
  }

  // ---------- bar button ----------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.opened
    tooltipText: "Browse Omarchy plugins"
    onPressed: function (b) { root.toggle() }
  }

  // ---------- card delegate ----------

  Component {
    id: cardDelegate

    Item {
      id: card
      required property var modelData

      width: column.width
      implicitHeight: cardBody.implicitHeight + Style.space(20)

      readonly property bool installed: root.installedIds[card.modelData.id] !== undefined
      readonly property bool installing: root.installingIds[card.modelData.id] === true

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: cardHover.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : Style.normalFillFor(root.bar.foreground, Color.accent)
      }

      MouseArea {
        id: cardHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      Row {
        id: cardBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(10)

        Rectangle {
          width: Style.space(32)
          height: Style.space(32)
          radius: width / 2
          color: root.accentColorFor(card.modelData)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: root.initialsFor(card.modelData)
            color: Color.background
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Column {
          id: infoColumn
          width: cardBody.width - Style.space(32) - installBtn.width - cardBody.spacing * 2
          spacing: Style.space(3)

          Text {
            width: parent.width
            text: root.displayName(card.modelData)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: {
              var bits = []
              var author = root.authorFor(card.modelData)
              if (author !== "") bits.push(author)
              bits.push(card.modelData.category || "Other")
              var tags = card.modelData.tags || []
              if (tags.length > 0) bits.push(tags.slice(0, 3).join(", "))
              return bits.join(" • ")
            }
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            spacing: Style.space(8)
            visible: !!card.modelData.securityOutcome || !!card.modelData.maintainerReviewed

            Text {
              visible: card.modelData.securityOutcome === "passed"
              text: "✓ scanned"
              color: Qt.darker(root.bar.foreground, 1.3)
              font.pixelSize: Style.font.caption
              font.family: root.bar.fontFamily
            }
            Text {
              visible: card.modelData.securityOutcome === "needs-fixes" || card.modelData.securityOutcome === "review-required"
              text: "⚠ " + (card.modelData.securityOutcome || "")
              color: Color.urgent
              font.pixelSize: Style.font.caption
              font.family: root.bar.fontFamily
            }
            Text {
              visible: !!card.modelData.maintainerReviewed
              text: "★ maintainer-reviewed"
              color: Color.accent
              font.pixelSize: Style.font.caption
              font.family: root.bar.fontFamily
            }
          }
        }

        Button {
          id: installBtn
          anchors.verticalCenter: parent.verticalCenter
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: card.installed
          iconSpinning: card.installing
          text: card.installed ? "✓ Installed" : (card.installing ? "Installing…" : (card.modelData.installType === "manual" ? "View" : "Get"))
          onClicked: {
            if (card.installed || card.installing) return
            if (card.modelData.installType === "manual") root.showManualInfo(card.modelData)
            else root.installEntry(card.modelData)
          }
        }
      }
    }
  }

  // ---------- popup ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(560), column.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: listScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: listScroll.width
          spacing: Style.space(12)

          // ---------- Header: title + refresh ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, refreshBtn.implicitHeight)

            Text {
              id: headerText
              text: "Omasis"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: refreshBtn
              iconText: "↻"
              iconSpinning: root.loading
              tooltipText: "Refresh registry"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.refresh()
            }
          }

          Text {
            visible: root.statusMessage !== ""
            width: parent.width
            text: root.statusMessage
            color: root.statusIsError ? Color.urgent : Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Search plugins, tags, authors…"
            foreground: root.bar.foreground
            onTextChanged: root.searchText = text
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.categoryOptions
              delegate: Button {
                required property var modelData
                text: modelData.label + " (" + (modelData.value === "" ? root.allEntries.length : (root.categoryCounts[modelData.value] || 0)) + ")"
                selected: root.activeCategory === modelData.value
                bordered: true
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.activeCategory = modelData.value
              }
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          PanelSectionHeader {
            foreground: root.bar.foreground
            text: "Plugins (" + root.filteredEntries.length + " of " + root.allEntries.length + ")"
          }

          Text {
            visible: root.filteredEntries.length === 0 && !root.loading
            width: parent.width
            text: root.allEntries.length === 0 ? "Loading the plugin registry…" : "No plugins match your search"
            opacity: 0.6
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.filteredEntries
              delegate: cardDelegate
            }
          }
        }
      }
    }
  }
}
