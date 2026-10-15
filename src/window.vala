// Главное окно: ожидание карточки и счётчики выдачи за сегодня.
// Разметка — в main_window_ui.vala (MainWindowUi),
// здесь только логика: обновление виджетов и обработчики сигналов.

public class MainWindow : MainWindowUi {
    private Database database;
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить смену дня

    // Приложили карточку (настоящую или в тестовом режиме)
    public signal void card_presented (int64 uid);

    public MainWindow (Adw.Application app, Database database) {
        Object (application: app);
        this.database = database;

        update_clock ();
        Timeout.add_seconds (1, () => {
            update_clock ();
            return Source.CONTINUE;
        });

        card_presented.connect (show_student);
    }

    // Пока нет окна ученика, показываем ученика и его отметки уведомлением
    private void show_student (int64 uid) {
        try {
            var student = database.find_student_by_card (uid);
            if (student == null) {
                show_toast (@"Карточка $uid не зарегистрирована");
                return;
            }
            var day = database.student_day (student, new DateTime.now_local ());
            show_toast ("%s, %s · завтрак: %s · обед: %s".printf (
                student.full_name, student.group_name,
                short_time (day.breakfast_at), short_time (day.lunch_at)));
        } catch (DatabaseError e) {
            show_database_error (e);
        }
    }

    // Счётчики за сегодня. Вызывать после списания и при смене дня.
    public void update_counts () {
        try {
            var counts = database.count_meals (new DateTime.now_local ());
            breakfast_count.label = counts.breakfasts.to_string ();
            lunch_count.label = counts.lunches.to_string ();
        } catch (DatabaseError e) {
            show_database_error (e);
        }
    }

    public void show_toast (string text) {
        toast_overlay.add_toast (new Adw.Toast (text));
    }

    private void show_database_error (DatabaseError e) {
        critical ("База данных: %s", e.message);
        show_toast ("Ошибка базы данных: " + e.message);
    }

    // 'HH:MM:SS' → 'HH:MM', нет отметки → «—»
    private static string short_time (string? time) {
        return time == null ? "—" : time.substring (0, 5);
    }

    private void update_clock () {
        var now = new DateTime.now_local ();
        window_title.subtitle = now.format ("%A, %e %B · %H:%M");

        // В полночь счётчики обнуляются: за новый день выдачи ещё не было
        var day = Database.format_date (now);
        if (day != today) {
            today = day;
            update_counts ();
        }
    }

    protected override void on_simulate_card () {
        // try_parse пропускает пустую строку (как 0) и знак минус, поэтому
        // сначала проверяем, что первым символом идёт цифра
        var text = card_entry.text.strip ();
        int64 uid = 0;
        if (!text.get_char (0).isdigit () || !int64.try_parse (text, out uid, null, 10)) {
            show_toast ("Номер карточки — целое число от 0 до %s".printf (int64.MAX.to_string ()));
            return;
        }
        card_entry.text = "";
        card_presented (uid);
    }
}
