import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // install.sh replaces this with the absolute path of the CLI
    readonly property string cli: "@N1XPOWER@"
    property var st: ({ apps: [], profiles: [] })
    property string app: ""
    property var appSt: {
        var a = (st.apps || []).filter(x => x.name === app)
        return a.length ? a[0] : null
    }
    property string note: ""
    property var fps: (st.fps && st.fps.length) ? st.fps[0] : null

    function num(v, d) { return (v === undefined || v === null) ? "–" : Number(v).toFixed(d) }
    function run(args) { exec.connectSource(cli + " " + args + " # " + Date.now()) }
    function poll() { exec.connectSource(cli + " status --json") }
    function q(s) { return "'" + String(s).replace(/'/g, "") + "'" }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source.indexOf(" status --json") >= 0) {
                try {
                    root.st = JSON.parse(data["stdout"])
                    if (!root.app && root.st.apps.length) root.app = root.st.apps[0].name
                } catch (e) {}
            } else {
                var err = (data["stderr"] || "").trim()
                root.note = err ? err.split("\n").pop() : (data["stdout"] || "").trim().split("\n").pop()
                root.poll()
            }
        }
    }

    Timer { interval: root.expanded ? 1000 : 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.poll() }

    toolTipMainText: "Power Deck"
    toolTipSubText: "SoC " + num(st.soc_w, 1) + " W · GPU " + num(st.gpu_w, 1) + " W @ " + num(st.gpu_mhz, 0) + " MHz"

    compactRepresentation: MouseArea {
        Layout.minimumWidth: lbl.implicitWidth + Kirigami.Units.smallSpacing * 2
        onClicked: root.expanded = !root.expanded
        PC3.Label {
            id: lbl
            anchors.centerIn: parent
            text: (root.st.soc_w !== undefined ? num(root.st.soc_w, 1) : num(root.st.gpu_w, 1)) + " W" + (root.fps ? " · " + num(root.fps.fps, 0) + " fps" : "")
            font.bold: true
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        spacing: Kirigami.Units.smallSpacing

        // ---- live readouts
        GridLayout {
            columns: 4
            Layout.fillWidth: true
            columnSpacing: Kirigami.Units.largeSpacing
            Repeater {
                model: [
                    ["FPS", root.fps ? num(root.fps.fps, 0) + "  (" + num(root.fps.ms, 1) + " ms)" : "–"],
                    ["System", num(root.st.sys_w, 1) + " W"],
                    ["SoC", num(root.st.soc_w, 1) + " W / " + num(root.st.pl1_w, 0)],
                    ["GPU", num(root.st.gpu_w, 1) + " W"],
                    ["GPU clock", num(root.st.gpu_mhz, 0) + " MHz"],
                    ["SoC temp", num(root.st.soc_c, 0) + " °C"],
                    ["GPU temp", num(root.st.gpu_temp_c, 0) + " °C"],
                    [root.st.ac ? "Charging" : "Battery", num(root.st.battery_w, 1) + " W · " + num(root.st.battery_pct, 0) + "%"]
                ]
                ColumnLayout {
                    spacing: 0
                    PC3.Label { text: modelData[0]; opacity: 0.6; font: Kirigami.Theme.smallFont }
                    PC3.Label { text: modelData[1]; font.bold: true }
                }
            }
        }
        PC3.Label {
            visible: !root.st.daemon
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: "Root helper not running: SoC/system power and the CPU/GPU caps are unavailable. Run power/install.sh."
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- system-wide controls
        RowLayout {
            PC3.Label { text: "Refresh"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.Button { text: "60 Hz"; checkable: true; checked: root.st.refresh === 60; onClicked: root.run("set refresh 60") }
            PC3.Button { text: "120 Hz"; checkable: true; checked: root.st.refresh === 120; onClicked: root.run("set refresh 120") }
        }
        Repeater {
            model: [
                { label: "SoC limit", key: "soc-limit", unit: "W", cur: root.st.soc_limit_w > 0 ? root.st.soc_limit_w : (root.st.soc_limit_range_w ? root.st.soc_limit_range_w[1] : 0), range: root.st.soc_limit_range_w, step: 1 },
                { label: "P-cores max", key: "cpu-p-max", cur: root.st.cpu_p_max_mhz, range: root.st.cpu_p_range_mhz, step: 100 },
                { label: "E-cores max", key: "cpu-e-max", cur: root.st.cpu_e_max_mhz, range: root.st.cpu_e_range_mhz, step: 100 },
                { label: "GPU max", key: "gpu-max", cur: 3003, range: [300, 3003], step: 50 }
            ]
            RowLayout {
                enabled: root.st.daemon === true
                PC3.Label { text: modelData.label; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
                PC3.Slider {
                    id: s
                    Layout.fillWidth: true
                    from: modelData.range ? modelData.range[0] : 0
                    to: modelData.range ? modelData.range[1] : 1
                    stepSize: modelData.step
                    Binding on value { when: !s.pressed && modelData.key !== "gpu-max"; value: modelData.cur || 0 }
                    Component.onCompleted: if (modelData.key === "gpu-max") value = to
                    onPressedChanged: if (!pressed) root.run("set " + modelData.key + " " + (value >= to ? 0 : Math.round(value)))
                }
                PC3.Label { text: s.value >= s.to ? "max" : Math.round(s.value) + " " + (modelData.unit || "MHz"); Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- per-application controls
        RowLayout {
            PC3.Label { text: "App"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.ComboBox {
                id: appBox
                Layout.fillWidth: true
                model: (root.st.apps || []).map(a => a.name)
                onActivated: root.app = currentText
                Binding on currentIndex { when: !appBox.popup.visible; value: Math.max(0, appBox.model.indexOf(root.app)) }
            }
            PC3.Label { text: root.appSt ? num(root.appSt.cpu_pct, 0) + "% CPU" : ""; Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
        }
        RowLayout {
            enabled: root.appSt !== null
            PC3.Label { text: "CPU limit"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.Slider {
                id: quota
                Layout.fillWidth: true
                from: 25; to: 2000; stepSize: 25
                Binding on value { when: !quota.pressed; value: root.appSt && root.appSt.quota ? root.appSt.quota : 2000 }
                onPressedChanged: if (!pressed) root.run("app " + root.q(root.app) + " quota " + (value >= to ? 0 : Math.round(value)))
            }
            PC3.Label { text: quota.value >= quota.to ? "none" : (quota.value / 100).toFixed(2) + " cores"; Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
        }
        RowLayout {
            enabled: root.appSt !== null
            PC3.Label { text: "Speed clamp"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.Slider {
                id: uclamp
                Layout.fillWidth: true
                from: 10; to: 100; stepSize: 5
                Binding on value { when: !uclamp.pressed; value: root.appSt ? root.appSt.uclamp : 100 }
                onPressedChanged: if (!pressed) root.run("app " + root.q(root.app) + " uclamp " + Math.round(value))
            }
            PC3.Label { text: uclamp.value >= 100 ? "off" : Math.round(uclamp.value) + " %"; Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
        }
        RowLayout {
            enabled: root.appSt !== null
            PC3.Label { text: "E-cores only"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.Switch {
                id: pin
                Binding on checked { value: root.appSt ? root.appSt.ecores : false }
                onToggled: root.run("app " + root.q(root.app) + " ecores " + (checked ? "on" : "off"))
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- camera clean-up (read live by the camera pipeline)
        Repeater {
            model: [
                { label: "Cam denoise", key: "denoise", from: 0, to: 100, step: 5, scale: 1 },
                { label: "Cam sharpen", key: "sharpen", from: 0, to: 100, step: 5, scale: 1 },
                { label: "Cam contrast", key: "contrast", from: 80, to: 160, step: 5, scale: 100 }
            ]
            RowLayout {
                PC3.Label { text: modelData.label; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
                PC3.Slider {
                    id: cs
                    Layout.fillWidth: true
                    from: modelData.from; to: modelData.to; stepSize: modelData.step
                    Binding on value { when: !cs.pressed; value: root.st.camera ? root.st.camera[modelData.key] * modelData.scale : modelData.from }
                    onPressedChanged: if (!pressed) root.run("camera " + modelData.key + " " + (value / modelData.scale))
                }
                PC3.Label { text: modelData.scale === 1 ? Math.round(cs.value) : (cs.value / 100).toFixed(2); Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- profiles
        RowLayout {
            PC3.Label { text: "Profile"; Layout.preferredWidth: Kirigami.Units.gridUnit * 6 }
            PC3.ComboBox {
                id: profBox
                Layout.fillWidth: true
                editable: true
                model: root.st.profiles || []
            }
            PC3.Button { text: "Apply"; enabled: profBox.editText.length > 0; onClicked: root.run("profile apply " + root.q(profBox.editText)) }
            PC3.Button { text: "Save"; enabled: profBox.editText.length > 0; onClicked: root.run("profile save " + root.q(profBox.editText) + " " + root.q(root.app)) }
        }
        PC3.Label {
            visible: root.note.length > 0
            Layout.fillWidth: true
            elide: Text.ElideRight
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: root.note
        }
    }
}
