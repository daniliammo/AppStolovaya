// Окно ученика: ФИО, группа и кнопки «Завтрак» / «Обед».
// Разметка — в student_dialog_ui.vala (StudentDialogUi).

public class StudentDialog : StudentDialogUi {
    private Database database;
    private Student student;
    private bool show_breakfast;
    private bool show_lunch;

    // Приём пищи списан
    public signal void meal_recorded (MealType type);
    public signal void database_failed (DatabaseError e);

    // only — показать только этот приём пищи, null — обе кнопки.
    // hint — пояснение внизу, как выбран приём пищи (может быть пустым).
    public StudentDialog (Database database, Student student, MealType? only, string hint) throws DatabaseError {
        this.database = database;
        this.student = student;
        if (only == null) {
            show_breakfast = show_lunch = true;
        } else {
            show_breakfast = (MealType) only == MealType.BREAKFAST;
            show_lunch = !show_breakfast;
        }

        avatar.text = student.full_name;
        name_label.label = student.full_name;
        group_label.label = student.group_name;
        hint_label.label = hint;
        hint_label.visible = hint != "";
        update_buttons ();
    }

    private void update_buttons () throws DatabaseError {
        var day = database.student_day (student, new DateTime.now_local ());
        setup_button (breakfast_button, show_breakfast, "Завтрак", day.breakfast_at);
        setup_button (lunch_button, show_lunch, "Обед", day.lunch_at);

        // Enter списывает, если доступна ровно одна кнопка
        if (breakfast_button.visible && breakfast_button.sensitive && !lunch_button.visible) {
            focus_widget = breakfast_button;
        } else if (lunch_button.visible && lunch_button.sensitive && !breakfast_button.visible) {
            focus_widget = lunch_button;
        }
    }

    // Уже получен — кнопка неактивна и показывает время
    private static void setup_button (Gtk.Button button, bool shown, string name, string? received_at) {
        button.visible = shown;
        button.sensitive = received_at == null;
        // Полученный приём пищи — красная кнопка
        if (received_at == null) {
            button.add_css_class ("suggested-action");
        } else {
            button.remove_css_class ("suggested-action");
            button.add_css_class ("destructive-action");
        }
        button.label = received_at == null
            ? name
            : "%s уже получен в %s".printf (name, received_at.substring (0, 5));
    }

    protected override void on_meal_clicked (MealType type) {
        try {
            if (database.record_meal (student.id, type, new DateTime.now_local ())) {
                meal_recorded (type);
                close ();
            } else {
                update_buttons ();  // успели списать раньше (двойное нажатие)
            }
        } catch (DatabaseError e) {
            database_failed (e);
            close ();
        }
    }
}
