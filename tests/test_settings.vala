// Тесты настроек и определения приёма пищи по времени. Запуск: meson test -C build

DateTime at (int hour, int minute) {
    return new DateTime.local (2026, 10, 15, hour, minute, 0);
}

void test_meal_for_time () {
    var lunch_from = 11 * 60 + 30;  // обед с 11:30
    assert_true (Settings.meal_for_time (at (0, 0), lunch_from) == MealType.BREAKFAST);
    assert_true (Settings.meal_for_time (at (11, 29), lunch_from) == MealType.BREAKFAST);
    assert_true (Settings.meal_for_time (at (11, 30), lunch_from) == MealType.LUNCH);
    assert_true (Settings.meal_for_time (at (23, 59), lunch_from) == MealType.LUNCH);
}

void test_defaults () throws Error {
    var settings = new Settings (new Database (":memory:"));
    assert_true (settings.auto_meal);
    assert_cmpint (settings.lunch_from, CompareOperator.EQ, Settings.DEFAULT_LUNCH_FROM);
    assert_true (settings.meal_at (at (10, 59)) == MealType.BREAKFAST);
    assert_true (settings.meal_at (at (11, 0)) == MealType.LUNCH);
}

void test_saved_in_database () throws Error {
    var db = new Database (":memory:");
    var settings = new Settings (db);
    settings.save_auto_meal (false);
    settings.save_lunch_from (12 * 60 + 15);

    // Новый объект читает сохранённое из базы
    var reloaded = new Settings (db);
    assert_false (reloaded.auto_meal);
    assert_cmpint (reloaded.lunch_from, CompareOperator.EQ, 12 * 60 + 15);
    assert_true (reloaded.meal_at (at (12, 0)) == MealType.BREAKFAST);
}

void test_bad_value_in_database () throws Error {
    var db = new Database (":memory:");
    db.set_setting ("lunch_from", "мусор");
    assert_cmpint (new Settings (db).lunch_from, CompareOperator.EQ, Settings.DEFAULT_LUNCH_FROM);
    db.set_setting ("lunch_from", "5000");  // больше суток
    assert_cmpint (new Settings (db).lunch_from, CompareOperator.EQ, Settings.DEFAULT_LUNCH_FROM);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/settings/meal-for-time", test_meal_for_time);
    Test.add_func ("/settings/defaults", () => wrap (test_defaults));
    Test.add_func ("/settings/saved-in-database", () => wrap (test_saved_in_database));
    Test.add_func ("/settings/bad-value", () => wrap (test_bad_value_in_database));
    return Test.run ();
}

delegate void TestBody () throws Error;

void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
