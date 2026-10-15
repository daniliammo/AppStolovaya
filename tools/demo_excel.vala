// Пример Excel-выгрузки на выдуманных данных, чтобы посмотреть, как выглядит файл.
// Данные живут только в памяти, настоящая база (canteen.db) не трогается.
//
//   ./build/demo-excel [папка]   (по умолчанию ~/Документы/Столовая/Пример)

const string[,] STUDENTS = {
    { "Алексеев Артём Дмитриевич", "5А" },
    { "Белова Анна Сергеевна", "5А" },
    { "Васильев Максим Игоревич", "5А" },
    { "Григорьева Софья Андреевна", "5А" },
    { "Дмитриев Иван Олегович", "5А" },
    { "Егорова Полина Викторовна", "5Б" },
    { "Жуков Матвей Алексеевич", "5Б" },
    { "Зайцева Виктория Павловна", "5Б" },
    { "Иванов Кирилл Романович", "5Б" },
    { "Ковалёва Дарья Михайловна", "5Б" },
    { "Лебедев Никита Сергеевич", "6А" },
    { "Морозова Алиса Денисовна", "6А" },
    { "Новиков Егор Владимирович", "6А" },
    { "Орлова Ксения Ильинична", "6А" },
    { "Павлов Тимофей Андреевич", "6А" }
};

int main (string[] args) {
    var directory = args.length > 1
        ? args[1]
        : Path.build_filename (ExcelExporter.default_directory (), "Пример");

    try {
        var db = new Database (":memory:");
        int64[] ids = {};
        for (int i = 0; i < STUDENTS.length[0]; i++) {
            ids += db.add_student (STUDENTS[i, 0], STUDENTS[i, 1], i + 1);
        }

        // Будни с 1 сентября текущего учебного года по сегодня
        var today = new DateTime.now_local ();
        var school_year = Database.school_year_of (today);
        var rand = new Rand.with_seed (2026);  // одинаковый результат при каждом запуске
        for (var day = new DateTime.local (school_year, 9, 1, 0, 0, 0);
             day.compare (today) <= 0;
             day = day.add_days (1)) {
            if (day.get_day_of_week () > 5) {
                continue;  // суббота и воскресенье
            }
            foreach (var id in ids) {
                if (rand.next_double () < 0.85) {
                    db.record_meal (id, MealType.BREAKFAST, day.add_minutes (8 * 60 + rand.int_range (0, 40)));
                }
                if (rand.next_double () < 0.75) {
                    db.record_meal (id, MealType.LUNCH, day.add_minutes (12 * 60 + rand.int_range (0, 60)));
                }
            }
        }

        var exporter = new ExcelExporter (db, directory);
        print ("%s\n", exporter.export_school_year (school_year));
    } catch (Error e) {
        printerr ("Ошибка: %s\n", e.message);
        return 1;
    }
    return 0;
}
