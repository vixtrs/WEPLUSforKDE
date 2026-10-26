import QtQuick 2.6
import org.kde.plasma.plasma5support as P5Support
import ".."

Item {
    id: root

    property var    configRoot: null
    property var    pyext: null
    property var    wpListModel: null
    property var    workshopPage: null
    property string pendingDeleteId: ""
    property string pendingDeletePath: ""

    readonly property string _dlScript: {
        let s = Common.urlNative(Qt.resolvedUrl("../../scripts/wek-download.py"));
        try { s = decodeURIComponent(s); } catch (e) {}
        return s;
    }

    signal finished(bool ok)

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function deleteWallpaper(item) {
        if (!item) return;
        let p = Common.urlNative(item.path || "");
        try { p = decodeURIComponent(p); } catch (e) {}
        const id = String(item.workshopid || "").trim();
        if (!id || !/^[0-9a-zA-Z_\-]+$/.test(id)) return;

        const safe = /(431960\/[0-9]+)$/.test(p)
                  || /wallpaper_engine\/projects\/(defaultprojects|myprojects)\/[^/]+$/.test(p);
        if (!safe) return;

        root.pendingDeleteId = id;
        root.pendingDeletePath = p;

        let libClean = configRoot ? Common.urlNative(configRoot.cfg_SteamLibraryPath || "") : "";
        try { libClean = decodeURIComponent(libClean); } catch (e) {}

        const cmd = "/usr/bin/python3 " + root.shellQuote(root._dlScript)
                  + " --library " + root.shellQuote(libClean)
                  + " --item " + root.shellQuote(id)
                  + " --delete-all";
        rmRunner.connectSource(cmd);
    }

    P5Support.DataSource {
        id: rmRunner
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            const code = data ? data["exit code"] : undefined;
            if (code === undefined || code === null || code === "") return;
            rmRunner.disconnectSource(source);
            const id = root.pendingDeleteId;
            root.pendingDeleteId = "";
            root.pendingDeletePath = "";
            if (root.configRoot) {
                if (id && root.configRoot.cfg_WallpaperWorkShopId === id) {
                    root.configRoot.cfg_WallpaperWorkShopId = "";
                    root.configRoot.cfg_WallpaperSource = "";
                }
                if (root.pyext && id) root.pyext.reset_wallpaper_config(id);
                if (root.workshopPage) root.workshopPage.refreshInstalled();
                if (root.wpListModel) root.wpListModel.refresh();
            }
            root.finished(Number(code) === 0);
        }
    }
}
