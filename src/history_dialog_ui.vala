// Разметка окна истории: выбор дня, итоги дня и список, кто и когда ел.
// Логика — в history_dialog.vala (класс HistoryDialog наследует HistoryDialogUi).

public abstract class HistoryDialogUi : Adw.Dialog {
    protected Gtk.Button prev_button;
    protected Gtk.Button next_button;
    protected Gtk.Button today_button;
    protected Gtk.MenuButton date_button;
    protected Gtk.Calendar calendar;
    protected Gtk.SearchEntry search_entry;
    protected Gtk.Label totals_label;
    protected Gtk.ListBox list;
    protected Gtk.Stack stack;  // "list" — список, "empty" — выдачи не было

    protected abstract void on_prev_day ();
    protected abstract void on_next_day ();
    protected abstract void on_today ();
    protected abstract void on_calendar_day_selected ();
    protected abstract void on_calendar_month_changed ();
    protected abstract void on_search_changed ();

    construct {
        title = "История";
        content_width = 640;
        content_height = 640;

        var toolbar = new Adw.ToolbarView () {
            content = build_content ()
        };
        toolbar.add_top_bar (build_header_bar ());
        toolbar.add_top_bar (build_search_bar ());
        child = toolbar;
    }

    // В заголовке: «Сегодня» и переключатель дня «‹ дата ›»
    private Adw.HeaderBar build_header_bar () {
        prev_button = new Gtk.Button.from_icon_name ("go-previous-symbolic") {
            tooltip_text = "Предыдущий день"
        };
        prev_button.clicked.connect (on_prev_day);

        next_button = new Gtk.Button.from_icon_name ("go-next-symbolic") {
            tooltip_text = "Следующий день"
        };
        next_button.clicked.connect (on_next_day);

        calendar = new Gtk.Calendar ();
        calendar.day_selected.connect (on_calendar_day_selected);
        calendar.notify["month"].connect (on_calendar_month_changed);
        calendar.notify["year"].connect (on_calendar_month_changed);

        date_button = new Gtk.MenuButton () {
            popover = new Gtk.Popover () { child = calendar },
            tooltip_text = "Выбрать день в календаре",
            always_show_arrow = true
        };

        var switcher = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        switcher.append (prev_button);
        switcher.append (date_button);
        switcher.append (next_button);

        today_button = new Gtk.Button.with_label ("Сегодня");
        today_button.clicked.connect (on_today);

        var header = new Adw.HeaderBar () {
            title_widget = switcher
        };
        header.pack_start (today_button);
        return header;
    }

    private Gtk.Widget build_search_bar () {
        search_entry = new Gtk.SearchEntry () {
            placeholder_text = "Поиск по ФИО или группе",
            hexpand = true
        };
        search_entry.search_changed.connect (on_search_changed);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        box.append (search_entry);
        return box;
    }

    private Gtk.Widget build_content () {
        totals_label = new Gtk.Label (null) {
            xalign = 0,
            margin_bottom = 6
        };
        totals_label.add_css_class ("heading");

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            valign = Gtk.Align.START
        };
        list.add_css_class ("boxed-list");

        var list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            margin_top = 6,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        list_box.append (totals_label);
        list_box.append (list);

        var scrolled = new Gtk.ScrolledWindow () {
            child = new Adw.Clamp () { child = list_box },
            vexpand = true
        };

        var empty = new Adw.StatusPage () {
            icon_name = "x-office-calendar-symbolic",
            title = "Выдачи не было",
            description = "В этот день никто не получал завтрак или обед"
        };

        stack = new Gtk.Stack ();
        stack.add_named (scrolled, "list");
        stack.add_named (empty, "empty");
        return stack;
    }

    // Строка ученика: ФИО, группа и справа время завтрака и обеда.
    // ФИО и группу могли поменять после выдачи — тогда видно и прежние.
    protected static Adw.ActionRow build_record_row (DayRecord record) {
        var row = new Adw.ActionRow () {
            title = Styles.changed_markup (record.issued_name, record.student.full_name),
            subtitle = Styles.changed_markup (record.issued_group, record.student.group_name),
            tooltip_text = record.change_note ()
        };
        row.add_suffix (build_meal_cell ("Завтрак", record.breakfast_at));
        row.add_suffix (build_meal_cell ("Обед", record.lunch_at));
        return row;
    }

    // «Завтрак» мелко, под ним время или «—»
    private static Gtk.Widget build_meal_cell (string name, string? time) {
        var caption = new Gtk.Label (name);
        caption.add_css_class ("caption");
        caption.add_css_class ("dim-label");

        var value = new Gtk.Label (time == null ? "—" : time.substring (0, 5));
        value.add_css_class ("numeric");
        if (time == null) {
            value.add_css_class ("dim-label");
        }

        var cell = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            valign = Gtk.Align.CENTER,
            width_request = 72
        };
        cell.append (caption);
        cell.append (value);
        return cell;
    }
}
