// Разметка панели считываний справа в главном окне: выбор дня, поиск,
// итоги дня и все считывания этого дня, новые сверху.
// Логика — в history_panel.vala (класс HistoryPanel наследует HistoryPanelUi).

public abstract class HistoryPanelUi : Gtk.Box {
    protected Gtk.Button prev_button;
    protected Gtk.Button next_button;
    protected Gtk.Button today_button;
    protected Gtk.MenuButton date_button;
    protected Gtk.Calendar calendar;
    protected Gtk.SearchEntry search_entry;
    protected Gtk.Label totals_label;
    protected Gtk.ListBox list;
    protected Gtk.Label placeholder;  // пустой список: почему пусто

    protected abstract void on_prev_day ();
    protected abstract void on_next_day ();
    protected abstract void on_today ();
    protected abstract void on_calendar_day_selected ();
    protected abstract void on_calendar_month_changed ();
    protected abstract void on_search_changed ();

    construct {
        orientation = Gtk.Orientation.VERTICAL;
        spacing = 12;
        width_request = 340;
        hexpand = false;  // иначе кнопку даты, растянутую внутри, растянуло бы на пол-окна

        var heading = new Gtk.Label ("Считывания");
        heading.add_css_class ("heading");

        search_entry = new Gtk.SearchEntry () {
            placeholder_text = "ФИО, группа или номер карточки"
        };
        search_entry.search_changed.connect (on_search_changed);

        // Без max_width_chars метка с переносом просила бы ширину всего текста
        totals_label = new Gtk.Label (null) {
            xalign = 0,
            wrap = true,
            max_width_chars = 30
        };
        totals_label.add_css_class ("dim-label");

        append (heading);
        append (build_day_switcher ());
        append (search_entry);
        append (totals_label);
        append (build_list ());
    }

    // «Сегодня» и переключатель дня «‹ дата ›» с календарём
    private Gtk.Widget build_day_switcher () {
        today_button = new Gtk.Button.with_label ("Сегодня");
        today_button.clicked.connect (on_today);

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
            always_show_arrow = true,
            hexpand = true
        };

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        box.append (today_button);
        box.append (prev_button);
        box.append (date_button);
        box.append (next_button);
        return box;
    }

    // Список только для просмотра: без выделения; длинный — прокручивается
    private Gtk.Widget build_list () {
        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            valign = Gtk.Align.START,
            can_focus = false
        };
        list.add_css_class ("boxed-list");

        placeholder = new Gtk.Label (null) {
            wrap = true,
            max_width_chars = 30,
            margin_top = 18,
            margin_bottom = 18,
            margin_start = 12,
            margin_end = 12
        };
        placeholder.add_css_class ("dim-label");
        list.set_placeholder (placeholder);

        return new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vexpand = true,
            child = list
        };
    }

    // Выдача: ФИО, приём пищи и группа, справа время.
    // ФИО и группу могли поменять после выдачи — тогда видно и прежние.
    protected static Adw.ActionRow build_meal_row (DayRecord record, string meal, string time) {
        var row = build_row (time);
        row.title = Styles.changed_markup (record.issued_name, record.student.full_name);
        row.subtitle = @"$meal · $(Styles.changed_markup (record.issued_group, record.student.group_name))";
        row.tooltip_text = record.change_note ();
        row.add_prefix (new Adw.Avatar (32, record.student.full_name, true));
        return row;
    }

    // Карточки нет у учеников: тип и номер, справа время
    protected static Adw.ActionRow build_unknown_row (CardRead card) {
        var row = build_row (card.scanned_at);
        row.title = "Неизвестная карточка";
        // Тип пустой, пока карточку, записанную без него, снова не приложат
        row.subtitle = card.card_type != ""
            ? @"$(Markup.escape_text (card.card_type)) · номер $(card.uid)"
            : @"Номер $(card.uid)";
        var icon = new Gtk.Image.from_icon_name ("dialog-question-symbolic") {
            pixel_size = 32
        };
        icon.add_css_class ("warning");
        row.add_prefix (icon);
        return row;
    }

    private static Adw.ActionRow build_row (string time) {
        var row = new Adw.ActionRow () {
            activatable = true,
            can_focus = true
        };
        var label = new Gtk.Label (time.substring (0, 5));
        label.add_css_class ("numeric");
        label.add_css_class ("dim-label");
        row.add_suffix (label);
        return row;
    }
}
