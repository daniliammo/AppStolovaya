// Тесты выгрузки в Excel. Запуск: meson test -C build
// Даты в прошлом: записи «из будущего» всегда считались бы изменёнными.

string tmp_dir;

DateTime at (int year, int day, int hour) {
    return new DateTime.local (year, 10, day, hour, 0, 0);
}

Database sample_database () throws Error {
    var db = new Database (":memory:");
    var a = db.add_student ("Алексеев Алексей", "5А", 1);
    var b = db.add_student ("Борисов Борис", "5Б", 2);
    db.record_meal (a, MealType.BREAKFAST, at (2024, 14, 8));
    db.record_meal (a, MealType.LUNCH, at (2025, 14, 12));
    db.record_meal (b, MealType.LUNCH, at (2025, 15, 12));
    return db;
}

// .xlsx — это zip-архив, он начинается с «PK»
void assert_xlsx (string path) throws Error {
    uint8[] data;
    FileUtils.get_data (path, out data);
    assert_true (data.length > 100);
    assert_true (data[0] == 'P' && data[1] == 'K');
    assert_false (FileUtils.test (@"$path.tmp", FileTest.EXISTS));
}

void test_export_changed () throws Error {
    var db = sample_database ();
    var exporter = new ExcelExporter (db, Path.build_filename (tmp_dir, "Столовая"));

    // Первая выгрузка: файл на каждый учебный год с записями
    // (октябрь 2024 — год 2024–2025, октябрь 2025 — 2025–2026)
    var files = exporter.export_changed ();
    assert_cmpint (files.length, CompareOperator.EQ, 2);
    assert_true (files[0].has_suffix ("/Столовая/столовая_2024-2025.xlsx"));
    assert_true (files[1].has_suffix ("/Столовая/столовая_2025-2026.xlsx"));
    assert_xlsx (files[0]);
    assert_xlsx (files[1]);

    // Ничего не изменилось — ничего не пишется
    assert_cmpint (exporter.export_changed ().length, CompareOperator.EQ, 0);

    // Файл удалили — собирается заново, хотя новых записей нет
    FileUtils.remove (files[0]);
    files = exporter.export_changed ();
    assert_cmpint (files.length, CompareOperator.EQ, 1);
    assert_true (files[0].has_suffix ("/Столовая/столовая_2024-2025.xlsx"));
    assert_xlsx (files[0]);

    // Год можно пересобрать принудительно, даже без записей
    files = exporter.export_changed (2023);
    assert_cmpint (files.length, CompareOperator.EQ, 1);
    assert_xlsx (exporter.file_for_school_year (2023));
}

// Второй файл не записался — при следующей выгрузке пересобираются оба
void test_export_partial_failure () throws Error {
    var db = sample_database ();
    var exporter = new ExcelExporter (db, Path.build_filename (tmp_dir, "Сбой"));
    var blocker = exporter.file_for_school_year (2025);
    DirUtils.create_with_parents (blocker, 0755);  // rename поверх папки не пройдёт
    try {
        exporter.export_changed ();
        assert_not_reached ();
    } catch (ExportError e) {
        assert_true (e is ExportError.FAILED);
    }
    DirUtils.remove (blocker);

    var files = exporter.export_changed ();
    assert_cmpint (files.length, CompareOperator.EQ, 2);
    assert_xlsx (blocker);
}

// Ученика переименовали — его годы пересобираются, хотя новых выдач нет;
// в файле прежнее ФИО зачёркнуто, а у ячейки примечание
void test_export_after_rename () throws Error {
    var db = sample_database ();
    var exporter = new ExcelExporter (db, Path.build_filename (tmp_dir, "Переименование"));
    assert_cmpint (exporter.export_changed ().length, CompareOperator.EQ, 2);

    var student = db.find_student_by_card (2);  // обедал только в 2025–2026
    student.full_name = "Борисов Богдан";
    db.update_student (student);
    var files = exporter.export_changed ();
    assert_cmpint (files.length, CompareOperator.EQ, 1);
    assert_true (files[0].has_suffix ("столовая_2025-2026.xlsx"));
    assert_xlsx (files[0]);
    assert_cmpint (exporter.export_changed ().length, CompareOperator.EQ, 0);

    // В .xlsx (zip) есть примечание с прежним и нынешним ФИО
    string comments;
    Process.spawn_sync (null, { "unzip", "-p", files[0], "xl/comments1.xml" }, null,
        SpawnFlags.SEARCH_PATH, null, out comments);
    assert_true ("Борисов Борис" in comments && "Борисов Богдан" in comments);
}

void test_export_year_bad_directory () throws Error {
    var db = sample_database ();
    var exporter = new ExcelExporter (db, "/proc/нет/Столовая");
    try {
        exporter.export_school_year (2025);
        assert_not_reached ();
    } catch (ExportError e) {
        assert_true (e is ExportError.FAILED);
    }
}

DateTime day (int year, int month, int date, int hour = 8) {
    return new DateTime.local (year, month, date, hour, 0, 0);
}

void test_category_report () throws Error {
    var db = new Database (":memory:");
    var a = db.add_student ("Алексеев Алексей", "5А", 1, "Сироты КРС", true);
    var b = db.add_student ("Борисов Борис", "5Б", 2, "Многодетные (ССЗ)", false);
    var c = db.add_student ("Без льготы", "5А", 3, "КРС нельготная категория", true);
    var d = db.add_student ("Сведения неизвестны", "5Б", 4);
    var e = db.add_student ("Бюджетность неизвестна", "5Б", 5, "Инвалиды ССЗ");
    var f = db.add_student ("Категория неизвестна", "5В", 6, null, false);
    db.record_meal (a, MealType.BREAKFAST, day (2023, 8, 31));  // другой учебный год
    foreach (var id in new int64[] { a, c, e, f }) {
        db.record_meal (id, MealType.BREAKFAST, day (2023, 9, 1));
    }
    foreach (var id in new int64[] { a, b, c, d }) {
        db.record_meal (id, MealType.LUNCH, day (2023, 9, 1, 12));
    }
    db.record_meal (a, MealType.BREAKFAST, day (2023, 9, 2));  // суббота тоже учитывается
    var student = db.find_student_by_card (1);
    student.full_name = "Алексеев Андрей";
    student.group_name = "6А";
    student.benefit_category = "Дети мобилизованных ССЗ";
    student.is_budget = false;
    db.update_student (student);
    db.record_meal (a, MealType.LUNCH, day (2023, 9, 2, 12));
    db.record_meal (b, MealType.BREAKFAST, day (2023, 10, 1));
    db.record_meal (a, MealType.LUNCH, day (2024, 1, 1, 12));
    db.record_meal (a, MealType.BREAKFAST, day (2024, 2, 29));
    db.record_meal (a, MealType.LUNCH, day (2024, 2, 29, 12));
    db.record_meal (b, MealType.BREAKFAST, day (2024, 2, 29));
    db.record_meal (c, MealType.LUNCH, day (2024, 8, 31, 12));
    db.record_meal (a, MealType.LUNCH, day (2024, 9, 1, 12));  // следующий учебный год

    var before = new ExcelExporter (db, Path.build_filename (tmp_dir, "Категории"));
    var before_path = before.export_school_year (2023);
    student.benefit_category = "Сироты (ПП)";
    student.is_budget = true;
    db.update_student (student);
    assert_false (db.record_meal (a, MealType.BREAKFAST, day (2023, 9, 1)));
    var after = new ExcelExporter (db, Path.build_filename (tmp_dir, "Категории после"));
    var after_path = after.export_school_year (2023);

    var source = Environment.get_variable ("G_TEST_SRCDIR") ?? ".";
    string output, errors;
    int status;
    Process.spawn_sync (null, { "python3", Path.build_filename (source, "tests", "verify_category_export.py"),
        before_path, after_path }, null, SpawnFlags.SEARCH_PATH, null, out output, out errors, out status);
    if (status != 0) error ("Проверка отчёта: %s\n%s", output, errors);
}

int main (string[] args) {
    Test.init (ref args);
    try {
        tmp_dir = DirUtils.make_tmp ("stolovaya-export-XXXXXX");
    } catch (FileError e) {
        error ("%s", e.message);
    }
    Test.add_func ("/excel/export-changed", () => wrap (test_export_changed));
    Test.add_func ("/excel/partial-failure", () => wrap (test_export_partial_failure));
    Test.add_func ("/excel/after-rename", () => wrap (test_export_after_rename));
    Test.add_func ("/excel/bad-directory", () => wrap (test_export_year_bad_directory));
    Test.add_func ("/excel/categories-and-snapshots", () => wrap (test_category_report));
    var result = Test.run ();

    foreach (var name in new string[] { "Столовая", "Сбой", "Переименование", "Категории", "Категории после" }) {
        var dir = Path.build_filename (tmp_dir, name);
        foreach (var year in new int[] { 2023, 2024, 2025 }) {
            FileUtils.remove (Path.build_filename (dir, @"столовая_$year-$(year + 1).xlsx"));
        }
        DirUtils.remove (dir);
    }
    DirUtils.remove (tmp_dir);
    return result;
}

delegate void TestBody () throws Error;

void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
