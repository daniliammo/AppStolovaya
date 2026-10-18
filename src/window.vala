// Главное окно: ожидание карточки, карточка ученика, результат выдачи,
// счётчики и последние выдачи за сегодня.
// Разметка — в main_window_ui.vala (MainWindowUi),
// здесь только логика: обновление виджетов и обработчики сигналов.

public class MainWindow : MainWindowUi {
    // Сколько секунд показывать результат и сколько ждать на странице ученика
    private const uint RESULT_SECONDS = 5;
    private const uint STUDENT_SECONDS = 15;
    private const int RECENT_COUNT = 5;

    private Database database;
    private Settings settings;
    private CardReader reader;
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить смену дня
    private MealType? current_meal = null;  // приём пищи по времени, чтобы заметить смену

    // Страница ученика: кто подошёл и какие кнопки что списывают
    private Student? student = null;
    private MealType primary_meal;
    private MealType? secondary_meal = null;
    private uint return_timeout = 0;  // таймер возврата к ожиданию

    // Одна выдача для списка «Последние выдачи»
    private class Issue {
        public string time;  // 'HH:MM:SS'
        public Student student;
        public MealType type;
    }

    // Приложили карточку (настоящую или в тестовом режиме)
    public signal void card_presented (int64 uid);

    public MainWindow (Adw.Application app, Database database, Settings settings, CardReader reader) {
        Object (application: app);
        this.database = database;
        this.settings = settings;
        this.reader = reader;

        setup_actions (app);
        setup_dark_button ();

        update_clock ();
        Timeout.add_seconds (1, () => {
            update_clock ();
            return Source.CONTINUE;
        });

        card_presented.connect ((uid) => show_student (uid));
        reader.card_read.connect ((card) => card_presented (card.uid));
        reader.notify["state"].connect (update_reader_status);
        update_reader_status ();
        show_idle ();
    }

    // F11 — во весь экран; в тестовом режиме Ctrl+1/2/3 — тестовые карточки 1, 2, 3
    private void setup_actions (Adw.Application app) {
        var fullscreen_action = new SimpleAction ("fullscreen", null);
        fullscreen_action.activate.connect (() => {
            if (fullscreened) {
                unfullscreen ();
            } else {
                fullscreen ();
            }
        });
        add_action (fullscreen_action);
        app.set_accels_for_action ("win.fullscreen", { "F11" });

#if DEBUG
        var test_card = new SimpleAction ("test-card", VariantType.INT32);
        test_card.activate.connect ((parameter) => simulate_card (parameter.get_int32 ()));
        add_action (test_card);
        for (int i = 1; i <= 3; i++) {
            app.set_accels_for_action ("win.test-card(%d)".printf (i), { "<Control>%d".printf (i) });
        }
#endif
    }

    // Кнопка тёмной темы. Пока её не трогали, программа следует системной теме.
    private void setup_dark_button () {
        var style_manager = Adw.StyleManager.get_default ();
        dark_button.active = style_manager.dark;
        dark_button.toggled.connect (() => {
            style_manager.color_scheme = dark_button.active
                ? Adw.ColorScheme.FORCE_DARK
                : Adw.ColorScheme.FORCE_LIGHT;
        });
    }

    // Зелёная точка — сканер подключён. Не работает — значок и полоса
    // с кнопкой «Настроить» (открывает настройки).
    private void update_reader_status () {
        foreach (var css in new string[] { "success", "warning", "error" }) {
            reader_icon.remove_css_class (css);
        }

        string icon, text, css;
        switch (reader.state) {
        case ReaderState.CONNECTED:
            icon = "media-record-symbolic";
            text = "Сканер подключён";
            css = "success";
            break;
        case ReaderState.NO_ACCESS:
            icon = "dialog-warning-symbolic";
            text = "Сканер подключён, но нет доступа к нему";
            css = "warning";
            break;
        default:
            icon = "dialog-error-symbolic";
            text = "Сканер не подключён";
            css = "error";
            break;
        }
        reader_icon.icon_name = icon;
        reader_icon.tooltip_text = text;
        reader_icon.add_css_class (css);

        reader_banner.title = text;
        reader_banner.revealed = reader.state != ReaderState.CONNECTED;
    }

    // --- Карточка состояния ---

    private void show_idle () {
        cancel_return ();
        student = null;
        set_status_class (null);
        stack.visible_child_name = PAGE_IDLE;
#if DEBUG
        card_entry.grab_focus ();
#endif
    }

    // Страница ученика. forced — приём пищи, выбранный в тестовом режиме;
    // null — по настройкам: по времени или обе кнопки.
    private void show_student (int64 uid, MealType? forced = null) {
        var now = new DateTime.now_local ();
        Student? found;
        DayRecord day;
        try {
            found = database.find_student_by_card (uid);
            if (found == null) {
                show_result ("status-unknown", "dialog-question-symbolic",
                    "Карточка не зарегистрирована", @"Номер $uid · обратитесь к администратору");
                return;
            }
            day = database.student_day (found, now);
        } catch (DatabaseError e) {
            show_database_error (e);
            return;
        }

        // Какие приёмы пищи можно списать: один (по времени или выбранный) или оба
        MealType? only = forced;
        var hint = "";
        if (forced != null) {
            hint = "Выбрано в тестовом режиме";
        } else if (settings.auto_meal) {
            only = settings.meal_at (now);
            hint = "Определено по времени: обед с %02d:%02d".printf (settings.lunch_from / 60, settings.lunch_from % 60);
        }
        MealType main = only != null ? (MealType) only : settings.meal_at (now);
        MealType? other = only == null ? (MealType?) other_meal (main) : null;

        var main_at = received_at (day, main);
        var other_at = other != null ? received_at (day, (MealType) other) : null;

        // Всё, что можно, уже получено — сразу красный экран
        if (main_at != null && (other == null || other_at != null)) {
            show_already (found, main, main_at);
            return;
        }

        student = found;
        // Основной уже получен, а другой ещё нет — большой кнопкой выдаём другой
        if (main_at != null) {
            primary_meal = (MealType) other;
            secondary_meal = main;
        } else {
            primary_meal = main;
            secondary_meal = other;
        }

        student_avatar.text = found.full_name;
        student_name.label = found.full_name;
        student_group.label = found.group_name;
        student_hint.label = hint;
        student_hint.visible = hint != "";

        primary_button.label = "Выдать " + meal_name (primary_meal).down ();
        secondary_button.visible = secondary_meal != null;
        if (secondary_meal != null) {
            var type = (MealType) secondary_meal;
            var at = received_at (day, type);
            secondary_button.sensitive = at == null;
            secondary_button.label = at == null
                ? "Выдать " + meal_name (type).down ()
                : "%s уже получен в %s".printf (meal_name (type), at.substring (0, 5));
        }

        set_status_class (null);
        stack.visible_child_name = PAGE_STUDENT;
        primary_button.grab_focus ();  // Enter выдаёт основной приём пищи
        schedule_return (STUDENT_SECONDS);
    }

    protected override void on_primary_clicked () {
        issue (primary_meal);
    }

    protected override void on_secondary_clicked () {
        if (secondary_meal != null) {
            issue ((MealType) secondary_meal);
        }
    }

    protected override void on_cancel_clicked () {
        show_idle ();
    }

    // Списать приём пищи ученику со страницы ученика
    private void issue (MealType type) {
        if (student == null) {
            return;
        }
        var who = student;
        var now = new DateTime.now_local ();
        try {
            if (database.record_meal (who.id, type, now)) {
                update_counts ();
                show_result ("status-ok", "object-select-symbolic",
                    "%s выдан, %s".printf (meal_name (type), now.format ("%H:%M")),
                    "%s · %s".printf (who.full_name, who.group_name));
            } else {
                // Успели списать раньше (двойное нажатие или второй считыватель)
                var at = received_at (database.student_day (who, now), type);
                show_already (who, type, at ?? now.format ("%H:%M:%S"));
            }
        } catch (DatabaseError e) {
            show_database_error (e);
            show_idle ();
        }
    }

    private void show_already (Student who, MealType type, string at) {
        show_result ("status-again", "dialog-error-symbolic",
            "%s уже получен в %s".printf (meal_name (type), at.substring (0, 5)),
            "%s · %s".printf (who.full_name, who.group_name));
    }

    // Цветной результат на всю карточку; через несколько секунд — снова ожидание
    private void show_result (string css, string icon, string title, string subtitle) {
        student = null;
        result_icon.icon_name = icon;
        result_title.label = title;
        result_subtitle.label = subtitle;
        set_status_class (css);
        stack.visible_child_name = PAGE_RESULT;
        schedule_return (RESULT_SECONDS);
    }

    private void set_status_class (string? css) {
        foreach (var name in new string[] { "status-ok", "status-again", "status-unknown" }) {
            status_card.remove_css_class (name);
        }
        if (css != null) {
            status_card.add_css_class (css);
        }
    }

    // Новая карточка или кнопка отменяют прежний таймер
    private void schedule_return (uint seconds) {
        cancel_return ();
        return_timeout = Timeout.add_seconds (seconds, () => {
            return_timeout = 0;
            show_idle ();
            return Source.REMOVE;
        });
    }

    private void cancel_return () {
        if (return_timeout != 0) {
            Source.remove (return_timeout);
            return_timeout = 0;
        }
    }

    // --- Диалоги ---

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

    // --- Счётчики и последние выдачи ---

    // Счётчики и последние выдачи за сегодня. Вызывать после списания,
    // при смене дня и при смене приёма пищи.
    public void update_counts () {
        var now = new DateTime.now_local ();
        var meal = settings.meal_at (now);
        try {
            var counts = database.count_meals (now);
            breakfast_count.label = counts.breakfasts.to_string ();
            lunch_count.label = counts.lunches.to_string ();

            // Сколько учеников с карточками ещё не получили текущий приём пищи
            int total = 0;
            var students = database.list_students ();
            foreach (var s in students) {
                if (s.card_uid != null) {
                    total++;
                }
            }
            var issued = meal == MealType.BREAKFAST ? counts.breakfasts : counts.lunches;
            remaining_caption.label = meal == MealType.BREAKFAST ? "Осталось на завтрак" : "Осталось на обед";
            remaining_label.label = "%d из %d".printf (int.max (total - issued, 0), total);
            remaining_progress.fraction = total > 0 ? double.min ((double) issued / total, 1.0) : 0.0;

            update_recent (database.day_records (now));
        } catch (DatabaseError e) {
            show_database_error (e);
        }

        // Подсветить плашку текущего приёма пищи
        if (meal == MealType.BREAKFAST) {
            breakfast_tile.add_css_class ("current");
            lunch_tile.remove_css_class ("current");
        } else {
            lunch_tile.add_css_class ("current");
            breakfast_tile.remove_css_class ("current");
        }
    }

    // Последние выдачи из записей дня: каждый завтрак и обед отдельно, новые сверху
    private void update_recent (GenericArray<DayRecord> records) {
        var issues = new GenericArray<Issue> ();
        foreach (var record in records) {
            if (record.breakfast_at != null) {
                issues.add (new Issue () { time = record.breakfast_at, student = record.student, type = MealType.BREAKFAST });
            }
            if (record.lunch_at != null) {
                issues.add (new Issue () { time = record.lunch_at, student = record.student, type = MealType.LUNCH });
            }
        }
        issues.sort ((a, b) => strcmp (b.time, a.time));

        // remove_all () убрал бы и заглушку «Сегодня ещё никто не получал»
        Gtk.ListBoxRow? old;
        while ((old = recent_list.get_row_at_index (0)) != null) {
            recent_list.remove (old);
        }
        for (int i = 0; i < issues.length && i < RECENT_COUNT; i++) {
            var item = issues[i];
            var row = new Adw.ActionRow () {
                title = Markup.escape_text (item.student.full_name),
                subtitle = "%s · %s".printf (meal_name (item.type), Markup.escape_text (item.student.group_name)),
                activatable = false,
                can_focus = false
            };
            row.add_prefix (new Adw.Avatar (32, item.student.full_name, true));
            var time = new Gtk.Label (item.time.substring (0, 5));
            time.add_css_class ("numeric");
            time.add_css_class ("dim-label");
            row.add_suffix (time);
            recent_list.append (row);
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
        window_title.subtitle = now.format ("%A, %e %B");
        clock_label.label = now.format ("%H:%M");

        var meal = settings.meal_at (now);
        var lunch_from = "%02d:%02d".printf (settings.lunch_from / 60, settings.lunch_from % 60);
        meal_period_label.label = meal == MealType.BREAKFAST
            ? @"Сейчас: ЗАВТРАК (до $lunch_from)"
            : @"Сейчас: ОБЕД (с $lunch_from)";

        // В полночь счётчики обнуляются: за новый день выдачи ещё не было.
        // С началом обеда «Осталось» считается уже по обедам.
        var day = Database.format_date (now);
        if (day != today || current_meal == null || (MealType) current_meal != meal) {
            today = day;
            current_meal = meal;
            update_counts ();
        }
    }

    // --- Вспомогательное ---

    private static string meal_name (MealType type) {
        return type == MealType.BREAKFAST ? "Завтрак" : "Обед";
    }

    private static MealType other_meal (MealType type) {
        return type == MealType.BREAKFAST ? MealType.LUNCH : MealType.BREAKFAST;
    }

    private static string? received_at (DayRecord day, MealType type) {
        return type == MealType.BREAKFAST ? day.breakfast_at : day.lunch_at;
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
        simulate_card (uid);
    }

    // Тестовый режим: приём пищи можно выбрать, не дожидаясь нужного времени
    private void simulate_card (int64 uid) {
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
