import QtQuick 2.5
import com.github.catsout.wallpaperEngineKde 1.2
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.private.mpris as Mpris
import ".."

Item {
    id: sceneItem
    anchors.fill: parent
    property alias source: player.source
    property string assets: "assets"
    property int displayMode: background.displayMode
    property string userPropsJson: background.userPropsJson
    property alias mouseTarget: player
    property int _dumpN: 0

    // ── waywallen-style media interactivity (v17) ────────────────────────
    // El motor C++ (SceneViewer) solo actualiza en tiempo real el mapa
    // `engine.userProperties` hacia los scripts JS de las capas. Combinado
    // con el polyfill universal `__wekTick()` (translate_pkg.py v17), este
    // puente alimenta tanto `engine.userProperties.u_*` como los eventos
    // `mediaPropertiesChanged`, `mediaPlaybackChanged`, `mediaTimelineChanged`
    // y `mediaThumbnailChanged` sin provocar tormentas de recarga.
    property var mediaUserVars: ({})
    property bool burstGuard: false
    property real lastLoggedPos: 0

    // ── Estimador y ancla local de tiempo (I-03) ─────────────────────────
    property bool _posPlaying: false
    property real _posAnchorUs: 0
    property double _posAnchorClock: 0
    property real _durUs: 0
    property real _lastPushedPosS: -10
    property double _lastPushedPosClock: 0
    property real _lastPushedDurS: 0

    // ── Puente nativo MPRIS2 de Plasma (fuente autoritativa) ─────────────
    property bool _useNativeMpris: true
    property var _lastGoodPlayer: null
    property int _mediaLastState: -1
    property int _anchorLogs: 0
    property bool _mediaAnySignal: false
    property string _lastPushedTitle: ""
    property string _lastPushedArtist: ""
    property string _lastPushedArtUrl: ""

    function isBrowserPlayer(p) {
        if (!p) return false;
        const id = String(p.identity || p.dbusName || "").toLowerCase();
        return id.indexOf("firefox") >= 0
            || id.indexOf("chrom") >= 0
            || id.indexOf("brave") >= 0
            || id.indexOf("vivaldi") >= 0
            || id.indexOf("edge") >= 0
            || id.indexOf("opera") >= 0
            || id.indexOf("zen") >= 0;
    }

    function mediaStateOf(p) {
        // PlaybackStatus::Status enum: 0=Stopped, 1=Paused, 2=Playing.
        // En QML puede llegar como número (2) o como string ("Playing").
        // IMPORTANTE: jamás asumir Playing solo porque length > 0; eso hacía
        // que pestañas pausadas de Firefox reportaran Playing (2) y pisaran
        // la portada de Spotify con miniaturas 336x188 de YouTube.
        if (!p) return 0;
        const ps = String(p.playbackStatus || "").toLowerCase();
        if (ps === "2" || ps === "playing") return 2;
        if (ps === "1" || ps === "paused") return 1;
        return 0;
    }

    function pickNativePlayer() {
        try {
            const cp = mprisNative.currentPlayer || null;
            if (!cp) return sceneItem._lastGoodPlayer || null;

            const st = sceneItem.mediaStateOf(cp);
            const isBrowser = sceneItem.isBrowserPlayer(cp);

            // Si currentPlayer saltó a un navegador que NO está reproduciendo
            // y tenemos un reproductor dedicado (ej. Spotify) guardado o pista
            // activa previa, mantenemos el reproductor bueno.
            if (isBrowser && st !== 2) {
                if (sceneItem._lastGoodPlayer && sceneItem._lastGoodPlayer !== cp) {
                    try {
                        if (sceneItem._lastGoodPlayer.track !== undefined)
                            return sceneItem._lastGoodPlayer;
                    } catch (e) {}
                }
                if (sceneItem._lastPushedTitle !== "")
                    return null;
            }

            if (!isBrowser || st === 2) {
                sceneItem._lastGoodPlayer = cp;
            }
            return cp;
        } catch (e) {
            return sceneItem._lastGoodPlayer || null;
        }
    }

    function nativeState() {
        const p = sceneItem.pickNativePlayer();
        if (!p) return -1;
        return sceneItem.mediaStateOf(p);
    }

    function pushNativeProperties(p) {
        if (!p) return;
        const title = String(p.track || "");
        const artist = Array.isArray(p.artist) ? p.artist.join(", ") : String(p.artist || "");
        const album = String(p.album || "");
        const albumArtist = String(p.albumArtist || artist || "");
        const artUrl = p.artUrl ? String(p.artUrl) : "";

        player.mediaPropertiesChanged(title, artist, album, albumArtist, "");
        sceneItem.applyMediaUserVars({
            u_title: title,
            u_artist: artist,
            u_album: album,
            u_albumartist: albumArtist,
            u_genres: ""
        });

        sceneItem._lastPushedTitle = title;
        sceneItem._lastPushedArtist = artist;

        if (background.mediaThumbAvailable && artUrl) {
            sceneItem._lastPushedArtUrl = artUrl;
            background.fetchCoverArt(artUrl);
            player.mediaThumbnailChanged(true, []);
        }
    }

    function pushNativeTimeline(p, forcePush) {
        if (!p) return;
        const posUs = Number(p.position) || 0;
        const lenUs = Number(p.length) || 0;
        const posS = Math.max(0, Math.round(posUs > 100000 ? posUs / 1e6 : posUs));
        const lenS = Math.max(0, Math.round(lenUs > 100000 ? lenUs / 1e6 : lenUs));

        player.mediaTimelineChanged(posS, lenS);

        const now = Date.now();
        const elapsedSincePush = sceneItem._posPlaying
            ? (now - sceneItem._lastPushedPosClock) / 1000.0
            : 0;
        const expectedPos = sceneItem._lastPushedPosS + elapsedSincePush;
        const drift = Math.abs(posS - expectedPos);

        // Solo empujamos u_position / u_duration por userProperties cuando:
        // 1) Se fuerza (cambio de pista, cambio de estado play/pause o firstFrame)
        // 2) Cambia la duración total de la canción
        // 3) Hay un salto/seek o deriva > 1.5s respecto al reloj local
        // 4) Han pasado >= 10s desde el último ancla mientras reproduce
        if (forcePush
            || lenS !== sceneItem._lastPushedDurS
            || drift > 1.5
            || (sceneItem._posPlaying && (now - sceneItem._lastPushedPosClock >= 10000))) {
            sceneItem._lastPushedPosS = posS;
            sceneItem._lastPushedPosClock = now;
            sceneItem._lastPushedDurS = lenS;
            sceneItem.applyMediaUserVars({
                u_position: posS,
                u_duration: lenS
            });
        }

        sceneItem._posAnchorUs = posS;
        sceneItem._posAnchorClock = now;
        if (lenS > 0)
            sceneItem._durUs = lenS * 1000;
    }

    function syncFromNative() {
        if (!sceneItem._useNativeMpris) return;
        const p = sceneItem.pickNativePlayer();
        if (!p) return;

        const st = sceneItem.mediaStateOf(p);
        let stateChanged = false;
        if (st !== sceneItem._mediaLastState) {
            sceneItem._mediaLastState = st;
            sceneItem._posPlaying = (st === 2);
            stateChanged = true;
            player.mediaPlaybackChanged(st);
            sceneItem.applyMediaUserVars({ u_playstate: st });
            console.log("[MEDIA NATIVE] state:", st, "|", p.identity);
        }

        const title = String(p.track || "");
        const artist = Array.isArray(p.artist) ? p.artist.join(", ") : String(p.artist || "");
        let trackChanged = false;
        if (title && (title !== sceneItem._lastPushedTitle || artist !== sceneItem._lastPushedArtist)) {
            trackChanged = true;
            console.log("[MEDIA NATIVE] track:", title, "|", artist);
            sceneItem.pushNativeProperties(p);
        }

        // Capturar artUrl incluso si Spotify lo publica unos ms después del cambio de título
        const artUrl = p.artUrl ? String(p.artUrl) : "";
        if (artUrl && artUrl !== sceneItem._lastPushedArtUrl && background.mediaThumbAvailable) {
            sceneItem._lastPushedArtUrl = artUrl;
            background.fetchCoverArt(artUrl);
            player.mediaThumbnailChanged(true, []);
        }

        sceneItem.pushNativeTimeline(p, stateChanged || trackChanged);
        posTicker.running = (st === 2) || ((Number(p.length) || 0) > 0);
    }

    Timer {
        id: syncThrottler
        interval: 60
        repeat: false
        onTriggered: sceneItem.syncFromNative()
    }

    Timer {
        id: posTicker
        interval: 2000
        repeat: true
        running: true
        onTriggered: {
            sceneItem.syncFromNative();
        }
    }

    Mpris.Mpris2Model {
        id: mprisNative
        onCurrentPlayerChanged: sceneItem.syncFromNative()
        onDataChanged: syncThrottler.restart()
    }

    Connections {
        target: sceneItem._useNativeMpris ? mprisNative.currentPlayer : null
        function onPositionChanged() {
            const p = sceneItem.pickNativePlayer();
            if (p) sceneItem.pushNativeTimeline(p, false);
        }
        function onPlaybackStatusChanged() {
            syncThrottler.restart();
        }
    }

    Timer {
        id: nativeBootSync
        interval: 600
        repeat: true
        running: sceneItem._useNativeMpris
        property int tries: 0
        onTriggered: {
            tries++;
            sceneItem.syncFromNative();
            if (mprisNative.currentPlayer || tries > 25) {
                running = false;
                tries = 0;
            }
        }
    }

    Timer {
        id: mediaBtnRetry
        interval: 300
        repeat: false
        property string name: ""
        onTriggered: {
            const np = sceneItem._useNativeMpris ? sceneItem.pickNativePlayer() : null;
            if (!np) return;
            const a = name.toLowerCase();
            try {
                if (a.indexOf("playpause") >= 0 || a === "bplaypause") np.PlayPause();
                else if (a.indexOf("next") >= 0) np.Next();
                else if (a.indexOf("prev") >= 0) np.Previous();
                else if (a === "play") np.Play();
                else if (a === "pause") np.Pause();
            } catch (e) {}
        }
    }

    // ── Ruta Legacy DBus / MprisMonitor (desactivada cuando _useNativeMpris=true) ──
    Plasma5Support.DataSource {
        id: mprisDBus
        engine: "DBus"
        connectedSources: []
        onDataChanged: {
            if (!sceneItem._useNativeMpris)
                sceneItem.mprisRefreshAnchor();
        }
    }

    function mprisConnect() {
        if (sceneItem._useNativeMpris) return;
        var want = "org.mpris.MediaPlayer2.spotify";
        var cur = null;
        try { cur = mprisDBus.connectedSources[0]; } catch(e) {}
        if (cur === want) return;
        try { if (cur) mprisDBus.disconnectSource(cur); } catch(e2) {}
        try {
            mprisDBus.connectSource(want + "|/org/mpris/MediaPlayer2|org.mpris.MediaPlayer2.Player");
        } catch(e3) {}
    }

    function mprisRefreshAnchor() {
        if (sceneItem._useNativeMpris) return;
        var svc = null;
        try { svc = mprisDBus.sources[0]; } catch (e) {}
        if (!svc) return;
        var d;
        try { d = mprisDBus.data[svc]; } catch (e) { d = undefined; }
        if (!d) return;
        function pick(iface, prop) {
            try {
                var v = d[iface] ? d[iface][prop] : undefined;
                if (Array.isArray(v)) v = v[0];
                return (typeof v === "number") ? v : undefined;
            } catch (e2) { return undefined; }
        }
        var pos = pick("org.mpris.MediaPlayer2.Player", "Position");
        var len = pick("org.mpris.MediaPlayer2.Player", "Length") !== undefined
                  ? pick("org.mpris.MediaPlayer2.Player", "Length")
                  : pick("org.mpris.MediaPlayer2.Player", "mpris:length");
        var status = pick("org.mpris.MediaPlayer2.Player", "PlaybackStatus");
        if (typeof status === "string" && sceneItem._mediaLastState === -1) {
            sceneItem._mediaLastState = (status === "Playing") ? 2 : ((status === "Paused") ? 1 : 0);
            sceneItem._posPlaying = (status === "Playing");
            try { player.mediaPlaybackChanged(sceneItem._mediaLastState); } catch(e4) {}
        }
        if (pos !== undefined) sceneItem._posAnchorUs = pos;
        if (len !== undefined && len > 0) sceneItem._durUs = len;
        sceneItem._posAnchorClock = Date.now();
    }

    Timer {
        id: posEstimator
        interval: 1000
        repeat: true
        running: background.systemPlayerCapture && sceneItem._posPlaying && !sceneItem._useNativeMpris
        onTriggered: {
            if (!sceneItem._posPlaying) return;
            var elapsedUs = (Date.now() - sceneItem._posAnchorClock) * 1000;
            var est = sceneItem._posAnchorUs + elapsedUs;
            if (sceneItem._durUs > 0 && est > sceneItem._durUs) est = sceneItem._durUs;
            try {
                player.mediaTimelineChanged(est, sceneItem._durUs);
                sceneItem.applyMediaUserVars({ u_position: est, u_duration: sceneItem._durUs });
            } catch (e) {}
        }
    }

    Timer {
        id: mediaSyncTimer
        interval: 600
        repeat: false
        onTriggered: {
            sceneItem.syncFromNative();
        }
    }

    Timer {
        id: mediaReconnectTimer
        interval: 800
        repeat: false
        onTriggered: {
            if (!sceneItem._useNativeMpris)
                mprisMonitor.enabled = background.systemPlayerCapture;
        }
    }

    Timer {
        id: mediaRefreshTimer
        interval: 20000
        repeat: true
        running: background.systemPlayerCapture || sceneItem._useNativeMpris
        onTriggered: {
            try {
                const p = sceneItem.pickNativePlayer();
                if (!p) return;
                const title = String(p.track || "");
                if (title) {
                    sceneItem.pushNativeProperties(p);
                }
            } catch(e) {}
        }
    }

    property int _mediaRetries: 0
    Timer {
        id: mediaBootWatchdog
        interval: 12000
        running: background.systemPlayerCapture && !sceneItem._useNativeMpris && sceneItem._mediaRetries < 3
        repeat: true
        onTriggered: {
            if (!sceneItem._mediaAnySignal) {
                sceneItem._mediaRetries += 1;
                sceneItem.mediaForceReconnect();
            }
        }
    }

    Timer {
        id: mediaBootInit
        interval: 6000
        repeat: false
        running: background.systemPlayerCapture && !sceneItem._useNativeMpris
        onTriggered: {
            sceneItem.mprisConnect();
            sceneItem.mprisRefreshAnchor();
        }
    }

    function mediaForceReconnect() {
        if (sceneItem._useNativeMpris) return;
        mprisMonitor.enabled = false;
        mediaReconnectTimer.restart();
    }

    function mediaPushMetadata(t, ar, al, aar, gen) {
        try {
            const albumArtist = aar || ar || "";
            player.mediaPropertiesChanged(t, ar, al, albumArtist, gen);
            sceneItem.applyMediaUserVars({
                u_title: t,
                u_artist: ar,
                u_album: al,
                u_albumartist: albumArtist,
                u_genres: Array.isArray(gen) ? gen.join(", ") : String(gen || "")
            });
        } catch (e) {
            console.error("[MEDIA] push metadata error:", e);
        }
    }

    function mediaPollParse(out) {
        var lines = String(out || "").split("\n");
        var best = null;
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (!ln) continue;
            var p_ = ln.split("|");
            if (p_.length < 5) continue;
            if (p_[1] === "Playing") { best = p_; break; }
            if (!best) best = p_;
        }
        if (!best) return;
        if (best[1] === "Playing" && sceneItem._mediaLastState !== 2 && mprisMonitor.enabled && !sceneItem._useNativeMpris) {
            sceneItem._mediaLastState = -1;
            sceneItem.mediaForceReconnect();
        }
        if (best[2] && best[2] !== sceneItem._lastPushedTitle && best[1] === "Playing") {
            sceneItem._lastPushedTitle = best[2];
            sceneItem.mediaPushMetadata(best[2], best[3], best[4], best[3], "");
        }
    }

    function applyMediaUserVars(vars) {
        if (background._pushSuspended)
            return;
        if (!background.mediaVarsBound || !background._bindsConfirmed)
            return;
        // Si hubo más de 1 firstFrame reciente (_ffStorm > 0), evitamos empujar
        // posición/duración como precaución adicional contra escenas sin schema u_position.
        if (background._ffStorm > 0) {
            delete vars.u_position;
            delete vars.u_duration;
        }
        var changed = false;
        for (var k in vars) {
            if (sceneItem.mediaUserVars[k] !== vars[k]) {
                sceneItem.mediaUserVars[k] = vars[k];
                changed = true;
            }
        }
        if (changed)
            player.userProperties = sceneItem.mergedUserProps();
    }

    function mergedUserProps() {
        var base = {};
        try { base = JSON.parse(sceneItem.userPropsJson || "{}"); } catch(e) {}
        for (var k in sceneItem.mediaUserVars)
            base[k] = sceneItem.mediaUserVars[k];
        return JSON.stringify(base);
    }

    property var volumeFade: Common.createVolumeFade(
        sceneItem,
        Qt.binding(function() { return background.mute ? 0 : background.volume; }),
        (volume) => { player.volume = volume / 100.0; }
    )

    onDisplayModeChanged: {
        if (displayMode == Common.DisplayMode.Scale)
            player.fillMode = SceneViewer.STRETCH;
        else if (displayMode == Common.DisplayMode.Aspect)
            player.fillMode = SceneViewer.ASPECTFIT;
        else if (displayMode == Common.DisplayMode.Crop)
            player.fillMode = SceneViewer.ASPECTCROP;
    }

    Timer {
        id: displayModeFixTimer
        interval: 50
        repeat: false
        onTriggered: sceneItem.displayModeChanged()
    }

    Connections {
        target: background
        function onDisplayModeChanged() {
            displayModeFixTimer.restart();
        }
    }

    MprisMonitor {
        id: mprisMonitor
        // Desactivado cuando _useNativeMpris=true para evitar bloqueos y logs fallidos
        enabled: background.systemPlayerCapture && !sceneItem._useNativeMpris

        onPlaybackStateChanged: function(state) {
            if (sceneItem._useNativeMpris) return;
            try {
                sceneItem._mediaAnySignal = true;
                sceneItem._mediaLastState = state;
                sceneItem._posPlaying = (state === 2);
                if (state !== 0) sceneItem.mprisConnect();
                if (state === 2 || state === 1) sceneItem.mprisRefreshAnchor();
                else { sceneItem._posAnchorUs = 0; sceneItem._posAnchorClock = Date.now(); }
                player.mediaPlaybackChanged(state);
                sceneItem.applyMediaUserVars({ u_playstate: state });
            } catch (e) {
                console.error("[WEK] error in mediaPlaybackChanged:", e);
            }
        }
        onPropertiesChanged: function(title, artist, albumTitle, albumArtist, genres) {
            if (sceneItem._useNativeMpris) return;
            try {
                sceneItem._mediaAnySignal = true;
                const effAlbumArtist = albumArtist || artist || "";
                player.mediaPropertiesChanged(title, artist, albumTitle, effAlbumArtist, genres);
                sceneItem.applyMediaUserVars({
                    u_title: title,
                    u_artist: artist,
                    u_album: albumTitle,
                    u_albumartist: effAlbumArtist,
                    u_genres: Array.isArray(genres) ? genres.join(", ") : String(genres || "")
                });
                if (title && title !== background.lastArtTitle) {
                    background.lastArtTitle = title;
                    background.fetchCoverArt();
                }
            } catch (e) {
                console.error("[WEK] error in mediaPropertiesChanged:", e);
            }
        }
        onThumbnailChanged: function(hasThumbnail, colors) {
            if (sceneItem._useNativeMpris) return;
            try {
                sceneItem._mediaAnySignal = true;
                player.mediaThumbnailChanged(hasThumbnail, colors);
            } catch (e) {
                console.error("[WEK] error in mediaThumbnailChanged:", e);
            }
        }
        onTimelineChanged: function(position, duration) {
            if (sceneItem._useNativeMpris) return;
            try {
                sceneItem._mediaAnySignal = true;
                sceneItem._posAnchorUs = position;
                sceneItem._posAnchorClock = Date.now();
                if (duration > 0) sceneItem._durUs = duration;
                player.mediaTimelineChanged(position, duration);
                sceneItem.applyMediaUserVars({ u_position: position, u_duration: duration });
            } catch (e) {
                console.error("[WEK] error in mediaTimelineChanged:", e);
            }
        }
        onEnabledChanged: function(enabled) {
            try {
                void enabled;
            } catch (e) {}
        }
    }

    SceneViewer {
        id: player
        anchors.fill: parent
        fps: background.fps
        speed: background.speed
        assets: sceneItem.assets
        userProperties: sceneItem.userPropsJson
        hdrOutput: background.hdrOutput
        systemAudioCapture: background.systemAudioCapture
        Component.onCompleted: {
            player.volume = background.mute ? 0 : background.volume / 100.0;
            player.setAcceptMouse(true);
            player.setAcceptHover(true);
        }

        Connections {
            target: background
            function onMuteChanged() {
                player.volume = background.mute ? 0 : background.volume / 100.0;
            }
            function onVolumeChanged() {
                if (!background.mute)
                    player.volume = background.volume / 100.0;
            }
        }

        Connections {
            target: player
            function onFirstFrame() {
                if (background.mute)
                    player.volume = 0;
                background.noteBackendReload();
                background.sig_backendFirstFrame('scene');

                // Pass dump desactivado en producción para no llenar /tmp ni penalizar el primer frame.

                if (background.mediaVarsBound || background._bindsConfirmed)
                    background._bindsConfirmed = true;

                sceneItem._lastPushedTitle = "";
                sceneItem._lastPushedArtist = "";
                sceneItem._lastPushedPosS = -10;
                mediaSyncTimer.restart();

                try {
                    const p = sceneItem.pickNativePlayer();
                    if (p && p.track) {
                        console.log("[MEDIA] first-frame push:", p.track, "|", p.artist);
                        const st = sceneItem.mediaStateOf(p);
                        sceneItem._mediaLastState = st;
                        sceneItem._posPlaying = (st === 2);
                        sceneItem.applyMediaUserVars({ u_playstate: st });
                        sceneItem.pushNativeProperties(p);
                        sceneItem.pushNativeTimeline(p, true);
                    }
                } catch(e) {}
            }

            function onUserShortcutRequested(name) {
                console.log("[WEK] userShortcutRequested:", name);
                var mapped = (background.mediaShortcuts &&
                              background.mediaShortcuts[name])
                             ? background.mediaShortcuts[name] : name;
                const act = String(mapped).toLowerCase();
                const np = sceneItem._useNativeMpris ? sceneItem.pickNativePlayer() : null;
                if (np) {
                    let acted = true;
                    console.log("[MEDIA BTN]", act, "->", np.identity,
                                "canPlay:", np.canPlay, "canPause:", np.canPause);
                    try {
                        if (act.indexOf("playpause") >= 0 || act === "bplaypause") {
                            np.PlayPause();
                        } else if (act.indexOf("next") >= 0) {
                            np.Next();
                        } else if (act.indexOf("prev") >= 0) {
                            np.Previous();
                        } else if (act === "pause") {
                            np.Pause();
                        } else if (act === "play") {
                            np.Play();
                        } else {
                            acted = false;
                        }
                    } catch (e) {
                        acted = false;
                    }
                    if (acted) {
                        syncThrottler.restart();
                        return;
                    }
                } else if (sceneItem._useNativeMpris && !mediaBtnRetry.running) {
                    mediaBtnRetry.name = String(name);
                    mediaBtnRetry.restart();
                    return;
                }
                if (!sceneItem._useNativeMpris)
                    mprisMonitor.invokeShortcut(mapped);
            }
        }
    }

    Component.onCompleted: {
        background.nowBackend = 'scene';
        sceneItem.displayModeChanged();
    }

    function play() {
        volumeFade.start();
        player.play();
    }

    function pause() {
        volumeFade.stop();
        player.pause();
    }

    function simulateClick(x, y) {
        if (!player) return;
        player.simulateHoverAt(x, y);
        if (typeof player.simulateClickAt === 'function')
            player.simulateClickAt(x, y, x, y);
    }

    function getMouseTarget() {
        return Qt.binding(function() { return player; });
    }
}
