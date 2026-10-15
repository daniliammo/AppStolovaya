// Разметка окна ученика (появляется при прикладывании карточки).
// Логика — в student_dialog.vala (класс StudentDialog наследует StudentDialogUi).

public abstract class StudentDialogUi : Adw.Dialog {
    protected Adw.Avatar avatar;
    protected Gtk.Label name_label;
    protected Gtk.Label group_label;
    protected Gtk.Label hint_label;
    protected Gtk.Button breakfast_button;
    protected Gtk.Button lunch_button;

    // Нажата кнопка «Завтрак» или «Обед»
    protected abstract void on_meal_clicked (MealType type);

    construct {
        title = "Ученик";
        content_width = 420;

        avatar = new Adw.Avatar (96, null, true);

        name_label = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        name_label.add_css_class ("title-2");

        group_label = new Gtk.Label (null);
        group_label.add_css_class ("dim-label");

        breakfast_button = build_meal_button ();
        breakfast_button.clicked.connect (() => on_meal_clicked (MealType.BREAKFAST));
        lunch_button = build_meal_button ();
        lunch_button.clicked.connect (() => on_meal_clicked (MealType.LUNCH));

        // Как выбран приём пищи: по времени или в тестовом режиме
        hint_label = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        hint_label.add_css_class ("caption");
        hint_label.add_css_class ("dim-label");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            margin_top = 12,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        box.append (avatar);
        box.append (name_label);
        box.append (group_label);
        box.append (breakfast_button);
        box.append (lunch_button);
        box.append (hint_label);

        var toolbar = new Adw.ToolbarView () {
            content = box
        };
        toolbar.add_top_bar (new Adw.HeaderBar ());
        child = toolbar;
    }

    // Большая кнопка-«таблетка»
    private static Gtk.Button build_meal_button () {
        var button = new Gtk.Button () {
            height_request = 56
        };
        button.add_css_class ("pill");
        return button;
    }
}
