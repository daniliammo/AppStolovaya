// Простой пример приложения на GTK 4 и Vala:
// окно с надписью, полем ввода и кнопкой-счётчиком.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class HelloApp : Adw.Application {
    public HelloApp () {
        Object (
            application_id: "org.example.Test",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void activate () {
        var window = active_window ?? new MainWindow (this);
        window.present ();
    }

    public static int main (string[] args) {
        return new HelloApp ().run (args);
    }
}
