// Steam Workshop browser. Lets the user search the Wallpaper Engine
// workshop (appid 431960), see results, mark already-installed items and
// open pages/items for subscribing on the Steam client. Shares the
// configuration dialog theme with the other pages.
import QtQuick 2.15
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5
import QtQuick.Window 2.0

import ".."
import "../components"
import "../js/utils.mjs" as Utils
import "../js/workshopQuery.mjs" as WS

import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami 2.6 as Kirigami

Item {
    id: root

    // ── Fixed dark palette (works regardless of the system theme) ────────
    readonly property color pageBg:       "#0e1014"
    readonly property color panelBg:      "#15181e"
    readonly property color cardBg:       "#1a1e26"
    readonly property color cardAlt:      "#20252f"
    readonly property color border:       "#2a3140"
    readonly property color hover:        "#3daee9"
    readonly property color text:         "#f5f6f8"
    readonly property color textDim:      "#a8b2bf"
    readonly property color textFaint:    "#6c7684"
    readonly property color accent:       "#3daee9"
    readonly property color success:      "#46a45a"
    readonly property color danger:       "#e05b4c"

    // ── Inputs (provided by config.qml) ────────────────────────────────────
    property string steamLibraryPath: ""
    property var pyext: null
    property string activeWorkshopId: ""

    // ── Outputs ────────────────────────────────────────────────────────────
    signal commitWallpaper(var item)
    signal wallpaperDownloaded()
    signal presetRequested(string presetId, string dependencyId, var preset)

    // ── State ──────────────────────────────────────────────────────────────
    property int totalPages: 1
    property int queryIndex: 1
    property string searchText: ""
    property string currentSort: WS.SortMode.Trend
    property bool loading: false
    property string statusText: ""

    property var items: ListModel {}
    property var installedIds: ({})
    property int _lastInstalledCount: 0

    // The KConfig "Path" entry is stored as a file:// URL.  pyext and the
    // shell helper need a native path, so normalize once here.
    readonly property string _libNative: nativePath(root.steamLibraryPath)
    readonly property string _workshopDirNative: Common.getWorkshopDir(root._libNative)
    // Keep the helper inside the plugin package so it can be shared/ported.
    readonly property string _triggerScript: nativePath(Qt.resolvedUrl("../../scripts/we-trigger.sh"))

    function nativePath(p) {
        if (!p) return "";
        let s = Common.urlNative(p);
        try { s = decodeURIComponent(s); } catch (e) {}
        return s;
    }

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    // ── Filter modes (anti-NSFW) ──────────────────────────────────────────
    // 0 = Off · 1 = Title scan · 2 = Deep (also reads installed project.json
    // contentrating + tags, which is what WE wallpapers actually carry).
    property int safeMode: 1
    property int hiddenCount: 0

    // Keyword scan with word-boundary checking so "sexy" matches "sex" but
    // "Sussex" doesn't, "18+" doesn't regex-explode, etc.
    function isNsfw(text) {
        if (!text) return false;
        const t = String(text).toLowerCase();
        const contains = [
            "nsfw", "hent", "porn", "xxx", "nud", "boob", "topless",
            "ecchi", "ahegao", "rule34", "r34", "milf", "oppai", "ntr",
            "fetish", "bdsm", "eroge", "lewd", "loli", "shota", "yaoi",
            "yuri", "sex", "18+"
        ];
        for (const w of contains) {
            if (t.indexOf(w) !== -1) return true;
        }
        for (const w of ["adult", "mature"]) {
            if (new RegExp("(^|[^a-z0-9])" + w + "($|[^a-z0-9])").test(t)) return true;
        }
        return false;
    }

    // Mark/unmark one item and keep hiddenCount in sync.
    function setItemNsfw(id, val) {
        for (let i = 0; i < root.items.count; i++) {
            const it = root.items.get(i);
            if (it.id === id) {
                if (Boolean(it.nsfw) !== val) {
                    root.items.setProperty(i, "nsfw", val);
                    root.hiddenCount += val ? 1 : -1;
                }
                return;
            }
        }
    }

    // Deep mode: read project.json of an already-installed wallpaper and flag
    // it from its own contentrating ("Questionable"/"Mature") and tags.
    function deepClassifyId(id) {
        if (!root.pyext) return;
        const proj = root._workshopDirNative + "/" + id + "/project.json";
        root.pyext.readfile(proj).then(txt => {
            const p = Utils.parseJson(txt);
            if (!p) return;
            const cr = String(p.contentrating || "").toLowerCase();
            const tags = Array.isArray(p.tags)
                ? p.tags.map(el => typeof el === "string" ? el : (el && el.key) || "").join(" ")
                : "";
            const flagged = cr === "mature" || cr === "questionable" || root.isNsfw(tags);
            if (flagged) root.setItemNsfw(id, true);
        }).catch(() => {});
    }

    // Recompute the flags after the mode changes.
    function reapplyFilter() {
        root.hiddenCount = 0;
        for (let i = 0; i < root.items.count; i++) {
            const it = root.items.get(i);
            const tagText = (it.tags || []).join(" ");
            const nsfw = (root.safeMode >= 1) && (
                root.isNsfw(it.title)
                || root.isNsfw(tagText)
                || /(?:^|[^a-z])(mature|questionable)(?:[^a-z]|$)/i.test(tagText)
            );
            if (nsfw) root.hiddenCount++;
            root.items.setProperty(i, "nsfw", nsfw);
            if (root.safeMode >= 2 && !nsfw && it.installed) root.deepClassifyId(it.id);
        }
    }

    function refreshInstalled() {
        if (!root.steamLibraryPath || !root.pyext) return;
        const dir = root._workshopDirNative;
        root.pyext.get_folder_list(dir, { only_dir: true }).then(res => {
            const set = {};
            if (res && res.items) {
                for (const it of res.items) set[it.name] = true;
            }
            installedIds = set;
            root._lastInstalledCount = Object.keys(set).length;
        }).catch(reason => console.error("[WEK Workshop] installed scan failed: " + reason));
    }

    function registerInstalledWatcher() {
        // Poll the workshop folder while the page is open so items that get
        // downloaded by the Steam client pop up as installed without a manual
        // "Scan Installed" click.
        if (installedTimer.running) return;
        installedTimer.repeat = true;
        installedTimer.interval = 4000;
        installedTimer.start();
    }

    Timer {
        id: installedTimer
        onTriggered: {
            root.syncInstalledFlags();
        }
    }

    function syncInstalledFlags() {
        if (!root.steamLibraryPath || !root.pyext) return;
        const dir = root._workshopDirNative;
        root.pyext.get_folder_list(dir, { only_dir: true }).then(res => {
            const set = {};
            if (res && res.items) {
                for (const it of res.items) set[it.name] = true;
            }
            installedIds = set;
            for (let i = 0; i < root.items.count; i++) {
                const it = root.items.get(i);
                if (it.installed !== (set[it.id] === true))
                    root.items.setProperty(i, "installed", set[it.id] === true);
            }
            const cnt = Object.keys(set).length;
            if (cnt > root._lastInstalledCount) {
                // New item detected — refresh the wallpaper list too.
                root._lastInstalledCount = cnt;
                root.wallpaperDownloaded();
            }
        }).catch(reason => console.error("[WEK Workshop] installed scan failed: " + reason));
    }

    // ── Install ───────────────────────────────────────────────────────────
    property string nowWorking: ""
    property int    _watchTicks: 0
    readonly property int _watchTimeout: 330
    property string _installOutput: ""
    property string _lastInstallError: ""

    function openItemFolder(id) {
        if (!root.steamLibraryPath) return;
        Qt.openUrlExternally(Qt.resolvedUrl(root._workshopDirNative + "/" + id).toString());
    }

    function startInstall(id, force, reinstall) {
        if (!id || root.nowWorking) return;
        if (!root.steamLibraryPath) {
            statusText = "Select your steam library first (Wallpapers tab)";
            return;
        }
        if (!force && installedIds[id] === true) {
            root.openItemFolder(id);
            return;
        }
        root.nowWorking = id;
        root._watchTicks = 0;
        root._installOutput = "";
        root._lastInstallError = "";
        statusText = "Downloading #" + id + "…";
        // Pass the normalized library; wek-download.py also accepts the raw
        // file:// URL, but a native path avoids any quoting surprises.
        let command = "/bin/sh " + root.shellQuote(root._triggerScript) + " "
            + root.shellQuote(root._libNative) + " " + root.shellQuote(id);
        if (reinstall)
            command += " " + root.shellQuote("431960") + " 1";
        fixRunner.connectSource(command);
        installWatch.start();
    }

    function handleInstallLine(line) {
        if (line.indexOf("STATUS ") === 0) {
            const parts = line.split(" ");
            const state = parts[1] || "";
            const bytes = Number(parts[2] || 0);
            if (state === "downloading") {
                const mb = Math.round(bytes / 1048576 * 10) / 10;
                statusText = "Downloading #" + root.nowWorking + " · " + mb + " MB…";
            } else if (state === "queued") {
                statusText = "Queued #" + root.nowWorking + "…";
            } else if (state === "starting") {
                statusText = "Starting Steam…";
            } else {
                statusText = line;
            }
            return;
        }
        if (line.indexOf("OK ") === 0) {
            statusText = "Installed " + root.nowWorking + ".";
            return;
        }
        if (line.indexOf("ERROR ") === 0) {
            root._lastInstallError = line.slice(6).trim();
            statusText = root._lastInstallError;
            return;
        }
        console.log("[WEK Workshop] " + line);
    }

    function finishInstall(code) {
        const id = root.nowWorking;
        installWatch.stop();
        root.nowWorking = "";
        root._installOutput = "";
        if (Number(code) === 0) {
            root._lastInstallError = "";
            statusText = "Installed " + id + ".";
            root.refreshInstalled();
            root.syncInstalledFlags();
            root.wallpaperDownloaded();
        } else {
            statusText = root._lastInstallError
                || ("Download failed for " + id + " (code " + code + ").");
            root._lastInstallError = "";
            root.refreshInstalled();
        }
    }

    P5Support.DataSource {
        id: fixRunner
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            const chunk = data && data.stdout !== undefined ? String(data.stdout) : "";
            if (chunk.length > 0) {
                root._installOutput += chunk;
                let nl = root._installOutput.indexOf("\n");
                while (nl >= 0) {
                    const line = root._installOutput.slice(0, nl).trim();
                    root._installOutput = root._installOutput.slice(nl + 1);
                    if (line.length > 0) root.handleInstallLine(line);
                    nl = root._installOutput.indexOf("\n");
                }
            }
            const code = data ? data["exit code"] : undefined;
            if (code !== undefined && code !== null && code !== "") {
                const rest = root._installOutput.trim();
                if (rest.length > 0) root.handleInstallLine(rest);
                root.finishInstall(code);
                fixRunner.disconnectSource(source);
            }
        }
    }

    Timer {
        id: installWatch
        interval: 2000
        repeat: true
        onTriggered: {
            if (!root.nowWorking) { stop(); return; }
            if (!root.pyext) return;
            const id = root.nowWorking;
            root._watchTicks++;
            if (root._watchTicks > root._watchTimeout) {
                stop();
                root.nowWorking = "";
                root._installOutput = "";
                statusText = "Download timed out for " + id + ". Try again or subscribe manually.";
                return;
            }
            const itemDir = root._workshopDirNative + "/" + id;
            // A non-zero size alone can be a partial/aborted commit.  Check
            // the file referenced by project.json (scene payloads are
            // scene.pkg even when project.json says scene.json) and treat
            // metadata-only presets/effects as complete.
            root.pyext.readfile(itemDir + "/project.json").then(txt => {
                const p = Utils.parseJson(txt);
                if (!p) return false;
                const typ = p.type ? String(p.type).toLowerCase() : "";
                const file = p.file ? String(p.file).replace(/\\/g, "/") : "";
                if (!typ || !file) return true;
                const base = file.split("/").pop();
                return root.pyext.get_folder_list(itemDir, { only_dir: false }).then(res => {
                    const names = new Set((res && res.items ? res.items : []).map(x => x.name));
                    if (names.has(base)) return true;
                    if (typ === "scene" && names.has(base.replace(/\.json$/i, ".pkg")))
                        return true;
                    return false;
                });
            }).then(ok => {
                if (!ok || root.nowWorking !== id) return;
                installWatch.stop();
                root.nowWorking = "";
                root._installOutput = "";
                statusText = "Installed " + id + ".";
                root.refreshInstalled();
                root.syncInstalledFlags();
                root.wallpaperDownloaded();
            }).catch(() => {});
        }
    }

    function fetch(pageNo) {
        if (!root.steamLibraryPath) {
            statusText = "Select your steam library first (Wallpapers tab)";
            return;
        }
        loading = true;
        statusText = "Querying Steam Workshop…";
        const url = WS.buildBrowseUrl({
            query: root.searchText,
            sort: root.currentSort,
            page: pageNo
        });
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, true);
        xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (X11; Linux x86_64)");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                loading = false;
                if (xhr.status !== 200) {
                    statusText = "Network error " + xhr.status + " while talking to Steam.";
                    return;
                }
                const feedTags = WS.extractFeedTags(xhr.responseText);
                const found = WS.parseBrowseHtml(xhr.responseText, feedTags);
                root.queryIndex = pageNo;
                items.clear();
                root.hiddenCount = 0;
                for (const it of found) {
                    // Steam's own age-rating tag (""Mature"" / ""Questionable"")
                    // is authoritative even when the author-declared project.json
                    // says ""Everyone"" (e.g. SF6 Beach).
                    const tagText = (it.tags || []).join(" ");
                    const flagged = root.isNsfw(it.title)
                        || (root.safeMode >= 1 && root.isNsfw(tagText))
                        || (root.safeMode >= 1 && /(?:^|[^a-z])(mature|questionable)(?:[^a-z]|$)/i.test(tagText));
                    if (flagged) root.hiddenCount++;
                    items.append({
                        id: it.id,
                        title: it.title,
                        author: it.author,
                        rating: it.rating,
                        preview: it.preview,
                        tags: it.tags || [],
                        installed: installedIds[it.id] === true,
                        nsfw: flagged
                    });
                }
                // Deep mode: also check installed wallpapers' own metadata.
                if (root.safeMode >= 2) {
                    for (let i = 0; i < root.items.count; i++) {
                        const it = root.items.get(i);
                        if (it.installed) root.deepClassifyId(it.id);
                    }
                }
                root.totalPages = Math.max(WS.parseTotalPages(xhr.responseText), pageNo + (found.length ? 1 : 0) - 1);
                const hidden = (root.safeMode >= 1 && root.hiddenCount)
                    ? " · " + root.hiddenCount + " hidden (filter)"
                    : "";
                statusText = found.length
                    ? `Page ${pageNo} · ${found.length} items${hidden}`
                    : "No results.";
            }
        };
        xhr.send();
    }

    function doSearch() {
        root.searchText = searchField.text.trim();
        root.fetch(1);
    }

    // ── UI ─────────────────────────────────────────────────────────────────
    Rectangle {
        id: pageBgRect
        anchors.fill: parent
        color: root.pageBg
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                radius: 9
                color: root.panelBg
                border.width: 1
                border.color: root.border

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    source: "internet-web-browser"
                    color: root.text
                }
            }
            ColumnLayout {
                spacing: 0
                Label {
                    text: "Steam Workshop"
                    font.bold: true
                    font.pixelSize: 14
                    color: root.text
                }
                Label {
                    text: "Wallpaper Engine · appid 431960"
                    color: root.textDim
                    font.pixelSize: 9
                }
            }
            Item { Layout.fillWidth: true }
        }

        // Search row
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search (anime, cyberpunk, rain, nature…)"
                // Plasma's config dialog treats Enter as "accept" and closes
                // the window. Capture Return/Enter here so it searches instead.
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        event.accepted = true;
                        root.doSearch(1);
                    }
                }
            }
            ComboBox {
                id: sortCombo
                Layout.preferredWidth: 190
                textRole: "text"
                model: [
                    { value: WS.SortMode.Trend,          text: "Trending" },
                    { value: WS.SortMode.TopRated,       text: "Top Rated" },
                    { value: WS.SortMode.MostSubscribed, text: "Most Subscribed" },
                    { value: WS.SortMode.Newest,         text: "Newest" }
                ]

                onActivated: {
                    root.currentSort = model[currentIndex].value;
                    root.fetch(1);
                }
            }
            Button {
                text: "Search"
                icon.name: "edit-find"
                onClicked: root.doSearch(1)
            }
            Button {
                text: "Scan Installed"
                icon.name: "view-refresh"
                onClicked: root.refreshInstalled()
            }
            Button {
                text: "Check"
                icon.name: "checkmark"
                onClicked: {
                    wsCheckPopup.runCheck(false, false);
                    wsCheckPopup.open();
                }
            }
            ComboBox {
                id: safeCombo
                Layout.preferredWidth: 150
                textRole: "text"
                property int _initialized: 0
                model: [
                    { value: 0, text: "Filter: Off" },
                    { value: 1, text: "Filter: Safe" },
                    { value: 2, text: "Filter: Deep" }
                ]
                currentIndex: {
                    switch (root.safeMode) {
                    case 0: return 0;
                    case 1: return 1;
                    default: return 2;
                    }
                }
                delegate: ItemDelegate {
                    width: safeCombo.width
                    highlighted: safeCombo.highlightedIndex === index
                    contentItem: Text {
                        text: modelData && modelData.text !== undefined ? modelData.text : ""
                        color: safeCombo.highlightedIndex === index
                            ? safeCombo.palette.highlightedText
                            : safeCombo.palette.text
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                onActivated: {
                    const mode = model[currentIndex].value;
                    if (mode !== root.safeMode) {
                        root.safeMode = mode;
                        root.reapplyFilter();
                    }
                }
            }
            BusyIndicator {
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                running: root.loading
            }
        }

        // Status line
        Label {
            Layout.fillWidth: true
            visible: Boolean(root.statusText)
            text: root.statusText
            color: root.textDim
            elide: Text.ElideRight
            font.italic: true
        }

        // Results grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.items.count > 0

            GridView {
                id: grid
                anchors.fill: parent
                clip: true
                model: root.items
                cellWidth: {
                    const minCard = 210;
                    const cols = Math.max(1, Math.floor(grid.width / minCard));
                    return grid.width / cols;
                }
                cellHeight: 295
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { }

                delegate: Rectangle {
                    id: card
                    width: grid.cellWidth - 12
                    height: grid.cellHeight - 12
                    radius: 12
                    color: root.cardBg
                    border.color: cardHover.hovered
                        ? root.hover
                        : (model.nsfw
                            ? Qt.rgba(0.9, 0.35, 0.25, 0.6)
                            : root.border)
                    border.width: cardHover.hovered ? 1.6 : 1
                    scale: cardHover.hovered ? 1.03 : 1.0
                    z: cardHover.hovered ? 10 : 1
                    Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
                    Behavior on border.width { NumberAnimation { duration: 130 } }

                    property bool revealed: false

                    HoverHandler {
                        id: cardHover
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ── Preview ───────────────────────────────────────
                        Rectangle {
                            id: previewClip
                            Layout.fillWidth: true
                            Layout.preferredHeight: 122
                            Layout.margins: 7
                            Layout.bottomMargin: 0
                            color: root.cardAlt
                            clip: true

                            Image {
                                anchors.fill: parent
                                source: model.preview
                                fillMode: Image.PreserveAspectCrop
                                cache: false
                                asynchronous: true
                                opacity: (model.nsfw && root.safeMode >= 1 && !card.revealed) ? 0 : 1
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                            }

                            // NSFW cover: blurred-out placeholder + reveal.
                            Rectangle {
                                anchors.fill: parent
                                color: root.cardBg
                                opacity: (model.nsfw && root.safeMode >= 1 && !card.revealed) ? 1 : 0
                                visible: opacity > 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 6
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 34
                                        Layout.preferredHeight: 34
                                        radius: 17
                                        color: root.danger
                                        Kirigami.Icon {
                                            anchors.centerIn: parent
                                            width: 18
                                            height: 18
                                            source: "object-locked"
                                            color: "white"
                                        }
                                    }
                                    Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Hidden by Safe Mode"
                                        color: root.textDim
                                        font.pixelSize: 9
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: card.revealed = true
                                    Label {
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottomMargin: 4
                                        text: "Click to reveal"
                                        color: Qt.rgba(1, 1, 1, 0.5)
                                        font.pixelSize: 8
                                    }
                                }
                            }

                            // Small badge: NSFW / Installed
                            RowLayout {
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.margins: 5
                                spacing: 4

                                Rectangle {
                                    visible: model.nsfw
                                    radius: 4
                                    color: root.danger
                                    Label {
                                        text: "NSFW"
                                        color: "white"
                                        font.pixelSize: 8
                                        font.bold: true
                                        anchors.centerIn: parent
                                        anchors.margins: 2
                                    }
                                }
                                Rectangle {
                                    visible: model.installed
                                    radius: 4
                                    color: root.success
                                    Label {
                                        text: "Installed"
                                        color: "white"
                                        font.pixelSize: 8
                                        font.bold: true
                                        anchors.centerIn: parent
                                        anchors.margins: 2
                                    }
                                }
                            }
                        }

                        // ── Text block ─────────────────────────────────────
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.margins: 8
                            spacing: 4

                            Label {
                                Layout.preferredWidth: parent.width
                                Layout.preferredHeight: 28
                                text: model.title
                                wrapMode: Text.WordWrap
                                elide: Text.ElideRight
                                maximumLineCount: 2
                                font.bold: true
                                font.pixelSize: 10
                                color: root.text
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    Layout.fillWidth: true
                                    text: model.author ? model.author : ""
                                    elide: Text.ElideRight
                                    color: root.textDim
                                    font.pixelSize: 9
                                }
                                RowLayout {
                                    spacing: 1
                                    visible: model && Number(model.rating || 0) > 0
                                    Repeater {
                                        model: model ? Math.max(0, Math.floor(Number(model.rating) || 0)) : 0
                                        Kirigami.Icon {
                                            width: 10
                                            height: 10
                                            source: "starred"
                                            color: "#FFD700"
                                        }
                                    }
                                }
                            }
                        }

                        // ── Actions ────────────────────────────────────────
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: 8
                            Layout.bottomMargin: 8
                            spacing: 6
                            Button {
                                Layout.fillWidth: true
                                enabled: !(model.id === root.nowWorking)
                                text: model.installed
                                    ? "Local"
                                    : (model.id === root.nowWorking ? "Downloading…" : "Install")
                                icon.name: model.installed ? "document-open-folder" : "cloud-download"
                                onClicked: {
                                    if (model.installed)
                                        root.openItemFolder(model.id);
                                    else
                                        root.startInstall(model.id);
                                }
                            }
                            Button {
                                Layout.fillWidth: true
                                text: "Steam"
                                icon.name: "internet-web-browser"
                                icon.color: "#ffffff"
                                onClicked: Qt.openUrlExternally(WS.workshopUrl(model.id))
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            Layout.leftMargin: 8
                            Layout.rightMargin: 8
                            Layout.bottomMargin: 8
                            visible: model.installed
                            text: "Use Wallpaper"
                            icon.name: "view-preview"
                            onClicked: root.commitWallpaperFromId(model.id)
                        }
                    }
                }
            }
        }

        // Empty state
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.items.count === 0 && !root.loading
            spacing: 10

            Item { Layout.fillHeight: true }

            Kirigami.Icon {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 48
                Layout.preferredHeight: 48
                source: root.statusText ? "emblem-warning" : "edit-find"
                opacity: 0.45
                color: root.text
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.statusText || "Search the Steam Workshop for Wallpaper Engine wallpapers."
                color: root.textDim
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                visible: !root.statusText
                text: "Tip: pick a sort mode and search a vibe - anime, rain, city, space..."
                color: root.textFaint
                font.italic: true
                font.pixelSize: 10
            }

            Item { Layout.fillHeight: true }
        }

        // Pager
        RowLayout {
            Layout.fillWidth: true
            visible: root.items.count > 0
            spacing: 12

            Button {
                text: "Previous"
                icon.name: "go-previous"
                enabled: root.queryIndex > 1
                onClicked: root.fetch(root.queryIndex - 1)
            }
            Item { Layout.fillWidth: true }
            Label {
                text: "Page " + root.queryIndex + (root.totalPages > 1 ? " of " + root.totalPages : "")
                color: root.textDim
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "Next"
                icon.name: "go-next"
                enabled: root.queryIndex < root.totalPages
                onClicked: root.fetch(root.queryIndex + 1)
            }
        }
    }

    function commitWallpaperFromId(id) {
        if (installedIds[id] !== true) {
            root.startInstall(id);
            return;
        }
        if (!root.pyext) return;
        const itemDir = root._workshopDirNative + "/" + id;
        root.pyext.readfile(itemDir + "/project.json").then(txt => {
            const p = Utils.parseJson(txt);
            if (!p) return;
            if (!p.file || !p.type) {
                if (p.dependency && p.preset) {
                    statusText = "Installing dependency #" + p.dependency
                        + " and applying preset…";
                    root.presetRequested(id, String(p.dependency), p.preset);
                } else {
                    statusText = "Item #" + id
                        + " is a preset/effect (no file/type) and cannot be used directly.";
                }
                return;
            }
            const item = {
                workshopid: id,
                path: Qt.resolvedUrl(itemDir).toString(),
                file: p.file || "scene.json",
                type: (p.type || "scene").toLowerCase(),
                preview: p.preview || "",
                title: p.title || id,
                contentrating: p.contentrating || "Everyone",
                tags: []
            };
            root.commitWallpaper(item);
        });
    }


    Popup {
        id: wsCheckPopup
        modal: true
        focus: true
        anchors.centerIn: parent
        width: 500
        padding: 16
        background: Rectangle {
            color: root.panelBg
            border.color: root.accent
            border.width: 1
            radius: 10
        }
        property var missingList: []
        property var unsubList: []
        property var orphanList: []
        property string summaryText: "Running audit…"
        readonly property string _dlScript: root.nativePath(Qt.resolvedUrl("../../scripts/wek-download.py"))

        function runCheck(cleanOrphans, removeUnsub) {
            if (!root._libNative) {
                wsCheckPopup.summaryText = "Select your Steam library first.";
                return;
            }
            wsCheckPopup.summaryText = "Checking Workshop manifest and local folders…";
            let cmd = "/usr/bin/python3 " + root.shellQuote(_dlScript) + " --library " + root.shellQuote(root._libNative) + " --check";
            if (cleanOrphans) cmd += " --clean-orphans";
            if (removeUnsub) cmd += " --remove-unsubscribed";
            wsCheckRunner.connectSource(cmd);
        }

        P5Support.DataSource {
            id: wsCheckRunner
            engine: "executable"
            connectedSources: []
            onNewData: (source, data) => {
                const out = data && data.stdout ? String(data.stdout) : "";
                const code = data ? data["exit code"] : undefined;
                if (code === undefined || code === null || code === "") return;
                wsCheckRunner.disconnectSource(source);
                const lines = out.split("\n");
                for (let i = 0; i < lines.length; i++) {
                    const ln = lines[i].trim();
                    if (ln.indexOf("CHECK_JSON ") === 0) {
                        try {
                            const rep = JSON.parse(ln.slice(11));
                            wsCheckPopup.missingList = rep.missing_download || [];
                            wsCheckPopup.unsubList = rep.unsubscribed_local || [];
                            wsCheckPopup.orphanList = rep.orphans || [];
                            wsCheckPopup.summaryText = "Subscribed: " + (rep.subscribed_count || 0)
                                + " · Installed: " + (rep.downloaded_count || 0);
                            root.refreshInstalled();
                            root.wallpaperDownloaded();
                        } catch (e) {}
                    }
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: "Workshop Integrity Check"; color: root.text; font.bold: true; font.pixelSize: 14 }
            Label { text: wsCheckPopup.summaryText; color: root.textDim; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Label { text: "Missing downloads: " + wsCheckPopup.missingList.length; color: root.text }
            RowLayout {
                visible: wsCheckPopup.missingList.length > 0
                Button {
                    text: "Download Missing (" + wsCheckPopup.missingList.length + ")"
                    onClicked: {
                        if (wsCheckPopup.missingList.length > 0)
                            root.startInstall(String(wsCheckPopup.missingList[0]), true, false);
                        wsCheckPopup.close();
                    }
                }
                Button { text: "Skip"; onClicked: wsCheckPopup.missingList = [] }
            }
            Label { text: "Unsubscribed local items: " + wsCheckPopup.unsubList.length; color: root.text }
            RowLayout {
                visible: wsCheckPopup.unsubList.length > 0
                Button { text: "Delete Unsubscribed"; onClicked: wsCheckPopup.runCheck(false, true) }
                Button { text: "Keep"; onClicked: wsCheckPopup.unsubList = [] }
            }
            Label { text: "Orphaned / leftover folders: " + wsCheckPopup.orphanList.length; color: root.text }
            RowLayout {
                visible: wsCheckPopup.orphanList.length > 0
                Button { text: "Clean Orphans (" + wsCheckPopup.orphanList.length + ")"; onClicked: wsCheckPopup.runCheck(true, false) }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: "Close"; onClicked: wsCheckPopup.close() }
            }
        }
    }

    Component.onCompleted: {
        refreshInstalled();
        registerInstalledWatcher();
        fetch(1);
    }
}