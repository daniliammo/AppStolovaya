// Окно истории: кто и когда получил питание в любой прошедший день.
// Разметка — в history_dialog_ui.vala (HistoryDialogUi).

// В GTK 4.20 select_day () устарела, а в привязках Vala 0.56 замены ещё нет.
// В GTK 4.18 (например, Debian 13) set_date () ещё нет.
#if GTK_4_20
[CCode (cname = "gtk_calendar_set_date")]
extern void calendar_set_date (Gtk.Calendar calendar, DateTime date);
#endif

public class HistoryDialog : HistoryDialogUi {
    private Database database;
    private DateTime day;          // показываемый день (полночь)
    private GenericArray<string> meal_days;  // дни с выдачей — отметки в календаре
    private bool updating = false; // календарь меняем сами — не реагировать
    private string day_totals = "";  // итоги дня без учёта поиска

    public signal void database_failed (DatabaseError e);

    public HistoryDialog (Database database) throws DatabaseError {
        this.database = database;
        list.set_filter_func (matches_search);
        meal_days = database.meal_days ();
        show_day (today ());
    }

    private static DateTime today () {
        var now = new DateTime.now_local ();
        return new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
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
        var is_today = day.compare (today ()) >= 0;
        next_button.sensitive = !is_today;  // в будущее не листаем
        today_button.sensitive = !is_today;

        var label = day.format ("%A, %e %B %Y");
        date_button.label = label.get_char (0).totitle ().to_string () + label.substring (label.index_of_nth_char (1));

        updating = true;
#if GTK_4_20
        calendar_set_date (calendar, day);
#else
        calendar.select_day (day);
#endif
        updating = false;
        mark_calendar ();

        var child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }

        var records = database.day_records (day);
        var counts = database.count_meals (day);
        foreach (var record in records) {
            list.append (build_record_row (record));
        }
        day_totals = @"Учеников: $(records.length) · завтраков: $(counts.breakfasts) · обедов: $(counts.lunches)";
        stack.visible_child_name = records.length > 0 ? "list" : "empty";
        update_totals ();
    }

    // Итоги дня, а при поиске — ещё сколько найдено
    private void update_totals () {
        if (search_entry.text.strip () == "") {
            totals_label.label = day_totals;
            return;
        }
        uint found = 0;
        for (var row = list.get_first_child (); row != null; row = row.get_next_sibling ()) {
            if (matches_search ((Gtk.ListBoxRow) row)) {
                found++;
            }
        }
        totals_label.label = @"$day_totals · найдено: $found";
    }

    // Отметить в календаре дни показанного месяца, когда была выдача
    private void mark_calendar () {
        calendar.clear_marks ();
        var prefix = "%04d-%02d-".printf (calendar.year, calendar.month + 1);
        foreach (var date in meal_days) {
            if (date.has_prefix (prefix)) {
                calendar.mark_day (int.parse (date.substring (8)));
            }
        }
    }

    // Поиск без учёта регистра по ФИО и группе
    private bool matches_search (Gtk.ListBoxRow row) {
        var query = search_entry.text.strip ().casefold ();
        if (query == "") {
            return true;
        }
        var record_row = (Adw.ActionRow) row;
        var text = @"$(record_row.title) $(record_row.subtitle)".casefold ();
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
