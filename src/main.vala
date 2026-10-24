// Учёт питания в столовой по NFC-карточкам.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class App : Adw.Application {
    private Database? database;
    private Settings? settings;
    private CardReader reader = new CardReader ();
    private string database_path;
    private string? database_error;
    private bool database_busy;  // не открылась, потому что занята другой программой
    private Adw.ApplicationWindow? error_window = null;
    private Adw.AlertDialog? error_dialog = null;
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
        Adw.StyleManager.get_default ().notify["accent-color"].connect (() => DesktopEntry.install ());
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
        database_path = Config.PORTABLE
            ? Path.build_filename (Environment.get_user_data_dir (), "Столовая", "canteen.db")
            : Config.DATABASE_PATH;
        if (open_database ()) {
            start_services ();
        }
    }

    // false — не открылась, причина в database_error
    private bool open_database () {
        try {
            database = new Database (database_path);
            settings = new Settings (database);
#if DEBUG
            add_demo_students ();

#endif
        } catch (DatabaseError e) {
            database = null;
            database_error = e.message;
            database_busy = e is DatabaseError.BUSY;
            critical ("База данных %s: %s", database_path, e.message);
            return false;
        }
        return true;
    }

    // Всё, что работает с базой: считыватель, выгрузка, действия меню
    private void start_services () {
        reader.start ();
        watch_notifications ();

        exporter = new ExcelExporter (database, ExcelExporter.default_directory ());

        var export = new SimpleAction ("export", null);
        export.activate.connect (() => {
            run_export (Database.school_year_of (new DateTime.now_local ()));
        });
        add_action (export);

        var import_students_action = new SimpleAction ("import-students", null);
        import_students_action.activate.connect (() => {
            activate ();
            import_students ((MainWindow) active_window);
        });
        add_action (import_students_action);

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
            check_database_users ();
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
            else {
                replace_export_notification ("Excel файлы не записаны", "Нечего записывать нового");
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
        close_desktop_notification (export_notification);
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
                names += @"«$(Path.get_basename (user.path))»";
            }
        }
        var program = string.joinv (", ", programs);
        var several = programs.length > 1;
        var one_file = files.length == 1;
        // Имена программ — в именительном падеже: «в программе LibreOffice»
        var where = @"$(several ? "в программах" : "в программе") $program";

        var list = string.joinv (", ", names);
        string body;
        if (stale) {
            body = one_file
                ? @"Файл $list обновлён, а $where открыта его старая версия. Если сохранить файл там, новые записи из него пропадут."
                : @"Файлы $list обновлены, а $where открыты их старые версии. Если сохранить файлы там, новые записи из них пропадут.";
        } else {
            body = (one_file ? @"Файл $list открыт $where." : @"Файлы $list открыты $where.")
                + " «Столовая» пересобирает Excel-файлы в полночь, при закрытии и по команде «Обновить Excel-файл»:"
                + " открытая копия при этом не обновится, а если сохранить её, новые записи пропадут из файла.";
        }
        body += " В базе «Столовой» записи останутся.\n\n"
            + "При закрытии программы закроются все её окна, несохранённые изменения в них будут потеряны.";

        var heading = one_file ? "Excel-файл открыт в другой программе" : "Excel-файлы открыты в другой программе";
        open_dialog = new Adw.AlertDialog (heading, body);
        open_dialog.add_response ("keep", "Не закрывать");
        open_dialog.add_response ("close", several ? "Закрыть программы" : @"Закрыть $program");
        open_dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
        open_dialog.default_response = "keep";
        open_dialog.close_response = "keep";
        open_dialog.response.connect ((response) => {
            if (response == "close") {
                close_programs (users, files, (closed) => {
                    if (closed) {
                        foreach (var file in files) {
                            FileUsers.remove_stale_lock (file);
                        }
                    }
                    toast_programs_closed (closed, program, several);
                });
            }
        });
        open_dialog.closed.connect (() => open_dialog = null);
        watch_release (open_dialog, users, files,
            released_message (programs, one_file ? "файл" : "файлы"), (dialog) => {
                foreach (var file in files) {
                    FileUsers.remove_stale_lock (file);
                }
                dialog.set_response_label ("keep", "Хорошо");
            });
        open_dialog.present (window);

        // Окно «Столовой», скорее всего, под LibreOffice — окно предупреждения не видно
        if (!window.is_active) {
            send_desktop_notification (heading, @"$(one_file ? "Открыт" : "Открыты") $where. Подробности — в окне «Столовой».",
                "dialog-warning-symbolic");
        }
    }

    public delegate void ProgramsClosed (bool closed);

    // Закрыть программы сигналом и подождать до 5 секунд, пока они отпустят
    // файлы. closed — отпустили.
    private void close_programs (GenericArray<FileUser> users, owned string[] files, owned ProgramsClosed done) {
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

            done (!still_open);
            return Source.REMOVE;
        });
    }

    public delegate void FilesReleased (Adw.AlertDialog dialog);

    // Пока окно-предупреждение открыто, следить, не закрыли ли программы сами
    // (вручную, из их окна). Закрыли — вместо кнопки «Закрыть …» сообщение
    // message, released меняет остальные кнопки.
    private void watch_release (Adw.AlertDialog dialog, GenericArray<FileUser> users, owned string[] files,
            string message, owned FilesReleased released) {
        uint check = 0;
        check = Timeout.add_seconds (1, () => {
            if (still_held (users, files)) {
                return Source.CONTINUE;
            }
            check = 0;
            dialog.body = message;
            dialog.remove_response ("close");
            released (dialog);
            return Source.REMOVE;
        });
        dialog.closed.connect (() => {
            if (check != 0) {
                Source.remove (check);
                check = 0;
            }
        });
    }

    // Держит ли файлы хоть одна из этих программ. Программы, открывшие файлы
    // позже, не в счёт: о них — отдельное предупреждение.
    private static bool still_held (GenericArray<FileUser> users, string[] files) {
        foreach (var holder in FileUsers.find_all (files)) {
            foreach (var user in users) {
                if (holder.pid == user.pid) {
                    return true;
                }
            }
        }
        return false;
    }

    // what — в винительном падеже: «файл», «базу»
    private static string released_message (string[] programs, string what) {
        var program = string.joinv (", ", programs);
        return programs.length > 1
            ? @"Программы $program завершились и освободили $what."
            : @"Программа $program завершилась и освободила $what.";
    }

    private void toast_programs_closed (bool closed, string program, bool several) {
        var window = active_window as MainWindow;
        if (closed) {
            window?.show_toast (@"$program $(several ? "закрыты" : "закрыт")");
        } else {
            window?.show_toast (@"$program не $(several ? "закрываются" : "закрывается") — закройте вручную");
        }
    }

    // Имена программ без повторов: у одной программы может быть несколько процессов
    // и открыто несколько файлов
    private static string[] program_names (GenericArray<FileUser> users) {
        var result = new string[0];
        foreach (var user in users) {
            if (!(user.name in result)) {
                result += user.name;
            }
        }
        return result;
    }

    // --- База открыта в другой программе ---
    //
    // Пока другая программа (DB Browser for SQLite) держит в базе незаписанные
    // изменения, выдачи не записываются, а каждый запрос к базе ждёт до секунды —
    // окно подвисает. А если она держит базу уже при запуске, базу не открыть.
    // Предупреждаем при запуске и предлагаем закрыть программу.

    // База и её спутники в режиме WAL: DB Browser держит открытыми все три
    private string[] database_files () {
        return { database_path, @"$database_path-wal", @"$database_path-shm" };
    }

    private void check_database_users () {
        var users = FileUsers.find_all (database_files ());
        if (users.length == 0) {
            return;
        }
        var programs = program_names (users);
        var program = string.joinv (", ", programs);
        var several = programs.length > 1;
        var where = @"$(several ? "в программах" : "в программе") $program";

        var dialog = new Adw.AlertDialog ("База данных открыта в другой программе",
            @"База «Столовой» открыта $where. Пока там есть незаписанные изменения,"
            + " выдачи не записываются, а окно «Столовой» подвисает при каждом считывании карточки.\n\n"
            + "При закрытии программы закроются все её окна, незаписанные изменения в них будут потеряны.");
        dialog.add_response ("keep", "Не закрывать");
        dialog.add_response ("close", several ? "Закрыть программы" : @"Закрыть $program");
        dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "keep";
        dialog.close_response = "keep";
        dialog.response.connect ((response) => {
            if (response == "close") {
                close_programs (users, database_files (), (closed) => toast_programs_closed (closed, program, several));
            }
        });
        watch_release (dialog, users, database_files (), released_message (programs, "базу"),
            (alert) => alert.set_response_label ("keep", "Хорошо"));
        dialog.present (active_window);
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

    // Убрать показанное уведомление; id 0 — уведомления нет
    public static void close_desktop_notification (uint32 id) {
        if (id == 0) {
            return;
        }
        try {
            Bus.get_sync (BusType.SESSION).call_sync (
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "CloseNotification",
                new Variant ("(u)", id), null, DBusCallFlags.NONE, 2000);
        } catch (Error e) {
            debug ("CloseNotification: %s", e.message);
        }
    }

    // Без базы работать нельзя: сообщаем об ошибке и выходим
    // База не открылась. Если её держит другая программа — предложить закрыть
    // её и открыть базу снова.
    private void show_database_error () {
        if (error_window == null) {
            error_window = new Adw.ApplicationWindow (this) {
                title = "Ошибка базы данных!",
                default_width = 520,
                default_height = 400
            };
        }
        error_window.present ();
        if (error_dialog != null) {
            return;
        }

        var users = database_busy ? FileUsers.find_all (database_files ()) : new GenericArray<FileUser> ();
        error_dialog = new Adw.AlertDialog ("Не удалось открыть базу данных", database_error);
        error_dialog.add_response ("quit", "Выйти");
        error_dialog.close_response = "quit";
        if (users.length > 0) {
            var programs = program_names (users);
            var program = string.joinv (", ", programs);
            var several = programs.length > 1;
            error_dialog.body = @"База «Столовой» открыта $(several ? "в программах" : "в программе") $program"
                + " и занята незаписанными изменениями. Закройте программу — тогда «Столовая» откроет базу.\n\n"
                + "При закрытии программы закроются все её окна, незаписанные изменения в них будут потеряны.";
            error_dialog.add_response ("close", several ? "Закрыть программы" : @"Закрыть $program");
            error_dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
            error_dialog.default_response = "close";
            watch_release (error_dialog, users, database_files (),
                released_message (programs, "базу") + " Теперь «Столовая» может её открыть.", (dialog) => {
                    dialog.add_response ("retry", "Открыть базу");
                    dialog.set_response_appearance ("retry", Adw.ResponseAppearance.SUGGESTED);
                    dialog.default_response = "retry";
                });
        } else if (database_busy) {
            // Кто держит базу, не видно (программа другого пользователя)
            error_dialog.add_response ("retry", "Повторить");
            error_dialog.default_response = "retry";
        }
        error_dialog.response.connect ((response) => {
            switch (response) {
            case "close":
                close_programs (users, database_files (), (closed) => retry_database ());
                break;
            case "retry":
                retry_database ();
                break;
            default:
                quit ();
                break;
            }
        });
        error_dialog.closed.connect (() => error_dialog = null);
        error_dialog.present (error_window);
    }

    private void retry_database () {
        if (!open_database ()) {
            show_database_error ();
            return;
        }
        start_services ();
        // Окно ошибки — единственное: без hold программа завершится с ним
        hold ();
        error_window.destroy ();
        error_window = null;
        activate ();
        release ();
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

    // Импорт учеников: выбрать таблицу Excel, загрузить, показать итог
    private void import_students (MainWindow window) {
        var filter = new Gtk.FileFilter () {
            name = "Таблицы Excel (.xlsx)"
        };
        filter.add_suffix ("xlsx");
        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        var dialog = new Gtk.FileDialog () {
            title = "Импорт учеников",
            filters = filters,
            default_filter = filter
        };
        dialog.open.begin (window, null, (obj, res) => {
            File file;
            try {
                file = dialog.open.end (res);
            } catch (Error e) {
                return;  // окно выбора закрыли
            }
            ImportResult result;
            try {
                result = StudentsImport.import_file (database, file.get_path ());
            } catch (Error e) {
                var alert = new Adw.AlertDialog ("Ученики не загружены", e.message);
                alert.add_response ("close", "Закрыть");
                alert.present (window);
                return;
            }
            window.update_counts ();
            show_import_result (window, result);
        });
    }

    private void show_import_result (MainWindow window, ImportResult result) {
        const int MAX_PROBLEMS = 10;
        var body = @"Добавлено учеников: $(result.added)\nОбновлено: $(result.updated)\nБез изменений: $(result.unchanged)";
        if (result.problems.length > 0) {
            body += @"\n\nНе загружено строк: $(result.problems.length)";
            for (int i = 0; i < result.problems.length && i < MAX_PROBLEMS; i++) {
                body += @"\n$(result.problems[i])";
            }
            if (result.problems.length > MAX_PROBLEMS) {
                body += "\n…";
            }
        }
        body += "\n\nУ новых карточек записаны только серия и номер — остальное программа допишет, когда карточку впервые приложат.";
        var alert = new Adw.AlertDialog ("Ученики загружены", body);
        alert.add_response ("close", "Готово");
        alert.present (window);
    }

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
