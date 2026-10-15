// Главное окно. Разметка лежит в data/window.ui и редактируется в Cambalache,
// здесь только логика: виджеты из шаблона и обработчики сигналов.

[GtkTemplate (ui = "/org/example/Stolovka/window.ui")]
public class MainWindow : Adw.ApplicationWindow {
    [GtkChild]
    private unowned Gtk.Label label;
    [GtkChild]
    private unowned Gtk.Entry entry;
    [GtkChild]
    private unowned Gtk.Button button;

    private int counter = 0;

    public MainWindow (Adw.Application app) {
        Object (application: app);
    }

    // По нажатию Enter приветствуем введённое имя
    [GtkCallback]
    private void on_entry_activate () {
        var name = entry.text.strip ();
        label.label = name == "" ? "Привет, GTK 4!" : @"Привет, $name!";
    }

    [GtkCallback]
    private void on_button_clicked () {
        counter++;
        button.label = @"Нажато: $counter раз";
    }
}
