import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Controls.Material 2.5 as QSMat
import QtQuick.Layouts 1.5

import ".."
import "../components"
import "../js/utils.mjs" as Utils

import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami 2.6 as Kirigami

Flickable {
    id: settingTab

    // Наследуем тему от родителя
    Kirigami.Theme.inherit: true

    property alias cfg_Fps: sliderFps.value
    property alias cfg_Volume: sliderVol.value
    property alias cfg_MpvStats: ckbox_mpvStats.checked
    property alias cfg_Speed: spin_speed.dValue
    property alias cfg_MuteAudio: ckbox_muteAudio.checked
    property alias cfg_MouseInput: ckbox_mouseInput.checked
    property string cfg_SceneMode
    property bool cfg_TrailsEnabled
    property string cfg_TrailStyle
    property string cfg_SelectorStyle
    property alias cfg_AnimatedPreview: ckbox_animatedPreview.checked
    property alias cfg_ResumeTime: resumeSpin.value
    property alias cfg_SwitchTimer: randomSpin.value
    property alias cfg_RandomizeWallpaper: ckbox_randomizeWallpaper.checked
    property alias cfg_NoRandomWhilePaused: ckbox_noRandomWhilePaused.checked
    property alias cfg_PauseFilterByScreen: ckbox_pauseFilterByScreen.checked

    property alias cfg_PauseOnBatPower: chkbox_pauseOnBatPower.checked
    property alias cfg_PauseBatPercent: spin_pauseBatPercent.value
    property alias cfg_HdrOutput: ckbox_hdrOutput.checked
    property alias cfg_SystemAudioCapture: ckbox_systemAudioCapture.checked
    property alias cfg_SystemPlayerCapture: ckbox_systemPlayerCapture.checked
    property alias cfg_BlurOnPause: ckbox_blurOnPause.checked
    property alias cfg_BlurRadius: sliderBlurRadius.value
    property alias cfg_BlurOnLock: ckbox_blurOnLock.checked
    property alias cfg_WaywallenBackend: ckbox_waywallenBackend.checked
    property alias cfg_AccentColorFromWallpaper: ckbox_accentColor.checked
    property alias cfg_ShowDiagnostics: ckbox_showDiagnostics.checked
    property alias cfg_ParallaxEnable: ckbox_parallaxEnable.checked
    property alias cfg_ParallaxAmount: sliderParallaxAmount.value
    property alias cfg_ParallaxInfluence: sliderParallaxInfluence.value
    property alias cfg_ParallaxDelay: sliderParallaxDelay.value


    Layout.fillWidth: true
    ScrollBar.vertical: ScrollBar { id: scrollbar }

    contentWidth: width - (scrollbar.visible ? scrollbar.width : 0)
    contentHeight: contentItem.childrenRect.height
    clip: true
    boundsBehavior: Flickable.OvershootBounds

    OptionGroup {
        header.visible: false
        anchors.left: parent.left
        anchors.right: parent.right


        OptionGroup {
            Layout.fillWidth: true
            header.text: 'Common Option'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor

            OptionItem {
                text: 'Pause'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/pause.svg'
                actor:  ComboBox {
                    id: pauseMode
                    model: [
                        {
                            text: "Focus or Maximized Window",
                            value: Common.PauseMode.FocusOrMax
                        },
                        {
                            text: "Focus Window",
                            value: Common.PauseMode.Focus
                        },
                        {
                            text: "Maximized Window",
                            value: Common.PauseMode.Max
                        },
                        {
                            text: "FullScreen",
                            value: Common.PauseMode.FullScreen
                        },
                        {
                            text: "Any Window",
                            value: Common.PauseMode.Any
                        },
                        {
                            text: "Never",
                            value: Common.PauseMode.Never
                        }
                    ]
                    textRole: "text"
                    onActivated: cfg_PauseMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_PauseMode)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Automatically pauses playback if any/focus/maximized window detected"
                        wrapMode: Text.Wrap
                    }
               }
            }
            OptionItem {
                text: 'Only check window on current screen'
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_pauseFilterByScreen
                }
            }
            OptionItem {
                text: 'Pause if PC is on battery power'
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: chkbox_pauseOnBatPower
                }
            }
            OptionItem {
                text: 'Pause if battery level is below'
                text_color: Kirigami.Theme.textColor
                actor: SpinBox {
                        id: spin_pauseBatPercent
                        from: 0
                        to: 100
                        stepSize: 1
                }
            }
            OptionItem {
                text: 'Display'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/window.svg'
                actor: ComboBox {
                    id: displayMode
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
                    ]
                    textRole: "text"
                    onActivated: cfg_DisplayMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_DisplayMode)
                }
            }

            OptionItem {
                text: 'Resume Time'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/timer.svg'
                actor: RowLayout {
                    spacing: 0
                    RowLayout {
                        SpinBox {
                            id: resumeSpin
                            from: 1
                            to: 60*1000
                            stepSize: 50
                        }
                        Label { text: " ms"; color: Kirigami.Theme.textColor }
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Time to wait to resume playback from pause"
                    }
                }
            }
            OptionItem {
                text: 'Randomize Timer'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/time.svg'
                actor: Switch {
                    id: ckbox_randomizeWallpaper
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Randomize wallpapers filtered in the 'Wallpapers' page"
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label {
                            id:heightpicker
                            text: "Randomize every "
                            color: Kirigami.Theme.textColor
                        }
                        SpinBox {
                            id: randomSpin
                            width: font.pixelSize * 4
                            from: 1
                            to: 60*24*30
                            stepSize: 1
                        }
                        Label { text: " min"; color: Kirigami.Theme.textColor }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label {
                            id: randomWhilePausedSetter
                            text: "Skip randomizing while wallpaper is paused  "
                            color: Kirigami.Theme.textColor
                        }
                        Switch {
                            id: ckbox_noRandomWhilePaused
                        }
                    }
                }
            }

            OptionItem {
                text: "Playback Speed"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/fast-forward.svg'
                actor: RowLayout {
                    DoubleSpinBox {
                        id: spin_speed
                        dFrom: 0.1
                        dTo: 16.0
                        dStepSize: 0.1
                    }
                }
            }


            OptionItem {
                text: "Mute Audio"
                text_color: Kirigami.Theme.textColor
                icon: ckbox_muteAudio.checked
                    ? '../../images/volume-off.svg'
                    : '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_muteAudio
                }
            }
            OptionItem {
                text: "Volume"
                text_color: Kirigami.Theme.textColor
                visible: !cfg_MuteAudio
                actor: RowLayout {
                    Layout.preferredWidth: displayMode.width
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderVol.value.toString()
                        color: Kirigami.Theme.textColor
                    }
                    Slider {
                        id: sliderVol
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 5.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
            }

            OptionItem {
                text: "System Audio Capture"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_systemAudioCapture
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        text: "When enabled, audio-reactive wallpapers respond to all system audio (music, videos, games). When disabled, only the wallpaper's own background music is used."
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            OptionItem {
                visible: libcheck.wallpaper
                text_color: Kirigami.Theme.textColor
                text: "Scene Mode"
                icon: '../../images/plugin.svg'
                actor: ComboBox {
                    id: combo_sceneMode
                    model: [
                        { text: "Plugin (base)", value: "plugin" },
                        { text: "Translator (experimental)", value: "translator" }
                    ]
                    textRole: "text"
                    onActivated: cfg_SceneMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_SceneMode)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Plugin mode uses the native engine (scene.pkg) untouched. Translator mode ADDS waywallen-style extras (parallax, native trails, manifests) on top of the base pipeline; translations are a versioned cache regenerated when the translator changes."
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
            OptionItem {
                visible: libcheck.wallpaper
                text_color: Kirigami.Theme.textColor
                text: "Mouse Input"
                icon: '../../images/mouse.svg'
                actor: Switch {
                    id: ckbox_mouseInput
                }
            }

            OptionItem {
                visible: libcheck.wallpaper
                text_color: Kirigami.Theme.textColor
                text: "Mouse Trails"
                icon: '../../images/mouse.svg'
                actor: Switch {
                    id: ckbox_trailsEnabled
                    checked: cfg_TrailsEnabled
                    onCheckedChanged: cfg_TrailsEnabled = checked
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Globally enables/disables the per-wallpaper mouse trails"
                        wrapMode: Text.Wrap
                    }
                }
            }

            OptionItem {
                visible: libcheck.wallpaper && cfg_MouseInput && cfg_TrailsEnabled
                text_color: Kirigami.Theme.textColor
                text: "Trail Style"
                icon: '../../images/sparkles.svg'
                actor: ComboBox {
                    id: trailStyleBox
                    model: [
                        {
                            text: "Generic — colored glow dots",
                            value: "generic"
                        },
                        {
                            text: "Accurate — wallpaper's own design",
                            value: "accurate"
                        }
                    ]
                    textRole: "text"
                    onActivated: cfg_TrailStyle = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_TrailStyle)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Generic approximates the trail with its colors and sizes. Accurate renders the wallpaper's own particle sprites and physics; falls back to Generic when a wallpaper provides no accurate data."
                        wrapMode: Text.Wrap
                    }
                }
            }

            OptionItem {
                text_color: Kirigami.Theme.textColor
                text: "Selector Style (Ctrl+W / Middle-Click)"
                icon: '../../images/window.svg'
                actor: ComboBox {
                    id: selectorStyleBox
                    model: [
                        { text: "Simple — cards only", value: "simple" },
                        { text: "Hyprland — slanted cascade", value: "hyprland" },
                        { text: "Glass — clean frosted glass", value: "glass" },
                        { text: "Default — classic with header & key hints", value: "default" }
                    ]
                    textRole: "text"
                    onActivated: cfg_SelectorStyle = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Math.max(0, Common.cbIndexOfValue(this, cfg_SelectorStyle || "simple"))
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Choose the visual style of the desktop wallpaper selector. You can also press Tab while the selector is open to switch styles live."
                        wrapMode: Text.Wrap
                    }
                }
            }

            OptionItem {
                text_color: Kirigami.Theme.textColor
                text: "Animated Preview"
                icon: '../../images/gif.svg'
                actor: Switch {
                    id: ckbox_animatedPreview
                }
            }
       }

        OptionGroup {
            Layout.fillWidth: true

            header.text: 'Local Video Tab Options (Isolated)'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor

            OptionItem {
                text: 'Video Backend'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/plugin.svg'
                actor: ComboBox {
                    model: [
                        {
                            text: "QtMultimedia",
                            value: Common.VideoBackend.QtMultimedia,
                            enabled: true
                        },
                        {
                            text: "Mpv",
                            value: Common.VideoBackend.Mpv,
                            enabled: libcheck.wallpaper
                        }
                    ].filter(el => el.enabled)
                    textRole: "text"
                    onActivated: cfg_VideoBackend = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_VideoBackend)
                }
            }

            OptionItem {
                text: 'Show Mpv Stats'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                visible: cfg_VideoBackend == Common.VideoBackend.Mpv
                actor: Switch {
                    id: ckbox_mpvStats
                }
            }
        }
        OptionGroup {
            Layout.fillWidth: true

            header.text: 'Scene Option'
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor
            visible: libcheck.wallpaper

            OptionItem {
                text: 'Fps'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/tuning.svg'
                actor: RowLayout {
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderFps.value.toString()
                        color: Kirigami.Theme.textColor
                    }
                    Slider {
                        id: sliderFps
                        Layout.fillWidth: true
                        from: 5
                        to: 60
                        stepSize: 1.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Low: 10, Medium: 15, High: 25, Ultra High: 30"
                    }
                }

            }
            OptionItem {
                text: 'HDR Output'
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_hdrOutput
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: "Pass HDR colors to the compositor without tonemapping. Requires Plasma HDR support."
                        wrapMode: Text.Wrap
                    }
                }
            }
            OptionItem {
                text: "System Player Capture"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_systemPlayerCapture
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        text: "When enabled, wallpapers can read the currently playing media (title, artist, album, thumbnail, play/pause controls) from any MPRIS-capable player."
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
            OptionItem {
                text: "Blur on pause"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/tuning.svg'
                actor: Switch {
                    id: ckbox_blurOnPause
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        text: "Blurs the frozen wallpaper frame while it is auto-paused."
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_blurOnPause.checked
                        Label {
                            text: "Blur radius: "
                            color: Kirigami.Theme.textColor
                        }
                        Slider {
                            id: sliderBlurRadius
                            Layout.fillWidth: true
                            from: 1
                            to: 30
                            stepSize: 1.0
                            snapMode: Slider.SnapOnRelease
                        }
                        Label { text: sliderBlurRadius.value.toString(); color: Kirigami.Theme.textColor }
                    }
                }
            }
            OptionItem {
                text: "Blur on screen lock"
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_blurOnLock
                }
            }
            OptionItem {
                visible: false
                text: "Waywallen Daemon Backend (Experimental)"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/plugin.svg'
                actor: Switch {
                    id: ckbox_waywallenBackend
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        text: "Enable a golden glowing particle trail that follows the cursor across the wallpaper."
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
            OptionItem {
                text: "Accent Color from Wallpaper"
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_accentColor
                }
            }
            OptionItem {
                text: "Camera Parallax"
                text_color: Kirigami.Theme.textColor
                icon: '../../images/mouse.svg'
                actor: Switch {
                    id: ckbox_parallaxEnable
                }
                contentBottom: ColumnLayout {
                    visible: ckbox_parallaxEnable.checked
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Amount: "; color: Kirigami.Theme.textColor }
                        Slider {
                            id: sliderParallaxAmount
                            Layout.fillWidth: true
                            from: 0.0
                            to: 1.0
                            stepSize: 0.05
                            snapMode: Slider.SnapOnRelease
                        }
                        Label { text: sliderParallaxAmount.value.toFixed(2); color: Kirigami.Theme.textColor }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Influence: "; color: Kirigami.Theme.textColor }
                        Slider {
                            id: sliderParallaxInfluence
                            Layout.fillWidth: true
                            from: 0.0
                            to: 2.0
                            stepSize: 0.1
                            snapMode: Slider.SnapOnRelease
                        }
                        Label { text: sliderParallaxInfluence.value.toFixed(1); color: Kirigami.Theme.textColor }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Delay (ms): "; color: Kirigami.Theme.textColor }
                        Slider {
                            id: sliderParallaxDelay
                            Layout.fillWidth: true
                            from: 0
                            to: 500
                            stepSize: 10
                            snapMode: Slider.SnapOnRelease
                        }
                        Label { text: sliderParallaxDelay.value.toString(); color: Kirigami.Theme.textColor }
                    }
                }
            }
            OptionItem {
                text: "Show Diagnostics Overlay"
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_showDiagnostics
                }
            }
            OptionItem {
                text: 'Shader cache'
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                actor: Kirigami.ActionToolBar {
                    Layout.fillWidth: true
                    alignment: Qt.AlignRight
                    flat: false
                    actions: [
                        Kirigami.Action {
                            text: 'Show'
                            tooltip: 'Show in file manager'
                            onTriggered: {
                                if(plugin_info.cache_path)
                                    Qt.openUrlExternally(plugin_info.cache_path);
                            }
                        }
                    ]
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        property string cache_path: Common.urlNative(plugin_info.cache_path)

                        color: Kirigami.Theme.disabledTextColor
                        text: plugin_info.cache_path
                        ? `${cache_path} - ${cache_size}`
                        : `Not available`

                        property string cache_size: {
                            if(pyext) {
                                pyext.get_dir_size(this.cache_path).then(res => {
                                    this.cache_size = Utils.prettyBytes(res);
                                }).catch(reason => console.error(reason));
                            }
                            return "? MB";
                        }
                    }
                }
            }
        }
    }


}

