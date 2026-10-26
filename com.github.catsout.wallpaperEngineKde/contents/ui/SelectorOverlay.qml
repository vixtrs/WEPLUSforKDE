// Wallpaper Selector overlay (v3 - State Machine & Multi-Screen Safe)
import QtQuick 2.15
import QtQuick.Layouts 1.12
import org.kde.kirigami 2.15 as Kirigami

Item {
    id: injectedRoot

    anchors.fill: parent
    z: 9999

    property bool open: false
    property var modelRef: null
    property var commonRef: null
    property int srcCount: 0
    property string currentId: ""
    property bool muted: false
    property string selectorStyle: "simple"
    property var notifyWallpaperSelected: null
    property var notifyClosed: null
    property var notifyToggleMute: null
    property var notifyRefresh: null
    property var notifyStyleChanged: null
    property bool refreshing: false

    function styleName(value) {
        const s = String(value || "simple").toLowerCase();
        if (s === "hyperland" || s === "hyprland") return "hyprland";
        if (s === "glass" || s === "simple" || s === "default") return s;
        return "simple";
    }
    readonly property string normalizedStyle: injectedRoot.styleName(injectedRoot.selectorStyle)
    readonly property bool isDefaultStyle:  normalizedStyle === "default"
    readonly property bool isSimpleStyle:   normalizedStyle === "simple"
    readonly property bool isHyprlandStyle: normalizedStyle === "hyprland"
    readonly property bool isGlassStyle:    normalizedStyle === "glass"

    // ── Single Source of Truth for Selection & Re-entrancy Guard (E-02, E-03) ──
    property bool selectionMode: false
    property int selectedSourceIndex: 0
    property int arrowIndex: 0
    property bool moving: false
    property bool dragging: false
    property real wheelAccum: 0
    property bool programmaticMove: false
    property bool applyingSelection: false
    property double suppressToggleUntil: 0
    property bool _styleSettling: false
    property int _centerTargetIndex: -1
    property int _centerAttempts: 0

    function targetListWidthForStyle(st) {
        const pw = parent ? parent.width : 1920;
        if (st === "hyprland") {
            return Math.min(pw * 0.96, 1740);
        }
        const bw = Math.min(pw * 0.92, 1500);
        const marg = (st === "glass") ? 32 : 28;
        return Math.max(200, bw - marg);
    }

    function centerXForStyle(idx, st) {
        const cw = (st === "hyprland") ? 168 : 200;
        const cs = (st === "hyprland") ? 12 : 14;
        const cstep = cw + cs;
        const lw = injectedRoot.targetListWidthForStyle(st);
        const totalItems = (selectorList && selectorList.model && selectorList.model.length) ? selectorList.model.length : 0;
        const calcContentW = totalItems > 0 ? (totalItems * cstep - cs) : (selectorList ? selectorList.contentWidth : 0);
        const maxX = Math.max(0, calcContentW - lw);
        const target = idx * cstep - (lw - cw) / 2;
        return Math.max(0, Math.min(target, maxX));
    }

    onSelectorStyleChanged: {
        const labels = {
            "simple":   "Simple",
            "hyprland": "Hyprland",
            "glass":    "Glass",
            "default":  "Default"
        };
        const st = injectedRoot.styleName(injectedRoot.selectorStyle);
        if (injectedRoot.open) {
            styleToastLabel.text = labels[st] || st;
            styleToast.opacity = 1.0;
            styleToastTimer.restart();
        }
        if (!injectedRoot.open || !selectorList) return;
        injectedRoot._styleSettling = true;
        wheelAnim.stop();
        arrowAnim.stop();
        let targetVis = injectedRoot.arrowIndex;
        if (injectedRoot.selectionMode && injectedRoot.srcCount > 0) {
            targetVis = injectedRoot.midCopyBaseIndex() + injectedRoot.selectedSourceIndex;
        }
        injectedRoot.arrowIndex = targetVis;
        injectedRoot._centerTargetIndex = targetVis;
        injectedRoot._centerAttempts = 0;
        centerRetryTimer.stop();
        centerHoldTimer.stop();
        styleSettleTimer.restart();
    }

    visible: open
    focus: open

    readonly property real cardWidth: isHyprlandStyle ? 168 : 200
    readonly property real cardSpacing: isHyprlandStyle ? 12 : 14
    readonly property real cardStep: cardWidth + cardSpacing

    function normalizeMod(n, m) {
        if (m <= 0) return 0;
        return ((n % m) + m) % m;
    }

    function midCopyBaseIndex() {
        if (injectedRoot.srcCount <= 0 || !selectorList || !selectorList.model) return 0;
        const total = selectorList.model.length || 0;
        const copies = Math.floor(total / injectedRoot.srcCount);
        const midCopy = Math.floor(copies / 2);
        return midCopy * injectedRoot.srcCount;
    }

    onOpenChanged: {
        injectedRoot.wheelAccum = 0;
        if (injectedRoot.open) {
            injectedRoot.applyingSelection = false;
            injectedRoot.forceActiveFocus();
            Qt.callLater(function() {
                if (injectedRoot.open) {
                    injectedRoot.resetCardDelegates();
                    injectedRoot.centerOnCurrent();
                }
            });
        } else {
            injectedRoot._styleSettling = false;
            injectedRoot.quiesce();
        }
    }

    onCurrentIdChanged: {
        if (injectedRoot.open && !injectedRoot.moving) {
            Qt.callLater(function() { if (injectedRoot.open) injectedRoot.centerOnCurrent(); });
        }
    }

    onSrcCountChanged: {
        if (injectedRoot.open) {
            Qt.callLater(function() { if (injectedRoot.open) injectedRoot.centerOnCurrent(); });
        }
    }

    onModelRefChanged: {
        if (injectedRoot.open) {
            Qt.callLater(function() { if (injectedRoot.open) injectedRoot.centerOnCurrent(); });
        }
    }

    function cycleStyle() {
        const order = ["simple", "hyprland", "glass", "default"];
        const labels = {
            "simple":   "Simple",
            "hyprland": "Hyprland",
            "glass":    "Glass",
            "default":  "Default"
        };
        const cur = injectedRoot.styleName(injectedRoot.selectorStyle);
        const next = order[(order.indexOf(cur) + 1) % order.length];
        injectedRoot.selectorStyle = next;
        if (typeof injectedRoot.notifyStyleChanged === "function")
            injectedRoot.notifyStyleChanged(next);
    }

    function centerX(idx) {
        if (!selectorList || selectorList.width <= 0) return 0;
        const totalItems = (selectorList.model && selectorList.model.length) ? selectorList.model.length : 0;
        const calcContentW = totalItems > 0
            ? (totalItems * injectedRoot.cardStep - injectedRoot.cardSpacing)
            : selectorList.contentWidth;
        const maxX = Math.max(0, calcContentW - selectorList.width);
        const target = idx * injectedRoot.cardStep
                     - (selectorList.width - injectedRoot.cardWidth) / 2;
        return Math.max(0, Math.min(target, maxX));
    }

    function currentIndexFromPos() {
        const cx = selectorList.contentX
                 + (selectorList.width - injectedRoot.cardWidth) / 2;
        return Math.max(0, Math.round(cx / injectedRoot.cardStep));
    }

    function syncSelectionFromVisualIndex(visIdx) {
        if (injectedRoot.srcCount <= 0) return;
        injectedRoot.arrowIndex = Math.max(0, visIdx);
        injectedRoot.selectedSourceIndex = injectedRoot.normalizeMod(injectedRoot.arrowIndex, injectedRoot.srcCount);
    }

    function enterSelectionMode() {
        if (!injectedRoot.selectionMode) {
            injectedRoot.selectionMode = true;
            injectedRoot.syncSelectionFromVisualIndex(injectedRoot.currentIndexFromPos());
        }
    }

    function centerOnIndex(idx) {
        if (!injectedRoot.open || !selectorList || injectedRoot.srcCount <= 0) return;
        injectedRoot._centerTargetIndex = Math.max(0, idx);
        injectedRoot._centerAttempts = 0;
        if (!injectedRoot.performCenter())
            centerRetryTimer.restart();
    }

    function cancelCenterHold() {
        injectedRoot._centerTargetIndex = -1;
        centerRetryTimer.stop();
        centerHoldTimer.stop();
    }

    function resetCardDelegates() {
        if (!selectorList) return;
        const del = selectorList.delegate;
        selectorList.delegate = null;
        selectorList.delegate = del;
    }

    function performCenter() {
        if (!injectedRoot.open || !selectorList || injectedRoot._centerTargetIndex < 0) {
            centerRetryTimer.stop();
            return false;
        }
        if (injectedRoot._styleSettling) return false;
        const st = injectedRoot.styleName(injectedRoot.selectorStyle);
        const cw = (st === "hyprland") ? 168 : 200;
        const cs = (st === "hyprland") ? 12 : 14;
        const step = cw + cs;
        const total = (selectorList.model && selectorList.model.length) ? selectorList.model.length : 0;
        if (total <= 0 || selectorList.width <= 0) return false;
        const expectedLw = injectedRoot.targetListWidthForStyle(st);
        if (Math.abs(selectorList.width - expectedLw) > 2) return false;
        const expectedCw = total * step - cs;
        if (selectorList.contentWidth + 1 < expectedCw) return false;
        const target = injectedRoot.centerXForStyle(injectedRoot._centerTargetIndex, st);
        const maxX = Math.max(0, selectorList.contentWidth - selectorList.width);
        const clamped = Math.max(0, Math.min(target, maxX));
        injectedRoot.programmaticMove = true;
        selectorList.contentX = clamped;
        injectedRoot.programmaticMove = false;
        const ok = Math.abs(selectorList.contentX - clamped) < 2;
        if (ok) {
            centerRetryTimer.stop();
            centerHoldTimer.restart();
            return true;
        }
        return false;
    }

    function centerOnCurrent() {
        if (injectedRoot.srcCount <= 0 || !selectorList || !selectorList.model) return;
        const base = injectedRoot.midCopyBaseIndex();
        let vis = -1;
        let src = 0;
        let found = false;
        for (let i = 0; i < injectedRoot.srcCount; i++) {
            const m = selectorList.model[base + i];
            if (m && String(m.workshopid) === String(injectedRoot.currentId)) {
                vis = base + i;
                src = i;
                found = true;
                break;
            }
        }
        if (!found) {
            const total = selectorList.model.length || 0;
            for (let i = 0; i < total; i++) {
                const m = selectorList.model[i];
                if (m && String(m.workshopid) === String(injectedRoot.currentId)) {
                    vis = i;
                    src = injectedRoot.normalizeMod(i, injectedRoot.srcCount);
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            vis = base;
            src = 0;
        }
        wheelAnim.stop();
        arrowAnim.stop();
        injectedRoot.selectionMode = true;
        injectedRoot.selectedSourceIndex = src;
        injectedRoot.arrowIndex = vis;
        injectedRoot.moving = false;
        injectedRoot.centerOnIndex(vis);
    }

    function settleToNearest() {
        if (!injectedRoot.open || injectedRoot.applyingSelection) return;
        if (injectedRoot.srcCount <= 0 || !selectorList || !selectorList.model) return;
        injectedRoot.cancelCenterHold();
        const idx = injectedRoot.currentIndexFromPos();
        injectedRoot.selectionMode = true;
        injectedRoot.syncSelectionFromVisualIndex(idx);
        injectedRoot.moving = true;
        selectorList.animateToStep(injectedRoot.centerX(idx));
    }

    function recenterCopyIfNeeded() {
        if (injectedRoot.srcCount <= 0 || !selectorList || !selectorList.model) return;
        const total = selectorList.model.length || 0;
        const margin = injectedRoot.srcCount * 4;
        if (injectedRoot.arrowIndex < margin || injectedRoot.arrowIndex >= total - margin) {
            const base = injectedRoot.midCopyBaseIndex();
            injectedRoot.arrowIndex = base + injectedRoot.selectedSourceIndex;
            injectedRoot.programmaticMove = true;
            selectorList.contentX = injectedRoot.centerX(injectedRoot.arrowIndex);
            injectedRoot.programmaticMove = false;
        }
    }

    function arrowMove(delta) {
        if (injectedRoot.srcCount <= 0 || injectedRoot.applyingSelection) return;
        injectedRoot.cancelCenterHold();
        if (!injectedRoot.selectionMode) {
            injectedRoot.enterSelectionMode();
        }
        injectedRoot.arrowIndex = Math.max(0, injectedRoot.arrowIndex + delta);
        injectedRoot.selectedSourceIndex = injectedRoot.normalizeMod(injectedRoot.arrowIndex, injectedRoot.srcCount);
        injectedRoot.moving = true;
        selectorList.animateToStep(injectedRoot.centerX(injectedRoot.arrowIndex));
    }

    function applySelection(visOrSrcIndex) {
        if (injectedRoot.applyingSelection || injectedRoot.srcCount <= 0) return;
        injectedRoot.cancelCenterHold();
        injectedRoot.applyingSelection = true;
        injectedRoot.suppressToggleUntil = Date.now() + 1500;
        const resolvedIdx = injectedRoot.normalizeMod(visOrSrcIndex, injectedRoot.srcCount);
        injectedRoot.selectedSourceIndex = resolvedIdx;
        if (typeof injectedRoot.notifyWallpaperSelected === "function")
            injectedRoot.notifyWallpaperSelected(resolvedIdx);
    }

    function confirmSelection() {
        if (injectedRoot.srcCount <= 0 || injectedRoot.applyingSelection) return;
        if (!injectedRoot.selectionMode) {
            injectedRoot.enterSelectionMode();
        }
        injectedRoot.applySelection(injectedRoot.selectedSourceIndex);
    }

    function quiesce() {
        injectedRoot.cancelCenterHold();
        injectedRoot.selectionMode = false;
        injectedRoot.moving = false;
        injectedRoot.programmaticMove = false;
        wheelAnim.stop();
        arrowAnim.stop();
        if (selectorList)
            selectorList.returnToBounds();
    }

    Keys.onLeftPressed:   injectedRoot.arrowMove(-1)
    Keys.onRightPressed:  injectedRoot.arrowMove(1)
    Keys.onReturnPressed: injectedRoot.confirmSelection()
    Keys.onEnterPressed:  injectedRoot.confirmSelection()
    Keys.onTabPressed:    injectedRoot.cycleStyle()
    Keys.onEscapePressed: {
        injectedRoot.suppressToggleUntil = Date.now() + 600;
        if (typeof injectedRoot.notifyClosed === "function")
            injectedRoot.notifyClosed();
    }
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_F5) {
            if (typeof injectedRoot.notifyRefresh === "function")
                injectedRoot.notifyRefresh();
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: injectedRoot.open
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: (mouse) => {
            mouse.accepted = true;
            injectedRoot.suppressToggleUntil = Date.now() + 600;
            if (typeof injectedRoot.notifyClosed === "function")
                injectedRoot.notifyClosed();
        }
    }

    Rectangle {
        id: box
        anchors.horizontalCenter: parent.horizontalCenter
        width: isHyprlandStyle
            ? Math.min(parent.width * 0.96, 1740)
            : Math.min(parent.width * 0.92, 1500)
        height: isHyprlandStyle
            ? 430
            : (isDefaultStyle ? 280 : 228)
        radius: isHyprlandStyle ? 0 : (isGlassStyle ? 26 : 22)

        color: {
            if (isHyprlandStyle) return "transparent";
            if (isGlassStyle)    return Qt.rgba(0.08, 0.11, 0.16, 0.28);
            return Qt.rgba(0.07, 0.07, 0.10, 0.94);
        }
        border.color: {
            if (isHyprlandStyle) return "transparent";
            if (isGlassStyle)    return Qt.rgba(1, 1, 1, 0.28);
            return Qt.rgba(1, 1, 1, 0.12);
        }
        border.width: isHyprlandStyle ? 0 : 1
        clip: !isHyprlandStyle

        y: injectedRoot.open
            ? (parent.height - height) / 2
            : (parent.height - height) / 2 + 60
        opacity: injectedRoot.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: Math.max(0, box.radius - 1)
            visible: injectedRoot.isGlassStyle
            color: "transparent"
            border.color: Qt.rgba(1, 1, 1, 0.12)
            border.width: 1
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.16) }
                GradientStop { position: 0.40; color: Qt.rgba(1, 1, 1, 0.04) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.08) }
            }
        }

        Rectangle {
            visible: injectedRoot.isGlassStyle
            anchors.top: parent.top
            anchors.topMargin: 1
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 48
            height: 1
            color: Qt.rgba(1, 1, 1, 0.42)
        }

        MouseArea {
            anchors.fill: parent
            enabled: !injectedRoot.isHyprlandStyle
            onClicked: (mouse) => { mouse.accepted = true; }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: injectedRoot.isHyprlandStyle ? 0 : (injectedRoot.isGlassStyle ? 16 : 14)
            spacing: injectedRoot.isDefaultStyle ? 8 : 0

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                visible: injectedRoot.isDefaultStyle

                Text {
                    text: "Wallpapers"
                    color: "#ffffff"
                    font.pixelSize: 15
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    Text { text: "Wheel: navigate"; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "Arrows: select";  color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "Enter: confirm";  color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "Click: apply";    color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "Tab: style";      color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "Ctrl+W: close";   color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                    Text { text: "F5: refresh";     color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 11 }
                }

                Item {
                    id: refreshBox
                    width: 30
                    height: 30
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.horizontalCenterOffset: -35
                    anchors.verticalCenter: parent.verticalCenter

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: 16
                        height: 16
                        source: "view-refresh"
                        color: "#ffffff"
                        opacity: injectedRoot.refreshing ? 0.4 : 0.85
                        RotationAnimator on rotation {
                            from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: injectedRoot.refreshing
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof injectedRoot.notifyRefresh === "function")
                                injectedRoot.notifyRefresh();
                        }
                    }
                }

                Item {
                    id: soundBox
                    width: 30
                    height: 30
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        source: injectedRoot.muted ? "audio-volume-muted" : "audio-volume-high"
                        color: "#ffffff"
                        opacity: injectedRoot.muted ? 0.45 : 1.0
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            injectedRoot.muted = !injectedRoot.muted;
                            if (typeof injectedRoot.notifyToggleMute === "function")
                                injectedRoot.notifyToggleMute(injectedRoot.muted);
                        }
                    }
                }
            }

            ListView {
                id: selectorList
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: ListView.Horizontal
                model: injectedRoot.modelRef
                spacing: injectedRoot.cardSpacing
                clip: false
                snapMode: ListView.NoSnap
                boundsBehavior: Flickable.StopAtBounds
                interactive: true
                maximumFlickVelocity: 2500

                onWidthChanged: {
                    if (injectedRoot.open && injectedRoot._centerTargetIndex >= 0)
                        injectedRoot.performCenter();
                }

                onContentWidthChanged: {
                    if (injectedRoot.open && injectedRoot._centerTargetIndex >= 0)
                        injectedRoot.performCenter();
                }

                function animateTo(target) {
                    arrowAnim.stop();
                    const maxX = Math.max(0, selectorList.contentWidth - selectorList.width);
                    const clamped = Math.max(0, Math.min(target, maxX));
                    injectedRoot.programmaticMove = true;
                    wheelAnim.from = selectorList.contentX;
                    wheelAnim.to = clamped;
                    wheelAnim.restart();
                }

                function animateToStep(target) {
                    wheelAnim.stop();
                    const maxX = Math.max(0, selectorList.contentWidth - selectorList.width);
                    const clamped = Math.max(0, Math.min(target, maxX));
                    injectedRoot.programmaticMove = true;
                    arrowAnim.from = selectorList.contentX;
                    arrowAnim.to = clamped;
                    arrowAnim.restart();
                }

                function scrollByCards(n) {
                    injectedRoot.arrowMove(-n);
                }

                function scrollSmooth(dx) {
                    injectedRoot.cancelCenterHold();
                    injectedRoot.selectionMode = false;
                    injectedRoot.moving = false;
                    animateTo(selectorList.contentX + dx);
                }

                NumberAnimation {
                    id: wheelAnim
                    target: selectorList
                    property: "contentX"
                    duration: 190
                    easing.type: Easing.OutCubic
                    onStopped: {
                        injectedRoot.moving = false;
                        injectedRoot.programmaticMove = false;
                    }
                }

                NumberAnimation {
                    id: arrowAnim
                    target: selectorList
                    property: "contentX"
                    duration: 190
                    easing.type: Easing.OutCubic
                    onStopped: {
                        injectedRoot.moving = false;
                        if (injectedRoot.selectionMode) {
                            selectorList.contentX = injectedRoot.centerX(injectedRoot.arrowIndex);
                            injectedRoot.recenterCopyIfNeeded();
                        }
                        injectedRoot.programmaticMove = false;
                    }
                }

                onContentXChanged: {
                    if (injectedRoot.dragging && !injectedRoot.programmaticMove && injectedRoot.open) {
                        injectedRoot.selectionMode = true;
                        injectedRoot.syncSelectionFromVisualIndex(injectedRoot.currentIndexFromPos());
                    }
                }

                onMovementStarted: {
                    if (!injectedRoot.programmaticMove) {
                        injectedRoot.cancelCenterHold();
                        injectedRoot.dragging = true;
                        injectedRoot.moving = true;
                        injectedRoot.selectionMode = true;
                        injectedRoot.syncSelectionFromVisualIndex(injectedRoot.currentIndexFromPos());
                    }
                }

                onMovementEnded: {
                    if (injectedRoot.dragging) {
                        injectedRoot.dragging = false;
                        injectedRoot.settleToNearest();
                    }
                }

                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        const dy = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                        if (dy === 0) return;
                        const notches = dy / 120;
                        if (Math.abs(notches) >= 1) {
                            injectedRoot.wheelAccum = 0;
                            selectorList.scrollByCards(-Math.round(notches));
                        } else {
                            injectedRoot.wheelAccum += dy;
                            while (injectedRoot.wheelAccum >= 120) {
                                injectedRoot.wheelAccum -= 120;
                                selectorList.scrollByCards(1);
                            }
                            while (injectedRoot.wheelAccum <= -120) {
                                injectedRoot.wheelAccum += 120;
                                selectorList.scrollByCards(-1);
                            }
                        }
                    }
                }

                delegate: Item {
                    id: cardSlot
                    width: injectedRoot.cardWidth
                    height: selectorList.height

                    readonly property real cardCenterInView: (x - selectorList.contentX) + width * 0.5
                    readonly property real viewCenter: selectorList.width * 0.5
                    readonly property real distFromCenter: Math.abs(cardCenterInView - viewCenter) / injectedRoot.cardStep
                    readonly property bool isSelectedCard: (injectedRoot.selectionMode && index === injectedRoot.arrowIndex)
                    readonly property bool isActiveWp: Boolean(modelData && String(modelData.workshopid) === String(injectedRoot.currentId))
                    readonly property bool isCenterHypr: isSelectedCard || (distFromCenter < 0.45)

                    z: injectedRoot.isHyprlandStyle ? Math.round(100 - distFromCenter * 10) : (isSelectedCard ? 10 : 1)

                    Rectangle {
                        id: standardCard
                        visible: !injectedRoot.isHyprlandStyle
                        width: parent.width
                        height: parent.height - (injectedRoot.isDefaultStyle ? 8 : 4)
                        anchors.verticalCenter: parent.verticalCenter
                        radius: injectedRoot.isGlassStyle ? 18 : 14

                        color: {
                            if (injectedRoot.isGlassStyle) {
                                if (cardSlot.isSelectedCard || cardHover.hovered) return Qt.rgba(1, 1, 1, 0.18);
                                return Qt.rgba(1, 1, 1, 0.07);
                            }
                            return Qt.rgba(1, 1, 1, 0.06);
                        }
                        border.color: {
                            if (cardSlot.isSelectedCard) return "#ffffff";
                            if (injectedRoot.isGlassStyle) {
                                if (cardSlot.isActiveWp) return Qt.rgba(0.60, 0.92, 1.0, 0.80);
                                return cardHover.hovered ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(1, 1, 1, 0.20);
                            }
                            if (cardSlot.isActiveWp && !injectedRoot.isDefaultStyle) return Qt.rgba(0.49, 1.0, 0.62, 0.65);
                            return Qt.rgba(1, 1, 1, 0.10);
                        }
                        border.width: cardSlot.isSelectedCard ? 1.8 : (cardSlot.isActiveWp && !injectedRoot.isDefaultStyle ? 1.4 : 1)
                        scale: cardSlot.isSelectedCard ? 1.0 : (cardHover.hovered ? 0.985 : 0.96)
                        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: injectedRoot.isGlassStyle ? 9 : 8
                            spacing: injectedRoot.isDefaultStyle ? 6 : 5

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredHeight: injectedRoot.isDefaultStyle ? 140 : -1
                                radius: injectedRoot.isGlassStyle ? 12 : 9
                                color: Qt.rgba(0, 0, 0, 0.30)
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: (modelData && typeof modelData.preview === "string" && modelData.preview)
                                        ? (injectedRoot.commonRef ? injectedRoot.commonRef.getWpModelPreviewSource(modelData) : "")
                                        : ""
                                    fillMode: Image.PreserveAspectCrop
                                    clip: true; cache: true; asynchronous: true; smooth: true
                                    visible: Boolean(modelData && typeof modelData.preview === "string" && modelData.preview)
                                }
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: 24; height: 24
                                    source: "view-image"
                                    color: "#ffffff"
                                    opacity: 0.8
                                    visible: !(modelData && typeof modelData.preview === "string" && modelData.preview)
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData ? (modelData.title || modelData.workshopid) : ""
                                color: "#ffffff"
                                opacity: injectedRoot.isGlassStyle ? 0.92 : 1.0
                                font.pixelSize: 12
                                font.bold: injectedRoot.isDefaultStyle
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: injectedRoot.isDefaultStyle
                                text: modelData ? (modelData.broken ? "ROTO / MAL DESCARGADO" : (String(modelData.workshopid) === String(injectedRoot.currentId) ? "Active" : (modelData.type || ""))) : ""
                                color: modelData ? (modelData.broken ? "#ff5c5c" : (String(modelData.workshopid) === String(injectedRoot.currentId) ? "#7dff9e" : Qt.rgba(1, 1, 1, 0.4))) : Qt.rgba(1, 1, 1, 0.4)
                                font.pixelSize: 10
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    Rectangle {
                        visible: !injectedRoot.isHyprlandStyle && cardSlot.isSelectedCard
                        anchors.centerIn: standardCard
                        width: standardCard.width + 16
                        height: standardCard.height + 16
                        radius: standardCard.radius + 7
                        color: "transparent"
                        border.width: 6
                        border.color: Qt.rgba(0.49, 0.85, 1.0, 0.30)
                    }

                    Rectangle {
                        visible: !injectedRoot.isHyprlandStyle && cardSlot.isSelectedCard
                        anchors.centerIn: standardCard
                        width: standardCard.width + 7
                        height: standardCard.height + 7
                        radius: standardCard.radius + 3
                        color: "transparent"
                        border.width: 2.5
                        border.color: "#8fdcff"
                    }

                    Item {
                        id: hyprCardContainer
                        visible: injectedRoot.isHyprlandStyle
                        anchors.centerIn: parent
                        width: parent.width
                        height: Math.max(155, 370 - Math.min(cardSlot.distFromCenter, 4.5) * 44)
                        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

                        opacity: Math.max(0.28, 1.0 - Math.max(0, cardSlot.distFromCenter - 0.3) * 0.16)
                        scale: cardSlot.isCenterHypr ? 1.06 : (cardHover.hovered ? 1.02 : 1.0)
                        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                        transform: Matrix4x4 {
                            property real shearX: -0.15
                            matrix: Qt.matrix4x4(1, shearX, 0, -shearX * hyprCardContainer.height * 0.5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: 6; anchors.topMargin: 10; anchors.rightMargin: -6; anchors.bottomMargin: -10
                            color: Qt.rgba(0, 0, 0, cardSlot.isCenterHypr ? 0.62 : 0.40)
                        }

                        Rectangle {
                            id: hyprCardBody
                            anchors.fill: parent
                            color: "#12131a"
                            border.color: cardSlot.isCenterHypr ? Qt.rgba(1, 1, 1, 0.85) : (cardSlot.isActiveWp ? Qt.rgba(0.49, 1.0, 0.62, 0.70) : Qt.rgba(1, 1, 1, 0.18))
                            border.width: cardSlot.isCenterHypr ? 2 : 1
                            clip: true

                            Image {
                                anchors.centerIn: parent
                                width: parent.width + Math.abs(0.15 * parent.height) + 18
                                height: parent.height
                                source: (modelData && typeof modelData.preview === "string" && modelData.preview) ? (injectedRoot.commonRef ? injectedRoot.commonRef.getWpModelPreviewSource(modelData) : "") : ""
                                fillMode: Image.PreserveAspectCrop; cache: true; asynchronous: true; smooth: true
                                visible: Boolean(modelData && typeof modelData.preview === "string" && modelData.preview)
                                transform: Matrix4x4 {
                                    property real unShearX: 0.15
                                    matrix: Qt.matrix4x4(1, unShearX, 0, -unShearX * hyprCardBody.height * 0.5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                                }
                            }
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                width: 28; height: 28
                                source: "view-image"
                                color: "#ffffff"
                                opacity: 0.75
                                visible: !(modelData && typeof modelData.preview === "string" && modelData.preview)
                            }
                        }
                            Rectangle {
                                visible: cardSlot.isSelectedCard
                                anchors.fill: hyprCardBody
                                anchors.margins: -9
                                color: "transparent"
                                border.width: 6
                                border.color: Qt.rgba(0.49, 0.85, 1.0, 0.30)
                            }

                            Rectangle {
                                visible: cardSlot.isSelectedCard
                                anchors.fill: hyprCardBody
                                anchors.margins: -3
                                color: "transparent"
                                border.width: 2.5
                                border.color: "#8fdcff"
                            }
                    }

                    HoverHandler { id: cardHover }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (mouse) => {
                            mouse.accepted = true;
                            if (injectedRoot.applyingSelection) return;
                            injectedRoot.cancelCenterHold();
                            if (injectedRoot.isHyprlandStyle && cardSlot.distFromCenter >= 0.45) {
                                injectedRoot.selectionMode = true;
                                injectedRoot.syncSelectionFromVisualIndex(index);
                                injectedRoot.moving = true;
                                selectorList.animateToStep(injectedRoot.centerX(index));
                                return;
                            }
                            injectedRoot.applySelection(index);
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: styleToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: box.top
        anchors.bottomMargin: 14
        width: styleToastLabel.implicitWidth + 24
        height: 26
        radius: 13
        color: Qt.rgba(0.08, 0.10, 0.14, 0.78)
        border.color: Qt.rgba(1, 1, 1, 0.24)
        border.width: 1
        opacity: 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }

        Text {
            id: styleToastLabel
            anchors.centerIn: parent
            text: ""
            color: "#ffffff"
            font.pixelSize: 11
            font.bold: true
        }

        Timer {
            id: styleToastTimer
            interval: 1100
            repeat: false
            onTriggered: styleToast.opacity = 0
        }
        Timer {
            id: styleSettleTimer
            interval: 45
            repeat: false
            onTriggered: {
                injectedRoot._styleSettling = false;
                if (injectedRoot.open && selectorList) {
                    const idx = injectedRoot.arrowIndex;
                    injectedRoot.resetCardDelegates();
                    selectorList.contentX = 0;
                    Qt.callLater(function() {
                        if (injectedRoot.open)
                            injectedRoot.centerOnIndex(idx);
                    });
                }
            }
        }

        Timer {
            id: centerRetryTimer
            interval: 25
            repeat: true
            onTriggered: {
                injectedRoot._centerAttempts++;
                if (injectedRoot.performCenter()) {
                    stop();
                } else if (injectedRoot._centerAttempts > 32) {
                    injectedRoot._centerTargetIndex = -1;
                    stop();
                }
            }
        }



        Timer {
            id: centerHoldTimer
            interval: 400
            repeat: false
            onTriggered: {
                if (!injectedRoot.open || injectedRoot._centerTargetIndex < 0) return;
                if (!selectorList) {
                    injectedRoot.cancelCenterHold();
                    return;
                }
                const st = injectedRoot.styleName(injectedRoot.selectorStyle);
                const expected = injectedRoot.centerXForStyle(injectedRoot._centerTargetIndex, st);
                const maxX = Math.max(0, selectorList.contentWidth - selectorList.width);
                const clamped = Math.max(0, Math.min(expected, maxX));
                if (Math.abs(selectorList.contentX - clamped) > 2) {
                    injectedRoot.centerOnIndex(injectedRoot._centerTargetIndex);
                } else {
                    injectedRoot._centerTargetIndex = -1;
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: injectedRoot.cycleStyle()
        }
    }
}
