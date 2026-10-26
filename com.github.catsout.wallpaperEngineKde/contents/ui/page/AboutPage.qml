import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.5

import ".."
import "../components"

import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami 2.4 as Kirigami

Flickable {
    Kirigami.Theme.inherit: true
    Layout.fillWidth: true
    ScrollBar.vertical: ScrollBar { id: scrollbar }

    contentWidth: width - (scrollbar.visible ? scrollbar.width : 0)
    contentHeight: contentItem.childrenRect.height
    clip: true
    boundsBehavior: Flickable.OvershootBounds

    OptionGroup {
        id: option_group
        header.visible: false
        anchors.left: parent.left
        anchors.right: parent.right

        OptionItem {
            text: 'WEPLUSforKDE — Created & Maintained by @vixtrs'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/sparkles.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <p><b>WEPLUSforKDE</b> is an expanded and hardened edition of the Wallpaper Engine plugin for KDE Plasma 6, featuring:</p>
                        <ul>
                            <li><b>Scene &amp; Package Translator Engine:</b> Automatic extraction, SceneScript compatibility shims, GLSL/SPIR-V adaptation, and raw RGBA/JPEG texture reconstruction.</li>
                            <li><b>Workshop Preset &amp; Dependency Resolver:</b> Automatic dependency chaining, asset staging, and direct preset activation.</li>
                            <li><b>Integrated Steam Workshop Browser &amp; Auditor:</b> Direct search, silent background installation, subscription/orphan verification, and full cleanup.</li>
                            <li><b>Web &amp; Native Audio/MPRIS Bridge:</b> Real-time PipeWire/PulseAudio FFT spectrum streaming and MPRIS media metadata &amp; cover synchronization.</li>
                            <li><b>Desktop Overlay Selector &amp; Interactive Trails:</b> Multi-style desktop carousel selector (Default, Glass, Simple, Hyprland) and native cursor trail rendering.</li>
                        </ul>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            text: 'Base Projects & Technical Credits'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/github.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <ul>
                            <li><b>wallpaper-engine-kde-plugin</b> by <i>catsout</i> — Core QML plugin architecture and C++/Vulkan SceneViewer backend.</li>
                            <li><b>linux-wallpaperengine</b> by <i>Almamu &amp; contributors</i> — Reference PKG/TEX format specifications and shader/particle documentation.</li>
                            <li><b>Smart Video Wallpaper Reborn</b> by <i>luisbocanegra</i> — Local video folder playback and power/screen pause heuristics.</li>
                            <li><b>mpv / QtWebEngine / PipeWire / playerctl</b> — Multimedia, web rendering, and audio/MPRIS integration foundations.</li>
                        </ul>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            text: 'Version & Environment'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/tag.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <ul>
                        <li>Edition: <b>WEPLUSforKDE</b> by <b>@vixtrs</b> by <b>@vixtrs</b> (${Common.version})</li>
                        <li>Native Scene Backend: ${plugin_info.version}</li>
                        <li>Qt / KDE Runtime: ${Qt.application.version}</li>
                        <li>File Helper: Native C++ FileHelper</li>
                        </ul>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            text: 'Library Status'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/checkmark.svg'
            contentBottom: ListView {
                implicitHeight: contentItem.childrenRect.height
                model: ListModel {}
                clip: false
                property var modelraw: [
                    { ok: libcheck.qtwebchannel, name: "QtWebChannel & QtWebEngine (Web wallpapers)" },
                    { ok: libcheck.wallpaper, name: "libWallpaperEngineKde (Scene & MPV backends)" }
                ]
                onModelrawChanged: {
                    this.model.clear();
                    this.modelraw.forEach((el) => this.model.append(el));
                }
                delegate: CheckBox {
                    text: name
                    checked: ok
                    enabled: false
                    contentItem: Text {
                        text: parent.text
                        color: Kirigami.Theme.disabledTextColor
                        leftPadding: parent.indicator.width + parent.spacing
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
