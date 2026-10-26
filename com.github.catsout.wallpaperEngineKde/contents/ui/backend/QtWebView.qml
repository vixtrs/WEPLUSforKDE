import QtQuick 2.5
import QtWebEngine 1.10
import QtWebChannel 1.10
import QtWebSockets
import org.kde.plasma.plasma5support as Plasma5Support
import ".."
import "../js/utils.mjs" as Utils

Item {
    id: webItem
    anchors.fill: parent
    property url source
    property bool hasLib: background.hasLib
    property int fps: background.fps
    property var readfile
    property var patchedHtml
    property string qwebChannelJs: ""
    property string bridgeUrl: "ws://127.0.0.1:38765"
    property string bridgeScript: Common.urlNative(Qt.resolvedUrl("../../scripts/wek-web-bridge.py"))
    property var _lastMedia: ({})
    property string _lastThumb: ""
    property string _lastThumbKey: ""
    property string _lastPropsKey: ""
    property string _lastThumbSent: ""
    property int _lastPlaybackState: -1
    property bool _audioWanted: false
    property bool _mediaWanted: false
    property bool _ensurePending: false

    // Load patched HTML when source changes (after scripts are ready)
    onSourceChanged: {
        if (web._scriptsReady)
            loadWallpaper();
    }

    // WE web wallpapers call these APIs from page scripts before QWebChannel
    // exists. QtWebEngine's Deferred user script runs after those scripts, so
    // install no-op/queued shims directly in the HTML head first.
    function injectWebCompat(html) {
        const shim = `<script>(function(){
window.__wekAudioWaiters = window.__wekAudioWaiters || [];
window.__wekMediaStatus = window.__wekMediaStatus || null;
window.__wekMediaProps = window.__wekMediaProps || null;
window.__wekMediaThumb = window.__wekMediaThumb || null;
window.__wekMediaTimeline = window.__wekMediaTimeline || null;
window.__wekMediaPlayback = window.__wekMediaPlayback || null;
window.wallpaperMediaIntegration = window.wallpaperMediaIntegration || {
    PLAYBACK_STOPPED: 0, PLAYBACK_PAUSED: 2, PLAYBACK_PLAYING: 1,
    playback: { STOPPED: 0, PAUSED: 2, PLAYING: 1 }
};
window.wallpaperRegisterAudioListener = function(cb){
    if (typeof cb === 'function' && window.__wekAudioWaiters.indexOf(cb) < 0)
        window.__wekAudioWaiters.push(cb);
};
window.wallpaperRegisterMediaStatusListener = function(cb){ window.__wekMediaStatus = cb; };
window.wallpaperRegisterMediaPropertiesListener = function(cb){ window.__wekMediaProps = cb; };
window.wallpaperRegisterMediaThumbnailListener = function(cb){ window.__wekMediaThumb = cb; };
window.wallpaperRegisterMediaTimelineListener = function(cb){ window.__wekMediaTimeline = cb; };
window.wallpaperRegisterMediaPlaybackListener = function(cb){ window.__wekMediaPlayback = cb; };
window.__wekApplyAudio = function(a){
    var arr = Array.isArray(a) ? a : (a && a.audio) || [];
    for (var i = 0; i < window.__wekAudioWaiters.length; i++) {
        try { window.__wekAudioWaiters[i](arr); } catch(e) { console.error('[WEK] audio listener:', e); }
    }
};
window.__wekApplyMediaThumb = function(event){
    if (typeof window.__wekMediaThumb === 'function') {
        try { window.__wekMediaThumb(event); } catch(e) { console.error('[WEK] media thumb:', e); }
    }
};
window.__wekApplyMedia = function(packet){
    packet = packet || {};
    if (packet.status && typeof window.__wekMediaStatus === 'function') {
        try { window.__wekMediaStatus(packet.status); } catch(e) {}
    }
    if (packet.properties && typeof window.__wekMediaProps === 'function') {
        try { window.__wekMediaProps(packet.properties); } catch(e) { console.error('[WEK] media props:', e); }
    }
    if (packet.timeline && typeof window.__wekMediaTimeline === 'function') {
        try { window.__wekMediaTimeline(packet.timeline); } catch(e) {}
    }
    if (packet.playback && typeof window.__wekMediaPlayback === 'function') {
        try { window.__wekMediaPlayback(packet.playback); } catch(e) {}
    }
};
})();</script>`;
        const m = html.match(/<head[^>]*>/i);
        if (m) {
            const at = m.index + m[0].length;
            return html.slice(0, at) + shim + html.slice(at);
        }
        return shim + html;
    }

    function loadWallpaper() {
        resetMediaDispatch();
        var fileUrl = webItem.source.toString();
        if (!fileUrl) return;

        var filePath = Common.urlNative(fileUrl);
        var baseUrl = fileUrl.substring(0, fileUrl.lastIndexOf('/') + 1);

        // Read HTML and inject History API patch before Angular/etc scripts
        var html = webItem.patchedHtml(filePath);
        if (html && html.length > 0) {
            html = injectWebCompat(String(html));
            console.warn("[WEK] loadHtml baseUrl=" + baseUrl + " htmlLen=" + html.length);
            web.loadHtml(html, baseUrl);
        } else {
            // Fallback: load URL directly (non-HTML wallpapers, read errors)
            console.warn("[WEK] fallback direct url=" + fileUrl);
            web.url = webItem.source;
        }
    }

    function ensureBridge() {
        if (_ensurePending)
            return;
        _ensurePending = true;
        bridgeLauncher.connectSource("python3 -u '" + bridgeScript + "' --ensure");
    }

    function resetMediaDispatch() {
        _lastPropsKey = "";
        _lastThumbSent = "";
        _lastThumbKey = "";
        _lastPlaybackState = -1;
        _audioWanted = false;
        _mediaWanted = false;
    }

    function handleBridgeMessage(message) {
        const text = String(message || "");
        if (text.length < 2)
            return;
        if (text.charAt(0) === "A") {
            if (!web._scriptsReady || !_audioWanted)
                return;
            const body = text.slice(1);
            if (body.charAt(0) === "[")
                web.runJavaScript("if (window.__wekApplyAudio) window.__wekApplyAudio(" + body + ");");
            return;
        }
        if (text.charAt(0) !== "M")
            return;
        try {
            const snap = JSON.parse(text.slice(1));
            if (snap.thumb)
                _lastThumb = snap.thumb;
            _lastMedia = snap;
            if (web._scriptsReady)
                sendMediaToPage(snap, false);
        } catch (e) {
            console.warn("[WEK] bridge media parse:", e);
        }
    }

    function sendMediaToPage(snap, force) {
        if (!web._scriptsReady)
            return;
        snap = snap || {};
        const title = String(snap.title || "");
        const artist = String(snap.artist || "");
        const album = String(snap.albumTitle || "");
        const albumArtist = String(snap.albumArtist || artist || "");
        const propsKey = [title, artist, album, albumArtist, String(snap.genres || "")].join("\u001f");
        const state = (typeof snap.state === "number") ? snap.state : 0;
        const packet = {
            status: { enabled: snap.enabled !== false },
            timeline: {
                position: Number(snap.position) || 0,
                duration: Number(snap.duration) || 0
            }
        };
        if (force || propsKey !== _lastPropsKey) {
            packet.properties = {
                title: title,
                artist: artist,
                subTitle: "",
                albumTitle: album,
                albumArtist: albumArtist,
                genres: String(snap.genres || ""),
                contentType: "music"
            };
            _lastPropsKey = propsKey;
        }
        if (force || state !== _lastPlaybackState) {
            packet.playback = { state: state };
            _lastPlaybackState = state;
        }
        web.runJavaScript("if (window.__wekApplyMedia) window.__wekApplyMedia(" + JSON.stringify(packet) + ");");
        const thumb = snap.thumb || _lastThumb;
        if (thumb && (force || thumb !== _lastThumbSent)) {
            const event = {
                thumbnail: thumb,
                primaryColor: snap.primaryColor || "#1e1e24",
                secondaryColor: snap.secondaryColor || "#50505c",
                tertiaryColor: snap.tertiaryColor || "#b4b4be",
                textColor: snap.textColor || "#ffffff",
                highContrastColor: snap.highContrastColor || "#ffffff"
            };
            web.runJavaScript("if (window.__wekApplyMediaThumb) window.__wekApplyMediaThumb(" + JSON.stringify(event) + ");");
            _lastThumbSent = thumb;
            _lastThumbKey = String(snap.thumbKey || "");
        }
    }

    function probeWebApi() {
        if (!web._scriptsReady)
            return;
        web.runJavaScript("(function(){return {audio: !!(window.__wekAudioWaiters && window.__wekAudioWaiters.length), media: !!(window.__wekMediaStatus || window.__wekMediaProps || window.__wekMediaThumb || window.__wekMediaTimeline || window.__wekMediaPlayback)};})()", function(res) {
            if (!res)
                return;
            _audioWanted = !!res.audio;
            _mediaWanted = !!res.media;
            console.warn("[WEK] web API audio=" + _audioWanted + " media=" + _mediaWanted);
            if (_lastMedia && Object.keys(_lastMedia).length > 0)
                sendMediaToPage(_lastMedia, true);
        });
    }

    property string userPropsJson: background.userPropsJson

    onUserPropsJsonChanged: {
        if (!webobj.loaded || !webobj.userProperties) return;
        if (!userPropsJson) return;
        try {
            var saved = JSON.parse(userPropsJson);
            // Build a delta object with only changed properties
            var delta = {};
            for (var key in saved) {
                if (webobj.userProperties.hasOwnProperty(key)) {
                    // Clone the property definition, update value
                    delta[key] = Object.assign({}, webobj.userProperties[key]);
                    delta[key].value = saved[key];
                    // Also update the stored base properties
                    webobj.userProperties[key].value = saved[key];
                }
            }
            if (Object.keys(delta).length > 0) {
                console.warn("[WEK] Sending updated user properties:", JSON.stringify(Object.keys(delta)));
                webobj.sigUserProperties(delta);
            }
        } catch(e) {
            console.warn("[WEK] Failed to parse userPropsJson:", e);
        }
    }

    onFpsChanged: {
        if(webobj.loaded) {
            webobj.generalProperties.fps = webItem.fps;
            webobj.sigGeneralProperties(webobj.generalProperties);
        }
    }

    Plasma5Support.DataSource {
        id: bridgeLauncher
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            _ensurePending = false;
        }
    }

    WebSocket {
        id: bridgeSocket
        url: webItem.bridgeUrl
        active: true
        onStatusChanged: {
            if (status === WebSocket.Open) {
                console.warn("[WEK] bridge connected " + url);
            } else if (status === WebSocket.Closed || status === WebSocket.Error) {
                console.warn("[WEK] bridge disconnected: " + errorString);
                active = false;
                bridgeRetryTimer.restart();
            }
        }
        onTextMessageReceived: (message) => webItem.handleBridgeMessage(message)
    }

    Timer {
        id: bridgeRetryTimer
        interval: 2000
        repeat: true
        running: true
        onTriggered: {
            if (bridgeSocket.status === WebSocket.Open)
                return;
            ensureBridge();
            if (!bridgeSocket.active)
                bridgeSocket.active = true;
        }
    }

    Timer {
        id: loadProbeTimer
        interval: 500
        repeat: false
        onTriggered: webItem.probeWebApi()
    }

    Image {
        id: pauseImage
        anchors.fill: parent
        visible: true
        enabled: false
    }
    QtObject {
        id: webobj
        WebChannel.id: "wpeQml"
        signal sigGeneralProperties(var properties)
        signal sigUserProperties(var properties)
        signal sigAudio(var audioArray)
        property bool loaded: false
        property var userProperties
        property var generalProperties
        onLoadedChanged: {
            if(!webobj.generalProperties)
                webobj.generalProperties = {fps: 24};
            var wpDir = Common.urlNative(webItem.source.toString());
            wpDir = wpDir.substring(0, wpDir.lastIndexOf('/'));
            // Load user properties from project.json BEFORE signaling,
            // so the wallpaper has zone/property data when it initializes.
            readfile(wpDir + "/project.json").then(function(text) {
                const json = Utils.parseJson(text);
                webobj.userProperties = json.general.properties;
                // Apply any saved user property overrides
                if (webItem.userPropsJson) {
                    try {
                        var saved = JSON.parse(webItem.userPropsJson);
                        for (var key in saved) {
                            if (webobj.userProperties.hasOwnProperty(key))
                                webobj.userProperties[key].value = saved[key];
                        }
                    } catch(e) {}
                }
                console.warn("[WEK] project.json loaded, properties:", JSON.stringify(Object.keys(json.general.properties || {})));
                // Now signal both — properties first, then general
                webobj.sigUserProperties(webobj.userProperties);
                webobj.sigGeneralProperties(webobj.generalProperties);
            });
        }
    }
    WebChannel {
        id: channel
        registeredObjects: [webobj]
    }

    WebEngineView {
    //WebView {
        id: web
        anchors.fill: parent
        enabled: true
        audioMuted: background.mute
        activeFocusOnPress: false
        webChannel: channel

        property bool paused: false
        property bool _scriptsReady: false
        property bool _init: {
            settings.fullscreenSupportEnabled = true;
            settings.autoLoadIconsForPage = false;
            settings.printElementBackgrounds = false;
            settings.playbackRequiresUserGesture = false;
            settings.pdfViewerEnabled = false;
            settings.showScrollBars = false;

            settings.localContentCanAccessRemoteUrls = true;
            settings.allowGeolocationOnInsecureOrigins = true;
            _init = true;
        }


        //onContextMenuRequested: function(request) {
        //    request.accepted = true;
        //}
        onLoadingChanged: (loadingInfo) => {
            console.warn("[WEK] onLoadingChanged status=" + loadingInfo.status
                + " url=" + loadingInfo.url
                + " (Succeeded=" + WebEngineView.LoadSucceededStatus
                + " Failed=" + WebEngineView.LoadFailedStatus + ")");
            if (loadingInfo.status == WebEngineView.LoadFailedStatus) {
                console.warn("[WEK] LOAD FAILED: " + loadingInfo.errorString);
            }
            if (loadingInfo.status == WebEngineView.LoadStartedStatus)
                webItem.resetMediaDispatch();
            if(loadingInfo.status == WebEngineView.LoadSucceededStatus) {
                // check pause after load
                if(paused) {
                    webItem.play();
                    webItem.pause();
                }
                loadProbeTimer.restart();
                background.sig_backendFirstFrame('QtWebEngine');
            }
        }

        onPausedChanged: {
            if(paused) {
                pauseTimer.start();
            }
            else {
                web.visible = true;
                web.lifecycleState = WebEngineView.LifecycleState.Active;
                pauseImage.visible = false;
            }
        }

        Component.onCompleted: {
            console.warn("[WEK] WebEngineView.onCompleted");

            if (!webItem.qwebChannelJs || webItem.qwebChannelJs.length < 100)
                console.warn("[WEK] qwebchannel source missing or truncated (" + webItem.qwebChannelJs.length + " chars)");
            else
                console.warn("[WEK] qwebchannel source loaded (" + webItem.qwebChannelJs.length + " chars)");

            // Single Deferred script: Audio listener + QWebChannel + channel init
            // DocumentCreation injection doesn't work for dynamically inserted
            // sourceCode scripts on this Qt build, so everything goes in Deferred.
            userScripts.insert([
                {
                    worldId: WebEngineScript.MainWorld,
                    injectionPoint: WebEngineScript.Deferred,
                    name: "WallpaperEngineInit",
                    sourceCode: `
                        if (!window.__wekAudioWaiters)
                            window.__wekAudioWaiters = [];
                        if (!window.wallpaperRegisterAudioListener) {
                            window.wallpaperRegisterAudioListener = function(listener) {
                                if (typeof listener === 'function')
                                    window.__wekAudioWaiters.push(listener);
                            };
                        }
                    ` + webItem.qwebChannelJs + `
                        console.warn('[WEK] Deferred script running, QWebChannel=' + typeof QWebChannel);
                        new QWebChannel(qt.webChannelTransport, function(channel) {
                            console.warn('[WEK] QWebChannel connected');
                            window.wpeQml = channel.objects.wpeQml;
                            var wpeQml = window.wpeQml;
                            var propertyListener = window.wallpaperPropertyListener;
                            if(propertyListener) {
                                if(propertyListener.applyGeneralProperties)
                                    wpeQml.sigGeneralProperties.connect(propertyListener.applyGeneralProperties);
                                if(propertyListener.applyUserProperties)
                                    wpeQml.sigUserProperties.connect(propertyListener.applyUserProperties);
                            }
                            wpeQml.loaded = true;
                            console.warn('[WEK] wpeQml.loaded set to true');
                        });
                        document.getElementsByTagName('body')[0].ondragstart = function() { return false; }
                    `
                }
            ])

            // Scripts registered — now safe to load wallpaper
            web._scriptsReady = true;
            webItem.loadWallpaper();

            background.nowBackend = 'QtWebEngine';
        }

    }
    // There is no signal for frame complete, so use timer to make sure not black result
    Timer{
        id: pauseTimer
        running: false
        repeat: false
        interval: 300
        onTriggered: {
            // only check paused status on timer, not set
            // this is async
            web.grabToImage(function(result) {
                // check for paused again, make sure web is visible
                if(web.paused == false || web.visible == false) return;
                pauseImage.source = result.url;
                pauseImage.visible = true;
                web.visible = false;
                web.lifecycleState = WebEngineView.LifecycleState.Frozen;
            });
        }
    }
    Component.onCompleted: {
        ensureBridge();
    }

    function play(){
        web.paused = false;
    }
    function pause(){
        // Set status first
        web.paused = true;
    }
    function getMouseTarget() {
        web.activeFocusOnPress = true;
        return Qt.binding(function() { return web.children[0]; })
    }
}
