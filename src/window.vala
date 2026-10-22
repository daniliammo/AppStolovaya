// Главное окно: ожидание карточки, карточка ученика, результат выдачи,
// счётчики и Последние считывания за сегодня.
// Разметка — в main_window_ui.vala (MainWindowUi),
// здесь только логика: обновление виджетов и обработчики сигналов.

public class MainWindow : MainWindowUi {
    // Сколько секунд показывать результат и сколько ждать на странице ученика
    private const uint RESULT_SECONDS = 10;
    private const uint STUDENT_SECONDS = 15;
    private const int RECENT_COUNT = 10;

    private Database database;
    private Settings settings;
    private CardReader reader;
    private string today = "";  // 'YYYY-MM-DD', чтобы заметить смену дня
    private MealType? current_meal = null;  // приём пищи по времени, чтобы заметить смену
    private int64 data_version = -1;  // чтобы заметить правку базы другой программой

    // Страница ученика: кто подошёл и какие кнопки что списывают
    private Student? student = null;
    private MealType primary_meal;
    private MealType? secondary_meal = null;
    private uint return_timeout = 0;  // таймер возврата к ожиданию
    private uint32 card_notification = 0;  // id уведомления о карточке, чтобы заменять его

    // База занята другой программой: проверка, отпустила ли она базу, и уведомление
    private uint busy_check = 0;
    private uint32 busy_notification = 0;
    // Уведомление «Сканер отключён» — когда окно не активно и сканер пропал
    private ReaderState reader_state = ReaderState.CONNECTED;
    private uint32 reader_notification = 0;

    // Одна строка списка «Последние считывания»: выдача или неизвестная карточка
    private class Issue {
        public string time;  // 'HH:MM:SS'
        public DayRecord? record;  // кто получил; null — карточки нет в базе
        public MealType type;
        public UnknownCard? card;  // неизвестная карточка (когда record — null)
    }

    // Приложили карточку (настоящую или в тестовом режиме)
    public signal void card_presented (CardRead card);

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

        card_presented.connect ((card) => show_student (card));
        reader.card_read.connect ((card) => card_presented (card));
        reader.notify["state"].connect (update_reader_status);
        reader_state = reader.state;  // без уведомления при запуске: окно ещё не показано
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
                idle_title.label = "Сканер подключен и готов к чтению карточек";
                idle_hint.label = "Все готово. Карточки будут читаться";
                break;

            case ReaderState.NO_ACCESS:
                icon = "dialog-warning-symbolic";
                text = "Сканер подключён, но нет доступа к нему";
                css = "warning";
                idle_title.label = "Сканер подключен но требуется настройка";
                idle_hint.label = "Нажмите настроить";
                break;

            case ReaderState.UNAVAILABLE:
                icon = "dialog-warning-symbolic";
                text = reader.open_error == Posix.EBUSY
                    ? "Сканер подключён, но занят другой программой"
                    : "Сканер подключён, но не открывается: %s".printf (strerror (reader.open_error));
                css = "warning";
                idle_title.label = "Сканер подключен но не открывается";
                idle_hint.label = "Закройте другие программы, работающие со сканером, или нажмите настроить";
                break;

            default: // не подключён
                icon = "dialog-error-symbolic";
                text = "Сканер не подключён";
                css = "error";
                idle_title.label = "Подключите сканер";
                idle_hint.label = "";
                break;
        }
        reader_icon.icon_name = icon;
        reader_icon.tooltip_text = text;
        reader_icon.add_css_class (css);

        reader_banner.title = text;
        reader_banner.revealed = reader.state != ReaderState.CONNECTED;
        notify_reader_lost ();
    }

    // Сканер отключили, а окно свёрнуто или под другим — карточки не читаются,
    // а полосы не видно. Подключили снова — уведомление убрать.
    private void notify_reader_lost () {
        var was = reader_state;
        reader_state = reader.state;
        if (reader_state == ReaderState.CONNECTED) {
            App.close_desktop_notification (reader_notification);
            reader_notification = 0;
        } else if (was == ReaderState.CONNECTED && !is_active) {
            reader_notification = App.send_desktop_notification ("Сканер отключён",
                "Карточки не читаются. Подключите сканер заново.",
                "dialog-error-symbolic", reader_notification);
        }
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
    private void show_student (CardRead card, MealType? forced = null) {
        var now = new DateTime.now_local ();
        Student? found;
        DayRecord day;
        try {
            found = database.find_student_by_card (card.uid);
            if (found == null) {
                show_unknown (card, now);
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
        notify_if_inactive ("auth-smartcard-symbolic", found.full_name,
            "%s · %s — в окне программы".printf (found.group_name, primary_button.label.down ()));
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

    // Карточки нет в базе: запоминаем прикладывание для «Последних выдач».
    // Если записать не удалось, предупреждение о карточке всё равно показываем.
    private void show_unknown (CardRead card, DateTime now) {
        try {
            database.record_unknown_card (new UnknownCard () {
                raw = card.raw,
                card_type = card.card_type,
                code = card.code,
                series = card.series,
                number = card.number
            }, now);
            update_counts ();
        } catch (DatabaseError e) {
            show_database_error (e);
        }
        show_result ("status-unknown", "dialog-question-symbolic",
            "Карточка не зарегистрирована", @"Номер $(card.uid) · обратитесь к администратору");
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
        notify_if_inactive (icon, title, subtitle);
    }

    // Карточку приложили, а окно свёрнуто или под другими окнами —
    // сообщаем системным уведомлением. Новое заменяет прежнее.
    private void notify_if_inactive (string icon, string title, string body) {
        if (!is_active) {
            card_notification = App.send_desktop_notification (title, body, icon, card_notification);
        }
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
        dialog.changed.connect (update_counts);
        dialog.present (this);
    }

    // --- Счётчики и Последние считывания ---

    // Счётчики и Последние считывания за сегодня. Вызывать после списания,
    // при смене дня и при смене приёма пищи.
    public void update_counts () {
        var now = new DateTime.now_local ();
        var meal = settings.meal_at (now);
        try {
            var counts = database.count_meals (now);
            breakfast_count.label = counts.breakfasts.to_string ();
            lunch_count.label = counts.lunches.to_string ();

            // Без плашки «Осталось» завтраки и обеды растягиваются на всю ширину
            remaining_tile.visible = settings.show_remaining;
            breakfast_tile.hexpand = !settings.show_remaining;
            lunch_tile.hexpand = !settings.show_remaining;
            if (settings.show_remaining) {
                update_remaining (meal, counts);
            }

            update_recent (database.day_records (now), database.unknown_cards (now));
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

    // Сколько учеников с карточками ещё не получили текущий приём пищи
    private void update_remaining (MealType meal, MealCounts counts) throws DatabaseError {
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
    }

    // Последние считывания из записей дня: каждый завтрак и обед отдельно,
    // вперемешку с неизвестными карточками, новые сверху
    private void update_recent (GenericArray<DayRecord> records, GenericArray<UnknownCard> unknown) {
        var issues = new GenericArray<Issue> ();
        foreach (var record in records) {
            if (record.breakfast_at != null) {
                issues.add (new Issue () { time = record.breakfast_at, record = record, type = MealType.BREAKFAST });
            }
            if (record.lunch_at != null) {
                issues.add (new Issue () { time = record.lunch_at, record = record, type = MealType.LUNCH });
            }
        }
        foreach (var card in unknown) {
            issues.add (new Issue () { time = card.scanned_at, record = null, card = card });
        }
        issues.sort ((a, b) => strcmp (b.time, a.time));

        // remove_all () убрал бы и заглушку «Сегодня ещё не прикладывались карточки»
        Gtk.ListBoxRow? old;
        while ((old = recent_list.get_row_at_index (0)) != null) {
            recent_list.remove (old);
        }
        for (int i = 0; i < issues.length && i < RECENT_COUNT; i++) {
            var item = issues[i];
            var row = new Adw.ActionRow () {
                activatable = false,
                can_focus = false
            };
            if (item.record != null) {
                // ФИО и группу могли поменять после выдачи — тогда видно и прежние
                var record = item.record;
                row.title = Styles.changed_markup (record.issued_name, record.student.full_name);
                row.subtitle = "%s · %s".printf (meal_name (item.type),
                    Styles.changed_markup (record.issued_group, record.student.group_name));
                row.tooltip_text = record.change_note ();
                row.add_prefix (new Adw.Avatar (32, record.student.full_name, true));
            } else {
                row.title = "Неизвестная карточка";
                row.subtitle = "%s · номер %s".printf (Markup.escape_text (item.card.card_type), item.card.uid.to_string ());
                var icon = new Gtk.Image.from_icon_name ("dialog-question-symbolic") {
                    pixel_size = 32
                };
                icon.add_css_class ("warning");
                row.add_prefix (icon);
            }
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
        if (e is DatabaseError.BUSY) {
            show_database_busy ();
        } else {
            show_toast ("Ошибка базы данных: " + e.message);
        }
    }

    // Базу держит другая программа (DB Browser с незаписанными изменениями):
    // полоса видна, пока та не отпустит базу. Окно «Столовой», скорее всего,
    // под этой программой — тогда ещё и уведомление, при каждой неудаче:
    // каждая — незаписанная выдача.
    private void show_database_busy () {
        database_banner.revealed = true;
        if (!is_active) {
            busy_notification = App.send_desktop_notification ("База занята другой программой",
                "Выдачи не записываются. Запишите или отмените изменения в программе, где открыта база.",
                "dialog-warning-symbolic", busy_notification);
        }
        if (busy_check != 0) {
            return;
        }
        busy_check = Timeout.add_seconds (2, () => {
            if (database.write_locked ()) {
                return Source.CONTINUE;
            }
            busy_check = 0;
            database_banner.revealed = false;
            App.close_desktop_notification (busy_notification);
            busy_notification = 0;
            return Source.REMOVE;
        });
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
        // Базу поправили другой программой (переименовали ученика в DB Browser,
        // добавили учеников) — «Последние считывания» и «Осталось» пересчитать
        int64 version = data_version;
        try {
            version = database.data_version ();
        } catch (DatabaseError e) {
            // Не страшно: пересчитаем при следующей выдаче
        }
        var day = Database.format_date (now);
        if (day != today || current_meal == null || (MealType) current_meal != meal || version != data_version) {
            today = day;
            current_meal = meal;
            data_version = version;
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
        if (!text.get_char (0).isdigit () || !int64.try_parse (text, out uid, null, 10) || uid > MAX_UID) {
            show_toast ("Номер карточки — целое число от 0 до %d".printf (MAX_UID));
            return;
        }
        card_entry.text = "";
        simulate_card (uid);
    }

    // Наибольший номер, который даёт считыватель: серия 255, номер 65535
    private const int MAX_UID = 255 * 65536 + 65535;

    // Тестовый режим: приём пищи можно выбрать, не дожидаясь нужного времени.
    // Карточка — как от считывателя, но с типом «Тест».
    private void simulate_card (int64 uid) {
        var card = new CardRead () {
            raw = "",
            card_type = "Тест",
            code = "",
            series = (int) (uid / 65536),
            number = (int) (uid % 65536)
        };
        switch (meal_choice.selected) {
        case 1:
            show_student (card, MealType.BREAKFAST);
            break;
        case 2:
            show_student (card, MealType.LUNCH);
            break;
        default:
            show_student (card);
            break;
        }
    }
#endif
}
