// Настройки программы. Хранятся в базе (таблица settings), поэтому
// переживают перезапуск и лежат вместе с остальными данными.

public class Settings {
    // Обед по умолчанию с 11:00, раньше — завтрак
    public const int DEFAULT_LUNCH_FROM = 11 * 60;

    private Database database;

    // Определять завтрак или обед по времени прикладывания.
    // Выключено — в окне ученика обе кнопки.
    public bool auto_meal { get; private set; default = true; }

    // С какого времени начинается обед, в минутах от полуночи
    public int lunch_from { get; private set; default = DEFAULT_LUNCH_FROM; }

    // Показывать на главном экране плашку «Осталось X из Y»
    public bool show_remaining { get; private set; default = true; }

    public Settings (Database database) throws DatabaseError {
        this.database = database;

        var auto = database.get_setting ("auto_meal");
        if (auto != null) {
            auto_meal = auto == "true";
        }
        var lunch = database.get_setting ("lunch_from");
        int minutes = 0;
        if (lunch != null && int.try_parse (lunch, out minutes) && minutes >= 0 && minutes < 24 * 60) {
            lunch_from = minutes;
        }
        var remaining = database.get_setting ("show_remaining");
        if (remaining != null) {
            show_remaining = remaining == "true";
        }
    }

    public void save_auto_meal (bool value) throws DatabaseError {
        database.set_setting ("auto_meal", value.to_string ());
        auto_meal = value;
    }

    public void save_lunch_from (int minutes) throws DatabaseError
        requires (minutes >= 0 && minutes < 24 * 60) {
        database.set_setting ("lunch_from", minutes.to_string ());
        lunch_from = minutes;
    }

    public void save_show_remaining (bool value) throws DatabaseError {
        database.set_setting ("show_remaining", value.to_string ());
        show_remaining = value;
    }

    // Какой приём пищи по времени: до начала обеда — завтрак
    public MealType meal_at (DateTime time) {
        return meal_for_time (time, lunch_from);
    }

    public static MealType meal_for_time (DateTime time, int lunch_from) {
        var minutes = time.get_hour () * 60 + time.get_minute ();
        return minutes < lunch_from ? MealType.BREAKFAST : MealType.LUNCH;
    }
}
