// Учёт питания в столовой по NFC-карточкам.
// Adw.Application сам следует системной теме (светлой или тёмной).

public class HelloApp : Adw.Application {
    public HelloApp () {
        Object (
            application_id: "org.example.Test",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void startup () {
        base.startup ();

        var about = new SimpleAction ("about", null);
        about.activate.connect (show_about);
        add_action (about);
    }

    protected override void activate () {
        var window = active_window ?? new MainWindow (this);
        window.present ();
    }

    private void show_about () {
        var dialog = new Adw.AboutDialog () {
            application_name = "Столовая",
            application_icon = "auth-smartcard-symbolic",
            version = "0.1.0",
            comments = "Учёт питания по NFC-карточкам"
        };
        dialog.present (active_window);
    }

    public static int main (string[] args) {
        return new HelloApp ().run (args);
    }
}
