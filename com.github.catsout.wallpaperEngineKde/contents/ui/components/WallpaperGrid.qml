// Shared grid surface used by both WallpaperPage (WE wallpapers) and
// VideoPage (plain videos). Source-agnostic: emits intent (itemClicked,
// favorToggled) and lets the parent page decide what to do.
import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Controls 2.3 as QQCClient
import QtQuick.Layouts 1.5
import QtQuick.Window 2.0

import ".."

import org.kde.plasma.core as PlasmaCore
import org.kde.kcmutils as KCM
import org.kde.kirigami 2.6 as Kirigami

KCM.GridView {
    id: root

    // ── Public API ───────────────────────────────────────────────────────────
    property string activeWorkshopId: ""
    property int    iconSize: 48
    property bool   animatedPreviewActive: true   // bind from cfg_AnimatedPreview on WE
    property bool   showFavorites: true
    property bool   showWorkshopLink: true
    property bool   showDelete: true              // hide on VideoPage (local videos)
    property var    customConf: null              // {favor: Set} when showFavorites
    property var    _disabledSet: []             // local disabled-in-random tracking
    signal itemClicked(var item, int index)
    signal favorToggled(var item, int index)
    signal randomExcludeToggled(var item, int index)
    signal saveCustomConfRequested()
    signal deleteRequested(var item, int index)

    // ── Internal state preserved from original implementation ────────────────
    readonly property var currentModel: view.model.get(view.currentIndex)
    readonly property var defaultModel: ListModel {}
    visible: view.count > 0

    view.implicitCellWidth: Screen.width / 10 + Kirigami.Units.smallSpacing * 2
    view.implicitCellHeight: Screen.height / 10 + Kirigami.Units.smallSpacing * 2 + Kirigami.Units.gridUnit * 3
    view.model: defaultModel
    view.delegate: KCM.GridDelegate {
        text: model.broken ? title + " (roto)" : title
        hoverEnabled: true
        actions: [
            Kirigami.Action {
                visible: root.showFavorites
                icon.name: favor ? "user-bookmarks-symbolic" : "bookmark-add-symbolic"
                tooltip: favor ? "Remove from favorites" : "Add to favorites"
                onTriggered: root.toggleFavor(model, index)
            },
            Kirigami.Action {
                icon.name: model.disabledInRandom ? "media-playlist-shuffle-symbolic" : "media-playlist-shuffle"
                icon.color: model.disabledInRandom ? "#e74c3c" : undefined
                tooltip: model.disabledInRandom ? "Excluded from random — click to include" : "Included in random — click to exclude"
                onTriggered: root.toggleRandomExclude(model, index)
            },
            Kirigami.Action {
                visible: root.showWorkshopLink
                icon.name: "folder-remote-symbolic"
                tooltip: "Open Workshop Link"
                enabled: workshopid && workshopid.match(Common.regex_workshop_online)
                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(workshopid))
            },
            Kirigami.Action {
                visible: root.showDelete
                icon.name: "edit-delete"
                tooltip: "Delete Wallpaper"
                onTriggered: root.deleteRequested(model, index)
            }
        ]
        QQCClient.Menu {
            id: delMenu
            property var target
            QQCClient.MenuItem {
                text: "Delete Wallpaper"
                icon.name: "edit-delete"
                onTriggered: {
                    if (delMenu.target) {
                        root.deleteRequested(delMenu.target, view.currentIndex);
                        delMenu.target = null;
                    }
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            z: 10
            cursorShape: Qt.ArrowCursor
            visible: root.showDelete
            onClicked: (mouse) => {
                view.currentIndex = index;
                delMenu.target = model;
                delMenu.popup(mouse.x, mouse.y);
            }
        }
        thumbnail: Rectangle {
            anchors.fill: parent
            color: "transparent"

            Kirigami.Icon {
                anchors.centerIn: parent
                width: root.iconSize
                height: width
                source: "view-preview"
                visible: imgPre.status !== Loader.Ready || (imgPre.item && !imgPre.item.visible)
            }

            Loader {
                id: imgPre
                anchors.fill: parent
                sourceComponent: root.animatedPreviewActive ? animatedPre : staticPre
            }

            Component {
                id: animatedPre
                AnimatedImage {
                    anchors.fill: parent
                    source: Common.getWpModelPreviewSource(model);
                    sourceSize.width: parent.width
                    fillMode: Image.PreserveAspectCrop
                    clip: true
                    cache: false
                    asynchronous: true
                    smooth: true
                    visible: true
                    paused: false
                    onVisibleChanged: paused = !visible
                    onStatusChanged: playing = (status == AnimatedImage.Ready)
                }
            }

            Component {
                id: staticPre
                Image {
                    anchors.fill: parent
                    source: Common.getWpModelPreviewSource(model);
                    sourceSize.width: parent.width
                    sourceSize.height: parent.height
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    asynchronous: true
                    smooth: true
                    visible: Boolean(preview)
                }
            }
        }
        onClicked: {
            view.currentIndex = index;
            root.itemClicked(model, index);
        }
    }

    function backtoBegin() {
        view.model = defaultModel
    }

    // When true, setCurIndex emits itemClicked for the resolved index (used
    // by WE page on first run when no wallpaper has been set yet).
    property bool autoCommitOnIndexResolve: false

    function setCurIndex(model) {
        new Promise((resolve, reject) => {
            for (let i = 0; i < model.count; i++) {
                if (model.get(i).workshopid === root.activeWorkshopId) {
                    view.currentIndex = i;
                    break;
                }
            }
            if (view.currentIndex == -1 && model.count != 0)
                view.currentIndex = 0;

            if (root.autoCommitOnIndexResolve && view.currentIndex != -1)
                root.itemClicked(model.get(view.currentIndex), view.currentIndex);

            resolve();
        });
    }

    function toggleFavor(model, index) {
        if (!index) index = view.currentIndex;
        if (!root.customConf) {
            // No favorites store wired up — emit a signal so the page may handle.
            root.favorToggled(model, index);
            return;
        }
        if (model.favor) {
            root.customConf.favor.delete(model.workshopid);
        } else {
            root.customConf.favor.add(model.workshopid);
        }
        view.model.assignModel(index, { favor: !model.favor });
        root.saveCustomConfRequested();

        if (index == view.currentIndex) view.currentIndexChanged();
    }

    function toggleRandomExclude(model, index) {
        if (!index) index = view.currentIndex;
        const id = model.workshopid;
        const newVal = !model.disabledInRandom;
        if (!root.customConf) {
            // No custom conf store wired up — let the page handle it.
            root.randomExcludeToggled(model, index);
            return;
        }
        if (newVal) {
            root.customConf.disabledInRandom.add(id);
        } else {
            root.customConf.disabledInRandom.delete(id);
        }
        view.model.assignModel(index, { disabledInRandom: newVal });
        root.saveCustomConfRequested();

        if (index == view.currentIndex) view.currentIndexChanged();
    }
}
