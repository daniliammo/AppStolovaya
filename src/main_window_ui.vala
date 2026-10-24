// Разметка главного окна: создание виджетов и их расположение.
// Логика — в window.vala (класс MainWindow наследует MainWindowUi).
//
// Слева большая карточка состояния (Gtk.Stack) и счётчики под ней,
// справа — Последние считывания. Карточка состояния переключается между
// страницами «ожидание», «ученик» и «результат»; цвет результата задаётся
// классами status-ok / status-again / status-unknown (стили — в styles.vala).

public abstract class MainWindowUi : Adw.ApplicationWindow {
    // Имена страниц карточки состояния
    protected const string PAGE_IDLE = "idle";
    protected const string PAGE_STUDENT = "student";
    protected const string PAGE_RESULT = "result";

    protected Adw.ToastOverlay toast_overlay;
    protected Adw.WindowTitle window_title;

    // Сканер: значок в заголовке и полоса с кнопкой «Настроить», когда он не работает
    protected Gtk.Image reader_icon;
    protected Gtk.Label idle_title;
    protected Gtk.Label idle_hint;
    protected Adw.Banner reader_banner;
    protected Gtk.ToggleButton dark_button;
    // Полоса «База занята другой программой» — пока выдачи не записываются
    protected Adw.Banner database_banner;

    // Карточка состояния и её страницы
    protected Gtk.Box status_card;
    protected Gtk.Stack stack;
    // Ожидание
    protected Gtk.Label clock_label;
    protected Gtk.Label meal_period_label;
    // Ученик
    protected Adw.Avatar student_avatar;
    protected Gtk.Label student_name;
    protected Gtk.Label student_group;
    protected Gtk.Label student_hint;
    protected Gtk.Button primary_button;    // «Выдать обед» — основной приём пищи
    protected Gtk.Button secondary_button;  // другой приём пищи, если разрешены оба
    // Результат
    protected Gtk.Image result_icon;
    protected Gtk.Label result_title;
    protected Gtk.Label result_subtitle;

    // Счётчики за сегодня
    protected Gtk.Box breakfast_tile;
    protected Gtk.Box lunch_tile;
    protected Gtk.Label breakfast_count;
    protected Gtk.Label lunch_count;
    protected Gtk.Box remaining_tile;  // можно скрыть в настройках
    protected Gtk.Label remaining_label;
    protected Gtk.Label remaining_caption;
    protected Gtk.ProgressBar remaining_progress;

    // Последние считывания
    protected Gtk.ListBox recent_list;

#if DEBUG
    protected Gtk.Entry card_entry;
    // Тестовый режим: какой приём пищи показать (0 — по настройкам, 1 — завтрак, 2 — обед)
    protected Gtk.DropDown meal_choice;
#endif

    // Кнопки на странице ученика
    protected abstract void on_primary_clicked ();
    protected abstract void on_secondary_clicked ();
    // «Отмена» — вернуться к ожиданию, ничего не списывая
    protected abstract void on_cancel_clicked ();

#if DEBUG
    // Enter в поле номера карточки или кнопка «Приложить карточку»
    protected abstract void on_simulate_card ();
#endif

    construct {
        title = "Столовая";
        default_width = 1100;
        default_height = 720;

        var main_column = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            hexpand = true
        };
        main_column.append (build_status_card ());
        main_column.append (build_counters ());

        var body = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 18) {
            margin_top = 18,
            margin_bottom = 18,
            margin_start = 18,
            margin_end = 18
        };
        body.append (main_column);
        body.append (build_recent_panel ());

        reader_banner = new Adw.Banner ("Сканер не подключён") {
            button_label = "Настроить",
            action_name = "app.preferences"
        };

        reader_banner.add_css_class ("error");

        database_banner = new Adw.Banner (
            "База занята другой программой — выдачи не записываются. Запишите или отмените изменения в ней");
        database_banner.add_css_class ("error");

        var toolbar = new Adw.ToolbarView () {
            content = body
        };
        toolbar.add_top_bar (build_header_bar ());
        toolbar.add_top_bar (reader_banner);
        toolbar.add_top_bar (database_banner);
#if DEBUG
        toolbar.add_bottom_bar (build_simulation_bar ());
#endif

        toast_overlay = new Adw.ToastOverlay () {
            child = toolbar
        };
        content = toast_overlay;
    }

    private Adw.HeaderBar build_header_bar () {
        window_title = new Adw.WindowTitle ("Столовая", "");

        var main_section = new Menu ();
        main_section.append ("История", "app.history");
        main_section.append ("Ученики", "app.students");
        main_section.append ("Импорт учеников…", "app.import-students");
        main_section.append ("Обновить Excel-файл", "app.export");
        main_section.append ("Настройки", "app.preferences");

        var view_section = new Menu ();
        view_section.append ("Во весь экран", "win.fullscreen");

        var about_section = new Menu ();
        about_section.append ("О программе", "app.about");
        about_section.append ("Выход", "app.quit");

        var menu = new Menu ();
        menu.append_section (null, main_section);
        menu.append_section (null, view_section);
        menu.append_section (null, about_section);

        var menu_button = new Gtk.MenuButton () {
            icon_name = "open-menu-symbolic",
            menu_model = menu,
            primary = true,
            tooltip_text = "Главное меню"
        };

        dark_button = new Gtk.ToggleButton () {
            icon_name = "weather-clear-night-symbolic",
            tooltip_text = "Тёмная тема"
        };

        // Маленький значок состояния сканера; подробности — во всплывающей подсказке
        reader_icon = new Gtk.Image () {
            pixel_size = 16,
            margin_start = 6
        };
        reader_icon.add_css_class ("reader-indicator");

        var header = new Adw.HeaderBar () {
            title_widget = window_title
        };
        header.pack_start (reader_icon);
        header.pack_end (menu_button);
        header.pack_end (dark_button);
        return header;
    }

    // Большая карточка состояния: ожидание → ученик → результат
    private Gtk.Widget build_status_card () {
        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            transition_duration = 250,
            vexpand = true,
            hexpand = true
        };
        stack.add_named (build_idle_page (), PAGE_IDLE);
        stack.add_named (build_student_page (), PAGE_STUDENT);
        stack.add_named (build_result_page (), PAGE_RESULT);

        status_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            vexpand = true
        };
        status_card.add_css_class ("card");
        status_card.add_css_class ("status-card");
        status_card.append (stack);
        return status_card;
    }

    // «Приложите карточку», большие часы и текущий приём пищи
    private Gtk.Widget build_idle_page () {
        var icon = new Gtk.Image.from_icon_name ("auth-smartcard-symbolic") {
            pixel_size = 128,
            margin_bottom = 12
        };
        icon.add_css_class ("dim-label");
        icon.add_css_class ("breathing");

        idle_title = new Gtk.Label ("Приложите карточку");
        idle_title.add_css_class ("title-1");

        idle_hint = new Gtk.Label ("к считывателю, чтобы получить завтрак или обед") {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        idle_hint.add_css_class ("dim-label");

        clock_label = new Gtk.Label ("00:00") {
            margin_top = 18
        };
        clock_label.add_css_class ("big-clock");

        meal_period_label = new Gtk.Label (null);
        meal_period_label.add_css_class ("title-3");
        meal_period_label.add_css_class ("accent");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        box.append (icon);
        box.append (idle_title);
        box.append (idle_hint);
        box.append (clock_label);
        box.append (meal_period_label);
        return box;
    }

    // Ученик: аватар, ФИО, группа и большая кнопка выдачи
    private Gtk.Widget build_student_page () {
        student_avatar = new Adw.Avatar (160, null, true);

        student_name = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        student_name.add_css_class ("student-name");

        student_group = new Gtk.Label (null);
        student_group.add_css_class ("title-2");
        student_group.add_css_class ("dim-label");

        primary_button = new Gtk.Button () {
            margin_top = 18
        };
        primary_button.add_css_class ("meal-button");
        primary_button.add_css_class ("suggested-action");
        primary_button.clicked.connect (() => on_primary_clicked ());

        secondary_button = new Gtk.Button ();
        secondary_button.add_css_class ("touch-button");
        secondary_button.add_css_class ("pill");
        secondary_button.clicked.connect (() => on_secondary_clicked ());

        var cancel_button = new Gtk.Button.with_label ("Отмена") {
            halign = Gtk.Align.CENTER
        };
        cancel_button.add_css_class ("touch-button");
        cancel_button.add_css_class ("flat");
        cancel_button.clicked.connect (() => on_cancel_clicked ());

        // Как выбран приём пищи: по времени или в тестовом режиме
        student_hint = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        student_hint.add_css_class ("caption");
        student_hint.add_css_class ("dim-label");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            valign = Gtk.Align.CENTER,
            margin_start = 48,
            margin_end = 48
        };
        box.append (student_avatar);
        box.append (student_name);
        box.append (student_group);
        box.append (primary_button);
        box.append (secondary_button);
        box.append (cancel_button);
        box.append (student_hint);
        return box;
    }

    // Результат: «✓ Обед выдан», «Обед уже получен», «Карточка не зарегистрирована»
    private Gtk.Widget build_result_page () {
        result_icon = new Gtk.Image () {
            pixel_size = 128
        };
        result_icon.add_css_class ("result-icon");

        result_title = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        result_title.add_css_class ("result-title");

        result_subtitle = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        result_subtitle.add_css_class ("title-2");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            margin_start = 24,
            margin_end = 24
        };
        box.append (result_icon);
        box.append (result_title);
        box.append (result_subtitle);
        return box;
    }

    // Плашки «Завтраки», «Обеды» и «Осталось X из Y» с полосой прогресса
    private Gtk.Widget build_counters () {
        breakfast_tile = build_counter_tile ("Завтраки", out breakfast_count);
        lunch_tile = build_counter_tile ("Обеды", out lunch_count);

        remaining_label = new Gtk.Label (null) {
            xalign = 0
        };
        remaining_label.add_css_class ("title-2");
        remaining_label.add_css_class ("numeric");

        remaining_caption = new Gtk.Label (null) {
            xalign = 0
        };
        remaining_caption.add_css_class ("dim-label");

        remaining_progress = new Gtk.ProgressBar () {
            margin_top = 12
        };

        remaining_tile = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            hexpand = true
        };
        remaining_tile.add_css_class ("card");
        remaining_tile.add_css_class ("counter-tile");
        remaining_tile.append (remaining_caption);
        remaining_tile.append (remaining_label);
        remaining_tile.append (remaining_progress);

        var strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        strip.append (breakfast_tile);
        strip.append (lunch_tile);
        strip.append (remaining_tile);
        return strip;
    }

    // Плашка: подпись и крупное число
    private static Gtk.Box build_counter_tile (string caption, out Gtk.Label count) {
        var caption_label = new Gtk.Label (caption) {
            xalign = 0
        };
        caption_label.add_css_class ("dim-label");

        count = new Gtk.Label ("0") {
            xalign = 0
        };
        count.add_css_class ("counter-number");
        count.add_css_class ("numeric");

        var tile = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            width_request = 160
        };
        tile.add_css_class ("card");
        tile.add_css_class ("counter-tile");
        tile.append (caption_label);
        tile.append (count);
        return tile;
    }

    // Справа: все считывания за сегодня, новые сверху; длинный список прокручивается
    private Gtk.Widget build_recent_panel () {
        var heading = new Gtk.Label ("Последние считывания");
        heading.add_css_class ("heading");

        // Список только для просмотра: без выделения и фокуса
        recent_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            valign = Gtk.Align.START,
            can_focus = false
        };
        recent_list.add_css_class ("boxed-list");

        var placeholder = new Gtk.Label ("Сегодня ещё не прикладывались карточки") {
            wrap = true,
            margin_top = 18,
            margin_bottom = 18,
            margin_start = 12,
            margin_end = 12
        };
        placeholder.add_css_class ("dim-label");
        recent_list.set_placeholder (placeholder);

        var scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vexpand = true,
            child = recent_list
        };

        var panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            width_request = 300
        };
        panel.append (heading);
        panel.append (scroller);
        return panel;
    }

#if DEBUG
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

        meal_choice = new Gtk.DropDown.from_strings ({ "По настройкам", "Завтрак", "Обед" }) {
            tooltip_text = "Какой приём пищи показать при прикладывании"
        };

        var button = new Gtk.Button.with_label ("Приложить карточку");
        button.add_css_class ("suggested-action");
        button.clicked.connect (on_simulate_card);

        var keys = new Gtk.Label ("Ctrl+1/2/3 — тестовые карточки 1, 2, 3");
        keys.add_css_class ("dim-label");
        keys.add_css_class ("caption");

        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.CENTER,
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };
        bar.append (label);
        bar.append (card_entry);
        bar.append (meal_choice);
        bar.append (button);
        bar.append (keys);
        return bar;
    }
#endif
}
