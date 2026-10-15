// Разметка главного окна: создание виджетов и их расположение.
// Логика — в window.vala (класс MainWindow наследует MainWindowUi).

public abstract class MainWindowUi : Adw.ApplicationWindow {
    protected Adw.ToastOverlay toast_overlay;
    protected Adw.WindowTitle window_title;
    protected Gtk.Label breakfast_count;
    protected Gtk.Label lunch_count;
    protected Gtk.Entry card_entry;

    // Enter в поле номера карточки или кнопка «Приложить карточку»
    protected abstract void on_simulate_card ();

    construct {
        title = "Столовая";
        default_width = 800;
        default_height = 600;

        var toolbar = new Adw.ToolbarView () {
            content = build_waiting_screen ()
        };
        toolbar.add_top_bar (build_header_bar ());
        toolbar.add_bottom_bar (build_simulation_bar ());

        toast_overlay = new Adw.ToastOverlay () {
            child = toolbar
        };
        content = toast_overlay;
    }

    private Adw.HeaderBar build_header_bar () {
        window_title = new Adw.WindowTitle ("Столовая", "");

        var main_section = new Menu ();
        main_section.append ("Ученики", "app.students");
        main_section.append ("Обновить Excel-файл", "app.export");

        var about_section = new Menu ();
        about_section.append ("О программе", "app.about");
        about_section.append ("Выход", "app.quit");

        var menu = new Menu ();
        menu.append_section (null, main_section);
        menu.append_section (null, about_section);

        var menu_button = new Gtk.MenuButton () {
            icon_name = "open-menu-symbolic",
            menu_model = menu,
            primary = true,
            tooltip_text = "Главное меню"
        };

        var header = new Adw.HeaderBar () {
            title_widget = window_title
        };
        header.pack_end (menu_button);
        return header;
    }

    // «Приложите карточку» и счётчики выдачи за сегодня
    private Gtk.Widget build_waiting_screen () {
        var icon = new Gtk.Image.from_icon_name ("auth-smartcard-symbolic") {
            pixel_size = 128,
            margin_bottom = 12
        };
        icon.add_css_class ("dim-label");

        var title = new Gtk.Label ("Приложите карточку");
        title.add_css_class ("title-1");

        var hint = new Gtk.Label ("к считывателю, чтобы получить завтрак или обед") {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        hint.add_css_class ("dim-label");

        var counters = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            homogeneous = true,
            margin_top = 24
        };
        counters.append (build_counter_card ("завтраков сегодня", out breakfast_count));
        counters.append (build_counter_card ("обедов сегодня", out lunch_count));

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        box.append (icon);
        box.append (title);
        box.append (hint);
        box.append (counters);
        return box;
    }

    // Плашка: крупное число и подпись под ним
    private Gtk.Widget build_counter_card (string caption, out Gtk.Label count) {
        count = new Gtk.Label ("0") {
            margin_top = 12
        };
        count.add_css_class ("title-1");
        count.add_css_class ("numeric");

        var caption_label = new Gtk.Label (caption) {
            margin_bottom = 12,
            margin_start = 24,
            margin_end = 24
        };
        caption_label.add_css_class ("dim-label");

        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        card.add_css_class ("card");
        card.append (count);
        card.append (caption_label);
        return card;
    }

    // Панель тестового режима: номер карточки вводится вручную вместо NFC
    private Gtk.Widget build_simulation_bar () {
        var label = new Gtk.Label ("Тестовый режим:");
        label.add_css_class ("dim-label");

        card_entry = new Gtk.Entry () {
            input_purpose = Gtk.InputPurpose.DIGITS,
            placeholder_text = "Номер карточки",
            width_chars = 20
        };
        card_entry.activate.connect (on_simulate_card);

        var button = new Gtk.Button.with_label ("Приложить карточку");
        button.add_css_class ("suggested-action");
        button.clicked.connect (on_simulate_card);

        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.CENTER,
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };
        bar.append (label);
        bar.append (card_entry);
        bar.append (button);
        return bar;
    }
}
