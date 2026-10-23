// Окно настроек: изменения сразу сохраняются в базу.
// Разметка — в settings_dialog_ui.vala (SettingsDialogUi).

public class SettingsDialog : SettingsDialogUi {
    private Settings settings;
    private bool loading = true;  // пока заполняем поля, ничего не сохраняем

    public signal void database_failed (DatabaseError e);
    // Настройка сохранена: главному окну пора обновить экран
    public signal void changed ();

    public SettingsDialog (Settings settings) {
        this.settings = settings;
        auto_meal_row.active = settings.auto_meal;
        lunch_hour.value = settings.lunch_from / 60;
        lunch_minute.value = settings.lunch_from % 60;
        show_remaining_row.active = settings.show_remaining;
        loading = false;
        update_system_status ();
    }

    // Подключён ли считыватель, есть ли доступ, нужна ли настройка
    private void update_system_status () {
        var reader = SystemSetup.find_reader ();
        var configured = SystemSetup.rules_installed ();

        reader_row.subtitle = reader != null
            ? @"Подключён: $reader"
            : "Не найден — подключите считыватель к USB";

        if (reader == null) {
            access_row.subtitle = "Проверка после подключения считывателя";
        } else if (!SystemSetup.can_access (reader)) {
            access_row.subtitle = "Нет — нажмите «Настроить»";
        } else if (!configured) {
            access_row.subtitle = "Есть, но система не настроена: ModemManager может мешать считывателю";
        } else {
            access_row.subtitle = "Есть";
        }

        setup_button.label = configured ? "Настроить заново" : "Настроить";
        if (configured) {
            setup_button.remove_css_class ("suggested-action");
        }
    }

    protected override void on_setup_clicked () {
        setup_button.sensitive = false;
        setup_spinner.visible = true;
        SystemSetup.run.begin ((obj, res) => {
            setup_button.sensitive = true;
            setup_spinner.visible = false;
            try {
                SystemSetup.run.end (res);
                add_toast (new Adw.Toast ("Система настроена"));
            } catch (Error e) {
                add_toast (new Adw.Toast (e.message) { timeout = 0 });
            }
            update_system_status ();
        });
    }

    protected override void on_auto_meal_changed () {
        if (loading) {
            return;
        }
        try {
            settings.save_auto_meal (auto_meal_row.active);
            changed ();
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
            changed ();
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }

    protected override void on_show_remaining_changed () {
        if (loading) {
            return;
        }
        try {
            settings.save_show_remaining (show_remaining_row.active);
            changed ();
        } catch (DatabaseError e) {
            database_failed (e);
        }
    }
}
