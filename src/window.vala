// Главное окно: ожидание карточки и счётчики выдачи за сегодня.
// Разметка — в main_window_ui.vala (MainWindowUi),
// здесь только логика: обновление виджетов и обработчики сигналов.

public class MainWindow : MainWindowUi {
    // Приложили карточку (настоящую или в тестовом режиме)
    public signal void card_presented (uint64 uid);

    public MainWindow (Adw.Application app) {
        Object (application: app);

        update_clock ();
        Timeout.add_seconds (1, () => {
            update_clock ();
            return Source.CONTINUE;
        });

        // Пока нет окна ученика, просто показываем номер карточки
        card_presented.connect ((uid) => {
            show_toast (@"Карточка $uid приложена");
        });
    }

    public void set_counts (int breakfasts, int lunches) {
        breakfast_count.label = breakfasts.to_string ();
        lunch_count.label = lunches.to_string ();
    }

    public void show_toast (string text) {
        toast_overlay.add_toast (new Adw.Toast (text));
    }

    private void update_clock () {
        var now = new DateTime.now_local ();
        window_title.subtitle = now.format ("%A, %e %B · %H:%M");
    }

    protected override void on_simulate_card () {
        // try_parse пропускает пустую строку (как 0) и знак минус, поэтому
        // сначала проверяем, что первым символом идёт цифра
        var text = card_entry.text.strip ();
        uint64 uid = 0;
        if (!text.get_char (0).isdigit () || !uint64.try_parse (text, out uid, null, 10)) {
            show_toast ("Номер карточки — целое неотрицательное число");
            return;
        }
        card_entry.text = "";
        card_presented (uid);
    }
}
