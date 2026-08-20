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
  // Object.create(null) rather than {} for every id-keyed map below: ids
  // and accents come from a public, community-editable registry, and a
  // crafted id like "__proto__" used as a bracket-access key on a normal
  // object literal can pollute Object.prototype. A null-prototype object
  // has no inherited keys to collide with.
  property var installedIds: Object.create(null)
  property string searchText: ""
  property string activeCategory: ""
  property bool loading: false
  property string statusMessage: ""
  property bool statusIsError: false
  property var installingIds: Object.create(null)
  property double lastFetchedAtMs: 0

  // Easter egg: click the "Omasis" title 9 times to run an "Omanova"
  // ticker across the header. titleClicks resets on its own after a
  // pause so it counts a burst of clicks, not lifetime clicks.
  property int titleClicks: 0
  property bool showEasterEgg: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (root.opened) {
      root.checkInstalled()
      root.maybeRefresh()
    }
  }

  // ---------- helpers ----------

  // Allowlist gate before anything reaches `git clone` (via `omarchy plugin
  // add`) or `Qt.openUrlExternally`. The registry is public and
  // community-editable, and git supports transport schemes (`ext::` in
  // particular) that run arbitrary shell commands when given as a clone
  // URL — restricting to plain https://github.com/<owner>/<repo> closes
  // that off entirely. omasis.sh already computes this server-side as
  // `repoSafe`; this is the client-side belt-and-suspenders check run
  // again right before either action, in case the cache is stale or was
  // written by an older version of the script.
  function isInstallableRepo(url) {
    return /^https:\/\/github\.com\/[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*(\.git)?\/?$/.test(String(url || ""))
  }

  function truncate(s, max) {
    var str = String(s || "")
    return str.length > max ? str.slice(0, max) + "…" : str
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
    // hasOwnProperty guard: e.accent is registry-controlled, and indexing
    // a plain object literal with a key like "constructor" or
    // "__proto__" resolves to an inherited value instead of undefined.
    if (e.accent && Object.prototype.hasOwnProperty.call(root.accentPalette, e.accent)) return root.accentPalette[e.accent]
    var keys = Object.keys(root.accentPalette)
    var h = 0
    var idStr = String(e.id || "")
    for (var i = 0; i < idStr.length; i++) h = (h * 31 + idStr.charCodeAt(i)) >>> 0
    return root.accentPalette[keys[h % keys.length]]
  }

  function initialsFor(e) {
    if (e.initials) return String(e.initials).slice(0, 3)
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

  function handleTitleClick() {
    root.titleClicks += 1
    titleClickResetTimer.restart()
    if (root.titleClicks >= 9) {
      root.titleClicks = 0
      root.triggerEasterEgg()
    }
  }

  function triggerEasterEgg() {
    root.showEasterEgg = true
    tickerAnim.restart()
  }

  Timer {
    id: titleClickResetTimer
    interval: 1500
    onTriggered: root.titleClicks = 0
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
    // Plain argv, no shell — this command has no variable input, but
    // running everything without a shell by default is the cheaper habit
    // than auditing each call site for whether it currently needs one.
    installedProc.command = ["omarchy", "plugin", "list", "--json"]
    installedProc.running = true
  }

  Process {
    id: installedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "").trim())
          var map = Object.create(null)
          if (Array.isArray(arr)) {
            for (var i = 0; i < arr.length; i++) {
              if (arr[i] && typeof arr[i].id === "string") map[arr[i].id] = arr[i]
            }
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
    if (entry.installType === "manual" || !root.isInstallableRepo(entry.repo)) {
      root.setStatus(root.displayName(entry) + " can't be installed automatically", true)
      return
    }
    if (root.installingIds[entry.id]) return
    var installing = Object.create(null)
    for (var k in root.installingIds) installing[k] = root.installingIds[k]
    installing[entry.id] = true
    root.installingIds = installing

    root.setStatus("Installing " + root.displayName(entry) + "…", false)
    installProc.entryId = entry.id
    installProc.entryName = root.displayName(entry)
    // Plain argv passed straight to execve — no shell involved, so there's
    // no quoting to get right and no metacharacters to worry about. The
    // isInstallableRepo() check above is what actually matters here: it's
    // the only thing standing between this repo URL and `git clone`.
    installProc.command = ["omarchy", "plugin", "add", entry.repo, "--yes", "--enable"]
    installProc.running = true
  }

  function clearInstalling(id) {
    var installing = Object.create(null)
    for (var k in root.installingIds) if (k !== id) installing[k] = root.installingIds[k]
    root.installingIds = installing
  }

  function showManualInfo(entry) {
    var note = root.truncate(entry.installNote || "This plugin needs manual setup — see the repo for instructions.", 300)
    var cmd = entry.installCommand ? (" Run: " + root.truncate(entry.installCommand, 300)) : ""
    root.setStatus(root.displayName(entry) + " — " + note + cmd, false)
    if (root.isInstallableRepo(entry.repo)) Qt.openUrlExternally(entry.repo)
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
        // "--" ends option parsing so a crafted plugin name starting with
        // "-" (e.g. "--icon=/some/path") is taken as the literal summary
        // text instead of being parsed as a notify-send flag.
        notifyProc.command = ["notify-send", "-a", "Omasis", "--", "Installed", finishedName]
        notifyProc.running = true
        return
      }

      var msg = root.truncate(installProc._stderrText.trim().replace(/^omarchy-plugin-add:\s*/, ""), 300)
      if (msg.indexOf("already installed") !== -1) {
        root.checkInstalled()
        root.setStatus(finishedName + " is already installed", false)
        return
      }
      root.setStatus("Failed to install " + finishedName + (msg ? ": " + msg : ""), true)
      notifyProc.command = ["notify-send", "-a", "Omasis", "-u", "critical", "--", "Install failed", finishedName + (msg ? " — " + msg : "")]
      notifyProc.running = true
    }
  }

  Process { id: notifyProc }

  // ---------- search + filter ----------

  readonly property var categoryCounts: {
    var counts = Object.create(null)
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
      var tags = Array.isArray(e.tags) ? e.tags : []
      var hay = (root.displayName(e) + " " + root.authorFor(e) + " " + (e.category || "") + " " + tags.join(" ")).toLowerCase()
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

      width: ListView.view ? ListView.view.width : 0
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
              var tags = Array.isArray(card.modelData.tags) ? card.modelData.tags : []
              if (tags.length > 0) bits.push(tags.slice(0, 3).join(", "))
              return bits.join(" • ")
            }
            textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.3)
              font.pixelSize: Style.font.caption
              font.family: root.bar.fontFamily
            }
            Text {
              // securityOutcome is only ever "needs-fixes"/"review-required"
              // here (omasis.sh clamps it to a fixed enum before caching),
              // but PlainText is cheap insurance against a stale cache.
              visible: card.modelData.securityOutcome === "needs-fixes" || card.modelData.securityOutcome === "review-required"
              text: "⚠ " + (card.modelData.securityOutcome || "")
              textFormat: Text.PlainText
              color: Color.urgent
              font.pixelSize: Style.font.caption
              font.family: root.bar.fontFamily
            }
            Text {
              visible: !!card.modelData.maintainerReviewed
              text: "★ maintainer-reviewed"
              textFormat: Text.PlainText
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
    contentHeight: panel.fittedContentHeight(Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Without this, PanelKeyCatcher's Keys.priority: Keys.BeforeItem
      // intercepts every keystroke ahead of the search field — 'j'/'k'/
      // 'h'/'l'/'x' get eaten as list-navigation commands, and even
      // plain characters only reach the field inconsistently. This is
      // the exact case the component's own doc comment calls out:
      // block it while the inline editor has focus so it forwards keys
      // through normally instead of racing the field for them.
      blocked: searchField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      // ListView rather than a plain Repeater-in-a-Column: the registry
      // has ~660 entries, and a Repeater instantiates every delegate for
      // its whole model immediately, whether on screen or not. With "All"
      // selected that is ~660 card items (each ~10 child Text/Rectangle/
      // Button elements) built synchronously the moment the popup opens —
      // the actual cause of the slow-to-open popup. ListView only
      // realizes delegates near the visible viewport (plus cacheBuffer)
      // and reuses them while scrolling, so opening cost no longer scales
      // with the registry size, only with what is actually on screen.
      ListView {
        id: listView
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: Style.space(600)
        spacing: Style.space(6)

        model: root.filteredEntries
        delegate: cardDelegate

        header: Column {
          width: listView.width
          spacing: Style.space(12)

          // ---------- Header: title + refresh ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, refreshBtn.implicitHeight)

            Text {
              id: headerText
              text: "Omasis"
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
              anchors.fill: headerText
              cursorShape: Qt.PointingHandCursor
              onClicked: root.handleTitleClick()
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

          Item {
            id: tickerContainer
            width: parent.width
            height: root.showEasterEgg ? tickerText.implicitHeight : 0
            visible: root.showEasterEgg
            clip: true

            Text {
              id: tickerText
              text: "Omanova"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              x: tickerContainer.width
            }

            NumberAnimation {
              id: tickerAnim
              target: tickerText
              property: "x"
              from: tickerContainer.width
              to: -tickerText.implicitWidth
              duration: 3500
              easing.type: Easing.Linear
              onFinished: root.showEasterEgg = false
            }
          }

          Text {
            // statusMessage is built from displayName()/installNote/
            // installCommand (all registry-controlled) plus raw CLI
            // stderr, so it is the least trustworthy string in this file.
            visible: root.statusMessage !== ""
            width: parent.width
            text: root.statusMessage
            textFormat: Text.PlainText
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

          Item {
            width: 1
            height: Style.space(2)
          }
        }
      }
    }
  }
}
