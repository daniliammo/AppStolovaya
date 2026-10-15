// Разметка окна настроек.
// Логика — в settings_dialog.vala (класс SettingsDialog наследует SettingsDialogUi).

public abstract class SettingsDialogUi : Adw.PreferencesDialog {
    protected Adw.SwitchRow auto_meal_row;
    protected Gtk.SpinButton lunch_hour;
    protected Gtk.SpinButton lunch_minute;

    protected abstract void on_auto_meal_changed ();
    protected abstract void on_lunch_time_changed ();

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
        add (page);
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
