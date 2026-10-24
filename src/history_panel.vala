// Панель считываний: кто и когда получил питание и какие неизвестные карточки
// прикладывали — за сегодня или за любой прошедший день.
// Разметка — в history_panel_ui.vala (HistoryPanelUi).

// В GTK 4.20 select_day () устарела, а в привязках Vala 0.56 замены ещё нет.
// В GTK 4.18 (например, Debian 13) set_date () ещё нет.
#if GTK_4_20
[CCode (cname = "gtk_calendar_set_date")]
extern void calendar_set_date (Gtk.Calendar calendar, DateTime date);
#endif

public class HistoryPanel : HistoryPanelUi {
    // Задаёт окно после создания панели; пока базы нет, панель пуста
    public Database? database { get; set; }

    private DateTime day;  // показываемый день (полночь)
    private bool updating = false;  // календарь меняем сами — не реагировать
    private string day_totals = "";  // итоги дня без учёта поиска

    // Одна строка списка: выдача или неизвестная карточка
    private class Issue {
        public string time;  // 'HH:MM:SS' — по нему порядок
        public Gtk.Widget row;
    }

    public signal void database_failed (DatabaseError e);

    construct {
        list.set_filter_func (matches_search);
        go_to (today ());
    }

    // Перечитать показанный день — после выдачи, смены дня или правки базы.
    // Сегодня — всегда текущий день: после полуночи панель переходит на новый.
    public void refresh () throws DatabaseError {
        show_day (showing_today () ? today () : day);
    }

    // Вернуться к сегодняшнему дню: приложили карточку — её видно сразу
    public void go_to_today () {
        if (!showing_today ()) {
            go_to (today ());
        }
    }

    private static DateTime today () {
        var now = new DateTime.now_local ();
        return new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
    }

    private bool showing_today () {
        return day.compare (today ()) >= 0;
    }

    // Переход на другой день из интерфейса: ошибку показывает главное окно
    private void go_to (DateTime new_day) {
        try {
            show_day (new_day);
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }

    private void show_day (DateTime new_day) throws DatabaseError {
        day = new_day;
        var is_today = showing_today ();
        next_button.sensitive = !is_today;  // в будущее не листаем
        today_button.sensitive = !is_today;

        // «Сб, 24 окт.», год — если не текущий
        var label = day.format (day.get_year () == today ().get_year () ? "%a, %e %b" : "%a, %e %b %Y");
        date_button.label = label.get_char (0).totitle ().to_string () + label.substring (label.index_of_nth_char (1));

        updating = true;
#if GTK_4_20
        calendar_set_date (calendar, day);
#else
        calendar.select_day (day);
#endif
        updating = false;

        // remove_all () убрал бы и заглушку
        Gtk.ListBoxRow? old;
        while ((old = list.get_row_at_index (0)) != null) {
            list.remove (old);
        }
        if (database == null) {
            return;
        }
        mark_calendar ();

        // Каждый завтрак и обед — отдельной строкой, вперемешку
        // с неизвестными карточками, новые сверху
        var records = database.day_records (day);
        var unknown = database.unknown_cards (day);
        var issues = new GenericArray<Issue> ();
        foreach (var record in records) {
            if (record.breakfast_at != null) {
                issues.add (new Issue () {
                    time = record.breakfast_at, row = build_meal_row (record, "Завтрак", record.breakfast_at)
                });
            }
            if (record.lunch_at != null) {
                issues.add (new Issue () { time = record.lunch_at, row = build_meal_row (record, "Обед", record.lunch_at) });
            }
        }
        foreach (var card in unknown) {
            issues.add (new Issue () { time = card.scanned_at, row = build_unknown_row (card) });
        }
        issues.sort ((a, b) => strcmp (b.time, a.time));
        foreach (var issue in issues) {
            list.append (issue.row);
        }

        var counts = database.count_meals (day);
        day_totals = @"Учеников: $(records.length) · завтраков: $(counts.breakfasts) · обедов: $(counts.lunches)";
        if (unknown.length > 0) {
            day_totals += @" · неизвестных карточек: $(unknown.length)";
        }
        update_totals ();
    }

    // Итоги дня, а при поиске — ещё сколько найдено; и что написать, если пусто
    private void update_totals () {
        if (search_entry.text.strip () == "") {
            totals_label.label = day_totals;
            placeholder.label = showing_today ()
                ? "Сегодня ещё не прикладывались карточки"
                : "В этот день карточки не прикладывались";
            return;
        }
        uint found = 0;
        for (var row = list.get_first_child (); row != null; row = row.get_next_sibling ()) {
            if (row is Gtk.ListBoxRow && matches_search ((Gtk.ListBoxRow) row)) {
                found++;
            }
        }
        totals_label.label = @"$day_totals · найдено: $found";
        placeholder.label = "Ничего не найдено";
    }

    // Отметить в календаре дни показанного месяца, когда была выдача
    private void mark_calendar () {
        calendar.clear_marks ();
        if (database == null) {
            return;
        }
        try {
            var prefix = "%04d-%02d-".printf (calendar.year, calendar.month + 1);
            foreach (var date in database.meal_days ()) {
                if (date.has_prefix (prefix)) {
                    calendar.mark_day (int.parse (date.substring (8)));
                }
            }
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }

    // Поиск без учёта регистра по ФИО, группе, типу и номеру карточки
    private bool matches_search (Gtk.ListBoxRow row) {
        var query = search_entry.text.strip ().casefold ();
        if (query == "") {
            return true;
        }
        var action_row = (Adw.ActionRow) row;
        var text = @"$(action_row.title) $(action_row.subtitle)".casefold ();
        return query in text;
    }

    protected override void on_prev_day () {
        go_to (day.add_days (-1));
    }

    protected override void on_next_day () {
        go_to (day.add_days (1));
    }

    protected override void on_today () {
        go_to (today ());
    }

    protected override void on_calendar_day_selected () {
        if (updating) {
            return;
        }
        var selected = calendar.get_date ();
        var picked = new DateTime.local (selected.get_year (), selected.get_month (), selected.get_day_of_month (), 0, 0, 0);
        date_button.popover.popdown ();
        // Будущие дни показывать незачем: там пусто
        go_to (picked.compare (today ()) > 0 ? today () : picked);
    }

    protected override void on_calendar_month_changed () {
        mark_calendar ();
    }

    protected override void on_search_changed () {
        list.invalidate_filter ();
        update_totals ();
    }
}
