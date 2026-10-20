// Выгрузка журнала выдачи в Excel: один файл на учебный год, с 1 сентября
// по 30 июня (столовая_2026-2027.xlsx), в нём лист «Итого» и по листу
// на каждый день выдачи. Учебный год обозначается годом начала: 2026 — это 2026–2027.
//
// libxlsxwriter не умеет дописывать в существующий файл, поэтому файл года
// каждый раз собирается заново из базы: сначала во временный файл, затем
// заменяет старый одной операцией rename, чтобы при сбое старый файл уцелел.

public errordomain ExportError {
    FAILED
}

public class ExcelExporter {
    private Database database;

    // Папка, куда пишутся файлы
    public string directory { get; private set; }

    public ExcelExporter (Database database, string directory) {
        this.database = database;
        this.directory = directory;
    }

    // ~/Документы/Столовая (папка «Документы» — из настроек XDG)
    public static string default_directory () {
        var documents = Environment.get_user_special_dir (UserDirectory.DOCUMENTS)
            ?? Path.build_filename (Environment.get_home_dir (), "Documents");
        return Path.build_filename (documents, "Столовая");
    }

    public string file_for_school_year (int school_year) {
        return Path.build_filename (directory, "столовая_%d-%d.xlsx".printf (school_year, school_year + 1));
    }

    // Пересобрать файлы учебных лет, где после прошлой выгрузки были новые
    // записи, и (если with_school_year != 0) файл этого года в любом случае.
    // Возвращает пути записанных файлов; пусто — выгружать было нечего.
    public GenericArray<string> export_changed (int with_school_year = 0) throws Error {
        var years = database.changed_school_years ();
        if (with_school_year != 0 && !(with_school_year in years)) {
            years += with_school_year;
        }

        var now = new DateTime.now_local ();
        var written = new GenericArray<string> ();
        foreach (var year in years) {
            var path = export_school_year (year);
            database.mark_exported (now, path, now);
            written.add (path);
        }
        return written;
    }

    // Собрать файл учебного года заново. Возвращает путь к файлу.
    public string export_school_year (int school_year) throws Error {
        if (DirUtils.create_with_parents (directory, 0755) != 0) {
            throw new ExportError.FAILED ("Не удалось создать папку %s: %s",
                directory, strerror (errno));
        }

        var path = file_for_school_year (school_year);
        var tmp_path = path + ".tmp";
        var workbook = Xlsx.Workbook.create (tmp_path);
        if (workbook == null) {
            throw new ExportError.FAILED ("Не удалось создать файл %s", tmp_path);
        }

        try {
            write_workbook (workbook, school_year);
        } catch (Error e) {
            workbook.close ();
            FileUtils.remove (tmp_path);
            throw e;
        }

        var result = workbook.close ();
        if (result != Xlsx.Error.NO_ERROR) {
            FileUtils.remove (tmp_path);
            throw new ExportError.FAILED ("Не удалось записать %s: %s", path, result.to_string ());
        }
        // Сначала данные на диск, потом rename: иначе при отключении питания
        // на месте файла мог бы остаться пустой, а в базе — отметка о выгрузке
        try {
            sync_to_disk (tmp_path, Posix.O_RDONLY);
        } catch (ExportError e) {
            FileUtils.remove (tmp_path);
            throw e;
        }
        if (FileUtils.rename (tmp_path, path) != 0) {
            var message = strerror (errno);
            FileUtils.remove (tmp_path);
            throw new ExportError.FAILED ("Не удалось заменить %s: %s", path, message);
        }
        // Сама замена — запись в папке
        sync_to_disk (directory, Posix.O_RDONLY | Posix.O_DIRECTORY);
        return path;
    }

    private static void sync_to_disk (string path, int flags) throws ExportError {
        var fd = Posix.open (path, flags);
        if (fd < 0 || Posix.fsync (fd) != 0) {
            var message = strerror (errno);
            if (fd >= 0) {
                Posix.close (fd);
            }
            throw new ExportError.FAILED ("Не удалось записать на диск %s: %s", path, message);
        }
        Posix.close (fd);
    }

    private void write_workbook (Xlsx.Workbook workbook, int school_year) throws Error {
        unowned var header = workbook.add_format ();
        header.set_bold ();
        header.set_bg_color (0xDDEBF7);
        header.set_bottom (Xlsx.Border.THIN);

        unowned var total = workbook.add_format ();
        total.set_bold ();
        total.set_top (Xlsx.Border.THIN);

        unowned var centered = workbook.add_format ();
        centered.set_align (Xlsx.Align.CENTER);

        // Лист «Итого»: строка на каждый день
        unowned var summary = add_sheet (workbook, "Итого");
        summary.set_column (0, 0, 22);
        summary.set_column (1, 2, 12);
        summary.freeze_panes (1, 0);
        write_row (summary, 0, { "Дата", "Завтраков", "Обедов" }, header);

        var days = database.meal_days (school_year);
        int year_breakfasts = 0, year_lunches = 0;
        unowned Xlsx.Worksheet last_sheet = summary;

        for (uint i = 0; i < days.length; i++) {
            var date = parse_date (days[i]);
            var title = date.format ("%d.%m.%Y");
            var records = database.day_records (date);

            unowned var sheet = add_sheet (workbook, title);
            var counts = write_day_sheet (sheet, title, records, header, total, centered);
            last_sheet = sheet;

            summary.write_string (i + 1, 0, title);
            summary.write_number (i + 1, 1, counts.breakfasts);
            summary.write_number (i + 1, 2, counts.lunches);
            year_breakfasts += counts.breakfasts;
            year_lunches += counts.lunches;
        }

        var total_row = days.length + 1;
        summary.write_string (total_row, 0, days.length > 0 ? "Всего за учебный год" : "Выдачи не было", total);
        summary.write_number (total_row, 1, year_breakfasts, total);
        summary.write_number (total_row, 2, year_lunches, total);

        // При открытии файла показываем последний день
        last_sheet.activate ();
    }

    // Лист одного дня: кто и когда получил питание, внизу итог
    private MealCounts write_day_sheet (Xlsx.Worksheet sheet, string date,
                                        GenericArray<DayRecord> records,
                                        Xlsx.Format header, Xlsx.Format total,
                                        Xlsx.Format centered) {
        sheet.set_column (0, 0, 36);
        sheet.set_column (1, 1, 10);
        sheet.set_column (2, 2, 12, centered);
        sheet.set_column (3, 4, 10, centered);
        sheet.freeze_panes (1, 0);
        sheet.fit_to_pages (1, 0);  // печать: все столбцы на одной странице по ширине
        write_row (sheet, 0, { "ФИО", "Группа", "Дата", "Завтрак", "Обед" }, header);

        MealCounts counts = { 0, 0 };
        uint32 row = 1;
        foreach (var record in records) {
            write_row (sheet, row++, {
                record.student.full_name,
                record.student.group_name,
                date,
                short_time (record.breakfast_at),
                short_time (record.lunch_at)
            });
            if (record.breakfast_at != null) {
                counts.breakfasts++;
            }
            if (record.lunch_at != null) {
                counts.lunches++;
            }
        }

        write_row (sheet, row, { "Итого", "", "" }, total);
        sheet.write_number (row, 3, counts.breakfasts, total);
        sheet.write_number (row, 4, counts.lunches, total);
        return counts;
    }

    private static unowned Xlsx.Worksheet add_sheet (Xlsx.Workbook workbook, string name) throws ExportError {
        unowned var sheet = workbook.add_worksheet (name);
        if (sheet == null) {
            throw new ExportError.FAILED ("Не удалось добавить лист «%s»", name);
        }
        return sheet;
    }

    private static void write_row (Xlsx.Worksheet sheet, uint32 row, string[] values, Xlsx.Format? format = null) {
        for (int col = 0; col < values.length; col++) {
            sheet.write_string (row, (uint16) col, values[col], format);
        }
    }

    // 'HH:MM:SS' → 'HH:MM', нет отметки → «—»
    private static string short_time (string? time) {
        return time == null ? "—" : time.substring (0, 5);
    }

    // 'YYYY-MM-DD' → полночь этого дня по местному времени
    private static DateTime parse_date (string date) throws ExportError {
        var parts = date.split ("-");
        if (parts.length != 3) {
            throw new ExportError.FAILED ("Неверная дата в базе: %s", date);
        }
        return new DateTime.local (int.parse (parts[0]), int.parse (parts[1]), int.parse (parts[2]), 0, 0, 0);
    }
}
