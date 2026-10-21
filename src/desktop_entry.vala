// Ярлык программы в системе: .desktop-файл и значок в папке данных
// пользователя (~/.local/share). По ним GNOME показывает значок и имя
// программы в панели задач, Alt+Tab и в уведомлениях — без ярлыка окно
// для GNOME «Неизвестное приложение». Ярлык ведёт на запущенную программу:
// переносимую папку можно положить куда угодно, ярлык обновится при запуске.

namespace DesktopEntry {
    public const string ID = "org.gurov.Stolovaya";
    const string ICON_RESOURCE = "/org/gurov/Stolovaya/icons/scalable/apps/" + ID + ".svg";

    public void install () {
        var data = Environment.get_user_data_dir ();
        try {
            var icon = resources_lookup_data (ICON_RESOURCE, ResourceLookupFlags.NONE);
            write_if_changed (Path.build_filename (data, "icons", "hicolor", "scalable", "apps", ID + ".svg"),
                icon.get_data ());

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
            write_if_changed (Path.build_filename (data, "applications", ID + ".desktop"), entry.data);
        } catch (Error e) {
            warning ("Ярлык программы: %s", e.message);
        }
    }

    // Не трогаем файл без надобности: GNOME перечитывает ярлыки при каждом изменении
    void write_if_changed (string path, uint8[] contents) throws Error {
        uint8[] old;
        try {
            FileUtils.get_data (path, out old);
            if (old.length == contents.length && Memory.cmp (old, contents, contents.length) == 0) {
                return;
            }
        } catch (FileError e) {
            // Файла ещё нет
        }
        DirUtils.create_with_parents (Path.get_dirname (path), 0755);
        FileUtils.set_data (path, contents);
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
        return "\"%s\"".printf (escaped.str);
    }
}
