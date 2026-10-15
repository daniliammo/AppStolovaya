// Учёт питания в столовой по NFC-карточкам.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class HelloApp : Adw.Application {
    private Database? database;
    private Settings? settings;
    private string? database_error;
    private ExcelExporter? exporter;
    private bool demo_data = false;
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить полночь

    public HelloApp () {
        Object (
            application_id: "org.example.Test",
            flags: ApplicationFlags.DEFAULT_FLAGS,
            // Узнавать о выходе из сеанса и выключении (сигнал query-end)
            register_session: true
        );

        add_main_option ("demo-data", 0, OptionFlags.NONE, OptionArg.NONE,
            "Добавить тестовых учеников с карточками 1, 2, 3", null);
    }

    protected override int handle_local_options (VariantDict options) {
        demo_data = options.contains ("demo-data");
        return -1;  // продолжить обычный запуск
    }

    protected override void startup () {
        base.startup ();

        var about = new SimpleAction ("about", null);
        about.activate.connect (show_about);
        add_action (about);

        // Выход: окна закрываются, затем shutdown () делает выгрузку
        var quit_action = new SimpleAction ("quit", null);
        quit_action.activate.connect (() => quit ());
        add_action (quit_action);
        set_accels_for_action ("app.quit", { "<Control>q" });

        var path = Config.DATABASE_PATH;
        try {
            database = new Database (path);
            settings = new Settings (database);
            if (demo_data) {
                add_demo_students ();
            }
        } catch (DatabaseError e) {
            database = null;
            database_error = e.message;
            critical ("База данных %s: %s", path, e.message);
            return;
        }

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
            run_export ();
            uninhibit (cookie);
        });
    }

    protected override void activate () {
        if (database == null) {
            show_database_error ();
            return;
        }
        var first_start = active_window == null;
        var window = active_window ?? new MainWindow (this, database, settings);
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
            run_export ();
        }
        base.shutdown ();
    }

    // Пересобрать файлы учебных лет с новыми записями (и with_school_year в любом случае)
    // и сообщить об этом. Ничего не изменилось — ничего не пишем и не сообщаем.
    private void run_export (int with_school_year = 0) {
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
        foreach (var file in files) {
            names += display_path (file);
        }
        send_desktop_notification (files.length == 1 ? "Excel-файл сохранён" : "Excel-файлы сохранены",
            string.joinv ("\n", names));
    }

    // Системное уведомление GNOME. Через org.freedesktop.Notifications напрямую:
    // GLib.Notification в GNOME работает только для приложений
    // с установленным .desktop-файлом.
    private static void send_desktop_notification (string title, string body) {
        try {
            var bus = Bus.get_sync (BusType.SESSION);
            bus.call_sync (
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "Notify",
                new Variant.tuple ({
                    new Variant.string ("Столовая"),  // имя приложения
                    new Variant.uint32 (0),            // id заменяемого уведомления
                    new Variant.string ("x-office-spreadsheet"),
                    new Variant.string (title),
                    new Variant.string (body),
                    new Variant.array (VariantType.STRING, {}),        // кнопки
                    new Variant.array (new VariantType ("{sv}"), {}),  // подсказки
                    new Variant.int32 (-1)             // время показа по умолчанию
                }),
                null, DBusCallFlags.NONE, 2000);
        } catch (Error e) {
            warning ("Уведомление не отправлено: %s", e.message);
        }
    }

    // /home/user/Документы/Столовая/x.xlsx → Документы/Столовая/x.xlsx
    private static string display_path (string path) {
        var home = Environment.get_home_dir () + "/";
        return path.has_prefix (home) ? path.substring (home.length) : path;
    }

    // Без базы работать нельзя: сообщаем об ошибке и выходим
    private void show_database_error () {
        var window = new Adw.ApplicationWindow (this) {
            title = "Столовая",
            default_width = 400,
            default_height = 200
        };
        window.present ();

        var dialog = new Adw.AlertDialog ("Не удалось открыть базу данных", database_error);
        dialog.add_response ("close", "Закрыть");
        dialog.response.connect (() => quit ());
        dialog.present (window);
    }

    private void add_demo_students () throws DatabaseError {
        string[,] students = {
            { "Иванов Иван Иванович", "5А" },
            { "Петрова Мария Сергеевна", "5А" },
            { "Сидоров Алексей Петрович", "6Б" }
        };
        for (int i = 0; i < students.length[0]; i++) {
            int64 card = i + 1;
            if (database.find_student_by_card (card) == null) {
                database.add_student (students[i, 0], students[i, 1], card);
            }
        }
    }

    private void show_about () {
        var dialog = new Adw.AboutDialog () {
            application_name = "Столовая",
            application_icon = "auth-smartcard-symbolic",
            version = "0.1.0",
            comments = "Учёт питания по NFC-карточкам"
        };
        dialog.present (active_window);
    }

    public static int main (string[] args) {
        return new HelloApp ().run (args);
    }
}
