// Окно настроек: изменения сразу сохраняются в базу.
// Разметка — в settings_dialog_ui.vala (SettingsDialogUi).

public class SettingsDialog : SettingsDialogUi {
    private Settings settings;
    private bool loading = true;  // пока заполняем поля, ничего не сохраняем

    public signal void database_failed (DatabaseError e);

    public SettingsDialog (Settings settings) {
        this.settings = settings;
        auto_meal_row.active = settings.auto_meal;
        lunch_hour.value = settings.lunch_from / 60;
        lunch_minute.value = settings.lunch_from % 60;
        loading = false;
    }

    protected override void on_auto_meal_changed () {
        if (loading) {
            return;
        }
        try {
            settings.save_auto_meal (auto_meal_row.active);
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }

    protected override void on_lunch_time_changed () {
        if (loading) {
            return;
        }
        try {
            settings.save_lunch_from (lunch_hour.get_value_as_int () * 60 + lunch_minute.get_value_as_int ());
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }
}
