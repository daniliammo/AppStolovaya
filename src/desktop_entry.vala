// Ярлык программы в системе: .desktop-файл и значок в папке данных
// пользователя (~/.local/share). По ним GNOME показывает значок и имя
// программы в панели задач, Alt+Tab и в уведомлениях — без ярлыка окно
// для GNOME «Неизвестное приложение». Ярлык ведёт на запущенную программу:
// переносимую папку можно положить куда угодно, ярлык обновится при запуске.
//
// Значок — в акцентном цвете системы (Настройки → Внешний вид): при его смене
// программа перезаписывает значок (см. App.startup). Без поддержки акцентных
// цветов он остаётся оранжевым, как в data/org.gurov.Stolovaya.svg.

namespace DesktopEntry {
    public const string ID = "org.gurov.Stolovaya";
    const string ICON_RESOURCE = "/org/gurov/Stolovaya/icons/scalable/apps/" + ID + ".svg";
    // Цвета основы в исходном значке: светлый верх, низ и тёмный «срез»
    const string ICON_LIGHT = "#ffa348";
    const string ICON_COLOR = "#e66100";
    const string ICON_DARK = "#c64600";

    public void install () {
        var data = Environment.get_user_data_dir ();
        try {
            var icon = (string) resources_lookup_data (ICON_RESOURCE, ResourceLookupFlags.NONE).get_data ();
            var style = Adw.StyleManager.get_default ();
            if (style.system_supports_accent_colors) {
                var accent = style.get_accent_color ().to_rgba ();
                icon = icon.replace (ICON_LIGHT, hex (mix (accent, 1, 0.3f)))
                    .replace (ICON_COLOR, hex (accent))
                    .replace (ICON_DARK, hex (mix (accent, 0, 0.15f)));
            }
            var theme = Path.build_filename (data, "icons", "hicolor");
            if (write_if_changed (Path.build_filename (theme, "scalable", "apps", @"$ID.svg"), icon.data)) {
                // GNOME Shell перечитывает значки, только когда меняется время
                // изменения папки темы, а не вложенных папок
                File.new_for_path (theme).set_attribute_uint64 (FileAttribute.TIME_MODIFIED,
                    get_real_time () / 1000000, FileQueryInfoFlags.NONE);
            }

            var exe = FileUtils.read_link ("/proc/self/exe");
            var entry = """[Desktop Entry]
Type=Application
Name=Столовая
Comment=Учёт питания по карточкам
Exec=%s
Icon=%s
Terminal=false
Categories=Office;
StartupNotify=true
""".printf (quote_exec (exe), ID);
            write_if_changed (Path.build_filename (data, "applications", @"$ID.desktop"), entry.data);
        } catch (Error e) {
            warning ("Ярлык программы: %s", e.message);
        }
    }

    // Цвет, смешанный с белым (to = 1) или чёрным (to = 0) в доле part
    Gdk.RGBA mix (Gdk.RGBA c, float to, float part) {
        return { c.red + (to - c.red) * part, c.green + (to - c.green) * part,
                 c.blue + (to - c.blue) * part, 1 };
    }

    string hex (Gdk.RGBA c) {
        return "#%02x%02x%02x".printf ((uint) (c.red * 255 + 0.5f),
            (uint) (c.green * 255 + 0.5f), (uint) (c.blue * 255 + 0.5f));
    }

    // Не трогаем файл без надобности: GNOME перечитывает ярлыки при каждом изменении.
    // true — файл записан.
    bool write_if_changed (string path, uint8[] contents) throws Error {
        uint8[] old;
        try {
            FileUtils.get_data (path, out old);
            if (old.length == contents.length && Memory.cmp (old, contents, contents.length) == 0) {
                return false;
            }
        } catch (FileError e) {
            // Файла ещё нет
        }
        DirUtils.create_with_parents (Path.get_dirname (path), 0755);
        FileUtils.set_data (path, contents);
        return true;
    }

    // Путь в Exec — в кавычках, \ " ` $ экранируются (спецификация Desktop Entry)
    string quote_exec (string path) {
        var escaped = new StringBuilder ();
        foreach (var c in path.data) {
            if (c == '\\' || c == '"' || c == '`' || c == '$') {
                escaped.append_c ('\\');
            }
            escaped.append_c ((char) c);
        }
        return @"\"$(escaped.str)\"";
    }
}
