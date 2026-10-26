import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import com.github.catsout.wallpaperEngineKde
import QtQuick.Window
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

WallpaperItem {
    id: wekRoot
    Rectangle {
    id: background
    anchors.fill: parent
    color: wallpaper.configuration.BackgroundColor
    
    property string steamlibrary: Qt.resolvedUrl(wallpaper.configuration.SteamLibraryPath).toString()
    property string source: Qt.resolvedUrl(wallpaper.configuration.WallpaperSource).toString()

    property string filterStr: wallpaper.configuration.FilterStr

    property int    videoBackend: wallpaper.configuration.VideoBackend
    property int    switchTimer: wallpaper.configuration.SwitchTimer
    property int    fps: Math.min(55, Number(wallpaper.configuration.Fps || 30))

    property bool   randomizeWallpaper: wallpaper.configuration.RandomizeWallpaper
    property bool   noRandomWhilePaused: wallpaper.configuration.NoRandomWhilePaused
    property bool   mouseInput: wallpaper.configuration.MouseInput
    property bool   trailsEnabled: wallpaper.configuration.TrailsEnabled
    property string sceneMode: wallpaper.configuration.SceneMode || "plugin"
    property string trailStyle: wallpaper.configuration.TrailStyle || "generic"
    property string selectorStyle: wallpaper.configuration.SelectorStyle || "simple"
    property bool   animatedPreview: wallpaper.configuration.AnimatedPreview
    property bool   mpvStats: wallpaper.configuration.MpvStats

    // ── Playback override for the right-click context menu ──────────────
    property bool   pauseOverride: false
    property string currentId: ""
    readonly property string selectorCurrentId: {
        const src = String(wallpaper.configuration.WallpaperSource || "");
        const m = src.match(/\/(?:431960|translated)\/(\d+)\//);
        if (m && m[1]) return m[1];
        return background.currentId;
    }
    property string previousId: ""
    property bool   _actionsRegistered: false
    // ─────────────────────────────────────────────────────────────────────

    property bool   pauseOnBatPower: wallpaper.configuration.PauseOnBatPower
    property int    pauseBatPercent: wallpaper.configuration.PauseBatPercent
    property bool   hdrOutput: wallpaper.configuration.HdrOutput
    // systemAudioCapture == usuario || manifest del wallpaper visualizer.
    // El C++ NUNCA arma el monitor pulse/pipewire si la property queda false
    // aunque detecte uniforms g_AudioSpectrum*; por eso el OR es obligatorio
    // monitor por sí solo). _audioManifestArm lo setea logNativeTrail().
    property bool   _audioManifestArm: true
    property bool   systemAudioCapture: wallpaper.configuration.SystemAudioCapture || background._audioManifestArm
    property bool   systemPlayerCapture: wallpaper.configuration.SystemPlayerCapture

    // ── waywallen-style effects & interactive widgets ────────────────────
    property bool   blurOnPause: wallpaper.configuration.BlurOnPause
    property int    blurRadius: wallpaper.configuration.BlurRadius
    property bool   blurOnLock: wallpaper.configuration.BlurOnLock

    // ── waywallen-style camera parallax (global mouse interactivity) ─────
    // Every wallpaper gets a subtle camera parallax that follows the cursor
    // (zoom + opposite-direction shift), recreating Wallpaper Engine's
    // cameraparallax for wallpapers that do not ship their own. Auto-detects
    // native parallax (parallaxDepth / cameraparallax / g_ParallaxPosition)
    // in the scene so the effect is never applied twice.
    property bool   parallaxEnable: wallpaper.configuration.ParallaxEnable
    property double parallaxAmount: wallpaper.configuration.ParallaxAmount
    property double parallaxInfluence: wallpaper.configuration.ParallaxInfluence
    property int    parallaxDelay: wallpaper.configuration.ParallaxDelay
    property bool   parallaxNative: false
    readonly property bool parallaxApply: background.parallaxEnable
        && background.mouseInput
        && !background.parallaxNative
        && background.nowBackend !== 'waywallen'
    property bool   lockPaused: false
    readonly property bool blurActive: (background.blurOnPause && !background.ok) || (background.blurOnLock && background.lockPaused) || (background.blurOnPause && background.backendPaused)
    // ─────────────────────────────────────────────────────────────────────

    
    property var curOpt: ({})
    property string workshopid: {
        const wid = wallpaper.configuration.WallpaperWorkShopId;
        pyext.read_wallpaper_config(wid).then((res) => this.curOpt = res);
        return wid;
    }
    function get_opt_value(key, def) {
        if(curOpt.hasOwnProperty(key))
            return curOpt[key];
        return def;
    }

    // Update all derived properties when curOpt changes
    onCurOptChanged: {
        console.log("main.qml onCurOptChanged, curOpt:", JSON.stringify(curOpt));
        displayMode = get_opt_value('display_mode', wallpaper.configuration.DisplayMode);
        // Mute is NEVER read from per-wallpaper config — the global
        // MuteAudio is the single source of truth (selector toggle,
        // keyboard shortcut). Per-wallpaper config stores a stale value
        // from a previous session that would override the live toggle.
        // mute = get_opt_value('mute_audio', wallpaper.configuration.MuteAudio);
        volume = get_opt_value('volume', wallpaper.configuration.Volume);
        speed = get_opt_value('speed', wallpaper.configuration.Speed);
        const userProps = curOpt['user_props'];
        const explicit = userProps ? JSON.stringify(userProps) : "";
        // Once project.json defaults have been merged (FNAF TV1/TV3, CRT, etc.)
        // they must NEVER be reset to "" here: the second curOpt reassignment
        // from applySource() would wipe them, re-push a changed userPropsJson
        // into the C++ engine and trigger a second scene reload while the
        // first one is still running (SIGSEGV in QQmlTypeLoader::getType).
        userPropsJson = explicit !== "" ? explicit : background.mergedUserProps;
        console.log("main.qml updated: displayMode=", displayMode, "speed=", speed, "userPropsJson=", userPropsJson);
        mergeUserPropDefaults();
    }

    // The per-wallpaper config only stores the props the user touched in the
    // config dialog. Wallpapers gate whole parts of themselves behind their
    // own user properties (FNAF Office: mediaplayerenabled -> TV1,
    // paperwadenabled -> TV3, crteffectenabled -> CRT overlays). Missing
    // keys evaluate to false in the engine JS and hide those layers
    // (black TVs). Merge the project.json defaults for every missing key.
    function mergeUserPropDefaults() {
        const wid = background.workshopid;
        if (!wid || !background.steamlibrary) return;
        const wsDir = Common.getWorkshopDir(background.steamlibrary) + "/" + wid;
        const transPj = Common.getTranslatedRoot(background.steamlibrary) + "/" + wid + "/project.json";
        _readNativeText(transPj).then((tTxt) => {
            if (tTxt && tTxt.length > 2) return tTxt;
            return _readNativeText(wsDir + "/project.json");
        }).then((txt) => {
            try {
                const probe = JSON.parse(txt);
                if (probe && probe.dependency && (!probe.general || !probe.general.properties)) {
                    const baseDir = Common.getWorkshopDir(background.steamlibrary) + "/" + String(probe.dependency);
                    return _readNativeText(baseDir + "/project.json");
                }
            } catch (e) {}
            return txt;
        }).then((txt) => {
            let props = {};
            try {
                const p = JSON.parse(txt);
                props = (p && p.general && p.general.properties) || {};
            } catch (e) {}
            const curopt = background.curOpt || {};
            const cur = curopt.user_props || {};
            const merged = {};
            for (const k in cur) merged[k] = cur[k];
            for (const k in props) {
                const v = props[k];
                if (v && typeof v === "object" && "value" in v && !(k in merged)) {
                    merged[k] = v.value;
                }
            }
            const nextJson = JSON.stringify(merged);
            background.mergedUserProps = nextJson;
            if (background.userPropsJson !== nextJson) {
                background.userPropsJson = nextJson;
                console.log("[WEK] user prop defaults merged: " + Object.keys(merged).length);
            }
        }).catch(() => {});
    }

    property int    displayMode: get_opt_value('display_mode', wallpaper.configuration.DisplayMode)
    property bool   mute: wallpaper.configuration.MuteAudio
    property int    volume: get_opt_value('volume', wallpaper.configuration.Volume)
    property real   speed: get_opt_value('speed', wallpaper.configuration.Speed)
    // User properties for scene wallpapers (JSON string format)
    property string userPropsJson: ""
    // Cached project.json defaults (FNAF TV1/TV3, CRT, etc.) so a second
    // curOpt reassignment cannot wipe them and trigger a reload loop.
    property string mergedUserProps: ""

    // Reactive bindings for configuration changes
    Connections {
        target: wallpaper.configuration
        function onDisplayModeChanged() {
            background.displayMode = background.get_opt_value('display_mode', wallpaper.configuration.DisplayMode);
        }
        function onMuteAudioChanged() {
            // ALWAYS use the global config value — per-wallpaper config
            // stores a stale mute_audio from a previous session and would
            // override the live mute toggle (selector speaker icon,
            // keyboard shortcut). Audio must respond instantly.
            background.mute = wallpaper.configuration.MuteAudio;
        }
        function onVolumeChanged() {
            background.volume = background.get_opt_value('volume', wallpaper.configuration.Volume);
        }
        function onSpeedChanged() {
            background.speed = background.get_opt_value('speed', wallpaper.configuration.Speed);
        }
        function onWallpaperWorkShopIdChanged() {
            background.currentId = wallpaper.configuration.WallpaperWorkShopId;
            background.syncSelectorOpen();
        }
        function onWallpaperSourceChanged() {
            background.currentId = wallpaper.configuration.WallpaperWorkShopId
                || background.currentId;
            if (background.selectorOverlayItem) {
                background.selectorOverlayItem.currentId = background.selectorCurrentId;
                if (background.selectorOverlayItem.open)
                    background.selectorOverlayItem.centerOnCurrent();
            }
        }
        function onSelectorStyleChanged() {
            background.selectorStyle = wallpaper.configuration.SelectorStyle || "simple";
            if (background.selectorOverlayItem) {
                background.selectorOverlayItem.selectorStyle = background.selectorStyle;
            }
        }
    }

    property int    perOptChanged: wallpaper.configuration.PerOptChanged
    onPerOptChangedChanged: {
        console.log("main.qml onPerOptChangedChanged, perOptChanged:", perOptChanged, "workshopid:", workshopid);
        pyext.read_wallpaper_config(workshopid).then((res) => {
            console.log("main.qml read_wallpaper_config result:", JSON.stringify(res));
            this.curOpt = res;
        });
    }

    Timer {
        id: refreshReopenTimer
        interval: 350
        repeat: false
        onTriggered: background.applyPendingRefresh()
    }

    // auto pause
    property bool   focusPause: false
    property bool   selectorOpen: false
    property string selectorLastSeen: ""
    property var    selectorTriggerItem: null
    property var    selectorOverlayItem: null
    property int    _selectorSrcCount: 0
    property int    _selectorRawCount: -1
    property int    _pendingSelectIdx: -1
    property var    _pendingRefreshReps: null
    property int    _pendingRefreshCount: 0
    // Only the primary containment owns the Ctrl+W bridge. With two screens
    // both containments saw the same counter and toggled their own overlay.
    readonly property bool isSelectorOwner: Screen.virtualX === 0 && Screen.virtualY === 0

    function _snapshotWp(m) {
        return {
            workshopid: m.workshopid || "",
            path: m.path || "",
            title: m.title || "unknown",
            preview: m.preview || "",
            type: m.type || "unknown",
            contentrating: m.contentrating || "Everyone",
            tags: m.tags || [],
            favor: m.favor || false,
            disabledInRandom: m.disabledInRandom || false,
            playlists: m.playlists || [],
            loaded: m.loaded || false
        };
    }

    property var syncSelectorOpen: function() {
        if (background.selectorOverlayItem) {
            const wasOpen = background.selectorOverlayItem.open;
            if (wallpaper.configuration.WallpaperWorkShopId && wallpaper.configuration.WallpaperWorkShopId !== background.currentId) {
                background.currentId = wallpaper.configuration.WallpaperWorkShopId;
            }
            // The wallpaper list loads async; rebuild the infinite carousel
            // ONLY on the closed->open transition, BEFORE making it visible.
            // Rebuilding while open resets contentX (active card/frame jumps)
            // and can crash during delegate incubation.
            if (background.selectorOpen && !wasOpen) {
                const count = wpListModel.model.count;
                if (count > 0 && count !== background._selectorRawCount) {
                    const reps = [];
                    const validItems = [];
                    for (let i = 0; i < count; i++) {
                        const it = wpListModel.model.get(i);
                        if (it && !it.broken) validItems.push(background._snapshotWp(it));
                    }
                    const vCount = validItems.length;
                    background._selectorRawCount = count;
                    background._selectorSrcCount = vCount;
                    for (let r = 0; r < 40; r++) {
                        for (let i = 0; i < vCount; i++) {
                            reps.push(validItems[i]);
                        }
                    }
                    background.selectorOverlayItem.modelRef = reps;
                    background.selectorOverlayItem.srcCount = background._selectorSrcCount;
                    console.log("[WEK] selector model rebuilt: " + count
                        + " wallpapers, " + vCount + " valid");
                }
            }
            background.selectorOverlayItem.currentId = background.selectorCurrentId;
            background.selectorOverlayItem.selectorStyle = background.selectorStyle;
            background.selectorOverlayItem.muted = (wallpaper.configuration.MuteAudio === true);
            background.selectorOverlayItem.open = background.selectorOpen;
            // Recenter ONLY on the closed->open transition; the periodic
            // 2s sync must never reset the user's scroll/arrow position.
            if (background.selectorOpen && !wasOpen)
                background.selectorOverlayItem.centerOnCurrent();
        }
    }

    property var applyPendingRefresh: function() {
        if (!background._pendingRefreshReps || !background.selectorOverlayItem) return;
        background._selectorSrcCount = background._pendingRefreshCount;
        background._selectorRawCount = wpListModel.model.count;
        background.selectorOverlayItem.modelRef = background._pendingRefreshReps;
        background.selectorOverlayItem.srcCount = background._pendingRefreshCount;
        background.selectorOverlayItem.currentId = background.selectorCurrentId;
        background._pendingRefreshReps = null;
        background.selectorOpen = true;
        background.syncSelectorOpen();
        console.log("[WEK] selector refreshed: " + background._pendingRefreshCount + " wallpapers");
    }

    property var ensureSelectorInjection: function() {
        if (!background.Window || !background.Window.contentItem) return;
        const dropArea = Common.findItem(background.Window.contentItem, "FolderViewDropArea");
        const targetParent = dropArea
            || Common.findItem(background.Window.contentItem, "AppletsLayout");
        if (!targetParent) return;

        if (!background.selectorTriggerItem) {
            const trig = Qt.createQmlObject(
                'import QtQuick 2.12; MouseArea { acceptedButtons: Qt.MiddleButton; anchors.fill: parent; z: -1 }',
                targetParent);
            trig.clicked.connect(function() {
                background.selectorOpen = !background.selectorOpen;
                background.syncSelectorOpen();
            });
            background.selectorTriggerItem = trig;
            console.log("[WEK] selector trigger injected");
        }

        if (!background.selectorOverlayItem) {
            const comp = Qt.createComponent(Qt.resolvedUrl("SelectorOverlay.qml"));
            if (comp.status === Component.Ready) {
                const validItems = [];
                for (let i = 0; i < wpListModel.model.count; i++) {
                    const it = wpListModel.model.get(i);
                    if (it && !it.broken) validItems.push(background._snapshotWp(it));
                }
                background._selectorSrcCount = validItems.length;
                const reps = [];
                for (let r = 0; r < 40; r++) {
                    for (let i = 0; i < background._selectorSrcCount; i++) {
                        reps.push(validItems[i]);
                    }
                }
                background.selectorOverlayItem = comp.createObject(targetParent, {
                    modelRef: reps,
                    srcCount: background._selectorSrcCount,
                    commonRef: Common,
                    currentId: background.selectorCurrentId,
                    selectorStyle: background.selectorStyle
                });
                if (background.selectorOverlayItem) {
                    background.selectorOverlayItem.notifyWallpaperSelected = function(idx) {
                        const arr = background.selectorOverlayItem.modelRef || [];
                        const picked = arr[idx];
                        if (picked && picked.workshopid) {
                            for (let j = 0; j < wpListModel.model.count; j++) {
                                if (wpListModel.model.get(j).workshopid === picked.workshopid) {
                                    background._pendingSelectIdx = j;
                                    selectDebounce.restart();
                                    return;
                                }
                            }
                        }
                        if (background._selectorSrcCount > 0) {
                            background._pendingSelectIdx = idx % background._selectorSrcCount;
                            selectDebounce.restart();
                        }
                    };
                    background.selectorOverlayItem.notifyClosed = function() {
                        background.selectorOpen = false;
                        background.syncSelectorOpen();
                    };
                    background.selectorOverlayItem.notifyStyleChanged = function(newStyle) {
                        background.selectorStyle = newStyle;
                        background.selectorOverlayItem.selectorStyle = newStyle;
                        wallpaper.configuration.SelectorStyle = newStyle;
                    };
                    background.selectorOverlayItem.notifyToggleMute = function(newMute) {
                        wallpaper.configuration.MuteAudio = newMute;
                        background.mute = newMute;
                        background.selectorOverlayItem.muted = newMute;
                    };
                    background.selectorOverlayItem.notifyRefresh = function() {
                        if (background.selectorOverlayItem.refreshing) return;
                        background.selectorOverlayItem.refreshing = true;
                        try {
                            wpListModel.refresh().then(function() {
                                try {
                                    // Sanitize: Windows WE projects can come back
                                    // broken (unreadable project.json) -> only keep
                                    // items the delegate can actually render.
                                    const valid = [];
                                    const needsPreview = [];
                                    for (let i = 0; i < wpListModel.model.count; i++) {
                                        const m = wpListModel.model.get(i);
                                        if (m && !m.broken && m.workshopid && (m.title || m.workshopid)) {
                                            valid.push(m);
                                            if (typeof m.preview !== "string" || !m.preview)
                                                needsPreview.push(m);
                                        }
                                    }
                                    console.log("[WEK] refresh: " + valid.length
                                        + " items, " + needsPreview.length + " missing preview");
                                    // MEGA-FIX: items whose preview got lost during the
                                    // model refresh (broken project.json read, Windows
                                    // WE projects, NTFS hiccups) are re-read straight
                                    // from disk before the grid is built, so thumbnails
                                    // always show.
                                    Promise.all(needsPreview.map(m => {
                                        const projPath = Common.getWpModelProjectPath(m);
                                        return wpListModel._readfile(Common.urlNative(projPath)).then(value => {
                                            wpListModel.loadItemFromJson(value, m);
                                            console.log("[WEK] preview fixed: " + m.workshopid
                                                + " -> " + m.preview);
                                        }).catch(reason => {
                                            console.log("[WEK] preview unreadable: "
                                                + m.workshopid + " (" + reason + ")");
                                        });
                                    })).then(function() {
                                        const reps = [];
                                        for (let r = 0; r < 80; r++) {
                                            for (let i = 0; i < valid.length; i++) {
                                                reps.push(background._snapshotWp(valid[i]));
                                            }
                                        }
                                        background._pendingRefreshReps = reps;
                                        background._pendingRefreshCount = valid.length;
                                        background.selectorOverlayItem.refreshing = false;
                                        if (background.selectorOverlayItem.open) {
                                            // NEVER swap the ListView model while it is
                                            // open/animating: delegate incubation during
                                            // a live swap segfaults plasmashell (Qt6 QML).
                                            // Close first; the swap happens on reopen.
                                            background.selectorOpen = false;
                                            background.selectorOverlayItem.open = false;
                                            background.selectorOverlayItem.quiesce();
                                            refreshReopenTimer.restart();
                                        } else {
                                            background.applyPendingRefresh();
                                        }
                                    }).catch(e => {
                                        background.selectorOverlayItem.refreshing = false;
                                        console.warn("[WEK] refresh rebuild failed: " + e);
                                    });
                                } catch (e) {
                                    background.selectorOverlayItem.refreshing = false;
                                    console.warn("[WEK] refresh rebuild failed: " + e);
                                }
                            });
                        } catch (e) {
                            background.selectorOverlayItem.refreshing = false;
                            console.warn("[WEK] refresh failed: " + e);
                        }
                    };
                    background.selectorOverlayItem.open = background.selectorOpen;
                    console.log("[WEK] selector overlay injected");
                }
            } else {
                console.warn("[WEK] SelectorOverlay.qml not ready: " + comp.errorString());
            }
        } else {
            background.syncSelectorOpen();
        }
    }
    property bool   ok: !windowModel.reqPause && !powerSource.reqPause && !focusPause

    // detect TTY switch and pause wallpaper(s)
    TTYSwitchMonitor {
        id: ttyMonitor
    onTtySwitch: (sleep) => {
            if (sleep) {
                console.log("Preparing for sleep (possibly a VT switch)")
            } else {
                console.log("Waking up (VT switch back)")
            }
    }
    }

    property string nowBackend: ""
    property bool waywallenBackend: false
    property bool backendPaused: false

    property var mouseHooker
    // Evaluated exactly ONCE at object construction. A live binding here
    // re-runs Common.checklib() on every change (#hasLib binding loop),
    // and each call does Qt.createQmlObject('import com.github... 1.2')
    // -> QQmlTypeLoader::getType on the same module while QML is already
    // compiling -> SIGSEGV. Cache the result so the module load happens a
    // single time.
    property bool hasLib: false

    property var customConf: Common.loadCustomConf(wallpaper.configuration.CustomConf)

    property string wallpaperPath
    property string wallpaperType
    // Native trail entries for the active wallpaper (from mousetrail.json).
    property var nativeTrails: []

    property bool _waitingFirstFrame: false
    signal sig_backendFirstFrame(string backname)
    function onBackendFirstFrame(backname) {
        background._waitingFirstFrame = false;
        console.log("[WEK] first-frame received: " + backname);
        // Reveal the backend hidden at load(): only now does its framebuffer
        // hold a clean, cleared frame, so nothing stale ever composites.
        if (backendLoader.item)
            try { backendLoader.item.opacity = 1; } catch(e) {}
        // The new wallpaper is rendering: release the old one (overlap switch)
        // and run a short crossfade over the swap so no pop is visible.
        // 1.5s delay matches the load() deferral to avoid mid-render kills.
        if (backendLoader.oldItem) {
            // 250ms cubre exactamente los 200ms de transitionVeil sin retener doble VRAM 1.5s
            try { backendLoader.oldItem.destroy(250); } catch(e) {}
            backendLoader.oldItem = null;
        }
        guardTimer.stop();
        transitionVeil.opacity = 1;
        veilCrossfade.restart();
        if (!background.ok || background.pauseOverride) background.autoPause();
        if (wallpaper.hasOwnProperty('accentColor'))
            wallpaper.accentColorChanged();
    }

    Component.onDestruction: {
        if(mouseHooker) {
            mouseHooker.destroy();
        }
        if (selectorTriggerItem) selectorTriggerItem.destroy();
        if (selectorOverlayItem) selectorOverlayItem.destroy();
    }

    property string _lastAppliedSource: ""
    function applySource() {
        // Guard: skip if source hasn't changed. Prevents unnecessary backend
        // reloads when the config dialog rewrites the same WallpaperSource
        // on Apply (even without wallpaper changes).
        if (source === background._lastAppliedSource && source !== "") return;
        background._lastAppliedSource = source;
        console.log("[WEK] applySource begin");
        // Overlap handoff: the backendLoader keeps the previous wallpaper
        // rendering until the new one produces its first frame, so we never
        // cover the load with a black veil (no black gap, no torn framebuffer
        // from destroying the old item mid-switch).
        transitionVeil.opacity = 0;
        veilFallback.stop();

        // Ensure user props are loaded for the current wallpaper before loading backend.
        // When both WallpaperWorkShopId and WallpaperSource change simultaneously,
        // QML may evaluate source first, so workshopid/curOpt/userPropsJson could be stale.
        const wid = wallpaper.configuration.WallpaperWorkShopId;
        if (wid) {
            pyext.read_wallpaper_config(wid).then((res) => { curOpt = res; });
        }

        const { path, type } = Common.unpackWallpaperSource(source);
        // Translated pkg preference: when the pkg has been extracted with
        // parallaxDepth injected (translate_pkg.py), feed the renderer the
        // translated directory instead of the original scene.pkg so every
        // layer tracks the cursor natively (waywallen-style).
        const translatedPath = type === "scene" && path ? translatedScenePath(path) : "";
        if (translatedPath) {
            const pkgPath = path.replace(/scene\.(json|pkg)(?:\+.*)?$/, "scene.pkg");
            ensureTranslatedFresh(translatedPath.replace(/scene\.json$/, ""),
                                  translatedPath.match(/translated\/(\d+)\//)[1],
                                  pkgPath);
            pyext.readfile(Common.urlNative(translatedPath)).then((txt) => {
                // fileHelper.readFile() surfaces QByteArray as a JS object in
                // some builds; String(...) normalizes it (byte array -> utf8
                // text) so the existence probe never silently false-positives.
                const s = String(txt === null || txt === undefined ? "" : (txt.toString ? txt.toString() : txt));
                const ok = s.length > 0;
                // Always use translated mode when the translated scene.json
                // exists and is readable. The translator already decides per-
                // scene whether to inject parallax, media patches, NaN guards
                // etc. — there is no "plain 3D" category because ALL WE scenes
                // have a top-level "camera" object, and the translator skips
                // injection for scenes that already have native parallax.
                if (ok) {
                    applySourceWithPath(translatedPath, type, "translated");
                } else {
                    applySourceWithPath(path, type, "pkg");
                }
            }).catch(() => {
                applySourceWithPath(path, type, "pkg");
            });
        } else {
            applySourceWithPath(path, type, "pkg");
        }
    }

    // Resolve the translated dir for a scene source, or "" when absent.
    // Sources reach us either as "<dir>/scene.pkg+<type>" or already
    // normalized to "<dir>/scene.json+<type>" — handle both.
    function translatedScenePath(path) {
        // guard silently locked wallpapers out of the translated dir even when
        // a valid translated/scene.json exists, so the C++ opened the original
        // .pkg and read the Steam project.json (u_* bindings never registered).
        // Resolution is now driven by DISK EXISTENCE, not the config flag:
        // applySource verifies the translated scene below before falling back.
        const m = path.match(/^(.*\/)(\d+)\/(?:scene\.pkg|scene\.json)(?:\+[^+]*)?$/);
        if (!m) return "";
        const prefix = /^[a-z]+:\/\//i.test(path) ? "file://" : "";
        return prefix + Common.getTranslatedRoot(background.steamlibrary) + "/" + m[2] + "/scene.json";
    }

    // Load the native trail manifest the translator wrote for this wallpaper
    // and publish its entries on background.nativeTrails for NativeTrail.qml.
    property string nativeTrailBase: ""
    property string translatedDirUrl: ""
    property var mediaShortcuts: ({})
    property bool mediaThumbAvailable: false
    property string lastArtUrl: ""
    property int _artSeq: 0
    // Caché simple para portadas de álbumes: evitar descargar la misma imagen
    // repetidamente y reducir la presión sobre la memoria de video.
    property var _artCache: ({})
    // fileHelper.readFile() surfaces QByteArray as a JS object in this build;
    // normalizing to String() is mandatory or every typeof==="string" probe
    // false-positives and translated manifests never load (media buttons,
    // covers, trails, audio manifests went silent). Wrap all reads through it.
    function _readNativeText(p) {
        return pyext.readfile(Common.urlNative(p)).then((txt) => {
            if (txt === null || txt === undefined) return "";
            return String(txt.toString ? txt.toString() : txt);
        }).catch(() => "");
    }
    // True only when the loaded scene actually declares/uses u_* media user
    // vars (u_position/u_title/...). Pushing them into a scene without
    // bindings makes the C++ setter fall back to a FULL SCENE RELOAD — at
    // the estimator's 1 Hz rate that is an endless restart loop (and each
    // reload recompiles every shader through NVIDIA gpucomp until it SEGVs).
    property bool mediaVarsBound: false
    property string lastArtTitle: ""
    property real lastArtReloadTs: 0
    function fetchCoverArt(directUrl) {
        if (!background.mediaThumbAvailable || !background.translatedDirUrl)
            return;
        if (directUrl) {
            fetchArt(String(directUrl));
            return;
        }
        artSource.connectSource(
            "sh -c 'playerctl -l 2>/dev/null | while read s; do " +
            "st=$(playerctl -p \"$s\" status 2>/dev/null); " +
            "[ \"$st\" = \"Playing\" ] || continue; " +
            "u=$(playerctl -p \"$s\" metadata mpris:artUrl 2>/dev/null); " +
            "[ -n \"$u\" ] && { echo WEKART $u; break; }; done'");
    }
    function probeMediaVarBindings(base) {
        const rx = /u_(title|artist|album|albumartist|genres|position|duration|playstate)/;
        _readNativeText(base + "project.json").then((ptxt) => {
            let bound = rx.test(ptxt);
            if (!bound) {
                _readNativeText(base + "scene.json").then((stxt) => {
                    background.mediaVarsBound = rx.test(stxt);
                    console.log("[WEK] media u_* bindings: " + background.mediaVarsBound);
                }).catch(() => { background.mediaVarsBound = false; });
            } else {
                background.mediaVarsBound = true;
                console.log("[WEK] media u_* bindings: true (project.json)");
            }
        }).catch(() => { background.mediaVarsBound = false; });
    }

    // Runtime confirmation that the C++ engine has REGISTERED u_* bindings
    // for this scene (bindings file written by wekde on first script read).
    // Static file probes are not enough: heavy scenes get pushes BEFORE their
    // scripts run once, and every unbound push triggers a full scene reload.
    property bool _bindsConfirmed: false
    property bool _pushSuspended: false
    property real _lastFFTs: 0
    property int _ffStorm: 0
    Timer {
        id: bindsConfirmTimer
        interval: 600
        repeat: true
        running: false
        property int tries: 0
        onTriggered: {
            tries++;
            background.confirmRuntimeBinds();
            if (background._bindsConfirmed || tries > 30)
                running = false;
        }
    }
    // Fallback: if the scene declares u_* media bindings but the C++ engine
    // never writes a bindings file (non-translated scenes, or engine bug),
    // force-confirm after 12s so media metadata still reaches the scene.
    Timer {
        id: bindsFallbackTimer
        interval: 12000
        repeat: false
        running: false
        onTriggered: {
            if (!background._bindsConfirmed && background.mediaVarsBound) {
                console.log("[WEK] bindings fallback: mediaVarsBound=true, forcing confirm (no bindings file)");
                background._bindsConfirmed = true;
            }
        }
    }
    function confirmRuntimeBinds() {
        const m = String(background.translatedDirUrl || "").match(/\/([0-9]{6,})\/$/);
        if (!m)
            return;
        // Bindings file holds the property names scripts actually read
        // (e.g. ["mediainfocollection", ...]); ANY entry proves the scene's
        // script engine is live and consuming userProperties.
        // If the file exists but is empty, still confirm when mediaVarsBound
        // is true (the scene declares u_* in its JSON but the engine didn't
        // write individual entries — common with non-translated scenes).
        const p = Common.getWekdeConfigDir(background.steamlibrary) + "/" + m[1] + "_bindings.json";
        _readNativeText(p).then((txt) => {
            try {
                const arr = JSON.parse(txt);
                if (Array.isArray(arr)) {
                    if (arr.length > 0 || background.mediaVarsBound) {
                        if (!background._bindsConfirmed)
                            console.log("[WEK] runtime bindings confirmed (" + arr.length + ") -> media pushes ON");
                        background._bindsConfirmed = true;
                    }
                }
            } catch (e) {}
        }).catch(() => {});
    }
    // Called from Scene.qml on every backend first-frame. Detects reload
    // storms (>=3 first-frames within 5s) and kills the push loop that
    // causes them instead of feeding it.
    function noteBackendReload() {
        const now = Date.now();
        if (now - _lastFFTs < 5000) {
            _ffStorm++;
            if (_ffStorm >= 3 && !_pushSuspended) {
                _pushSuspended = true;
                console.warn("[WEK] RELOAD-STORM GUARD: suspending media u_* pushes (reload loop detected)");
            }
        } else {
            _ffStorm = 0;
            // Resume media pushes after 5s of calm — the storm is over.
            if (_pushSuspended) {
                _pushSuspended = false;
                console.log("[WEK] reload storm cooldown: media pushes resumed");
            }
        }
        _lastFFTs = now;
        if (!_pushSuspended) {
            _bindsConfirmed = false;
            bindsConfirmTimer.tries = 0;
            bindsConfirmTimer.restart();
            bindsFallbackTimer.restart();
        }
    }
    function logNativeTrail(translatedSceneUrl) {
        const base = translatedSceneUrl.replace(/scene\.json$/, "");
        background.translatedDirUrl = base;
        // (la traducción al vuelo ya se dispara desde applySource)
        background.mediaVarsBound = false;
        background._bindsConfirmed = false;
        background._pushSuspended = false;
        probeMediaVarBindings(base);
        _readNativeText(base + "mediaplayer.json").then((txt) => {
            if (txt.length === 0) return;
            try {
                const m = JSON.parse(txt);
                background.mediaShortcuts = m.shortcuts || {};
                background.mediaThumbAvailable = !!m.has_media_thumbnail;
                if (m.has_media_thumbnail ||
                    Object.keys(background.mediaShortcuts).length > 0)
                    console.log("[WEK] media bridge: thumbnail=" +
                                m.has_media_thumbnail + " shortcuts=" +
                                JSON.stringify(m.shortcuts));
            } catch (e) {}
        });
        const audioManifestUrl = translatedSceneUrl.replace(/scene\.json$/, "audio_visualizer.json");
        _readNativeText(audioManifestUrl).then((txt) => {
            if (txt.length === 0) return;
            try {
                const m = JSON.parse(txt);
                if (m && m.needs_audio_spectrum) {
                    console.log("[WEK] audio visualizer -> systemAudioCapture ON (res=" + (m.suggested_resolution || 32) + ")");
                    background._audioManifestArm = true;
                }
            } catch (e) {}
        });
        const manifestUrl = translatedSceneUrl.replace(/scene\.json$/, "mousetrail.json");
        _readNativeText(manifestUrl).then((txt) => {
            if (txt.length === 0) return;
            try {
                const m = JSON.parse(txt);
                if (m.has_native_trail) {
                    console.log("[WEK] native mousetrail x" + m.trails.length +
                                ": " + m.trails.map(t => t.name).join(", "));
                    background.nativeTrailBase = base;
                    background.nativeTrails = m.trails;
                }
                else
                    console.log("[WEK] no native mousetrail in wallpaper " + m.workshop_id);
            } catch (e) {}
        });
    }

    function applySourceWithPath(effectivePath, type, mode) {
        // Trails only apply to scene wallpapers loaded from a translated dir;
        // reset first so a non-trail wallpaper never inherits stale entries.
        // NOTE: lastArtUrl deliberately survives reloads — resetting it made
        // every poll re-copy the same art and re-trigger the reload forever.
        background.nativeTrails = [];
        background.nativeTrailBase = "";
        background.translatedDirUrl = "";
        background.mediaShortcuts = ({});
        background.mediaThumbAvailable = false;
        background.mediaVarsBound = false;
        background._audioManifestArm = true;
        // Reset push suspension on every wallpaper change — the storm guard
        // from the previous wallpaper must not poison the next one.
        background._pushSuspended = false;
        background._bindsConfirmed = false;
        const path_changed = background.wallpaperPath !== effectivePath;
        const type_changed = background.wallpaperType !== type;
        const is_infobackend = background.nowBackend === "InfoShow";

        if(type_changed) wallpaperType = type;
        if(path_changed) wallpaperPath = effectivePath;

        // Keep selector in sync: extract workshop ID from the source path
        // so the "Active" highlight is correct even when kconfig only sets
        // WallpaperSource without WallpaperWorkShopId.
        if (effectivePath) {
            const widMatch = effectivePath.match(/\/431960\/(\d{6,})\//);
            if (widMatch && !wallpaper.configuration.WallpaperWorkShopId && widMatch[1] !== background.currentId) {
                background.currentId = widMatch[1];
                background.syncSelectorOpen();
                console.log("[WEK] currentId synced from source: " + widMatch[1]);
            }
        }

        // Smart parallax & audio fallback detection: wallpapers that ship their
        // own parallax must not get the synthetic camera rig on top of it, and
        // scenes with audio uniforms/supportsaudioprocessing arm AudioCapture.
        if (type === "scene" && effectivePath) {
            _readNativeText(effectivePath).then((txt) => {
                background.parallaxNative = /parallaxDepth|cameraparallax|g_ParallaxPosition|depthparallax/i.test(txt);
                if (/g_AudioSpectrum|registerAudioBuffers|Simple_Audio_Bars|"AUDIOPROCESSING"|"audioprocessingmode"/i.test(txt)) {
                    background._audioManifestArm = true;
                }
            }).catch(() => { background.parallaxNative = false; });
            const projUrl = effectivePath.replace(/scene\.(json|pkg)(?:\+.*)?$/, "project.json");
            _readNativeText(projUrl).then((ptxt) => {
                if (/"supportsaudioprocessing"\s*:\s*true/i.test(ptxt)) {
                    background._audioManifestArm = true;
                }
            }).catch(() => {});
        }

        // Media-player wallpapers in base mode: reuse the shortcut map the
        // translator already wrote (mediaplayer.json) WITHOUT loading the
        // translated scene. This wires openUserShortcut buttons (play/
        // pause/next/prev) for music-player scenes in plugin mode too.
        if (type === "scene" && mode === "pkg" && background.workshopid) {
            const mpJson = "file://" + Common.getTranslatedRoot(background.steamlibrary) + "/" + background.workshopid + "/mediaplayer.json";
            _readNativeText(mpJson).then((txt) => {
                try {
                    const j = JSON.parse(txt);
                    if (j && j.shortcuts && Object.keys(j.shortcuts).length)
                        background.mediaShortcuts = j.shortcuts;
                } catch (e) {}
            });
        }

        if(type_changed || is_infobackend || !source) {
            loadBackend();
        } else if(path_changed) {
            backendLoader.item.source = effectivePath;
        }

        // After the reset above, (re)load trail entries for translated dirs.
        if (mode === "translated")
            logNativeTrail(effectivePath);

        sourceCallback();
        console.log("[WEK] applySource end " + background.wallpaperPath + " (" + mode + ")");
    }

    function getWorkshopIDPath() {
        return Common.getWorkshopDir(this.steamlibrary) + `/${this.workshopid}`;
    }

    onMouseInputChanged: {
        if(this.mouseInput) {
            hookTimer.start();
        }
        else if(this.mouseHooker) {
            this.mouseHooker.target = null;
            this.mouseHooker.destroy();
            this.mouseHooker = null;
        }
    }

    Timer {
        id: hookTimer
        running: true
        repeat: false
        interval: 2000
        property int tryTimes: 0
        onTriggered: {
            tryTimes++;
            if(tryTimes >= 10 || !background.hasLib || !background.mouseInput) return;
            // waywallen backend forwards input natively via its own
            // window event filter — no hooker needed (global guard).
            if(background.nowBackend === 'waywallen') return;
            if(background.mouseHooker) return;
            background.hookMouse();
        }
        Component.onCompleted: {
            background.hookMouse.connect(background.hookMouseSlot);
        }
    }
    signal hookMouse
    function doHookMouse() {
        if(background.Window) {
            let hookParent = null;
            // Plasma 5: MouseEventListener → QQuickGridView
            const screenArea = Common.findItem(Window.contentItem, "MouseEventListener");
            if(screenArea !== null) {
                hookParent = Common.findItem(screenArea, "QQuickGridView");
            }
            // Plasma 6: AppletsLayout (desktop widget/icon area)
            if(hookParent === null) {
                hookParent = Common.findItem(Window.contentItem, "AppletsLayout");
            }
            // Plasma 6 fallback: FolderViewDropArea
            if(hookParent === null) {
                hookParent = Common.findItem(Window.contentItem, "FolderViewDropArea");
            }
            if(hookParent === null) {
                if(hookTimer.tryTimes >= 9) {
                    const tree = Common.genItemListStr(Window.contentItem, "  ", function(item) {
                        return item.toString();
                    });
                    console.warn("[WEK] MouseHook: failed to find hook target. Item tree:\n" + tree);
                }
                return false;
            }
            console.warn("[WEK] MouseHook: found target " + hookParent);
            if(background.mouseHooker) background.mouseHooker.destroy();
            // Native click pipeline: wekde::MouseGrabber (C++) intercepts
            // clicks on empty desktop areas (z:-1 keeps icons/widgets on top)
            // and forwards them into its target SceneViewer, which drives the
            // wallpaper engine's own cursorClick/cursorEnter script events.
            // The wrapper Item additionally exposes trackPos/trackInside for
            // the cursorFeeder (hover injection), parallax and native trails.
            background.mouseHooker = Qt.createQmlObject(`import QtQuick 2.12;
                import com.github.catsout.wallpaperEngineKde 1.2
                Item {
                    id: hookRoot
                    // High z: this overlay sees empty-desktop clicks first,
                    // forwards them into the wallpaper, then releases the
                    // event (accepted=false) so icons/widgets still work.
                    z: 99999
                    anchors.fill: parent
                    property point trackPos: Qt.point(-1, -1)
                    property bool trackInside: false
                    property var target: null
                    onTargetChanged: grabber.target = target
                    signal desktopClicked(real cx, real cy)
                    signal desktopMoved(real cx, real cy)
                    MouseGrabber {
                        id: grabber
                        anchors.fill: parent
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        onEntered: {
                            hookRoot.trackInside = true;
                            hookRoot.trackPos = Qt.point(mouseX, mouseY);
                        }
                        onPositionChanged: {
                            hookRoot.trackInside = true;
                            hookRoot.trackPos = Qt.point(mouseX, mouseY);
                            hookRoot.desktopMoved(mouseX, mouseY);
                        }
                        onExited: {
                            hookRoot.trackInside = false;
                            hookRoot.trackPos = Qt.point(-1, -1);
                        }
                        onPressed: (mouse) => {
                            hookRoot.trackPos = Qt.point(mouseX, mouseY);
                            hookRoot.desktopClicked(mouseX, mouseY);
                            // Let the click continue down to icons/widgets.
                            mouse.accepted = false;
                        }
                    }
                }
            `, hookParent);
            // Forward desktop clicks into the wallpaper backend, mapping
            // coordinates from the hook area into the SceneViewer's space.
            background.mouseHooker.desktopMoved.connect(function(cx, cy) {
                const be = backendLoader.item;
                if (!be) return;
                if (nativeTrail.visible) {
                    nativeTrail.cursorPos = background.mouseHooker.mapToItem(nativeTrail, cx, cy);
                    nativeTrail.cursorInside = true;
                }
                const t = be.mouseTarget;
                if (t && typeof t.simulateHoverAt === 'function') {
                    const p = t.mapFromItem(background.mouseHooker, cx, cy);
                    t.simulateHoverAt(p.x, p.y);
                }
            });
            background.mouseHooker.desktopClicked.connect(function(cx, cy) {
                const be = backendLoader.item;
                if (!be) return;
                const t = be.mouseTarget;
                const mapTarget = t || be;
                const p = mapTarget.mapFromItem(background.mouseHooker, cx, cy);
                // Scene wallpapers: native C++ click injection on SceneViewer.
                if (t && typeof t.simulateClickAt === 'function') {
                    console.log("[WEK Click Translator] scene click at", Math.round(p.x), Math.round(p.y));
                    t.simulateHoverAt(p.x, p.y);
                    t.simulateClickAt(p.x, p.y, p.x, p.y);
                    return;
                }
                // Web wallpapers: dispatch synthetic events inside the page.
                if (typeof be.simulateClick === 'function') {
                    console.log("[WEK Click Translator] web click at", Math.round(p.x), Math.round(p.y));
                    be.simulateClick(p.x, p.y);
                    return;
                }
                console.log("[WEK Click Translator] no click path for backend:", be);
            });

            // Wire the forwarding target right away (backend may already be
            // loaded); backend changeMouseTarget refreshes it on each load.
            const be = backendLoader.item;
            let t = be ? be.mouseTarget : null;
            if(!t && be && typeof be.getMouseTarget === 'function') {
                const b = be.getMouseTarget();
                if(typeof b === 'function') { try { t = b() || b; } catch(e) { t = b; } }
                else t = b;
            }
            if(t) background.mouseHooker.target = t;
            console.log("[WEK] doHookMouse: grabber created, initial target:", t);
            return true;
       }
       return false;
    }
    function hookMouseSlot() {
        if(!background.doHookMouse()) {
            hookTimer.start();
        } else {
            hookTimer.tryTimes = 0;
        }
    }

    // Continuous cursor feeder: pointer updates only reach the scene through
    // QML hover events, which arrive in bursts while the cursor moves over the
    // desktop and stop the moment it rests, causing cursor-tracked effects
    // (parallax layers, g_PointerPosition shaders, cursor script events) to
    // stutter or stall. Re-inject the last tracked cursor position into the
    // renderer at a fixed cadence so it always has a fresh pointer.
    // Only re-injects when the position actually changed: avoids hammering
    // the render thread 30x/s while the cursor is idle (source of tirones).
    Timer {
        id: cursorFeeder
        interval: 16
        repeat: true
        running: background.mouseInput && background.nowBackend === 'scene'
        property point lastPos: Qt.point(-1, -1)
        onTriggered: {
            const hook = background.mouseHooker;
            if (!hook || !backendLoader.item || hook.trackPos.x < 0)
                return;
            // Keep the trail renderer's cursor fresh even when idle. The
            // hook reports coords in its own space (offset from the
            // wallpaper by panel/containment margins) — map them into the
            // trail renderer's space so particles sit centered on the
            // pointer, and tell it whether the pointer is over the desktop
            // at all so trails dissolve instead of freezing mid-air.
            nativeTrail.cursorPos =
                background.mouseHooker.mapToItem(nativeTrail,
                                                 hook.trackPos.x,
                                                 hook.trackPos.y);
            nativeTrail.cursorInside = hook.trackInside !== false;
            if (hook.trackPos.x === lastPos.x && hook.trackPos.y === lastPos.y)
                return;
            lastPos = hook.trackPos;
            // Map hook coords (AppletsLayout space, excludes panels) into the
            // backend's space before injecting, otherwise the engine's
            // internal cursor sits offset by the panel height and hit-testing
            // resolves the wrong layer on cursorEnter/cursorClick.
            const be = backendLoader.item;
            const target = be.mouseTarget;
            if (target) {
                const p = target.mapFromItem(hook, hook.trackPos.x, hook.trackPos.y);
                target.simulateHoverAt(p.x, p.y);
            }
        }
    }

    // ── native per-wallpaper mouse trails ────────────────────────────────
    // No generic overlay: each wallpaper's own trail (particle systems bound
    // to the cursor, distilled by translate_pkg.py into mousetrail.json) is
    // drawn here with its real colors/sizes/lifetimes/rates. The renderer
    // receives the cursor through the feeder above.
    // ─────────────────────────────────────────────────────────────────────
    NativeTrail {
        id: nativeTrail
        anchors.fill: parent
        z: 9999
        visible: background.mouseInput
                 && background.trailsEnabled
                 && background.nowBackend === 'scene'
        mode: background.trailStyle
        baseUrl: background.nativeTrailBase
        specs: background.nativeTrails
    }

    // ── media-player album art bridge ────────────────────────────────────
    // $mediaThumbnail system textures aren't implemented by the C++ engine;
    // the translator retargets those passes to <translated>/media_thumbnail.png.
    // Poll MPRIS for the current track's art URL, refresh that file, and
    // softly reload the wallpaper (overlap handoff, no black gap) so the
    // cover stays in sync with the playing song.
    // Re-translation runner: executes translate_pkg.py when a translated dir
    // is older than the plugin expects (translator_version.json), then reloads.
    Plasma5Support.DataSource {
        id: retranslateSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            const out = data && data.stdout ? String(data.stdout) : "";
            if (out.indexOf("WEKRT_OK") === 0) {
                disconnectSource(sourceName);
                console.log("[WEK] retranslate finished -> reloading backend");
                background.loadBackend();
            } else if (out.indexOf("WEKPRESET_OK") === 0) {
                disconnectSource(sourceName);
                const wid = wallpaper.configuration.WallpaperWorkShopId;
                if (wid) pyext.read_wallpaper_config(wid).then((res) => { background.curOpt = res; });
            }
        }
    }

    function runTranslator(pkgPath, existingBaseDir) {
        const script = Common.scriptsDir + "/translate_pkg.py";
        if (existingBaseDir) {
            const realBase = existingBaseDir.replace(/^file:\/\//, "");
            console.log("[WEK] actualizando en caliente (no-destructivo): " + realBase);
            retranslateSource.connectSource(
                "python3 '" + script + "' --upgrade-existing '" + realBase + "' >/dev/null 2>&1 && echo WEKRT_OK");
            return;
        }
        const real = pkgPath.replace(/^file:\/\//, "");
        console.log("[WEK] traduciendo " + real + " (modo translator)");
        retranslateSource.connectSource(
            "python3 '" + script + "' '" + real + "' >/dev/null 2>&1 && echo WEKRT_OK");
    }
    function ensureTranslatedFresh(base, sid, pkgPath) {
        _readNativeText(base + "translator_version.json").then((txt) => {
            let v = -1;
            try { v = JSON.parse(txt).version || -1; } catch (e) {}
            if (v >= 17) return;
            // Si scene.json ya existe en disco, hacemos upgrade no-destructivo
            // para no pisar jamás parches manuales.
            _readNativeText(base + "scene.json").then((stxt) => {
                if (stxt && stxt.length > 10) {
                    return; // Fast-path: scene.json ya está traducido en disco, no relanzar Python en caliente
                } else {
                    runTranslator(pkgPath, "");
                }
            }).catch(() => {
                runTranslator(pkgPath, "");
            });
        }).catch(() => {
            _readNativeText(base + "scene.json").then((stxt) => {
                if (stxt && stxt.length > 10) {
                    return; // Fast-path: scene.json ya está traducido en disco, no relanzar Python en caliente
                } else {
                    runTranslator(pkgPath, "");
                }
            }).catch(() => {
                runTranslator(pkgPath, "");
            });
        });
    }

    property string _pendingArtUrl: ""
    property bool reloadOnArtChange: false

    Plasma5Support.DataSource {
        id: artSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            const out = data && data.stdout ? String(data.stdout) : "";
            if (out.indexOf("WEKART ") === 0) {
                disconnectSource(sourceName);
                fetchArt(out.slice(7).trim());
            } else if (out.indexOf("WEKCP_OK") === 0) {
                disconnectSource(sourceName);
                const m = out.match(/WEKCP_OK\s+(\d+)\s*(\S*)/);
                if (m && Number(m[1]) !== background._artSeq) {
                    console.log("[WEK] stale cover write discarded (seq " +
                                m[1] + " vs " + background._artSeq + ")");
                    return;
                }
                const doneUrl = (m && m[2]) ? m[2] : background._pendingArtUrl;
                if (doneUrl) {
                    background.lastArtUrl = doneUrl;
                    background._artCache[doneUrl] = true;
                    const keys = Object.keys(background._artCache);
                    if (keys.length > 20) {
                        delete background._artCache[keys[0]];
                    }
                }
                console.log("[WEK] album art file refreshed (seq " + background._artSeq + ")");
                const now = Date.now();
                if (background.reloadOnArtChange && now - background.lastArtReloadTs > 6000) {
                    background.lastArtReloadTs = now;
                    background.loadBackend();
                }
            } else if (data && data["exit code"] !== undefined) {
                disconnectSource(sourceName);
            }
        }
    }
    function fetchArt(url) {
        if (!url || url === background.lastArtUrl || !background.translatedDirUrl)
            return;
        if (background._artCache[url]) {
            background.lastArtUrl = url;
            return;
        }
        background._pendingArtUrl = url;
        background._artSeq = (background._artSeq || 0) + 1;
        const seq = background._artSeq;
        const dir = background.translatedDirUrl.replace(/^file:\/\//, "");
        // Archivos temporales únicos por seq para impedir condiciones de carrera
        const raw = dir + ".art_" + seq + ".raw";
        const pngTmp = dir + ".art_" + seq + ".png";
        const texTmp = dir + "materials/.media_cover_" + seq + ".tex";
        const texOut = dir + "materials/media_cover.tex";
        const seqFile = dir + ".art_seq";
        const scriptsDir = Common.scriptsDir + "/";
        const texgen = "python3 '" + scriptsDir + "png2tex.py' '" + pngTmp + "' '" + texTmp + "'";
        const commit = "[ \"$(cat '" + seqFile + "' 2>/dev/null)\" = '" + seq + "' ] && mv -f '" + texTmp + "' '" + texOut + "'";
        const cleanup = "rm -f '" + raw + "' '" + pngTmp + "' '" + texTmp + "'";
        const conv = "(magick '" + raw + "' '" + pngTmp + "' 2>/dev/null"
            + " || convert '" + raw + "' '" + pngTmp + "' 2>/dev/null"
            + " || ffmpeg -y -loglevel error -i '" + raw + "' '" + pngTmp + "' 2>/dev/null"
            + " || cp -f '" + raw + "' '" + pngTmp + "')"
            + " && " + texgen
            + " && " + commit
            + " && " + cleanup
            + " && echo 'WEKCP_OK " + seq + " " + url + "'"
            + " || { " + cleanup + "; false; }";
        let dl = null;
        if (url.indexOf("http") === 0)
            dl = "curl -fsSL --max-time 12 -o '" + raw + "' '" + url + "'";
        else if (url.indexOf("file://") === 0)
            dl = "cp '" + decodeURIComponent(url.replace(/^file:\/\//, "")) + "' '" + raw + "'";
        if (dl) {
            const cmd = "echo -n '" + seq + "' > '" + seqFile + "' && " + dl + " && " + conv;
            artSource.connectSource(cmd);
        }
    }
    Timer {
        id: artPollTimer
        interval: 15000
        repeat: true
        triggeredOnStart: false
        running: false
    }

    WindowModel {
        id: windowModel
        screenGeometry: wallpaper.parent.screenGeometry
        filterByScreen: wallpaper.configuration.PauseFilterByScreen
        modePlay: wallpaper.configuration.PauseMode
        resumeTime: wallpaper.configuration.ResumeTime
    }

    PowerSource {
        id: powerSource
        readonly property bool reqPause: {
            (background.pauseOnBatPower && (st_battery_state == 'NoCharge' || st_battery_state == 'Discharging')) ||
            (background.pauseBatPercent !== 0 && st_battery_has && st_battery_percent < background.pauseBatPercent)
        }
    }

    // REMOVED: unmuteReload caused a full backend reload on every unmute,
    // which visually looks like the wallpaper "changes" (black flash, shader
    // recompile). Audio must be controlled through volume/mute properties
    // without restarting the wallpaper.

    // Auto-pause when another window has focus (saves CPU)
    // NOTE: gated on the configured pause mode — with PauseMode.Never the
    // user explicitly wants the wallpaper always playing. A wallpaper is a
    // desktop containment, Qt.application.active is false for it virtually
    // always, so an ungated timer here paused+blurred forever.
    Timer {
        id: focusPauseTimer
        interval: 2000
        repeat: true
        running: wallpaper.configuration.PauseMode !== Common.PauseMode.Never
        Component.onCompleted: {
            if (running && Qt.application.active === false)
                background.focusPause = true;
        }
        onTriggered: {
            if (!running) return;
            var newPause = !Qt.application.active;
            if (newPause !== background.focusPause) {
                background.focusPause = newPause;
                console.log("[WEK] focusPause=" + newPause + " Qt.application.active=" + Qt.application.active);
            }
        }
    }

    Pyext {
        id: pyext
    }
    WallpaperListModel {
        id: wpListModel
        enabled: true
        workshopDirs: Common.getProjectDirs(background.steamlibrary)
        globalConfigPath: Common.getGlobalConfigPath(background.steamlibrary)
        filterStr: background.filterStr
        initItemOp: (item) => {
            if(!background.customConf) return;
            item.favor = background.customConf.favor.has(item.workshopid);
            item.disabledInRandom = background.customConf.disabledInRandom.has(item.workshopid);
        }
        readfile: pyext.readfile

        function changeWallpaper(index) {
            if(this.model.count === 0) return;
            const model = this.model.get(index);
            if (model.broken) return;
            background.previousId = background.currentId;
            background.currentId = model.workshopid;
            wallpaper.configuration.WallpaperWorkShopId = model.workshopid;
            if (model.isPreset && model.dependency) {
                const lib = Common.urlNative(background.steamlibrary);
                const script = Common.scriptsDir + "/wek-preset.py";
                const baseMatch = (model.basepath || "").match(/\/([0-9]+)$/);
                const baseId = baseMatch ? baseMatch[1] : String(model.dependency);
                retranslateSource.connectSource(
                    "python3 '" + script + "' --library '" + lib + "' --preset '" + model.workshopid + "' --base '" + baseId + "' >/dev/null 2>&1 && echo WEKPRESET_OK"
                );
            }
            wallpaper.configuration.WallpaperSource = Common.packWallpaperSource(model);
        }
    }
    Timer {
        id: randomizeTimer
        running: background.randomizeWallpaper && background.switchTimer > 0
        interval: Math.max(background.switchTimer * 1000 * 60, 5000)
        repeat: true
        onTriggered: {
            // Double-guard: never change if user disabled randomization
            if (!background.randomizeWallpaper || background.switchTimer <= 0) return;
            if(!(background.noRandomWhilePaused && !background.ok)) {
                // Pick random item, skipping disabledInRandom ones.
                const candidates = [];
                for (let j = 0; j < wpListModel.model.count; j++) {
                    const m = wpListModel.model.get(j);
                    if (!m.disabledInRandom) candidates.push(j);
                }
                if (candidates.length > 0) {
                    const i = candidates[Math.floor(Math.random() * candidates.length)];
                    wpListModel.changeWallpaper(i);
                }
            }
        }
    }

    // lauch pause time to avoid freezing
    Timer {
        id: lauchPauseTimer
        running: false
        repeat: false
        interval: 300
        onTriggered: {
            // Instant-start: only hold the initial frame paused when the
            // wallpaper is actually meant to be paused right now.
            if (!background.ok && !background._waitingFirstFrame && backendLoader.item) backendLoader.item.pause();
            playTimer.start();
        }
    }
    Timer{
        id: playTimer
        running: false
        repeat: false
        interval: 5000
        onTriggered: { background.autoPause(); }
    }
    // lauch pause end

    // As always autoplay for refresh lastframe, sourceChange need autoPause
    // need a time for delay, which is needed for refresh
    function sourceCallback() {
        sourcePauseTimer.start();   
    }
    Timer {
        id: sourcePauseTimer
        running: false
        repeat: false
        interval: 200
        onTriggered: background.autoPause();
    }
    // main  
    Item { 
        id: backendLoader
        anchors.fill: parent
        clip: true
        property var item: null
        property var oldItem: null
        property var retries: 0

        signal loaded

        // Camera-parallax rig: the rendered wallpaper is slightly zoomed and
        // shifts opposite to the cursor, exactly like WE's cameraparallax.
        scale: background.parallaxApply ? (1.0 + background.parallaxAmount) : 1.0
        Behavior on scale {
            NumberAnimation { duration: background.parallaxDelay; easing.type: Easing.OutCubic }
        }
        transform: Translate {
            id: parallaxShift
            x: {
                const hook = background.mouseHooker;
                if (!background.parallaxApply || !hook || hook.trackPos.x < 0)
                    return 0;
                return -(hook.trackPos.x - backendLoader.width / 2) * background.parallaxInfluence;
            }
            y: {
                const hook = background.mouseHooker;
                if (!background.parallaxApply || !hook || hook.trackPos.y < 0)
                    return 0;
                return -(hook.trackPos.y - backendLoader.height / 2) * background.parallaxInfluence;
            }
            Behavior on x {
                NumberAnimation { duration: background.parallaxDelay; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                NumberAnimation { duration: background.parallaxDelay; easing.type: Easing.OutCubic }
            }
        }

        // If a freshly created backend never renders (broken scene, hw
        // hiccup), roll back to the wallpaper that was showing instead of
        // leaving a black screen or an error card. On the first backend (or
        // after a rollback with nothing to restore) the size-0 framebuffer
        // glitch during kwin's initial resize is transient -> recreate the
        // backend a few times before giving up.
        Timer {
            id: guardTimer
            // 45s: heavy pkgs (FNAF Office 4K: ~30MB of DXT textures plus
            // audio-bar shaders) legitimately take >20s to their first frame
            // on cold shader caches; 20s rolled those back mid-load.
            interval: 45000
            repeat: false
            onTriggered: {
                // A scene paused by loss of focus delays its first frame;
                // never roll back while the workspace is inactive.
                if (!Qt.application.active) {
                    guardTimer.start();
                    return;
                }
                const bl = backendLoader;
                if (bl.item && bl.oldItem) {
                    try { bl.item.destroy(); } catch(e) {}
                    bl.item = bl.oldItem;
                    bl.oldItem = null;
                    // Resume audio on the rolled-back wallpaper.
                    if (typeof bl.item.play === "function") bl.item.play();
                    transitionVeil.opacity = 0;
                    console.log("[WEK] backend did not render in 45s, rolled back to previous");
                    return;
                }
                bl.retries = bl.retries + 1;
                if (bl.retries <= 3 && background.source) {
                    console.log("[WEK] backend no first frame after 45s, retry #" + bl.retries);
                    background.loadBackend();
                } else {
                    console.log("[WEK] backend gave up after " + bl.retries + " retries");
                }
            }
        }

        // Keep the MouseGrabber's forwarding target in sync with whichever
        // backend is currently loaded (Scene.qml exposes getMouseTarget()).
        function changeMouseTarget() {
            if(!backendLoader.item || !background.mouseHooker) return;
            let re = backendLoader.item.mouseTarget || null;
            if(!re && typeof backendLoader.item.getMouseTarget === 'function') {
                const b = backendLoader.item.getMouseTarget();
                if(typeof b === 'function') { try { re = b() || b; } catch(e) { re = b; } }
                else re = b;
            }
            background.mouseHooker.target = re;
            console.log("[WEK] changeMouseTarget:", re);
        }
        Component.onCompleted: {
            this.loaded.connect(this.changeMouseTarget);
            background.mouseHookerChanged.connect(this.changeMouseTarget);
        }
        Component.onDestruction: {
            if(this.item) this.item.destroy();
        }
        function onWaywallenPauseChanged(paused) {
            background.backendPaused = paused;
        }
        function load(url, properties) {
            const com = Qt.createComponent(url);
            if(com.status === Component.Ready) {
                // Defer destruction: destroying an item mid-render causes QML
                // binding errors and miniaudio race crashes. Give it 1.5s to
                // finish any pending operations (shader compile, audio init).
                if (this.oldItem) {
                    try { this.oldItem.destroy(300); } catch(e) {}
                    this.oldItem = null;
                }
                this.oldItem = this.item;
                // Silence the previous wallpaper immediately so its audio
                // never stacks on top of the new one during the handoff.
                if (this.oldItem && typeof this.oldItem.pause === "function")
                    this.oldItem.pause();
                background._waitingFirstFrame = true;
                guardTimer.start();
                console.log("[WEK] load() guard armed");
                try {
                    this.item = com.createObject(this, properties);
                } catch(e) {
                    this.item = this.oldItem;
                    this.oldItem = null;
                    guardTimer.stop();
                    this.loadInfoShow(e);
                    return;
                }
                // Hide the new backend until its first REAL frame: while a
                // heavy scene initializes its FBO is still being set up, and
                // an un-cleared / half-filled back buffer composites as a
                // ghostly smear on top of the previous wallpaper (glitch on
                // heavy loads / fast switches). opacity 0 keeps it out of the
                // composite; onBackendFirstFrame() flips it to 1.
                if (this.item) {
                    try { this.item.opacity = 0; } catch(e) {}
                }
                this.loaded();
                if (url === "backend/Waywallen.qml" && this.item && this.item.pauseEffectActive !== undefined) {
                    background.backendPaused = this.item.pauseEffectActive;
                    this.item.pauseEffectActiveChanged.connect(backendLoader.onWaywallenPauseChanged);
                }
            } else if(com.status == Component.Error) {
                this.loadInfoShow(com.errorString());
            }
        }
function loadInfoShow(info) {
        this.load("backend/InfoShow.qml", {
            wid: background.workshopid,
            type: background.wallpaperType,
            info: info
        });
        // InfoShow paints plain QML (no scene FBO) and never emits a
        // first-frame signal, so reveal it immediately after the load.
        if (this.item)
            try { this.item.opacity = 1; } catch(e) {}
    }
    }

    function loadBackend() {
        let qmlsource = "";
        let properties = {};

    
        // check source
        if(!background.source) {
            backendLoader.loadInfoShow("Source is empty. The config may be broken.");
            return;
        }
        // waywallen daemon backend: renders through the daemon's own renderers
        // (wescene/weweb), which support the full WE feature set the SceneViewer
        // lacks (depth parallax, media player controls, cursor events, ...).
        if (background.waywallenBackend) {
            qmlsource = "backend/Waywallen.qml";
            backendLoader.load(qmlsource, properties);
            sourceCallback();
            return;
        }
        // choose backend
        switch (background.wallpaperType) {
            case 'video':
                if(background.videoBackend == Common.VideoBackend.Mpv && background.hasLib)
                    qmlsource = "backend/Mpv.qml";
                else qmlsource = "backend/QtMultimedia.qml";
                properties = {};
                break;
            case 'web':
                qmlsource = "backend/QtWebView.qml";
                properties = {readfile: pyext.readfile, qwebChannelJs: pyext.qwebChannelSource(), patchedHtml: pyext.patchedHtml};
                break;
            case 'scene':
                if(background.hasLib) {
                    qmlsource = "backend/Scene.qml";
                    properties = {"assets": Common.getAssetsPath(steamlibrary)};
                } else {
                    backendLoader.loadInfoShow("Plugin lib not found. To support scene, please compile and install it.");
                    return; 
                }
                break;
            default:
                backendLoader.loadInfoShow("Not supported wallpaper type");
                return; 
        }
        // Don't pass source as a constructor property — set it after load.
        // This ensures QML bindings (e.g. userProperties) are evaluated first,
        // so the C++ backend receives USER_PROPS before SOURCE/LOAD_SCENE.
        console.error("load backend: "+qmlsource);
        backendLoader.load(qmlsource, properties);
        if (background.waywallenBackend) return;
        backendLoader.item.source = background.wallpaperPath;
        sourceCallback();
    }
   
    function autoPause() {
        if (!backendLoader.item) return;
        if (background.pauseOverride) {
            backendLoader.item.pause();
            return;
        }
        if (background._waitingFirstFrame) {
            backendLoader.item.play();
            return;
        }
        background.ok
            ? backendLoader.item.play()
            : backendLoader.item.pause();
    }

    Component.onCompleted: {
        // Cache the plugin module availability exactly once (see hasLib).
        background.hasLib = Common.checklib_wallpaper(background);
        console.log("[WEK] weked lib ready: " + background.hasLib);
        // background signal connect FIRST so that a failure while loading
        // the initial backend can never break wallpaper changes afterwards.
        background.sig_backendFirstFrame.connect(background.onBackendFirstFrame);
        background.videoBackendChanged.connect(loadBackend);
        background.okChanged.connect(autoPause);
        background.sourceChanged.connect(applySource);
        background.currentId = wallpaper.configuration.WallpaperWorkShopId;
        lauchPauseTimer.start();
        // ONLY start randomize timer if the user actually wants randomization.
        // Calling start() unconditionally overrides the running binding and
        // causes the wallpaper to change every SwitchTimer minutes.
        if (background.randomizeWallpaper && background.switchTimer > 0)
            randomizeTimer.start();
        console.log("[WEK] boot v3 armed");

        // load first backend (last; guarded so startup never breaks switching)
        try {
            applySource();
        } catch(e) {
            console.log("[WEK] initial applySource failed: " + e);
        }

        if (!background._actionsRegistered
            && typeof Plasmoid !== "undefined"
            && Plasmoid.contextualActions) {
            background._actionsRegistered = true;
            console.log("[WEK] registering context menu actions");

            const nextAction = Qt.createQmlObject(
                'import org.kde.plasma.core as PlasmaCore; PlasmaCore.Action {}',
                background);
            nextAction.text = "Next Wallpaper";
            nextAction.icon.name = "media-skip-forward";
            nextAction.visible = Qt.binding(() => wpListModel.model.count > 1);
            nextAction.triggered.connect(() => {
                if (wpListModel.model.count === 0) return;
                const candidates = [];
                for (let j = 0; j < wpListModel.model.count; j++) {
                    const m = wpListModel.model.get(j);
                    if (!m.disabledInRandom) candidates.push(j);
                }
                const i = candidates.length > 0
                    ? candidates[Math.floor(Math.random() * candidates.length)]
                    : Math.floor(Math.random() * wpListModel.model.count);
                wpListModel.changeWallpaper(i);
            });
            Plasmoid.contextualActions.push(nextAction);

            const prevAction = Qt.createQmlObject(
                'import org.kde.plasma.core as PlasmaCore; PlasmaCore.Action {}',
                background);
            prevAction.text = "Previous Wallpaper";
            prevAction.icon.name = "media-skip-backward";
            prevAction.visible = Qt.binding(() =>
                background.previousId !== "" && wpListModel.model.count > 1);
            prevAction.triggered.connect(() => {
                for (let i = 0; i < wpListModel.model.count; i++) {
                    if (wpListModel.model.get(i).workshopid === background.previousId) {
                        wpListModel.changeWallpaper(i);
                        break;
                    }
                }
            });
            Plasmoid.contextualActions.push(prevAction);

            const pauseAction = Qt.createQmlObject(
                'import org.kde.plasma.core as PlasmaCore; PlasmaCore.Action {}',
                background);
            pauseAction.text = Qt.binding(() =>
                background.pauseOverride ? "Resume" : "Pause");
            pauseAction.icon.name = Qt.binding(() =>
                background.pauseOverride ? "media-playback-start" : "media-playback-pause");
            pauseAction.triggered.connect(() => {
                background.pauseOverride = !background.pauseOverride;
                background.autoPause();
            });
            Plasmoid.contextualActions.push(pauseAction);
            console.log("[WEK] actions registered");
        }
    }

    // ── waywallen-style blur on pause (auto-pause + blur) ───────────────
    // When the wallpaper auto-pauses (window covers / focus loss / battery)
    // or the screen locks, instead of freezing the frame bare, blur the
    // frozen frame like waywallen's BlurPauseEffect (MultiEffect, blurMax 64,
    // 180ms OutCubic easing). Cost is zero while the effect is inactive.
    MultiEffect {
        id: pauseBlur
        anchors.fill: parent
        source: backendLoader
        visible: background.blurActive
        autoPaddingEnabled: false
        blurEnabled: true
        blurMax: 64
        blur: background.blurActive ? background.blurRadius / 64.0 : 0.0
        Behavior on blur {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // Screen-lock watcher: kwin exposes org.freedesktop.ScreenSaver with the
    // ActiveChanged(bool) signal; poll GetActive as a fallback in case the
    // signal subscription is not delivered.
    Plasma5Support.DataSource {
        id: screenSaverSource
        engine: "DBus"
        connectedSources: ["org.freedesktop.ScreenSaver"]
        onDataChanged: {
            const svc = data["org.freedesktop.ScreenSaver"];
            if (!svc) return;
            let v = svc.ActiveChanged;
            if (v === undefined) v = svc.GetActive;
            if (Array.isArray(v)) v = v[0];
            if (typeof v === "boolean") background.lockPaused = v;
        }
    }
    Timer {
        id: lockPollTimer
        interval: 5000
        repeat: true
        running: background.blurOnLock
        onTriggered: {
            try {
                screenSaverSource.call("org.freedesktop.ScreenSaver/ScreenSaver",
                                       "org.freedesktop.ScreenSaver", "GetActive", []);
            } catch (e) {}
        }
        Component.onCompleted: {
            if (background.blurOnLock) {
                try {
                    screenSaverSource.call("org.freedesktop.ScreenSaver/ScreenSaver",
                                           "org.freedesktop.ScreenSaver", "GetActive", []);
                } catch (e) {}
            }
        }
    }

    // ── Wallpaper Selector (middle-click / Ctrl+W) ─────────────────────────
    // Transition veil: covers the wallpaper during backend swaps so half-
    // rendered frames never show (smooth/glitch-free switching).
    Rectangle {
        id: transitionVeil
        anchors.fill: parent
        color: "#000000"
        opacity: 0
        z: 15
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
    }
    Timer {
        id: veilFallback
        interval: 700
        repeat: false
        onTriggered: transitionVeil.opacity = 0
    }
    // Short crossfade mask triggered on the new backend's first frame:
    // veil 1 -> 0 with the 200ms Behavior hides the old->new pop.
    Timer {
        id: veilCrossfade
        interval: 30
        repeat: false
        onTriggered: transitionVeil.opacity = 0
    }

    // Debounce rapid card clicks so only the final pick applies.
    Timer {
        id: selectDebounce
        interval: 120
        repeat: false
        onTriggered: {
            if (background._pendingSelectIdx >= 0) {
                wpListModel.changeWallpaper(background._pendingSelectIdx);
                background._pendingSelectIdx = -1;
                background.selectorOpen = false;
                background.syncSelectorOpen();
            }
        }
    }

    // ── waywallen-style accent color sync ────────────────────────────────
    // When "Accent color from wallpaper" is enabled, notify Plasma that the
    // wallpaper changed every time content refreshes (first frame, backend
    // swap) so the "from the background colors" accent stays in sync.
    readonly property bool accentColorFromWallpaper: wallpaper.configuration
        ? wallpaper.configuration.AccentColorFromWallpaper
        : false

    function scheduleAccentColorRefresh() {
        if (!background.accentColorFromWallpaper) {
            accentColorRefreshTimer.stop();
            return;
        }
        accentColorRefreshTimer.restart();
    }

    function refreshAccentColor() {
        if (wallpaper.hasOwnProperty("accentColor")) {
            if (Qt.colorEqual(wallpaper.accentColor, "transparent")) {
                wallpaper.accentColorChanged();
            } else {
                wallpaper.accentColor = "transparent";
            }
        }
    }

    Timer {
        id: accentColorRefreshTimer
        interval: 2000
        repeat: false
        onTriggered: background.refreshAccentColor()
    }

    onAccentColorFromWallpaperChanged: {
        if (background.accentColorFromWallpaper)
            background.scheduleAccentColorRefresh();
        else
            accentColorRefreshTimer.stop();
    }

    // ── waywallen-style diagnostics overlay ──────────────────────────────
    Loader {
        anchors { top: parent.top; left: parent.left; margins: 12 }
        active: wallpaper.configuration.ShowDiagnostics === true
        z: 20

        sourceComponent: Rectangle {
            id: diagBox
            width: diagText.implicitWidth + 16
            height: diagText.implicitHeight + 12
            color: Qt.rgba(0, 0, 0, 0.55)
            radius: 6

            Text {
                id: diagText
                x: 8; y: 6
                color: "#cdd6f4"
                font.pixelSize: 13
                font.family: "monospace"
                text: {
                    let s = "source:   " + (background.wallpaperPath || "(none)")
                    s += "\ntype:     " + (background.wallpaperType || "-")
                    s += "\nbackend:  " + (background.nowBackend || "-")
                    s += "\nstate:    " + (background.ok ? "playing" : "paused")
                          + (background.pauseOverride ? " [manual-pause]" : "")
                    s += "\nblur:     " + (background.blurActive ? "on" : "off")
                          + " r=" + background.blurRadius
                    s += "\nlock:     " + (background.lockPaused ? "locked" : "-")
                          + "  bat-pause: " + (background.batteryPaused ? "on" : "-")
                    s += "\nmouse:    " + (background.mouseInput ? "forwarded" : "off")
                          + "  fps: " + (background.fps ? background.fps : "-")
                    s += "\nwindows:  " + diagText.windowsSummary()
                    return s
                }

                function windowsSummary() {
                    const list = background.windowModel ? background.windowModel.windows : null;
                    if (!list || list.length === 0)
                        return "0 covering windows";
                    let s = list.length + " covering: ";
                    for (let i = 0; i < list.length; i++) {
                        const w = list[i];
                        s += (w.app || "?") + "[" + (w.fullscreen ? "F" : w.maximized ? "M" : "-")
                             + (w.active ? "A" : "-") + "] ";
                    }
                    return s;
                }
            }
        }
    }

    // Ctrl+W bridge: KWin writes an increasing counter; each change toggles.
    Timer {
        id: selectorPollTimer
        interval: 300
        repeat: true
        running: true
        onTriggered: {
            if (!background.isSelectorOwner) return;
            background._readNativeText(Common.getAppletsRcPath(background.steamlibrary)).then(txt => {
                const widM = txt.match(/WallpaperWorkShopId=([0-9]{6,})/);
                if (widM && widM[1] && widM[1] !== background.currentId && wallpaper.configuration.WallpaperWorkShopId === widM[1]) {
                    background.currentId = widM[1];
                }
                const m = txt.match(/SelectorOpen=([0-9]+)/);
                if (!m) return;
                const v = m[1];
                if (background.selectorLastSeen === "") {
                    background.selectorLastSeen = v;
                    return;
                }
                if (v === background.selectorLastSeen) return;
                // Consume the counter even when the toggle must be ignored;
                // otherwise the same value is replayed after the debounce and
                // reopens the selector (the old intermittent "restart" bug).
                background.selectorLastSeen = v;
                if (selectDebounce.running) return;
                if (background.selectorOverlayItem
                        && background.selectorOverlayItem.applyingSelection) return;
                if (background.selectorOverlayItem
                        && Date.now() < (background.selectorOverlayItem.suppressToggleUntil || 0)) return;
                background.selectorOpen = !background.selectorOpen;
                background.syncSelectorOpen();
                console.log("[WEK] selector poll: toggle (counter " + v + ")");
            });
        }
    }

    // Injection: trigger + overlay live in the desktop's top layer so they
    // can actually receive mouse events.
    Timer {
        id: selectorInjectTimer
        interval: 2000
        repeat: true
        running: true
        onTriggered: background.ensureSelectorInjection();
    }

}
}
