import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.5
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami 2.4 as Kirigami

import "page"

import "js/utils.mjs" as Utils
import org.kde.plasma.plasma5support as P5Support

ColumnLayout {
    id: root
    spacing: 5

    // Устанавливаем тему для всех дочерних элементов
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    // Required by Plasma 6
    property var configDialog
    property var wallpaperConfiguration

    property string cfg_SteamLibraryPath
    property string cfg_WallpaperWorkShopId
    property string cfg_WallpaperSource
    property string cfg_FilterStr
    property int    cfg_SortMode
    property string cfg_VideoFolderPath

    property alias  cfg_Fps:                 settingPage.cfg_Fps
    property alias  cfg_Volume:              settingPage.cfg_Volume
    property alias  cfg_MpvStats:            settingPage.cfg_MpvStats
    property alias  cfg_Speed:               settingPage.cfg_Speed
    property alias  cfg_MuteAudio:           settingPage.cfg_MuteAudio
    property alias  cfg_MouseInput:          settingPage.cfg_MouseInput
    property alias  cfg_TrailsEnabled:       settingPage.cfg_TrailsEnabled
    property alias  cfg_SceneMode:          settingPage.cfg_SceneMode
    property alias  cfg_TrailStyle:          settingPage.cfg_TrailStyle
    property alias  cfg_SelectorStyle:       settingPage.cfg_SelectorStyle
    property alias  cfg_AnimatedPreview:     settingPage.cfg_AnimatedPreview
    property alias  cfg_ResumeTime:          settingPage.cfg_ResumeTime
    property alias  cfg_SwitchTimer:         settingPage.cfg_SwitchTimer
    property alias  cfg_RandomizeWallpaper:  settingPage.cfg_RandomizeWallpaper
    property alias  cfg_NoRandomWhilePaused: settingPage.cfg_NoRandomWhilePaused
    property alias  cfg_PauseFilterByScreen: settingPage.cfg_PauseFilterByScreen
    property alias  cfg_PauseOnBatPower:     settingPage.cfg_PauseOnBatPower
    property alias  cfg_PauseBatPercent:     settingPage.cfg_PauseBatPercent
    property alias  cfg_HdrOutput:           settingPage.cfg_HdrOutput
    property alias  cfg_SystemAudioCapture:  settingPage.cfg_SystemAudioCapture
    property alias  cfg_SystemPlayerCapture: settingPage.cfg_SystemPlayerCapture
    property alias  cfg_BlurOnPause:        settingPage.cfg_BlurOnPause
    property alias  cfg_BlurRadius:         settingPage.cfg_BlurRadius
    property alias  cfg_BlurOnLock:         settingPage.cfg_BlurOnLock
    property alias  cfg_WaywallenBackend:   settingPage.cfg_WaywallenBackend
    property alias  cfg_AccentColorFromWallpaper: settingPage.cfg_AccentColorFromWallpaper
    property alias  cfg_ShowDiagnostics:    settingPage.cfg_ShowDiagnostics
    property alias  cfg_ParallaxEnable:     settingPage.cfg_ParallaxEnable
    property alias  cfg_ParallaxAmount:     settingPage.cfg_ParallaxAmount
    property alias  cfg_ParallaxInfluence:  settingPage.cfg_ParallaxInfluence
    property alias  cfg_ParallaxDelay:      settingPage.cfg_ParallaxDelay
    property int    cfg_DisplayMode
    property int    cfg_PauseMode
    property int    cfg_VideoBackend

    property int    cfg_PerOptChanged: 0

    //property alias  cfg_UseMpv
    //property string cfg_BackgroundColor: "black"
    //property alias  cfg_FilterMode: wallpaperPage.cfg_FilterMode

    property string cfg_CustomConf
    property var customConf: {
        customConf = Common.loadCustomConf(cfg_CustomConf);
    }

    // ── Workshop preset (dependency) support ─────────────────────────────
    // A preset item stores only project.json ("preset" + "dependency"); the
    // real wallpaper is the dependency. Selecting "Install dependency and
    // apply preset" downloads the dependency, writes the preset into its
    // user_props and activates the base wallpaper.
    property string _pendingPresetId: ""
    property string _pendingDependencyId: ""
    property var _pendingPresetData: null
    property var _pendingBaseData: null
    property bool _presetApplying: false
    property int _presetTicks: 0
    property string _reinstallStatus: ""
    readonly property string _presetScript: {
        let s = Common.urlNative(Qt.resolvedUrl("../scripts/wek-preset.py"));
        try { s = decodeURIComponent(s); } catch (e) {}
        return s;
    }

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function nativeLibPath(p) {
        let s = Common.urlNative(p || "");
        try { s = decodeURIComponent(s); } catch (e) {}
        return s;
    }

    function clearPendingPreset() {
        root._pendingPresetId = "";
        root._pendingDependencyId = "";
        root._pendingPresetData = null;
        root._pendingBaseData = null;
        root._presetTicks = 0;
        presetApplyTimer.stop();
    }

    function itemPayloadReady(dir, p) {
        const typ = p.type ? String(p.type).toLowerCase() : "";
        const file = p.file ? String(p.file).replace(/\\/g, "/") : "";
        if (!typ || !file) return Promise.resolve(true);
        const base = file.split("/").pop();
        return pyext.get_folder_list(dir, { only_dir: false }).then(res => {
            const names = new Set((res && res.items ? res.items : []).map(x => x.name));
            if (names.has(base)) return true;
            if (typ === "scene" && names.has(base.replace(/\.json$/i, ".pkg")))
                return true;
            return false;
        });
    }

    function tryApplyPendingPreset() {
        if (root._presetApplying) return Promise.resolve(false);
        if (!root._pendingDependencyId || !pyext) return Promise.resolve(false);
        const depId = root._pendingDependencyId;
        const lib = root.nativeLibPath(root.cfg_SteamLibraryPath);
        const dir = Common.getWorkshopDir(lib) + "/" + depId;
        return pyext.readfile(dir + "/project.json").then(txt => {
            const p = Utils.parseJson(txt);
            if (!p) return false;
            // The direct dependency can itself be a preset: follow the chain
            // until we reach the item that really renders (file + type).
            if (!p.file || !p.type) {
                if (p.dependency && String(p.dependency) !== depId) {
                    const next = String(p.dependency);
                    root._pendingDependencyId = next;
                    root._presetTicks = 0;
                    workshopPage.statusText = "Downloading base template #"
                        + next + "…";
                    workshopPage.startInstall(next, true, false);
                } else {
                    workshopPage.statusText = "Item #" + depId
                        + " has no payload and no usable dependency.";
                }
                return false;
            }
            // project.json may arrive before scene.pkg / the video. Do not
            // activate the base until its actual payload is on disk.
            return root.itemPayloadReady(dir, p).then(ready => {
                if (!ready) return false;
                // Stage the preset's own files/ assets inside the base folder
                // (and the translated folder), rewrite the paths and write
                // user_props. The script follows the full dependency chain.
                root._pendingBaseData = p;
                root._presetApplying = true;
                presetApplyTimer.stop();
                workshopPage.statusText = "Applying preset over base #" + depId
                    + (p.title ? " (" + p.title + ")" : "") + "…";
                presetRunner.connectSource(
                    "/usr/bin/python3 " + root.shellQuote(root._presetScript)
                    + " --library " + root.shellQuote(lib)
                    + " --preset " + root.shellQuote(root._pendingPresetId)
                    + " --base " + root.shellQuote(depId)
                );
                return true;
            });
        }).catch(() => false);
    }

    function installPreset(presetId, dependencyId, preset) {
        if (!dependencyId) return;
        if (!pyext) {
            workshopPage.statusText = "Python/FileHelper helper is not ready.";
            return;
        }
        if (workshopPage.nowWorking) {
            workshopPage.statusText = "Wait for the current download to finish.";
            return;
        }
        root._pendingPresetId = String(presetId);
        root._pendingDependencyId = String(dependencyId);
        root._pendingPresetData = preset || ({});
        root._presetTicks = 0;
        // force=true bypasses the QML "already installed" check only; a
        // complete dependency just makes the downloader print OK. It must not
        // re-download the base, so reinstall stays false.
        workshopPage.startInstall(root._pendingDependencyId, true, false);
        presetApplyTimer.start();
    }

    P5Support.DataSource {
        id: presetRunner
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            const chunk = data && data.stdout !== undefined ? String(data.stdout) : "";
            if (chunk.length > 0)
                console.log("[WEK preset] " + chunk.trim());
            const code = data ? data["exit code"] : undefined;
            if (code === undefined || code === null || code === "") return;
            presetRunner.disconnectSource(source);
            root._presetApplying = false;
            const baseId = root._pendingDependencyId;
            const presetId = root._pendingPresetId || baseId;
            const baseData = root._pendingBaseData;
            if (Number(code) === 0) {
                root.cfg_WallpaperWorkShopId = presetId;
                if (baseData && baseData.file && baseData.type) {
                    const lib = root.nativeLibPath(root.cfg_SteamLibraryPath);
                    const dir = Common.getWorkshopDir(lib) + "/" + baseId;
                    root.cfg_WallpaperSource = Common.packWallpaperSource({
                        path: Qt.resolvedUrl(dir).toString(),
                        file: baseData.file,
                        type: String(baseData.type).toLowerCase()
                    });
                }
                // Force the running wallpaper to reload the new user_props.
                root.cfg_PerOptChanged = (root.cfg_PerOptChanged + 1) % 100000;
                workshopPage.statusText = "Preset #" + root._pendingPresetId
                    + " applied over base #" + baseId
                    + (baseData && baseData.title ? " (" + baseData.title + ")" : "")
                    + ".";
                root.clearPendingPreset();
                wpListModel.refresh();
            } else {
                const err = chunk.trim().split("\n")
                    .filter(l => l.indexOf("ERROR ") === 0).pop();
                workshopPage.statusText = err
                    ? err.slice(6)
                    : ("Could not apply preset (code " + code + ").");
                root.clearPendingPreset();
            }
        }
    }

    Timer {
        id: presetApplyTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (root._presetApplying) return;
            if (!root._pendingDependencyId) { stop(); return; }
            root._presetTicks++;
            if (root._presetTicks > 900) {
                workshopPage.statusText = "Timed out waiting for dependency #"
                    + root._pendingDependencyId;
                root.clearPendingPreset();
                return;
            }
            root.tryApplyPendingPreset().then(ok => {
                if (ok) { presetApplyTimer.stop(); return; }
                // The downloader stopped without a usable dependency.
                if (root._presetTicks > 8 && !workshopPage.nowWorking) {
                    const msg = workshopPage.statusText
                        || ("Could not install dependency #" + root._pendingDependencyId);
                    workshopPage.statusText = msg;
                    root.clearPendingPreset();
                }
            });
        }
    }

    property var iconSizes: {
        if(PlasmaCore.Units) {
            iconSizes = PlasmaCore.Units.iconSizes;
        } else {
            iconSizes = {
                large: 48
            }
        }
    }
    // property var themeWidth: {
    //     if(PlasmaCore.Theme && PlasmaCore.Theme.mSize) {
    //         themeWidth = PlasmaCore.Theme.mSize(theme.defaultFont).width;
    //     } else if(theme) {
    //         themeWidth = theme.mSize(theme.defaultFont).width;
    //     } else {
    //         themeWidth = font.pixelSize;
    //     }
    // }

    property var libcheck: ({
        wallpaper: false,
        qtwebchannel: false
    })

    property var plugin_info: ({
        version: "-",
        cache_path: null
    })

    property var pyext: null

    Component.onCompleted: {
        try {
            let lc_wallpaper = Common.checklib_wallpaper(root);
            let lc_webchannel = Common.checklib_webchannel(root);
            libcheck = { wallpaper: lc_wallpaper, qtwebchannel: lc_webchannel };
            if (lc_wallpaper) {
                let pi = Qt.createQmlObject(`
                    import QtQuick 2.0;
                    import com.github.catsout.wallpaperEngineKde 1.2
                    PluginInfo {}
                `, root);
                if (pi) plugin_info = pi;
            }
        } catch (error) {
            console.error("[WEK] plugin/lib check failed in config dialog: " + error);
        }
        try {
            let py = Qt.createQmlObject(`
                import QtQuick 2.0;
                Pyext {}
            `, root);
            if (py) pyext = py;
        } catch (error) {
            console.error("[WEK] pyext failed in config dialog: " + error);
        }
    }

    function saveConfig() {
        wallpaperPage.saveConfig();
    }

    function refreshWallpaperList() {
        return wpListModel.refresh();
    }

    WallpaperListModel {
        id: wpListModel
        workshopDirs: Common.getProjectDirs(cfg_SteamLibraryPath)
        globalConfigPath: Common.getGlobalConfigPath(cfg_SteamLibraryPath)
        filterStr: cfg_FilterStr
        sortMode: cfg_SortMode
        initItemOp: (item) => {
            if(!root.customConf) return;
            item.favor = root.customConf.favor.has(item.workshopid);
        }
        enabled: Boolean(cfg_SteamLibraryPath)
        readfile: pyext ? pyext.readfile : null
    }

    Component.onDestruction: {
        if(this.pyext) this.pyext.destroy();
    }

    function saveCustomConf() {
        cfg_CustomConf = Common.prepareCustomConf(this.customConf);
    }


    // Content
    PlasmaComponents.TabBar {
        id: bar
        implicitWidth: font.pixelSize*8 * 5
        PlasmaComponents.TabButton {
            text: "Wallpapers"
        }
        PlasmaComponents.TabButton {
            text: "Videos"
        }
        PlasmaComponents.TabButton {
            text: "Workshop"
        }
        PlasmaComponents.TabButton {
            text: "Settings"
        }
        PlasmaComponents.TabButton {
            text: "About"
        }
    }

    StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: bar.currentIndex

        WallpaperPage {
            id: wallpaperPage
            deleteHelper: deleteHelper
            presetBusy: root._pendingDependencyId !== ""
            presetMessage: root._pendingDependencyId !== ""
                ? workshopPage.statusText : root._reinstallStatus
            onPresetApplyRequested: (presetId, dependencyId, preset) => {
                root.installPreset(presetId, dependencyId, preset);
            }
            onReinstallRequested: (itemId) => {
                if (root._pendingDependencyId) {
                    workshopPage.statusText = "Wait for the current install to finish.";
                    return;
                }
                root._reinstallStatus = "Reinstalling #" + itemId + "…";
                workshopPage.statusText = root._reinstallStatus;
                workshopPage.startInstall(itemId, true, true);
            }
        }

        VideoPage {
            id: videoPage
            deleteHelper: deleteHelper
            cfg_VideoFolderPath: root.cfg_VideoFolderPath
            activeWorkshopId: root.cfg_WallpaperWorkShopId
            cachePath: root.plugin_info ? (root.plugin_info.cache_path || "") : ""
            pyext: root.pyext
            onCfg_VideoFolderPathChanged: root.cfg_VideoFolderPath = videoPage.cfg_VideoFolderPath
            onCommitWallpaper: (item) => {
                root.cfg_WallpaperWorkShopId = "";
                root.cfg_WallpaperSource = Common.packWallpaperSource(item);
            }
        }

        WorkshopPage {
            id: workshopPage
            steamLibraryPath: root.cfg_SteamLibraryPath
            pyext: root.pyext
            activeWorkshopId: root.cfg_WallpaperWorkShopId
            onCommitWallpaper: (item) => {
                root.cfg_WallpaperWorkShopId = item.workshopid;
                root.cfg_WallpaperSource = Common.packWallpaperSource(item);
            }
            onPresetRequested: (presetId, dependencyId, preset) => {
                root.installPreset(presetId, dependencyId, preset);
            }
            onWallpaperDownloaded: {
                root._reinstallStatus = "✓ Reinstalled & verified.";
                root.cfg_PerOptChanged = (root.cfg_PerOptChanged + 1) % 100000;
                wpListModel.refresh();
                workshopPage.refreshInstalled();
                if (root._pendingDependencyId)
                    root.tryApplyPendingPreset();
            }
        }

        SettingPage {
            id: settingPage
        }

        AboutPage {}
    }

    DeleteHelper {
        id: deleteHelper
        configRoot: root
        pyext: root.pyext
        wpListModel: wpListModel
        workshopPage: workshopPage
        onFinished: (ok) => {
            if (ok) wpListModel.refresh();
        }
    }
}
