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

    public App () {
        Object (
            application_id: "org.gurov.Stolovaya",
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

        // Выгрузка в полночь: проверяем дату каждые 30 секунд
        today = Database.format_date (new DateTime.now_local ());
        Timeout.add_seconds (30, () => {
            var day = Database.format_date (new DateTime.now_local ());
            if (day != today) {
                today = day;
                run_export ();
            }
            return Source.CONTINUE;
        });

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
        }
    }

    // Закрытие программы: выгружаем всё, что изменилось
    protected override void shutdown () {
        if (exporter != null) {
            // Программа закрывается — кнопки нажимать будет некому
            run_export (0, false);
        }
        base.shutdown ();
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
            send_desktop_notification ("Не удалось сохранить Excel-файл", e.message);
            return;
        }
        if (files.length == 0) {
            return;
        }

        var names = new string[0];
        exported_files = {};
        foreach (var file in files) {
            names += file;
            exported_files += file;
        }
        export_notification = send_desktop_notification (
            files.length == 1 ? "Excel-файл сохранён" : "Excel-файлы сохранены",
            string.joinv ("\n", names), "x-office-spreadsheet", export_notification,
            interactive ? new string[] { "open-folder", "Открыть папку" } : new string[0]);
        if (interactive) {
            warn_if_open (files);
        }
    }

    // Пересобранный файл открыт в другой программе (например, LibreOffice):
    // в ней старая версия, и если сохранить файл там, она запишется поверх
    // новой. Сообщаем и предлагаем закрыть эту программу.
    private void warn_if_open (GenericArray<string> files) {
        var users = new GenericArray<FileUser> ();
        var open_files = new string[0];
        var programs = new string[0];
        foreach (var file in files) {
            var found = FileUsers.find (file);
            if (found.length > 0) {
                open_files += file;
            }
            foreach (var user in found) {
                if (!(user.name in programs)) {
                    programs += user.name;
                }
                // Одна программа может держать несколько файлов
                var known = false;
                foreach (var other in users) {
                    known = known || other.pid == user.pid;
                }
                if (!known) {
                    users.add (user);
                }
            }
        }
        if (users.length == 0 || active_window == null) {
            return;
        }

        var names = new string[0];
        foreach (var file in open_files) {
            names += "«%s»".printf (Path.get_basename (file));
        }
        // Имена программ — в именительном падеже: «в программе LibreOffice»
        var program = string.joinv (", ", programs);
        var where = (programs.length == 1 ? "в программе " : "в программах ") + program;
        var body = open_files.length == 1
            ? "Файл %s обновлён, а %s открыта его старая версия. Если сохранить файл там, новые записи из него пропадут.".printf (names[0], where)
            : "Файлы %s обновлены, а %s открыты их старые версии. Если сохранить файлы там, новые записи из них пропадут.".printf (string.joinv (", ", names), where);
        body += " В базе «Столовой» они останутся.\n\n"
            + "При закрытии программы закроются все её окна, несохранённые изменения в них будут потеряны.";

        var dialog = new Adw.AlertDialog (
            open_files.length == 1 ? "Excel-файл открыт в другой программе" : "Excel-файлы открыты в другой программе",
            body);
        dialog.add_response ("keep", "Не закрывать");
        dialog.add_response ("close", programs.length == 1 ? "Закрыть " + program : "Закрыть программы");
        dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "keep";
        dialog.close_response = "keep";
        dialog.response.connect ((response) => {
            if (response == "close") {
                close_programs (users, open_files, program, programs.length > 1);
            }
        });
        dialog.present (active_window);
    }

    // Закрыть программы сигналом и подождать до 5 секунд, пока они отпустят файлы
    private void close_programs (GenericArray<FileUser> users, string[] files, string program, bool several) {
        foreach (var user in users) {
            FileUsers.terminate (user);
        }
        int waited = 0;
        Timeout.add (250, () => {
            waited += 250;
            var still_open = false;
            foreach (var file in files) {
                still_open = still_open || FileUsers.find (file).length > 0;
            }
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
                    new Variant.array (new VariantType ("{sv}"), {}),  // подсказки
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
            application_icon = "auth-smartcard-symbolic",
            version = Config.VERSION,
            comments = "Учёт питания по карточкам\nРаботает с карточками EM-Marine и Mifare (125 кГц и 13.56 МГц).\nВидит некоторые телефоны, но только те которые представляются как Mifare.\nПротестировано на сканере IronLogic Z-2 (мод. RD AII)",
            developer_name = "Гуров Данил Дмитриевич",
        };
        dialog.set_license_type (Gtk.License.GPL_3_0);
        dialog.present (active_window);
    }

    public static int main (string[] args) {
        return new App ().run (args);
    }
}
