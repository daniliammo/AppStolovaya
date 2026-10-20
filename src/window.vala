// Главное окно: ожидание карточки и счётчики выдачи за сегодня.
// Разметка — в main_window_ui.vala (MainWindowUi),
// здесь только логика: обновление виджетов и обработчики сигналов.

public class MainWindow : MainWindowUi {
    private Database database;
    private Settings settings;
    private CardReader reader;
    private StudentDialog? student_dialog;  // открытое окно ученика
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить смену дня

    // Приложили карточку (настоящую или в тестовом режиме)
    public signal void card_presented (int64 uid);

    public MainWindow (Adw.Application app, Database database, Settings settings, CardReader reader) {
        Object (application: app);
        this.database = database;
        this.settings = settings;
        this.reader = reader;

        update_clock ();
        Timeout.add_seconds (1, () => {
            update_clock ();
            return Source.CONTINUE;
        });

        card_presented.connect ((uid) => show_student (uid));
        reader.card_read.connect ((card) => card_presented (card.uid));
        reader.notify["state"].connect (update_reader_status);
        update_reader_status ();
    }

    // Зелёная галочка — сканер подключён, красный крестик — нет
    private void update_reader_status () {
        foreach (var css in new string[] { "success", "warning", "error" }) {
            reader_icon.remove_css_class (css);
            reader_label.remove_css_class (css);
        }

        string icon, text, css;
        switch (reader.state) {
            case ReaderState.CONNECTED:
                App.send_desktop_notification ("Сканер подключен", "Все работает.");
                icon = "object-select-symbolic";
                text = "Сканер подключён";
                css = "success";
                break;
            case ReaderState.NO_ACCESS:
                icon = "dialog-warning-symbolic";
                text = "Сканер подключён, но нет доступа: Настройки → «Настроить»";
                css = "warning";
                break;
            default:
                App.send_desktop_notification ("Сканер отключён", "Подключите сканер заново.");
                icon = "window-close-symbolic";
                text = "Сканер не подключён";
                css = "error";
                break;
        }
        reader_icon.icon_name = icon;
        reader_label.label = text;
        reader_icon.add_css_class (css);
        reader_label.add_css_class (css);
    }

    // Окно ученика. forced — приём пищи, выбранный в тестовом режиме;
    // null — по настройкам: по времени или обе кнопки.
    private void show_student (int64 uid, MealType? forced = null) {
        Student? student;
        StudentDialog dialog;
        try {
            student = database.find_student_by_card (uid);
            if (student == null) {
                show_toast (@"Карточка $uid не зарегистрирована");
                return;
            }

            MealType? only = forced;
            var hint = "";
            if (forced != null) {
                hint = "Выбрано в тестовом режиме";
            } else if (settings.auto_meal) {
                only = settings.meal_at (new DateTime.now_local ());
                hint = "Определено по времени: обед с %02d:%02d".printf (settings.lunch_from / 60, settings.lunch_from % 60);
            }
            dialog = new StudentDialog (database, student, only, hint);
        } catch (DatabaseError e) {
            show_database_error (e);
            return;
        }

        // Приложили следующую карточку — предыдущее окно закрывается
        student_dialog?.close ();
        student_dialog = dialog;

        dialog.meal_recorded.connect ((type) => {
            update_counts ();
            show_toast ("%s: %s".printf (type == MealType.BREAKFAST ? "Завтрак" : "Обед", student.full_name));
        });
        dialog.database_failed.connect (show_database_error);
        dialog.closed.connect (on_student_dialog_closed);
        dialog.present (this);
    }

    // Отправитель приходит параметром: лямбда с dialog внутри создала бы
    // цикл ссылок «окно → обработчик → окно», и окно никогда не освобождалось бы
    private void on_student_dialog_closed (Adw.Dialog dialog) {
        if (student_dialog == dialog) {
            student_dialog = null;
        }
    }

    public void show_history () {
        HistoryDialog dialog;
        try {
            dialog = new HistoryDialog (database);
        } catch (DatabaseError e) {
            show_database_error (e);
            return;
        }
        dialog.database_failed.connect (show_database_error);
        dialog.present (this);
    }

    public void show_settings () {
        var dialog = new SettingsDialog (settings);
        dialog.database_failed.connect (show_database_error);
        dialog.present (this);
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

#if DEBUG
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

        // Тестовый режим: приём пищи можно выбрать, не дожидаясь нужного времени
        switch (meal_choice.selected) {
        case 1:
            show_student (uid, MealType.BREAKFAST);
            break;
        case 2:
            show_student (uid, MealType.LUNCH);
            break;
        default:
            show_student (uid);
            break;
        }
    }
#endif
}
