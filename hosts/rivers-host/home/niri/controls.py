"""Small layer-shell audio card, backed by PipeWire's PulseAudio interface."""
import signal
import gi
import pulsectl

gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('GtkLayerShell', '0.1')
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell, Pango

CSS = b'''
window { background: transparent; }
#card { background-color: rgba(28,34,43,0.66); background-image: linear-gradient(to bottom, rgba(255,255,255,0.08), rgba(255,255,255,0.01)); border: 1px solid rgba(255,255,255,0.30); border-radius: 18px; padding: 18px; box-shadow: inset 0 1px rgba(255,255,255,0.12); }
* { font-family: "Noto Sans CJK SC"; font-size: 12px; color: #f7f9fc; text-shadow: none; }
.title { font-size: 16px; font-weight: bold; }
.section { color: #d7dfe8; font-size: 11px; }
button { background: transparent; background-image: none; box-shadow: none; border: none; border-radius: 9px; padding: 7px 9px; }
button:hover { background: rgba(255,255,255,0.14); }
button.active { background: rgba(255,255,255,0.17); box-shadow: inset 0 0 0 1px rgba(255,255,255,0.20); }
scale { padding: 12px 2px; }
scale trough { background: rgba(255,255,255,0.18); min-height: 6px; border: none; border-radius: 3px; }
scale highlight { background: rgba(255,255,255,0.88); border: none; border-radius: 3px; }
scale slider { background: #ffffff; border: 1px solid rgba(255,255,255,0.9); min-width: 14px; min-height: 14px; box-shadow: none; }
separator { background: rgba(255,255,255,0.16); min-height: 1px; }
'''

class Card:
    def __init__(self):
        self.pulse = pulsectl.Pulse('niri-control-card')
        self.updating = False
        self.signature = None
        self.window = Gtk.Window(title='声音控制')
        self.window.set_name('audio-card')
        self.window.set_resizable(False)
        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_namespace(self.window, 'niri-controls')
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.TOP)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, True)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.RIGHT, True)
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.TOP, 10)
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.RIGHT, 12)
        GtkLayerShell.set_keyboard_mode(self.window, GtkLayerShell.KeyboardMode.ON_DEMAND)
        self.window.set_visual(self.window.get_screen().get_rgba_visual())
        self.window.connect('destroy', Gtk.main_quit)
        self.window.connect('key-press-event', self.key)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, 800)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_name('card')
        box.set_size_request(340, -1)
        self.window.add(box)
        header = Gtk.Box(spacing=8)
        title = Gtk.Label(label='声音', xalign=0)
        title.get_style_context().add_class('title')
        header.pack_start(title, True, True, 0)
        close = Gtk.Button(label='×')
        close.connect('clicked', lambda *_: self.window.close())
        header.pack_end(close, False, False, 0)
        box.pack_start(header, False, False, 0)
        self.output = self.volume_row(box, '输出音量', False)
        self.label(box, '播放设备')
        self.devices = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.pack_start(self.devices, False, False, 0)
        box.pack_start(Gtk.Separator(), False, False, 3)
        self.mic = self.volume_row(box, '麦克风', True)
        self.error = Gtk.Label(xalign=0)
        self.error.set_line_wrap(True)
        box.pack_start(self.error, False, False, 0)
        self.refresh()
        self.dismiss_surfaces = self.make_dismiss_surfaces()
        self.window.show_all()
        self.error.set_visible(bool(self.error.get_text()))
        GLib.timeout_add(700, self.refresh)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self.window.close)

    def make_dismiss_surfaces(self):
        # Separate transparent surfaces receive outside clicks. Only the card's
        # namespace has blur, so these must never inherit its background effect.
        surfaces = []
        display = Gdk.Display.get_default()
        for index in range(display.get_n_monitors()):
            surface = Gtk.Window()
            surface.set_visual(surface.get_screen().get_rgba_visual())
            GtkLayerShell.init_for_window(surface)
            GtkLayerShell.set_namespace(surface, 'niri-controls-dismiss')
            GtkLayerShell.set_monitor(surface, display.get_monitor(index))
            GtkLayerShell.set_layer(surface, GtkLayerShell.Layer.TOP)
            GtkLayerShell.set_exclusive_zone(surface, -1)
            GtkLayerShell.set_keyboard_mode(surface, GtkLayerShell.KeyboardMode.NONE)
            for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                         GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
                GtkLayerShell.set_anchor(surface, edge, True)
            surface.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
            surface.connect('button-press-event', self.dismiss)
            surface.show_all()
            surfaces.append(surface)
        return surfaces

    def dismiss(self, *_):
        self.window.close()
        return True

    def label(self, box, text):
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class('section')
        box.pack_start(label, False, False, 0)
        return label

    def volume_row(self, box, title, source):
        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label=title, xalign=0), True, True, 0)
        value = Gtk.Label()
        row.pack_end(value, False, False, 0)
        mute = Gtk.Button(label='静音')
        mute.connect('clicked', lambda *_: self.change_mute(source))
        row.pack_end(mute, False, False, 0)
        box.pack_start(row, False, False, 0)
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        scale.set_draw_value(False)
        scale.connect('value-changed', lambda s: self.change_volume(source, s.get_value()))
        box.pack_start(scale, False, False, 0)
        return scale, value, mute

    def default(self, source):
        info = self.pulse.server_info()
        name = info.default_source_name if source else info.default_sink_name
        nodes = self.pulse.source_list() if source else self.pulse.sink_list()
        return next((n for n in nodes if n.name == name), None)

    def perform(self, operation):
        try:
            operation()
            self.error.set_text('')
        except pulsectl.PulseError as exc:
            self.error.set_text(f'音频设备暂不可用：{exc}')
        self.refresh()

    def change_volume(self, source, value):
        if not self.updating:
            def change():
                node = self.default(source)
                if node:
                    self.pulse.volume_set_all_chans(node, value / 100)
            self.perform(change)

    def change_mute(self, source):
        def change():
            node = self.default(source)
            if node:
                self.pulse.mute(node, not node.mute)
        self.perform(change)

    def select(self, name):
        def change():
            sink = next(n for n in self.pulse.sink_list() if n.name == name)
            self.pulse.default_set(sink)
            # Existing streams should follow the user's explicit device selection.
            for stream in self.pulse.sink_input_list():
                self.pulse.sink_input_move(stream.index, sink.index)
        self.perform(change)

    def refresh(self):
        self.updating = True
        try:
            info = self.pulse.server_info()
            sinks = self.pulse.sink_list()
            signature = [(n.name, n.description, n.name == info.default_sink_name) for n in sinks]
            if signature != self.signature:
                self.signature = signature
                for child in self.devices.get_children():
                    child.destroy()
                for name, description, active in signature:
                    button = Gtk.Button()
                    label = Gtk.Label(label=('✓  ' if active else '    ') + description, xalign=0)
                    label.set_ellipsize(Pango.EllipsizeMode.END)
                    label.set_max_width_chars(32)
                    button.add(label)
                    button.set_tooltip_text(description)
                    if active:
                        button.get_style_context().add_class('active')
                    button.connect('clicked', lambda _, n=name: self.select(n))
                    self.devices.pack_start(button, False, False, 0)
                self.devices.show_all()
            for source, widgets in ((False, self.output), (True, self.mic)):
                scale, value, mute = widgets
                node = self.default(source)
                scale.set_sensitive(node is not None)
                mute.set_sensitive(node is not None)
                if node:
                    percent = round(node.volume.value_flat * 100)
                    scale.set_value(percent)
                    value.set_text(f'{percent}%')
                    mute.set_label('取消静音' if node.mute else '静音')
                else:
                    value.set_text('未连接')
            self.error.set_visible(bool(self.error.get_text()))
        except pulsectl.PulseError:
            self.error.set_text('音频服务连接中断，关闭后重新打开。')
            self.error.show()
        finally:
            self.updating = False
        return True

    def key(self, _, event):
        if event.keyval == Gdk.KEY_Escape:
            self.window.close()
            return True
        return False

Card()
Gtk.main()
