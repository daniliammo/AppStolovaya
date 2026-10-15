// Тесты базы данных. Запуск: meson test -C build

DateTime at (int day, int hour, int minute) {
    return new DateTime.local (2026, 10, day, hour, minute, 0);
}

void test_schema () throws Error {
    var db = new Database (":memory:");
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 1);
}

void test_students () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 123);
    db.add_student ("Петров Пётр", "5Б");  // без карточки

    var found = db.find_student_by_card (123);
    assert_nonnull (found);
    assert_cmpint ((int) found.id, CompareOperator.EQ, (int) id);
    assert_cmpstr (found.full_name, CompareOperator.EQ, "Иванов Иван");
    assert_cmpstr (found.group_name, CompareOperator.EQ, "5А");
    assert_null (db.find_student_by_card (999));

    var all = db.list_students ();
    assert_cmpint (all.length, CompareOperator.EQ, 2);
    assert_true (all[1].card_uid == null);

    // Привязать карточку ученику без карточки
    all[1].card_uid = int64.MAX;
    db.update_student (all[1]);
    assert_cmpstr (db.find_student_by_card (int64.MAX).full_name, CompareOperator.EQ, "Петров Пётр");
}

void assert_constraint (Database db, string full_name, int64? card_uid) {
    try {
        db.add_student (full_name, "5А", card_uid);
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }
}

void test_student_constraints () throws Error {
    var db = new Database (":memory:");
    db.add_student ("Иванов Иван", "5А", 123);
    assert_constraint (db, "Другой ученик", 123);  // карточка уже занята
    assert_constraint (db, "Отрицательный", -1);
    assert_constraint (db, "", 5);
    assert_cmpint (db.list_students ().length, CompareOperator.EQ, 1);
}

void test_record_meal () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 1);

    assert_true (db.record_meal (id, MealType.BREAKFAST, at (15, 8, 12)));
    assert_false (db.record_meal (id, MealType.BREAKFAST, at (15, 8, 13)));  // повторно
    assert_true (db.record_meal (id, MealType.LUNCH, at (15, 12, 30)));
    // На следующий день отметки снова свободны
    assert_true (db.record_meal (id, MealType.BREAKFAST, at (16, 8, 5)));

    var counts = db.count_meals (at (15, 0, 0));
    assert_cmpint (counts.breakfasts, CompareOperator.EQ, 1);
    assert_cmpint (counts.lunches, CompareOperator.EQ, 1);

    var student = db.find_student_by_card (1);
    var today = db.student_day (student, at (16, 0, 0));
    assert_cmpstr (today.breakfast_at, CompareOperator.EQ, "08:05:00");
    assert_null (today.lunch_at);
}

void test_record_meal_unknown_student () throws Error {
    var db = new Database (":memory:");
    try {
        db.record_meal (42, MealType.LUNCH, at (15, 12, 0));
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }
}

void test_day_records () throws Error {
    var db = new Database (":memory:");
    var b = db.add_student ("Борисов Борис", "5Б", 2);
    var a = db.add_student ("Алексеев Алексей", "5А", 1);
    db.add_student ("Не ел", "5А", 3);

    db.record_meal (b, MealType.LUNCH, at (15, 12, 40));
    db.record_meal (a, MealType.BREAKFAST, at (15, 8, 10));
    db.record_meal (a, MealType.LUNCH, at (15, 12, 30));
    db.record_meal (a, MealType.LUNCH, at (14, 12, 0));

    var records = db.day_records (at (15, 0, 0));
    assert_cmpint (records.length, CompareOperator.EQ, 2);  // кто не ел, в списке нет
    assert_cmpstr (records[0].student.full_name, CompareOperator.EQ, "Алексеев Алексей");
    assert_cmpstr (records[0].breakfast_at, CompareOperator.EQ, "08:10:00");
    assert_cmpstr (records[0].lunch_at, CompareOperator.EQ, "12:30:00");
    assert_cmpstr (records[1].student.full_name, CompareOperator.EQ, "Борисов Борис");
    assert_null (records[1].breakfast_at);

    var days = db.meal_days ();
    assert_cmpint (days.length, CompareOperator.EQ, 2);
    assert_cmpstr (days[0], CompareOperator.EQ, "2026-10-14");
    assert_cmpstr (days[1], CompareOperator.EQ, "2026-10-15");
    assert_cmpint (db.meal_days (2026).length, CompareOperator.EQ, 2);  // учебный 2026–2027
    assert_cmpint (db.meal_days (2025).length, CompareOperator.EQ, 0);
}

void test_school_years () throws Error {
    // Учебный год по году начала: сентябрь–июнь, лето — к закончившемуся году
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 9, 1, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 12, 31, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2027, 6, 30, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2027, 7, 15, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 8, 31, 0, 0, 0)), CompareOperator.EQ, 2025);

    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 1);
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 6, 30, 12, 0, 0));  // 2023–2024
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 8, 20, 12, 0, 0));  // лето → 2023–2024
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 9, 1, 12, 0, 0));   // 2024–2025
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2025, 5, 25, 12, 0, 0));  // 2024–2025

    assert_cmpint (db.meal_days (2023).length, CompareOperator.EQ, 2);
    assert_cmpint (db.meal_days (2024).length, CompareOperator.EQ, 2);
    var years = db.changed_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 2);
    assert_cmpint (years[0], CompareOperator.EQ, 2023);
    assert_cmpint (years[1], CompareOperator.EQ, 2024);
}

void test_exports () throws Error {
    var db = new Database (":memory:");
    assert_null (db.last_export_date ());
    db.mark_exported (at (14, 0, 0), "/tmp/a.xlsx", at (15, 0, 1));
    db.mark_exported (at (15, 0, 0), "/tmp/a.xlsx", at (15, 18, 0));
    db.mark_exported (at (15, 0, 0), "/tmp/a.xlsx", at (15, 19, 0));  // повторно за тот же день
    assert_cmpstr (db.last_export_date (), CompareOperator.EQ, "2026-10-15");
}

void test_reopen_file () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "sub", "canteen.db");  // папка sub создаётся сама

    var db = new Database (path);
    db.add_student ("Иванов Иван", "5А", 7);
    db = null;  // закрыть

    db = new Database (path);  // миграция не должна повториться
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 1);
    assert_nonnull (db.find_student_by_card (7));
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, "sub", name));
    }
    DirUtils.remove (Path.build_filename (dir, "sub"));
    DirUtils.remove (dir);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/database/schema", () => wrap (test_schema));
    Test.add_func ("/database/students", () => wrap (test_students));
    Test.add_func ("/database/student-constraints", () => wrap (test_student_constraints));
    Test.add_func ("/database/record-meal", () => wrap (test_record_meal));
    Test.add_func ("/database/record-meal-unknown-student", () => wrap (test_record_meal_unknown_student));
    Test.add_func ("/database/day-records", () => wrap (test_day_records));
    Test.add_func ("/database/school-years", () => wrap (test_school_years));
    Test.add_func ("/database/exports", () => wrap (test_exports));
    Test.add_func ("/database/reopen-file", () => wrap (test_reopen_file));
    return Test.run ();
}

delegate void TestBody () throws Error;

// Любая неожиданная ошибка базы — провал теста с её текстом
void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
