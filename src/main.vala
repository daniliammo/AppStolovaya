// Учёт питания в столовой по NFC-карточкам.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class HelloApp : Adw.Application {
    private Database? database;
    private string? database_error;
    private bool demo_data = false;

    public HelloApp () {
        Object (
            application_id: "org.example.Test",
            flags: ApplicationFlags.DEFAULT_FLAGS
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

        var path = Config.DATABASE_PATH;
        try {
            database = new Database (path);
            if (demo_data) {
                add_demo_students ();
            }
        } catch (DatabaseError e) {
            database = null;
            database_error = e.message;
            critical ("База данных %s: %s", path, e.message);
        }
    }

    protected override void activate () {
        if (database == null) {
            show_database_error ();
            return;
        }
        var window = active_window ?? new MainWindow (this, database);
        window.present ();
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
