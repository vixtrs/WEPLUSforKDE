import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Controls 2.3 as QQC
import QtQuick.Window 2.0 // for Screen
import QtQuick.Dialogs
import QtQuick.Layouts 1.5

import ".."
import "../components"

import "../js/utils.mjs" as Utils
import "../js/bbcode.mjs" as BBCode

import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.components as PlasmaComponents
// for kcm gridview
import org.kde.kcmutils as KCM
import org.kde.kirigami 2.6 as Kirigami
import org.kde.kquickcontrolsaddons 2.0

RowLayout {
    id: wpPage
    Layout.fillWidth: true

    // Наследуем тему от родителя
    Kirigami.Theme.inherit: true

    // Preset items (only "preset" + "dependency" in project.json) need the
    // base Workshop item. The config page downloads it and writes the preset
    // into the base wallpaper's user_props.
    signal presetApplyRequested(string presetId, string dependencyId, var preset)
    signal reinstallRequested(string itemId)
    property bool presetBusy: false
    property string presetMessage: ""
    property var deleteHelper: null

    function saveConfig() {
        right_opts.save_changes();
    }

    function requestPresetInstall(item) {
        if (!item || !item.dependency || !item.path) return;
        pyext.readfile(Common.urlNative(item.path + "/project.json")).then(txt => {
            const p = Utils.parseJson(txt);
            if (!p || !p.preset) {
                wpPage.presetMessage = "This item has no preset data.";
                return;
            }
            wpPage.presetApplyRequested(
                String(item.workshopid), String(item.dependency), p.preset);
        }).catch(reason => console.error("[WEK] preset read failed: " + reason));
    }
    
    Control {
        id: left_content
        Layout.fillWidth: true
        Layout.fillHeight: true
        topPadding: 8
        leftPadding: Kirigami.Units.largeSpacing
        rightPadding: 0
        bottomPadding: 0

        contentItem: ColumnLayout {
            id: wpselsect
            anchors.left: parent.left
            anchors.right: parent.right

            RowLayout {
                id: infoRow
                Layout.alignment: Qt.AlignHCenter
                spacing: 5

                Label {
                    visible: cfg_WallpaperWorkShopId
                    text: `Shopid: ${cfg_WallpaperWorkShopId}  Type: ${Common.unpackWallpaperSource(cfg_WallpaperSource).type}`
                    //${cfg_WallpaperType}
                }

                Kirigami.ActionToolBar {
                    Layout.fillWidth: true
                    alignment: Qt.AlignRight
                    flat: false

                    ActionGroup {
                        id: group_sort
                        exclusive: true
                    }
                    Component {
                        id: comp_action_filter
                        Kirigami.Action {
                            property int act_index;

                            checkable: false
                            checked: action_cb_filter.modelValues[act_index]
                            onTriggered: {
                                if(!checkable) return;
                                const modelValues = action_cb_filter.modelValues;
                                modelValues[act_index] = Number(!modelValues[act_index]);
                                cfg_FilterStr = Utils.intArrayToStr(modelValues);
                            }

                            Component.onCompleted: comp_action_sort.Component.destruction.connect(this.destroy)
                        }
                    }
                    Component {
                        id: comp_action_sort
                        Kirigami.Action {
                            ActionGroup.group: group_sort

                            property int act_value;
                            checkable: true
                            checked: {
                                checked = cfg_SortMode == act_value;
                            }
                            onTriggered: cfg_SortMode = act_value

                            Component.onCompleted: comp_action_sort.Component.destruction.connect(this.destroy)
                        }
                    }

                    actions: [
                        Kirigami.Action {
                            icon.name: "folder-symbolic"
                            text: 'Library'
                            tooltip: cfg_SteamLibraryPath ? cfg_SteamLibraryPath : 'Select steam library dir'
                            onTriggered: libraryModeDialog.open()
                        },
                        Kirigami.Action {
                            id: action_cb_filter
                            text: 'Filter'
                            icon.name: "view-filter"
                            property int currentIndex
                            readonly property var model: Common.filterModel
                            readonly property var modelValues: Common.filterModel.getValueArray(cfg_FilterStr)

                            children: model.map((el, index) => comp_action_filter.createObject(null, {
                                text: el.text, 
                                act_index: index,
                                checkable: el.type !== '_nocheck'
                            }))
                        },
                        Kirigami.Action {
                            id: action_cb_sort
                            text: model[currentIndex].short
                            icon.name: "view-sort-descending-symbolic"
                            property int currentIndex: Common.modelIndexOfValue(model, cfg_SortMode)
                            readonly property var model: [
                                {
                                    text: "Sort By Workshop Id",
                                    short: "Id",
                                    value: Common.SortMode.Id
                                },
                                {
                                    text: "Sort Alphabetically By Name",
                                    short: "Alphabetical",
                                    value: Common.SortMode.Name
                                },
                                {
                                    text: "Show Newest Modified First",
                                    short: "Modified",
                                    value: Common.SortMode.Modified
                                }
                            ]
                            children: model.map((el, index) => comp_action_sort.createObject(null, {text: el.text, act_value: el.value}))
                        },
                        Kirigami.Action {
                            icon.name: "view-refresh-symbolic"
                            text: 'Refresh'
                            onTriggered: wpListModel.refresh()
                        },
                        Kirigami.Action {
                            icon.name: "checkmark"
                            text: 'Check'
                            tooltip: 'Verify subscribed, downloaded and orphan wallpapers'
                            onTriggered: {
                                checkAuditDialog.runAudit(false, false);
                                checkAuditDialog.open();
                            }
                        }
                    ]
                }
            }

            Loader {
                id: picViewLoader
                Layout.fillWidth: true
                Layout.fillHeight: true
                
                // over wite the implicitWidth to 0
                Layout.preferredHeight: 0

                asynchronous: false
                sourceComponent: picViewCom
                visible: status == Loader.Ready

                Component.onCompleted: {
                    const refreshIndex = () => {
                        this.item.view.model = wpListModel.model; 
                        if(this.status == Loader.Ready) {
                            this.item.setCurIndex(wpListModel.model);
                        }
                    }
                    wpListModel.modelStartSync.connect(this.item.backtoBegin);
                    wpListModel.modelRefreshed.connect(refreshIndex.bind(this));
                }

                Kirigami.Heading {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    visible: picViewLoader.item && picViewLoader.item.view.count === 0
                    level: 2
                    text: {
                        if(!pyext.ok) {
                            return `Python helper run failed: ${pyext.log}`;
                        }
                        if(!cfg_SteamLibraryPath)
                            return "Select your steam library through the folder selecting button above";
                        if(wpListModel.countNoFilter > 0)
                            return `Found ${wpListModel.countNoFilter} wallpapers, but none of them matched filters`;
                        return `There are no wallpapers in steam library`;
                    }
                    opacity: 0.5
                }
            }
            Component {
                id: picViewCom
                WallpaperGrid {
                    id: picViewGrid
                    anchors.fill: parent

                    activeWorkshopId: cfg_WallpaperWorkShopId
                    iconSize: root.iconSizes.large
                    animatedPreviewActive: cfg_AnimatedPreview
                    showFavorites: true
                    showWorkshopLink: true
                    customConf: root.customConf
                    autoCommitOnIndexResolve: !cfg_WallpaperSource

                    onItemClicked: (item, index) => {
                        if (item.broken) return;
                        if (item.isPreset && item.dependency) {
                            cfg_WallpaperWorkShopId = item.workshopid;
                            if (item.basepath && item.basefile && item.basetype) {
                                cfg_WallpaperSource = Common.packWallpaperSource(item);
                            }
                            wpPage.requestPresetInstall(item);
                            return;
                        }
                        cfg_WallpaperSource = Common.packWallpaperSource(item);
                        cfg_WallpaperWorkShopId = item.workshopid;
                    }
                    onSaveCustomConfRequested: root.saveCustomConf()
                    onDeleteRequested: (item, index) => {
                        const dh = wpPage.deleteHelper || (typeof deleteHelper !== 'undefined' ? deleteHelper : null);
                        if (dh) dh.deleteWallpaper(item);
                    }
                }
            }

            QQC.Popup {
                id: libraryModeDialog
                modal: true
                focus: true
                anchors.centerIn: parent
                width: 440
                padding: 18
                background: Rectangle {
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.highlightColor
                    border.width: 1
                    radius: 10
                }
                property string detectStatus: ""
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 12
                    Label {
                        text: "Steam Library Configuration"
                        font.bold: true
                        font.pixelSize: 15
                        Layout.fillWidth: true
                    }
                    Label {
                        text: "Choose Automatic Detection to scan your drives for Wallpaper Engine (431960), or use Smart Manual Selection (accepts Steam, steamapps, workshop, or 431960 folders)."
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        opacity: 0.85
                    }
                    Label {
                        visible: Boolean(libraryModeDialog.detectStatus)
                        text: libraryModeDialog.detectStatus
                        color: Kirigami.Theme.positiveTextColor
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        P5Support.DataSource {
                            id: libDetectRunner
                            engine: "executable"
                            connectedSources: []
                            onNewData: (source, data) => {
                                const out = data && data.stdout ? String(data.stdout) : "";
                                const code = data ? data["exit code"] : undefined;
                                if (code === undefined || code === null || code === "") return;
                                libDetectRunner.disconnectSource(source);
                                const lines = out.split("\n");
                                for (let i = 0; i < lines.length; i++) {
                                    const ln = lines[i].trim();
                                    if (ln.indexOf("DETECTED_LIBRARY ") === 0) {
                                        const payload = ln.slice(17).trim();
                                        cfg_SteamLibraryPath = "file://" + payload;
                                        libraryModeDialog.detectStatus = "Detected: " + payload;
                                        wpListModel.refresh();
                                        libraryModeDialog.close();
                                        return;
                                    }
                                }
                                libraryModeDialog.detectStatus = "Auto-detect could not find a library with Workshop 431960 items. Please use Smart Manual Mode.";
                            }
                        }
                        QQC.Button {
                            Layout.fillWidth: true
                            icon.name: "search"
                            text: "Auto-Detect Library"
                            onClicked: {
                                libraryModeDialog.detectStatus = "Scanning Steam libraryfolders.vdf and mounted drives…";
                                let dlScript = Common.urlNative(Qt.resolvedUrl("../../scripts/wek-download.py"));
                                try { dlScript = decodeURIComponent(dlScript); } catch (e) {}
                                const q = "'" + String(dlScript).replace(/'/g, "'\\''") + "'";
                                libDetectRunner.connectSource("python3 " + q + " --detect-library");
                            }
                        }
                        QQC.Button {
                            Layout.fillWidth: true
                            icon.name: "folder-open"
                            text: "Smart Manual Mode…"
                            onClicked: {
                                libraryModeDialog.close();
                                wpDialog.open();
                            }
                        }
                    }
                }
            }


            QQC.Popup {
                id: checkAuditDialog
                modal: true
                focus: true
                anchors.centerIn: parent
                width: 520
                padding: 18
                background: Rectangle {
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.highlightColor
                    border.width: 1
                    radius: 10
                }
                property bool busy: false
                property int subCount: 0
                property int dlCount: 0
                property var missingList: []
                property var unsubList: []
                property var orphanList: []
                property string statusMsg: ""
                readonly property string _dlScript: Common.urlNative(Qt.resolvedUrl("../../scripts/wek-download.py"))

                function shellQuote(s) {
                    return "'" + String(s).replace(/'/g, "'\\''") + "'";
                }

                function runAudit(cleanOrphans, removeUnsub) {
                    if (!cfg_SteamLibraryPath) {
                        checkAuditDialog.statusMsg = "Select a Steam library first.";
                        return;
                    }
                    checkAuditDialog.busy = true;
                    checkAuditDialog.statusMsg = "Checking subscriptions and local files…";
                    let lib = Common.urlNative(cfg_SteamLibraryPath);
                    try { lib = decodeURIComponent(lib); } catch (e) {}
                    let cmd = "/usr/bin/python3 " + shellQuote(_dlScript) + " --library " + shellQuote(lib) + " --check";
                    if (cleanOrphans) cmd += " --clean-orphans";
                    if (removeUnsub) cmd += " --remove-unsubscribed";
                    checkAuditRunner.connectSource(cmd);
                }

                P5Support.DataSource {
                    id: checkAuditRunner
                    engine: "executable"
                    connectedSources: []
                    onNewData: (source, data) => {
                        const out = data && data.stdout ? String(data.stdout) : "";
                        const code = data ? data["exit code"] : undefined;
                        if (code === undefined || code === null || code === "") return;
                        checkAuditRunner.disconnectSource(source);
                        checkAuditDialog.busy = false;
                        const lines = out.split("\n");
                        for (let i = 0; i < lines.length; i++) {
                            const ln = lines[i].trim();
                            if (ln.indexOf("CHECK_JSON ") === 0) {
                                try {
                                    const rep = JSON.parse(ln.slice(11));
                                    checkAuditDialog.subCount = rep.subscribed_count || 0;
                                    checkAuditDialog.dlCount = rep.downloaded_count || 0;
                                    checkAuditDialog.missingList = rep.missing_download || [];
                                    checkAuditDialog.unsubList = rep.unsubscribed_local || [];
                                    checkAuditDialog.orphanList = rep.orphans || [];
                                    checkAuditDialog.statusMsg = "Audit complete: " + checkAuditDialog.subCount + " subscribed, " + checkAuditDialog.dlCount + " installed.";
                                    wpListModel.refresh();
                                } catch (e) {
                                    checkAuditDialog.statusMsg = "Failed to parse audit report.";
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 10
                    Label {
                        text: "Workshop Subscription & Integrity Check"
                        font.bold: true
                        font.pixelSize: 15
                        Layout.fillWidth: true
                    }
                    Label {
                        text: checkAuditDialog.statusMsg
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Kirigami.Theme.separatorColor
                    }
                    Label {
                        text: "1. Subscribed but NOT downloaded: " + checkAuditDialog.missingList.length
                            + (checkAuditDialog.missingList.length > 0 ? " (" + checkAuditDialog.missingList.slice(0, 6).join(", ") + ")" : "")
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        visible: checkAuditDialog.missingList.length > 0
                        spacing: 8
                        QQC.Button {
                            text: "Download Missing (" + checkAuditDialog.missingList.length + ")"
                            icon.name: "cloud-download"
                            enabled: !checkAuditDialog.busy
                            onClicked: {
                                for (let i = 0; i < checkAuditDialog.missingList.length; i++) {
                                    wpPage.reinstallRequested(String(checkAuditDialog.missingList[i]));
                                }
                                checkAuditDialog.statusMsg = "Queued download for " + checkAuditDialog.missingList.length + " missing item(s).";
                            }
                        }
                        QQC.Button {
                            text: "Dismiss / Skip"
                            onClicked: checkAuditDialog.missingList = []
                        }
                    }
                    Label {
                        text: "2. Downloaded locally but NO LONGER subscribed: " + checkAuditDialog.unsubList.length
                            + (checkAuditDialog.unsubList.length > 0 ? " (" + checkAuditDialog.unsubList.slice(0, 6).join(", ") + ")" : "")
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        visible: checkAuditDialog.unsubList.length > 0
                        spacing: 8
                        QQC.Button {
                            text: "Remove Unsubscribed (" + checkAuditDialog.unsubList.length + ")"
                            icon.name: "edit-delete"
                            enabled: !checkAuditDialog.busy
                            onClicked: checkAuditDialog.runAudit(false, true)
                        }
                        QQC.Button {
                            text: "Keep Local Copies"
                            onClicked: checkAuditDialog.unsubList = []
                        }
                    }
                    Label {
                        text: "3. Orphaned / leftover folders from incomplete deletes: " + checkAuditDialog.orphanList.length
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        visible: checkAuditDialog.orphanList.length > 0
                        spacing: 8
                        QQC.Button {
                            text: "Clean Leftovers / Junk (" + checkAuditDialog.orphanList.length + ")"
                            icon.name: "edit-clear-history"
                            enabled: !checkAuditDialog.busy
                            onClicked: checkAuditDialog.runAudit(true, false)
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Item { Layout.fillWidth: true }
                        QQC.Button {
                            text: "Re-Scan"
                            icon.name: "view-refresh"
                            enabled: !checkAuditDialog.busy
                            onClicked: checkAuditDialog.runAudit(false, false)
                        }
                        QQC.Button {
                            text: "Close"
                            onClicked: checkAuditDialog.close()
                        }
                    }
                }
            }

            FolderDialog {
                id: wpDialog
                title: "Select Steam Library, steamapps, workshop, or 431960 folder"
                onAccepted: {
                    let raw = Utils.trimCharR(wpDialog.selectedFolder.toString(), '/');
                    // Smart normalization: strip /steamapps/workshop/content/431960/<id> if user clicked deeper
                    raw = raw.replace(/\/steamapps(\/workshop(\/content(\/431960(\/[0-9]+)?)?)?)?$/i, "");
                    raw = raw.replace(/\/workshop(\/content(\/431960(\/[0-9]+)?)?)?$/i, "");
                    raw = raw.replace(/\/content(\/431960(\/[0-9]+)?)?$/i, "");
                    raw = raw.replace(/\/431960(\/[0-9]+)?$/i, "");
                    cfg_SteamLibraryPath = raw;
                    return wpListModel.refresh();
                }
            }
        }
    }

    Control {
        id: right_content
        Layout.preferredWidth: parent.width / 3
        Layout.fillHeight: true

        readonly property int image_size: 300
        readonly property int content_margin: 16
        property var wpmodel: { 
            return picViewLoader.item.currentModel
            ? Common.wpitemFromQtObject(picViewLoader.item.currentModel)
            : Common.wpitem_template;
        }

        visible: Layout.preferredWidth > image_size + content_margin*2 + right_content_scrollbar.width

        topPadding: 0
        leftPadding: 0
        rightPadding: 0
        bottomPadding: 0

        background: Rectangle {
            color: Kirigami.Theme.backgroundColor
        }

        contentItem: Flickable {
            anchors.fill: parent

            ScrollBar.vertical: ScrollBar { id: right_content_scrollbar }

            contentWidth: width - (right_content_scrollbar.visible ? right_content_scrollbar.width : 0)
            contentHeight: flick_content.implicitHeight

            clip: true
            boundsBehavior: Flickable.OvershootBounds

            ColumnLayout {
                id: flick_content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: right_content.content_margin
                anchors.rightMargin: anchors.leftMargin
                spacing: 8

                AnimatedImage { 
                    id: animated_image; 
                    Layout.topMargin: right_content.content_margin
                    Layout.preferredWidth: right_content.image_size
                    Layout.preferredHeight: Layout.preferredWidth
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop

                    source: Common.getWpModelPreviewSource(right_content.wpmodel)
                    fillMode: Image.PreserveAspectFit
                    cache: true
                    asynchronous: true
                    onStatusChanged: playing = (status == AnimatedImage.Ready)
                }

                Text {
                    Layout.alignment: Qt.AlignTop
                    Layout.minimumWidth: 0
                    Layout.fillWidth: true
                    Layout.minimumHeight: implicitHeight

                    text: right_content.wpmodel.title
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    Layout.fillWidth: true
                    visible: right_content.wpmodel.broken
                    text: right_content.wpmodel.dependency
                        ? "Preset / dependent item: requires Workshop "
                          + right_content.wpmodel.dependency
                        : "Incomplete download or unsupported wallpaper type"
                    color: "#ff5c5c"
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 10
                }

                QQC.Button {
                    Layout.fillWidth: true
                    visible: Boolean(right_content.wpmodel.dependency)
                    enabled: !wpPage.presetBusy
                    text: wpPage.presetBusy
                        ? "Installing dependency…"
                        : "Install dependency #" + right_content.wpmodel.dependency
                          + " and apply preset"
                    icon.name: "cloud-download"
                    onClicked: wpPage.requestPresetInstall(right_content.wpmodel)
                }

                QQC.Button {
                    Layout.fillWidth: true
                    visible: Boolean(right_content.wpmodel.workshopid)
                    enabled: !wpPage.presetBusy
                    text: right_content.wpmodel.broken ? "Reinstall this item" : "Reinstall / Verify this item"
                    icon.name: "view-refresh"
                    onClicked: wpPage.reinstallRequested(
                        String(right_content.wpmodel.workshopid))
                }

                Text {
                    Layout.fillWidth: true
                    visible: Boolean(wpPage.presetMessage)
                    text: wpPage.presetMessage
                    color: Kirigami.Theme.textColor
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 10
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    spacing: 8

                    Control {
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Kirigami.Theme.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                            text: right_content.wpmodel.type
                        }
                    }

                    Control {
                        id: control_dir_size
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding
                        visible: false

                        background: Rectangle {
                            color: Kirigami.Theme.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                            readonly property bool _set_text: {
                                const dir = right_content.wpmodel.path;
                                if(!dir.match(Common.regex_path_check)) {
                                    control_dir_size.visible = false;
                                    return false;
                                }
                                pyext.get_dir_size(Common.urlNative(dir)).then(res => {
                                    this.text = Utils.prettyBytes(res);
                                    control_dir_size.visible = true;
                                }).catch(reason => console.error(reason));
                                return true;
                            }
                        }
                    }

                    Kirigami.ActionToolBar {
                        Layout.fillWidth: false
                        Layout.preferredWidth: implicitWidth
                        flat: true

                        actions: [
                            Kirigami.Action {
                                id: right_act_favor
                                
                                icon.name: right_content.wpmodel.favor 
                                    ? "bookmarks-symbolic"
                                    : "bookmark-add-symbolic"
                                tooltip: right_content.wpmodel.favor
                                    ? 'Remove from favorites'
                                    : 'Add to favorites'
                                onTriggered: picViewLoader.item.toggleFavor(right_content.wpmodel)
                            },
                            Kirigami.Action {
                                icon.name: "emblem-symbolic-link"
                                tooltip: "Open Workshop Link"
                                enabled: right_content.wpmodel.workshopid.match(Common.regex_workshop_online)
                                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(right_content.wpmodel.workshopid))
                            },
                            Kirigami.Action {
                                icon.name: "folder-symbolic"
                                tooltip: "Open Containing Folder"
                                onTriggered: Qt.openUrlExternally(right_content.wpmodel.path) 
                            }
                        ]
                    }
                }

                ListView {
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    implicitWidth: contentItem.childrenRect.width
                    implicitHeight: contentItem.childrenRect.height

                    orientation: ListView.Horizontal
                    model: ListModel {}
                    readonly property bool _set_model: {
                        const wpmodel = right_content.wpmodel;
                        const tags = right_content.wpmodel.tags;
                        const playlists = right_content.wpmodel.playlists;
                        const _model = this.model;
                        _model.clear();
                        for(const i of Array(tags.length).keys())
                            _model.append(tags.get(i));
                        for(const i of Array(playlists.length).keys()){
                            var playlist = playlists.get(i);
                            if(playlist != null) { _model.append(playlists.get(i)); }
                        }
                        _model.append({key: wpmodel.contentrating});
                        return true;
                    }
                    clip: false
                    spacing: 8

                    delegate: Control {
                        leftPadding: 8
                        topPadding: 4
                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Kirigami.Theme.activeBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            text: model.key
                        }
                    }
                }

                Component {
                    id: right_opt_combox
                    ComboBox {
                        property var def_val

                        textRole: "text"
                        onActivated: {}

                        property var res_val: currentIndex >= 0 ? Common.cbCurrentValue(this) : def_val
                        function finish() {
                            currentIndex = Common.cbIndexOfValue(this, def_val);
                        }
                    }
                }
                Component {
                    id: right_opt_switch
                    Switch {
                        property bool def_val
                        property bool res_val: checked
                        function finish() {
                            checked = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_spinbox
                    SpinBox {
                        property int def_val
                        property int res_val: value
                        function finish() {
                            value = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_dspinbox
                    DoubleSpinBox {
                        property real def_val
                        property real res_val: dValue
                        function finish() {
                            dValue = def_val;
                        }
                    }
                }

                OptionGroup {
                    id: right_opts
                    Layout.fillWidth: true

                    readonly property string workshopid: right_content.wpmodel.workshopid

                    property var config_resets: new Set()
                    property var config_changes: ({})
                    property var config: ({})

                    onWorkshopidChanged: {
                        if (workshopid) {
                            pyext.read_wallpaper_config(workshopid).then(res => {
                                config = res;
                            });
                        } else {
                            config = {};
                        }
                    }
                    Component.onCompleted: {
                        if (workshopid) {
                            pyext.read_wallpaper_config(workshopid).then(res => {
                                config = res;
                            });
                        }
                    }
                    function save_changes() {
                        console.log("save_changes called, config_changes:", JSON.stringify(config_changes));
                        config_resets.forEach((wid) => {
                            pyext.reset_wallpaper_config(wid).then(res => {});
                        });
                        Object.entries(config_changes).forEach(([wid, cfg]) => {
                            console.log("saving config for wid:", wid, "cfg:", JSON.stringify(cfg));
                            pyext.write_wallpaper_config(wid, cfg);
                        });
                        // Clear after saving
                        config_changes = {};
                        config_resets.clear();
                    }
                    function set_config(key, val) {
                        console.log("set_config called, key:", key, "val:", val, "workshopid:", workshopid);
                        if(!key || !workshopid) return;

                        if (!config_changes[workshopid])
                            config_changes[workshopid] = {}
                        config_changes[workshopid][key] = val;

                        this.config_changesChanged();

                        // Write to disk immediately (like savePropChange does)
                        const cfg = {};
                        cfg[key] = val;
                        pyext.write_wallpaper_config(workshopid, cfg);

                        console.log("set_config: cfg_PerOptChanged before:", cfg_PerOptChanged);
                        cfg_PerOptChanged++;
                        console.log("set_config: cfg_PerOptChanged after:", cfg_PerOptChanged);
                    }
                    function reset_config() {
                        config_resets.add(workshopid);
                        delete config_changes[workshopid];
                        config = {}
                        // Write reset to disk immediately
                        pyext.reset_wallpaper_config(workshopid);
                        cfg_PerOptChanged++;
                    }
                    function in_config_changes(key) {
                        return config_changes.hasOwnProperty(workshopid) && config_changes[workshopid].hasOwnProperty(key);
                    }

                    function get_config_val(key) {
                        if (in_config_changes(key))
                            return config_changes[workshopid][key];
                        if (config.hasOwnProperty(key))
                            return config[key];
                        return null;
                    }
                    function has_change(key) {
                        return config.hasOwnProperty(key) || in_config_changes(key);
                    }

                    header.text: 'Option'
                    header.text_color: Kirigami.Theme.textColor
                    header.icon: '../../images/cheveron-down.svg'
                    header.color: Kirigami.Theme.activeBackgroundColor

                    header.actor: Kirigami.ActionToolBar {
                        Layout.fillWidth: true
                        alignment: Qt.AlignRight
                        flat: true
                        actions: [
                            Kirigami.Action {
                                text: 'Reset'
                                onTriggered: {
                                    right_opts.reset_config();
                                }
                            }
                        ]
                    }
                    Repeater {
                        property bool markModel: false;
                        model: [
                            {
                                mark_: markModel,
                                text: 'Display',
                                config_key: 'display_mode',
                                comp: right_opt_combox,
                                props: {
                                    model: [
                                        {
                                            text: "Keep Aspect Ratio",
                                            value: Common.DisplayMode.Aspect
                                        },
                                        {
                                            text: "Scale and Crop",
                                            value: Common.DisplayMode.Crop
                                        },
                                        {
                                            text: "Scale to Fill",
                                            value: Common.DisplayMode.Scale
                                        },
                                    ],
                                    def_val: cfg_DisplayMode,
                                }
                            },
                            {
                                text: 'Mute Audio',
                                config_key: 'mute_audio',
                                comp: right_opt_switch,
                                props: {
                                    def_val: cfg_MuteAudio
                                },
                            },
                            {
                                text: 'Volume',
                                config_key: 'volume', 
                                comp: right_opt_spinbox,
                                props: {
                                    def_val: cfg_Volume,
                                    from: 1,
                                    to: 100,
                                    stepSize: 1,
                                },
                            },
                            {
                                text: 'Speed',
                                config_key: 'speed', 
                                comp: right_opt_dspinbox,
                                props: {
                                    def_val: cfg_Speed,
                                    dFrom: 0.1,
                                    dTo: 16,
                                    dStepSize: 0.1,
                                },
                            },

                        ]
                        OptionItem {
                            text: modelData.text
                            text_color: Kirigami.Theme.textColor

                            property bool is_changed: right_opts.config && 
                                right_opts.config_changes && 
                                right_opts.has_change(modelData.config_key)

                            icon: is_changed ? Qt.resolvedUrl('../../images/edit-pencil.svg') : ''
                            actor: Loader {
                                sourceComponent: modelData.comp
                                onLoaded: {
                                    Object.entries(modelData.props).forEach(([key, value]) => {
                                        this.item[key] = value;
                                    });
                                    const changed_val = right_opts.get_config_val(modelData.config_key);
                                    if(changed_val !== null) {
                                        this.item['def_val'] = changed_val;
                                    }

                                    this.item.finish();
                                    this.item.onRes_valChanged.connect(() => {
                                        right_opts.set_config(modelData.config_key, this.item.res_val);
                                    });
                                }
                            }
                        }
                        Component.onCompleted: {
                            right_opts.onConfigChanged.connect(() => {
                                markModel = !markModel;
                            });
                        }
                    }
                }
                // User Properties from project.json
                Component {
                    id: user_prop_color
                    ColorButton { }
                }

                OptionGroup {
                    id: user_props_group
                    Layout.fillWidth: true
                    visible: user_props_repeater.model.length > 0

                    readonly property string workshopid: right_content.wpmodel.workshopid
                    onWorkshopidChanged: {
                        // Load saved config FIRST so it's available when Repeater creates delegates
                        propChanges = {};
                        if (workshopid) {
                            pyext.read_wallpaper_config(workshopid).then(res => {
                                propConfig = res || {};
                            });
                            pyext.read_active_bindings(workshopid).then(res => {
                                activeBindings = res || [];
                            });
                        } else {
                            propConfig = {};
                            activeBindings = [];
                        }
                        // Clear last — this triggers _loadProps → userProperties → Repeater rebuild
                        userProperties = [];
                    }

                    property var userProperties: []
                    property var propConfig: ({})
                    property var propChanges: ({})
                    property var activeBindings: []

                    property bool _loadProps: {
                        // Force re-evaluation when workshopid changes
                        const wid = workshopid;
                        const wpPath = right_content.wpmodel.path;
                        const projectPath = Common.getWpModelProjectPath(right_content.wpmodel);
                        if (wid && wpPath && wpPath.match(Common.regex_path_check)) {
                            pyext.readfile(Common.urlNative(projectPath)).then(value => {
                                const project = Utils.parseJson(value);
                                if (project && project.general && project.general.properties) {
                                    const props = project.general.properties;
                                    const arr = [];
                                    // Helper to convert localization keys to readable text
                                    function formatLabel(text, key) {
                                        if (!text) return key;
                                        // Convert "ui_browse_properties_XXX" to "Xxx Yyy"
                                        if (text.startsWith('ui_browse_properties_')) {
                                            const suffix = text.replace('ui_browse_properties_', '');
                                            return suffix.split('_').map(w =>
                                                w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
                                            ).join(' ');
                                        }
                                        // Strip HTML tags
                                        let cleaned = text.replace(/<[^>]*>/g, ' ');
                                        // Collapse whitespace
                                        cleaned = cleaned.replace(/\s+/g, ' ').trim();
                                        return cleaned || key;
                                    }
                                    for (const key in props) {
                                        const prop = props[key];
                                        // Skip non-interactive types (info text, groups)
                                        if (!prop.type || prop.type === 'text' || prop.type === 'group')
                                            continue;
                                        arr.push({
                                            key: key,
                                            text: formatLabel(prop.text, key),
                                            type: prop.type,
                                            value: prop.value,
                                            min: prop.min,
                                            max: prop.max,
                                            options: prop.options
                                        });
                                    }
                                    userProperties = arr;
                                } else {
                                    userProperties = [];
                                }
                            }).catch(reason => {
                                console.error(`read project.json error: ${reason}`);
                                userProperties = [];
                            });
                        } else {
                            userProperties = [];
                        }
                        return true;
                    }

                    function savePropChange(key, val) {
                        if (!workshopid) return;

                        // Create new object to trigger QML binding update
                        const newChanges = Object.assign({}, propChanges);
                        newChanges[key] = val;
                        propChanges = newChanges;

                        // Build config to save: merge with existing under 'user_props' key
                        const userPropsConfig = {};
                        userPropsConfig['user_props'] = Object.assign({}, propConfig['user_props'] || {}, propChanges);
                        pyext.write_wallpaper_config(workshopid, userPropsConfig);

                        // Signal main.qml to reload config
                        cfg_PerOptChanged++;
                    }

                    function getPropValue(key, defaultVal) {
                        if (propChanges.hasOwnProperty(key)) return propChanges[key];
                        if (propConfig['user_props'] && propConfig['user_props'].hasOwnProperty(key))
                            return propConfig['user_props'][key];
                        return defaultVal;
                    }

                    function resetUserProps() {
                        propChanges = {};
                        const resetConfig = { 'user_props': {} };
                        pyext.write_wallpaper_config(workshopid, resetConfig);
                        propConfig = {};

                        // Signal main.qml to reload config
                        cfg_PerOptChanged++;
                    }

                    header.text: 'User Properties'
                    header.text_color: Kirigami.Theme.textColor
                    header.icon: '../../images/cheveron-down.svg'
                    header.color: Kirigami.Theme.activeBackgroundColor

                    header.actor: Kirigami.ActionToolBar {
                        Layout.fillWidth: true
                        alignment: Qt.AlignRight
                        flat: true
                        actions: [
                            Kirigami.Action {
                                text: 'Reset'
                                onTriggered: user_props_group.resetUserProps()
                            }
                        ]
                    }

                    Repeater {
                        id: user_props_repeater
                        model: user_props_group.userProperties

                        OptionItem {
                            text: modelData.text
                            text_color: Kirigami.Theme.textColor

                            // Gray out properties not bound to any shader
                            property bool isBound: true
                            enabled: true
                            opacity: 1.0

                            property bool is_changed: user_props_group.propChanges.hasOwnProperty(modelData.key)
                            icon: is_changed ? Qt.resolvedUrl('../../images/edit-pencil.svg') : ''

                            actor: Loader {
                                sourceComponent: {
                                    switch(modelData.type) {
                                        case 'bool':
                                            return right_opt_switch;
                                        case 'slider':
                                            // Use int spinbox if min/max are integers
                                            const hasDecimals = (modelData.min && modelData.min % 1 !== 0) ||
                                                               (modelData.max && modelData.max % 1 !== 0) ||
                                                               (modelData.value && modelData.value % 1 !== 0);
                                            return hasDecimals ? right_opt_dspinbox : right_opt_spinbox;
                                        case 'color':
                                            return user_prop_color;
                                        case 'combo':
                                            return right_opt_combox;
                                        default:
                                            return null;
                                    }
                                }

                                onLoaded: {
                                    const savedVal = user_props_group.getPropValue(modelData.key, null);
                                    const defVal = savedVal !== null ? savedVal : modelData.value;

                                    switch(modelData.type) {
                                        case 'bool':
                                            this.item.def_val = Boolean(defVal);
                                            break;
                                        case 'slider':
                                            const hasDecimals = (modelData.min && modelData.min % 1 !== 0) ||
                                                               (modelData.max && modelData.max % 1 !== 0) ||
                                                               (modelData.value && modelData.value % 1 !== 0);
                                            if (hasDecimals) {
                                                this.item.dFrom = modelData.min || 0;
                                                this.item.dTo = modelData.max || 100;
                                                this.item.dStepSize = (modelData.max - modelData.min) / 100 || 0.01;
                                                this.item.def_val = defVal || 0;
                                            } else {
                                                this.item.from = Math.floor(modelData.min || 0);
                                                this.item.to = Math.floor(modelData.max || 100);
                                                this.item.stepSize = 1;
                                                this.item.def_val = Math.floor(defVal || 0);
                                            }
                                            break;
                                        case 'color':
                                            // Color can be string "0.1 0.2 0.3" or object {r,g,b}
                                            let colorVal = "#ffffff";
                                            if (typeof defVal === 'string' && defVal.includes(' ')) {
                                                const parts = defVal.split(' ').map(Number);
                                                if (parts.length >= 3) {
                                                    colorVal = Qt.rgba(parts[0], parts[1], parts[2], 1.0);
                                                }
                                            } else if (defVal && typeof defVal === 'string') {
                                                colorVal = defVal;
                                            }
                                            this.item.def_val = colorVal;
                                            this.item.colorValue = colorVal;
                                            break;
                                        case 'combo':
                                            // Build model from options
                                            if (modelData.options) {
                                                const comboModel = [];
                                                for (const opt of modelData.options) {
                                                    let label = String(opt.label || opt.value);
                                                    // Convert localization keys to readable text
                                                    if (label.startsWith('ui_browse_properties_')) {
                                                        const suffix = label.replace('ui_browse_properties_', '');
                                                        label = suffix.split('_').map(w =>
                                                            w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
                                                        ).join(' ');
                                                    }
                                                    // Strip HTML tags
                                                    label = label.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
                                                    comboModel.push({
                                                        text: label,
                                                        value: opt.value
                                                    });
                                                }
                                                this.item.model = comboModel;
                                                this.item.def_val = defVal || 0;
                                            }
                                            break;
                                    }

                                    this.item.finish();
                                    this.item.onRes_valChanged.connect(() => {
                                        user_props_group.savePropChange(modelData.key, this.item.res_val);
                                    });
                                }
                            }
                        }
                    }
                }

                PlasmaComponents.TextArea {
                    id: descriptionTextArea
                    Layout.alignment: Qt.AlignTop
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.minimumHeight: implicitHeight

                    visible: false
                    text: ''
                    color: Kirigami.Theme.textColor

                    function loadDescription() {
                        const path = Common.getWpModelProjectPath(right_content.wpmodel);
                        if (path) {
                            pyext.readfile(Common.urlNative(path)).then(value => {
                                const project = Utils.parseJson(value);
                                const desc = project && project.description ? project.description : '';
                                descriptionTextArea.visible = Boolean(desc);
                                if (descriptionTextArea.visible) {
                                    // Remote <img> tags make QML try to open
                                    // https://... as local files. Keep the
                                    // formatted text/links, drop embedded images.
                                    descriptionTextArea.text = String(BBCode.parser.parse(desc))
                                        .replace(/<img\b[^>]*>/gi, "");
                                }
                            }).catch(reason => console.error(`read '${path}' error\n`, reason));
                        } else {
                            descriptionTextArea.visible = false;
                        }
                    }

                    Connections {
                        target: right_content
                        function onWpmodelChanged() {
                            descriptionTextArea.loadDescription();
                        }
                    }
                    Component.onCompleted: loadDescription()

                    font.bold: false
 
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                    horizontalAlignment: Text.AlignLeft
                    readOnly: true

                    onLinkActivated: Qt.openUrlExternally(link)
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                        acceptedButtons: Qt.NoButton
                    }
                }
            }
        }
    }
}
