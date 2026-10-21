// Учёт питания в столовой по NFC-карточкам.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class App : Adw.Application {
    private Database? database;
    private Settings? settings;
    private CardReader reader = new CardReader ();
    private string? database_error;
    private ExcelExporter? exporter;
#if DEBUG
    private bool demo_data = true;
#endif
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить полночь

    // Последнее уведомление о выгрузке: его кнопка «Открыть папку»
    // показывает эти файлы. Новое уведомление заменяет прежнее.
    private uint32 export_notification = 0;
    private string[] exported_files = {};
    // Токен от сервера уведомлений, чтобы файловый менеджер открылся поверх окон
    private string? activation_token = null;

    // Excel-файлы, открытые в других программах (см. check_open_files)
    private FileMonitor? export_dir_monitor = null;
    private uint open_check_timeout = 0;
    private int[] warned_pids = {};  // о ком уже предупредили, пока держат файлы
    private Adw.AlertDialog? open_dialog = null;

    public App () {
        Object (
            application_id: DesktopEntry.ID,
            flags: ApplicationFlags.DEFAULT_FLAGS,
            // Узнавать о выходе из сеанса и выключении (сигнал query-end)
            register_session: true
        );

#if DEBUG
        add_main_option ("demo-data", 0, OptionFlags.NONE, OptionArg.NONE,
            "Добавить тестовых учеников с карточками 1, 2, 3", null);
#endif
    }

#if DEBUG
    protected override int handle_local_options (VariantDict options) {
        demo_data = options.contains ("demo-data");
        return -1;  // продолжить обычный запуск
    }
#endif

    protected override void startup () {
        base.startup ();
        Styles.load ();
        DesktopEntry.install ();
        Gtk.Window.set_default_icon_name (DesktopEntry.ID);

        var about = new SimpleAction ("about", null);
        about.activate.connect (show_about);
        add_action (about);

        // Выход: окна закрываются, затем shutdown () делает выгрузку
        var quit_action = new SimpleAction ("quit", null);
        quit_action.activate.connect (() => quit ());
        add_action (quit_action);
        set_accels_for_action ("app.quit", { "<Control>q" });

        // В переносимой сборке база — в папке данных пользователя
        // (~/.local/share/Столовая): переживает замену папки с программой
        var path = Config.PORTABLE
            ? Path.build_filename (Environment.get_user_data_dir (), "Столовая", "canteen.db")
            : Config.DATABASE_PATH;
        try {
            database = new Database (path);
            settings = new Settings (database);
#if DEBUG
            add_demo_students ();

#endif
        } catch (DatabaseError e) {
            database = null;
            database_error = e.message;
            critical ("База данных %s: %s", path, e.message);
            return;
        }

        reader.start ();
        watch_notifications ();

        exporter = new ExcelExporter (database, ExcelExporter.default_directory ());

        var export = new SimpleAction ("export", null);
        export.activate.connect (() => {
            run_export (Database.school_year_of (new DateTime.now_local ()));
        });
        add_action (export);

        var history = new SimpleAction ("history", null);
        history.activate.connect (() => {
            activate ();
            ((MainWindow) active_window).show_history ();
        });
        add_action (history);
        set_accels_for_action ("app.history", { "<Control>h" });

        var preferences = new SimpleAction ("preferences", null);
        preferences.activate.connect (() => {
            activate ();
            ((MainWindow) active_window).show_settings ();
        });
        add_action (preferences);
        set_accels_for_action ("app.preferences", { "<Control>comma" });

        // Выгрузка в полночь: проверяем дату каждые 30 секунд.
        // Заодно — не открыл ли файл кто-то, кроме LibreOffice (его видно сразу).
        today = Database.format_date (new DateTime.now_local ());
        Timeout.add_seconds (30, () => {
            var day = Database.format_date (new DateTime.now_local ());
            if (day != today) {
                today = day;
                run_export ();
            }
            check_open_files ();
            return Source.CONTINUE;
        });
        watch_export_directory ();

        // Выход из сеанса: не даём завершить сеанс, пока файл не записан
        query_end.connect (() => {
            var cookie = inhibit (active_window, Gtk.ApplicationInhibitFlags.LOGOUT, "Сохранение Excel-файла");
            run_export (0, false);
            uninhibit (cookie);
        });
    }

    protected override void activate () {
        Posix.statvfs buf;
//         if (Posix.statvfs_exec ("/", out Posix.statvfs buf)) {
//
//         }

        if (database == null) {
            show_database_error ();
            return;
        }
        var first_start = active_window == null;
        var window = active_window ?? new MainWindow (this, database, settings, reader);
        window.present ();

        // При запуске догоняем выгрузку, если программа была закрыта
        // или компьютер выключен, когда были новые записи
        if (first_start) {
            run_export ();
            check_open_files ();
        }
    }

    // Закрытие программы: выгружаем всё, что изменилось
    protected override void shutdown () {
        if (exporter != null) {
            // Программа закрывается — кнопки нажимать будет некому
            run_export (0, false);
            // Нового нечего было записать, а уведомление о прошлой выгрузке
            // ещё на экране — иначе оно пропадёт вместе с программой
            if (export_notification != 0) {
                replace_export_notification (export_title (exported_files.length),
                    string.joinv ("\n", exported_files));
            }
        }
        base.shutdown ();
    }

    private static string export_title (int count) {
        return count == 1 ? "Excel-файл сохранён" : "Excel-файлы сохранены";
    }

    // Пересобрать файлы учебных лет с новыми записями (и with_school_year в любом случае)
    // и сообщить об этом. Ничего не изменилось — ничего не пишем и не сообщаем.
    // interactive — кнопка «Открыть папку» в уведомлении и окно, если файл
    // открыт в другой программе; false — при выходе программы или из сеанса.
    private void run_export (int with_school_year = 0, bool interactive = true) {
        GenericArray<string> files;
        try {
            files = exporter.export_changed (with_school_year);
        } catch (Error e) {
            critical ("Выгрузка в Excel: %s", e.message);
            if (interactive) {
                send_desktop_notification ("Не удалось сохранить Excel-файл", e.message);
            } else {
                send_detached_notification ("Не удалось сохранить Excel-файл", e.message);
            }
            return;
        }
        if (files.length == 0) {
            return;
        }

        var names = new string[0];
        foreach (var file in files) {
            names += file;
        }
        var body = string.joinv ("\n", names);
        if (!interactive) {
            replace_export_notification (export_title (files.length), body);
            return;
        }
        exported_files = names;
        export_notification = send_desktop_notification (export_title (files.length), body,
            "x-office-spreadsheet", export_notification, { "open-folder", "Открыть папку" });
        warn_if_open (files);
    }

    // Уведомление о выгрузке, которое переживёт выход программы: прежнее
    // закрываем, новое шлёт отдельный процесс (см. send_detached_notification)
    private void replace_export_notification (string title, string body) {
        if (export_notification != 0) {
            try {
                Bus.get_sync (BusType.SESSION).call_sync (
                    "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications", "CloseNotification",
                    new Variant ("(u)", export_notification), null, DBusCallFlags.NONE, 2000);
            } catch (Error e) {
                debug ("CloseNotification: %s", e.message);
            }
        }
        export_notification = 0;
        exported_files = {};
        send_detached_notification (title, body);
    }

    // GNOME Shell убирает уведомления программы, когда она завершается, если
    // узнал её по окну (по PID отправителя) — так бывает, пока окно открыто.
    // Уведомление от отдельного процесса gdbus без окон ни к какой программе
    // не привязано и остаётся на экране после выхода. Подсказку desktop-entry
    // ему не передаём: с ней GNOME привяжет его к программе и уберёт,
    // как только gdbus завершится.
    private static void send_detached_notification (string title, string body) {
        string[] argv = {
            "gdbus", "call", "--session",
            "--dest", "org.freedesktop.Notifications",
            "--object-path", "/org/freedesktop/Notifications",
            "--method", "org.freedesktop.Notifications.Notify",
            "--",  // иначе -1 в конце gdbus примет за параметр
            new Variant.string ("Столовая").print (false), "0",
            new Variant.string ("x-office-spreadsheet").print (false),
            new Variant.string (title).print (false),
            new Variant.string (body).print (false),
            "[]", "{}", "-1"
        };
        try {
            Process.spawn_async (null, argv, null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL, null, null);
        } catch (SpawnError e) {
            warning ("gdbus: %s", e.message);
            send_desktop_notification (title, body);
        }
    }

    // --- Excel-файл открыт в другой программе ---
    //
    // Программа (например, LibreOffice) держит файл, а выгрузка заменяет его
    // новым: в программе остаётся старая версия, и если сохранить её, новые
    // записи пропадут из файла. Предупреждаем, как только файл открыли,
    // и ещё раз после выгрузки — тогда открытая копия уже устарела.

    // LibreOffice, открывая файл, создаёт рядом «.~lock.имя#» — проверяем сразу.
    // Файл он открывает чуть позже блокировки, поэтому проверка через секунду.
    private void watch_export_directory () {
        DirUtils.create_with_parents (exporter.directory, 0755);
        try {
            export_dir_monitor = File.new_for_path (exporter.directory).monitor_directory (FileMonitorFlags.NONE);
        } catch (Error e) {
            warning ("Слежение за папкой %s: %s", exporter.directory, e.message);
            return;
        }
        export_dir_monitor.changed.connect ((file) => {
            if (!file.get_basename ().has_prefix (".~lock.")) {
                return;
            }
            if (open_check_timeout != 0) {
                Source.remove (open_check_timeout);
            }
            open_check_timeout = Timeout.add_seconds (1, () => {
                open_check_timeout = 0;
                check_open_files ();
                return Source.REMOVE;
            });
        });
    }

    // Excel-файлы в папке выгрузки
    private string[] export_files () {
        string[] result = {};
        try {
            var dir = Dir.open (exporter.directory);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_suffix (".xlsx") && !name.has_prefix (".")) {
                    result += Path.build_filename (exporter.directory, name);
                }
            }
        } catch (FileError e) {
            // Папки ещё нет — выгрузки не было
        }
        return result;
    }

    // Предупредить о программах, которые открыли файл, — один раз за открытие
    private void check_open_files () {
        var users = FileUsers.find_all (export_files ());

        // Кто файлы закрыл — при следующем открытии предупредим снова
        int[] still_open = {};
        foreach (var pid in warned_pids) {
            foreach (var user in users) {
                if (user.pid == pid) {
                    still_open += pid;
                    break;
                }
            }
        }
        warned_pids = still_open;

        var fresh = new GenericArray<FileUser> ();
        foreach (var user in users) {
            if (!(user.pid in warned_pids)) {
                fresh.add (user);
            }
        }
        if (fresh.length > 0 && open_dialog == null) {
            show_open_dialog (fresh, false);
        }
    }

    // После выгрузки: открытые копии уже устарели — предупредить в любом случае
    private void warn_if_open (GenericArray<string> files) {
        string[] paths = {};
        foreach (var file in files) {
            paths += file;
        }
        var users = FileUsers.find_all (paths);
        if (users.length > 0) {
            show_open_dialog (users, true);
        }
    }

    // stale — файл уже заменён выгрузкой, в программе старая версия
    private void show_open_dialog (GenericArray<FileUser> users, bool stale) {
        var window = active_window;
        if (window == null) {
            return;
        }
        if (open_dialog != null) {
            open_dialog.force_close ();
        }

        // Программы и файлы без повторов: одна программа может держать два файла
        var programs = new string[0];
        var files = new string[0];
        var names = new string[0];
        foreach (var user in users) {
            if (!(user.pid in warned_pids)) {
                warned_pids += user.pid;
            }
            if (!(user.name in programs)) {
                programs += user.name;
            }
            if (!(user.path in files)) {
                files += user.path;
                names += "«%s»".printf (Path.get_basename (user.path));
            }
        }
        var program = string.joinv (", ", programs);
        var several = programs.length > 1;
        var one_file = files.length == 1;
        // Имена программ — в именительном падеже: «в программе LibreOffice»
        var where = (several ? "в программах " : "в программе ") + program;

        string body;
        if (stale) {
            body = one_file
                ? "Файл %s обновлён, а %s открыта его старая версия. Если сохранить файл там, новые записи из него пропадут.".printf (names[0], where)
                : "Файлы %s обновлены, а %s открыты их старые версии. Если сохранить файлы там, новые записи из них пропадут.".printf (string.joinv (", ", names), where);
        } else {
            body = (one_file ? "Файл %s открыт %s." : "Файлы %s открыты %s.").printf (string.joinv (", ", names), where)
                + " «Столовая» пересобирает Excel-файлы в полночь, при закрытии и по команде «Обновить Excel-файл»:"
                + " открытая копия при этом не обновится, а если сохранить её, новые записи пропадут из файла.";
        }
        body += " В базе «Столовой» записи останутся.\n\n"
            + "При закрытии программы закроются все её окна, несохранённые изменения в них будут потеряны.";

        var heading = one_file ? "Excel-файл открыт в другой программе" : "Excel-файлы открыты в другой программе";
        open_dialog = new Adw.AlertDialog (heading, body);
        open_dialog.add_response ("keep", "Не закрывать");
        open_dialog.add_response ("close", several ? "Закрыть программы" : "Закрыть " + program);
        open_dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
        open_dialog.default_response = "keep";
        open_dialog.close_response = "keep";
        open_dialog.response.connect ((response) => {
            if (response == "close") {
                close_programs (users, files, program, several);
            }
        });
        open_dialog.closed.connect (() => open_dialog = null);
        open_dialog.present (window);

        // Окно «Столовой», скорее всего, под LibreOffice — окно предупреждения не видно
        if (!window.is_active) {
            send_desktop_notification (heading, "%s %s. Подробности — в окне «Столовой».".printf (
                one_file ? "Открыт" : "Открыты", where), "dialog-warning-symbolic");
        }
    }

    // Закрыть программы сигналом и подождать до 5 секунд, пока они отпустят файлы
    private void close_programs (GenericArray<FileUser> users, string[] files, string program, bool several) {
        foreach (var user in users) {
            FileUsers.terminate (user);
        }
        int waited = 0;
        Timeout.add (250, () => {
            waited += 250;
            var still_open = FileUsers.find_all (files).length > 0;
            if (still_open && waited < 5000) {
                return Source.CONTINUE;
            }

            var window = active_window as MainWindow;
            if (still_open) {
                window?.show_toast ("%s не %s — закройте вручную".printf (program, several ? "закрываются" : "закрывается"));
            } else {
                foreach (var file in files) {
                    FileUsers.remove_stale_lock (file);
                }
                window?.show_toast ("%s %s".printf (program, several ? "закрыты" : "закрыт"));
            }
            return Source.REMOVE;
        });
    }

    // Нажатие кнопки в уведомлении приходит сигналом ActionInvoked, а перед ним
    // ActivationToken. Сигналы общие для всех программ — сверяем id уведомления.
    private void watch_notifications () {
        try {
            Bus.get_sync (BusType.SESSION).signal_subscribe (
                "org.freedesktop.Notifications", "org.freedesktop.Notifications",
                null, "/org/freedesktop/Notifications", null, DBusSignalFlags.NONE,
                (connection, sender, path, iface, name, parameters) => {
                    if (export_notification == 0
                        || parameters.get_child_value (0).get_uint32 () != export_notification) {
                        return;
                    }
                    switch (name) {
                    case "ActivationToken":
                        activation_token = parameters.get_child_value (1).get_string ();
                        break;
                    case "ActionInvoked":
                        if (parameters.get_child_value (1).get_string () == "open-folder") {
                            show_in_file_manager (exported_files, activation_token);
                        }
                        activation_token = null;
                        break;
                    case "NotificationClosed":
                        export_notification = 0;
                        activation_token = null;
                        break;
                    }
                });
        } catch (Error e) {
            warning ("Кнопки в уведомлениях не будут работать: %s", e.message);
        }
    }

    // Открыть папку с файлами в файловом менеджере и выделить их.
    // Не умеет (нет org.freedesktop.FileManager1) — просто открыть папку.
    private static void show_in_file_manager (string[] files, string? token) {
        if (files.length == 0) {
            return;
        }
        var uris = new string[0];
        foreach (var file in files) {
            uris += File.new_for_path (file).get_uri ();
        }
        try {
            Bus.get_sync (BusType.SESSION).call_sync (
                "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1", "ShowItems",
                new Variant.tuple ({ new Variant.strv (uris), new Variant.string (token ?? "") }),
                null, DBusCallFlags.NONE, 5000);
            return;
        } catch (Error e) {
            debug ("FileManager1.ShowItems: %s", e.message);
        }
        try {
            var folder = File.new_for_path (files[0]).get_parent ();
            AppInfo.launch_default_for_uri (folder.get_uri (), null);
        } catch (Error e) {
            warning ("Не удалось открыть папку: %s", e.message);
        }
    }

    // Системное уведомление GNOME. Через org.freedesktop.Notifications напрямую:
    // GLib.Notification в GNOME работает только для приложений
    // с установленным .desktop-файлом.
    // replaces — id прежнего уведомления, которое заменить новым (0 — показать
    // отдельно). actions — кнопки парами: ключ, надпись. Возвращает id
    // показанного уведомления, 0 — если не вышло.
    public static uint32 send_desktop_notification (string title, string body,
            string icon = "x-office-spreadsheet", uint32 replaces = 0, string[] actions = {}) {
        try {
            var bus = Bus.get_sync (BusType.SESSION);
            var reply = bus.call_sync (
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "Notify",
                new Variant.tuple ({
                    new Variant.string ("Столовая"),  // имя приложения
                    new Variant.uint32 (replaces),     // id заменяемого уведомления
                    new Variant.string (icon),
                    new Variant.string (title),
                    new Variant.string (body),
                    new Variant.strv (actions),                        // кнопки
                    // Подсказка: чьё уведомление — имя и значок из ярлыка программы
                    new Variant.array (new VariantType ("{sv}"), {
                        new Variant.dict_entry (new Variant.string ("desktop-entry"),
                            new Variant.variant (new Variant.string (DesktopEntry.ID)))
                    }),
                    new Variant.int32 (-1)             // время показа по умолчанию
                }),
                new VariantType ("(u)"), DBusCallFlags.NONE, 2000);
            return reply.get_child_value (0).get_uint32 ();
        } catch (Error e) {
            warning ("Уведомление не отправлено: %s", e.message);
            return 0;
        }
    }

    // Без базы работать нельзя: сообщаем об ошибке и выходим
    private void show_database_error () {
        var window = new Adw.ApplicationWindow (this) {
            title = "Ошибка базы данных!",
            default_width = 400,
            default_height = 200
        };
        window.present ();

        var dialog = new Adw.AlertDialog ("Не удалось открыть базу данных", database_error);
        dialog.add_response ("close", "Закрыть");
        dialog.response.connect (() => quit ());
        dialog.present (window);
    }

#if DEBUG
    private void add_demo_students () throws DatabaseError {
        string[,] students = {
            { "Иванов Иван Тестович", "ТЕСТ" },
            { "Петрова Мария Сергеевна", "ТЕСТ" },
            { "Сидоров Алексей Петрович", "ТЕСТ" }
        };
        for (int i = 0; i < students.length[0]; i++) {
            int64 card = i + 1;
            if (database.find_student_by_card (card) == null) {
                database.add_student (students[i, 0], students[i, 1], card);
            }
        }
    }
#endif

    private void show_about () {
        var dialog = new Adw.AboutDialog () {
            application_name = "Столовая",
            application_icon = DesktopEntry.ID,
            version = Config.VERSION,
            comments = "Учёт питания по карточкам\nРаботает с карточками EM-Marine и Mifare (125 кГц и 13.56 МГц).\nВидит некоторые телефоны, но только те которые представляются как Mifare.\nПротестировано на сканере IronLogic Z-2 (мод. RD AII)",
            developer_name = "Гуров Данил Дмитриевич",
        };
        dialog.set_license_type (Gtk.License.GPL_3_0);
        dialog.present (active_window);
    }

    public static int main (string[] args) {
        // Настройка системы от root (см. SystemSetup.run): без окна,
        // программа завершается сразу после настройки
        if (args.length == 2 && args[1] == SystemSetup.FLAG) {
            return SystemSetup.apply ();
        }
        return new App ().run (args);
    }
}
