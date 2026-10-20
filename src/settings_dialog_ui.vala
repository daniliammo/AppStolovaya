// Разметка окна настроек.
// Логика — в settings_dialog.vala (класс SettingsDialog наследует SettingsDialogUi).

public abstract class SettingsDialogUi : Adw.PreferencesDialog {
    protected Adw.SwitchRow auto_meal_row;
    protected Gtk.SpinButton lunch_hour;
    protected Gtk.SpinButton lunch_minute;
    protected Adw.SwitchRow show_remaining_row;
    protected Adw.ActionRow reader_row;   // подключён ли считыватель
    protected Adw.ActionRow access_row;   // есть ли у программы доступ к нему
    protected Gtk.Button setup_button;
    protected Adw.Spinner setup_spinner;

    protected abstract void on_auto_meal_changed ();
    protected abstract void on_lunch_time_changed ();
    protected abstract void on_show_remaining_changed ();
    protected abstract void on_setup_clicked ();

    construct {
        title = "Настройки";

        auto_meal_row = new Adw.SwitchRow () {
            title = "Определять по времени",
            subtitle = "При прикладывании карточки показывать только завтрак или только обед. Если выключено — обе кнопки"
        };
        auto_meal_row.notify["active"].connect (on_auto_meal_changed);

        lunch_hour = build_time_spin (23, 1);
        lunch_minute = build_time_spin (59, 5);
        lunch_hour.value_changed.connect (on_lunch_time_changed);
        lunch_minute.value_changed.connect (on_lunch_time_changed);

        var time_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            valign = Gtk.Align.CENTER
        };
        time_box.append (lunch_hour);
        time_box.append (new Gtk.Label (":"));
        time_box.append (lunch_minute);

        var lunch_row = new Adw.ActionRow () {
            title = "Обед начинается в",
            subtitle = "Раньше — завтрак"
        };
        lunch_row.add_suffix (time_box);
        // Время обеда имеет смысл, только когда определение по времени включено
        auto_meal_row.bind_property ("active", lunch_row, "sensitive", BindingFlags.SYNC_CREATE);

        var group = new Adw.PreferencesGroup () {
            title = "Завтрак и обед"
        };
        group.add (auto_meal_row);
        group.add (lunch_row);

        var page = new Adw.PreferencesPage ();
        page.add (group);
        page.add (build_screen_group ());
        page.add (build_system_group ());
        add (page);
    }

    // Что показывать на главном экране
    private Adw.PreferencesGroup build_screen_group () {
        show_remaining_row = new Adw.SwitchRow () {
            title = "Показывать «Осталось»",
            subtitle = "Сколько учеников с карточками ещё не получили завтрак или обед"
        };
        show_remaining_row.notify["active"].connect (on_show_remaining_changed);

        var group = new Adw.PreferencesGroup () {
            title = "Главный экран"
        };
        group.add (show_remaining_row);
        return group;
    }

    // Считыватель карт: состояние и кнопка настройки системы
    private Adw.PreferencesGroup build_system_group () {
        reader_row = new Adw.ActionRow () {
            title = "Считыватель карт"
        };
        access_row = new Adw.ActionRow () {
            title = "Доступ к считывателю"
        };

        setup_spinner = new Adw.Spinner () {
            visible = false
        };
        setup_button = new Gtk.Button.with_label ("Настроить") {
            valign = Gtk.Align.CENTER
        };
        setup_button.add_css_class ("suggested-action");
        setup_button.clicked.connect (on_setup_clicked);

        var setup_row = new Adw.ActionRow () {
            title = "Настроить систему",
            subtitle = "Доступ к считывателю без пароля. Пароль администратора спросят один раз. Сеть и интернет не затрагиваются"
        };
        setup_row.add_suffix (setup_spinner);
        setup_row.add_suffix (setup_button);

        var group = new Adw.PreferencesGroup () {
            title = "Система"
        };
        group.add (reader_row);
        group.add (access_row);
        group.add (setup_row);
        return group;
    }

    // Поле часов или минут: показывает число с ведущим нулём (09:05)
    private static Gtk.SpinButton build_time_spin (int max, int step) {
        var spin = new Gtk.SpinButton.with_range (0, max, step) {
            numeric = true,
            wrap = true,
            width_chars = 2,
            orientation = Gtk.Orientation.VERTICAL
        };
        spin.output.connect (() => {
            spin.text = "%02d".printf ((int) spin.value);
            return true;
        });
        return spin;
    }
}
