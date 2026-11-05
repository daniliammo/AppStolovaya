// Выгрузка журнала выдачи в Excel: один файл на учебный год, с 1 сентября
// по 31 августа (столовая_2026-2027.xlsx): общие итоги, категории за год,
// месячные отчёты по завтракам и обедам и ежедневные поимённые листы.
//
// libxlsxwriter не умеет дописывать в существующий файл, поэтому файл года
// каждый раз собирается заново из базы: сначала во временный файл, затем
// заменяет старый одной операцией rename, чтобы при сбое старый файл уцелел.
// Ручные правки в файле при этом пропадают — об этом сказано на каждом листе.

public errordomain ExportError {
    FAILED
}

public class ExcelExporter {
    // Первая строка каждого листа, над шапкой таблицы
    public const string NOTE = "Этот файл программа «Столовая» собирает заново из своей базы "
        + "при каждой выгрузке — ручные правки в нём будут удалены.";

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
        return Path.build_filename (directory, @"столовая_$school_year-$(school_year + 1).xlsx");
    }

    // Пересобрать файлы учебных лет, где после прошлой выгрузки были новые
    // записи или файла нет (удалили, перенесли), и (если with_school_year != 0)
    // файл этого года в любом случае.
    // Возвращает пути записанных файлов; пусто — выгружать было нечего.
    public GenericArray<string> export_changed (int with_school_year = 0) throws Error {
        // Запомнить до выгрузки: всё, что новее, попадёт в следующую
        var last_meal = database.last_meal_id ();
        var last_queued = database.last_queued_id ();
        var years = database.changed_school_years ();
        foreach (var year in database.meal_school_years ()) {
            if (!(year in years) && !FileUtils.test (file_for_school_year (year), FileTest.EXISTS)) {
                years += year;
            }
        }
        if (with_school_year != 0 && !(with_school_year in years)) {
            years += with_school_year;
        }

        var written = new GenericArray<string> ();
        foreach (var year in years) {
            written.add (export_school_year (year));
        }
        // Отметка — только когда записаны все файлы: если второй файл не
        // записался, его год иначе больше не считался бы изменённым
        if (written.length > 0) {
            var now = new DateTime.now_local ();
            database.mark_exported (now, written[written.length - 1], now, last_meal, last_queued);
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
        var tmp_path = @"$path.tmp";
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
        header.set_text_wrap ();

        unowned var total = workbook.add_format ();
        total.set_bold ();
        total.set_top (Xlsx.Border.THIN);

        unowned var centered = workbook.add_format ();
        centered.set_align (Xlsx.Align.CENTER);

        // ФИО или группа, которые поменяли после выдачи: как было в тот день
        unowned var struck = workbook.add_format ();
        struck.set_font_strikeout ();
        struck.set_font_color (0x808080);

        unowned var note = workbook.add_format ();
        note.set_italic ();
        note.set_font_color (0xC00000);
        note.set_text_wrap ();
        note.set_align (Xlsx.Align.VERTICAL_CENTER);

        // Лист «Итого»: строка на каждый день
        unowned var summary = add_sheet (workbook, "Итого");
        summary.set_column (0, 0, 22);
        summary.set_column (1, 2, 12);
        write_note (summary, 2, 3, note);
        write_row (summary, 1, { "Дата", "Завтраков", "Обедов" }, header);

        var days = database.meal_days (school_year);
        var categories = new CategoryReport ();
        int year_breakfasts = 0, year_lunches = 0;
        unowned Xlsx.Worksheet last_sheet = summary;

        for (uint i = 0; i < days.length; i++) {
            var date = parse_date (days[i]);
            var title = date.format ("%d.%m.%Y");
            var records = database.day_records (date);
            foreach (var record in records) {
                categories.add (date, record);
            }

            unowned var sheet = add_sheet (workbook, title);
            var counts = write_day_sheet (sheet, title, records, header, total, centered, note, struck);
            last_sheet = sheet;

            summary.write_string (i + 2, 0, title);
            summary.write_number (i + 2, 1, counts.breakfasts);
            summary.write_number (i + 2, 2, counts.lunches);
            year_breakfasts += counts.breakfasts;
            year_lunches += counts.lunches;
        }

        var total_row = days.length + 2;
        summary.write_string (total_row, 0, days.length > 0 ? "Всего за учебный год" : "Выдачи не было", total);
        summary.write_number (total_row, 1, year_breakfasts, total);
        summary.write_number (total_row, 2, year_lunches, total);

        write_category_reports (workbook, school_year, categories, note);

        // При открытии файла показываем последний день
        last_sheet.activate ();
    }

    // Лист одного дня: кто и когда получил питание, внизу итог
    private MealCounts write_day_sheet (Xlsx.Worksheet sheet, string date,
                                        GenericArray<DayRecord> records,
                                        Xlsx.Format header, Xlsx.Format total,
                                        Xlsx.Format centered, Xlsx.Format note, Xlsx.Format struck) {
        // Прежнее и нынешнее ФИО вместе в 36 знаков не влезают — ширина
        // по самой длинной строке
        double name_width = 36, group_width = 10;
        foreach (var record in records) {
            name_width = double.max (name_width, shown_width (record.issued_name, record.student.full_name));
            group_width = double.max (group_width, shown_width (record.issued_group, record.student.group_name));
            foreach (var state in new StudentState?[] { record.breakfast_state, record.lunch_state }) {
                if (state != null) {
                    name_width = double.max (name_width, shown_width (state.full_name, record.student.full_name));
                    group_width = double.max (group_width, shown_width (state.group_name, record.student.group_name));
                }
            }
        }
        sheet.set_column (0, 0, name_width);
        sheet.set_column (1, 1, group_width);
        sheet.set_column (2, 2, 12, centered);
        sheet.set_column (3, 4, 10, centered);
        sheet.set_column (5, 5, 32);
        sheet.set_column (6, 6, 17);
        sheet.set_landscape ();
        sheet.set_paper (9);  // A4
        sheet.fit_to_pages (1, 0);  // печать: все столбцы на одной странице по ширине
        write_note (sheet, 6, 2, note);
        write_row (sheet, 1, { "ФИО", "Группа", "Дата", "Завтрак", "Обед", "Категория на момент выдачи", "Бюджетность на момент выдачи" }, header);
        sheet.set_row (1, 32);
        sheet.repeat_rows (0, 1);

        MealCounts counts = { 0, 0 };
        uint32 row = 2;
        foreach (var record in records) {
            var breakfast = record.breakfast_state;
            var lunch = record.lunch_state;
            // Если между завтраком и обедом сведения поменялись, две строки
            // показывают оба состояния, каждая со своим временем выдачи.
            if (breakfast != null && lunch != null && same_state (breakfast, lunch)) {
                write_day_row (sheet, row++, date, record.student, breakfast,
                    record.breakfast_at, record.lunch_at, struck);
            } else {
                if (breakfast != null) {
                    write_day_row (sheet, row++, date, record.student, breakfast, record.breakfast_at, null, struck);
                }
                if (lunch != null) {
                    write_day_row (sheet, row++, date, record.student, lunch, null, record.lunch_at, struck);
                }
            }
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

    private static bool same_state (StudentState a, StudentState b) {
        return a.full_name == b.full_name && a.group_name == b.group_name
            && a.benefit_category == b.benefit_category && a.is_budget == b.is_budget;
    }

    private static void write_day_row (Xlsx.Worksheet sheet, uint32 row, string date, Student current,
                                       StudentState state, string? breakfast, string? lunch, Xlsx.Format struck) {
        write_row (sheet, row, { "", "", date, short_time (breakfast), short_time (lunch),
            state.benefit_category ?? "Не указана", budget_name (state.is_budget) });
        write_changed (sheet, row, 0, state.full_name, current.full_name, struck);
        write_changed (sheet, row, 1, state.group_name, current.group_name, struck);
        var change = new DayRecord () {
            student = current, issued_name = state.full_name, issued_group = state.group_name
        };
        var message = change.change_note ();
        if (message != null) {
            sheet.write_comment (row, 0, message, Xlsx.CommentOptions () { width = 320, height = 90 });
        }
    }

    private static string budget_name (bool? budget) {
        return budget == null ? "Не указана" : budget ? "Бюджет" : "Не бюджет (ВБ)";
    }

    private const string[] MONTHS = {
        "Сентябрь", "Октябрь", "Ноябрь", "Декабрь", "Январь", "Февраль",
        "Март", "Апрель", "Май", "Июнь", "Июль", "Август"
    };

    private void write_category_reports (Xlsx.Workbook workbook, int school_year,
                                          CategoryReport report, Xlsx.Format note) throws ExportError {
        unowned var header = workbook.add_format ();
        header.set_bold ();
        header.set_bg_color (0x234E70);
        header.set_font_color (0xFFFFFF);
        header.set_border (Xlsx.Border.THIN);
        header.set_align (Xlsx.Align.CENTER);
        header.set_align (Xlsx.Align.VERTICAL_CENTER);
        header.set_text_wrap ();

        unowned var cell = workbook.add_format ();
        cell.set_border (Xlsx.Border.THIN);
        cell.set_align (Xlsx.Align.CENTER);
        cell.set_align (Xlsx.Align.VERTICAL_CENTER);
        cell.set_font_size (10);

        unowned var label = workbook.add_format ();
        label.set_border (Xlsx.Border.THIN);
        label.set_text_wrap ();
        label.set_align (Xlsx.Align.VERTICAL_CENTER);
        label.set_font_size (10);

        unowned var budget = workbook.add_format ();
        budget.set_border (Xlsx.Border.THIN);
        budget.set_bold ();
        budget.set_bg_color (0xF0F5FA);
        budget.set_align (Xlsx.Align.CENTER);
        budget.set_align (Xlsx.Align.VERTICAL_CENTER);
        budget.set_rotation (90);

        unowned var total = workbook.add_format ();
        total.set_border (Xlsx.Border.THIN);
        total.set_bg_color (0xDCEEDF);
        total.set_bold ();
        total.set_align (Xlsx.Align.CENTER);
        total.set_align (Xlsx.Align.VERTICAL_CENTER);
        total.set_text_wrap ();

        unowned var title = workbook.add_format ();
        title.set_bold ();
        title.set_font_size (18);
        title.set_font_color (0x17365D);
        title.set_align (Xlsx.Align.CENTER);

        write_category_sheet (workbook, school_year, -1, 0, report, header, cell, label, budget, total, title, note);
        for (int month = 0; month < 12; month++) {
            for (int meal = 0; meal < 2; meal++) {
                write_category_sheet (workbook, school_year, month, meal, report, header, cell, label, budget, total, title, note);
            }
        }
    }

    // Месяц: № | Бюджетность | Категория | 1 .. последний день | Дето/дни.
    // Год:   № | Бюджетность | Категория | Завтраков | Обедов | Всего.
    private void write_category_sheet (Xlsx.Workbook workbook, int school_year, int month, int meal,
                                       CategoryReport report, Xlsx.Format header, Xlsx.Format cell,
                                       Xlsx.Format label, Xlsx.Format budget, Xlsx.Format total,
                                       Xlsx.Format title, Xlsx.Format note) throws ExportError {
        var annual = month < 0;
        var year = month < 4 ? school_year : school_year + 1;
        var month_date = annual ? null : new DateTime.local (year, (month + 8) % 12 + 1, 1, 0, 0, 0);
        var day_count = annual ? 0 : month_date.add_months (1).add_days (-1).get_day_of_month ();
        var meal_name = meal == 0 ? "завтраки" : "обеды";
        var name = annual ? "Категории за год" : @"$(MONTHS[month]) $year $meal_name";
        unowned var sheet = add_sheet (workbook, name);
        uint16 last_col = annual ? 5 : (uint16) (day_count + 3);
        sheet.set_column (0, 0, 5);
        sheet.set_column (1, 1, annual ? 20 : 6);
        sheet.set_column (2, 2, 32);
        sheet.set_column (3, last_col, annual ? 18 : 4.5, cell);
        sheet.set_column (last_col, last_col, annual ? 23 : 12);
        write_note (sheet, last_col, annual ? 2 : 1, note);
        sheet.merge_range (1, 0, 1, last_col,
            annual ? @"Отчёт по категориям за $school_year–$(school_year + 1) учебный год"
                   : @"$(MONTHS[month]) $year — $meal_name", title);
        sheet.set_row (1, 30);
        sheet.merge_range (2, 0, 2, last_col,
            "Фактически выданное питание. Сведения о студенте — на момент каждой выдачи; неизвестные значения учтены отдельно.", label);
        sheet.set_row (2, annual ? 30 : 20);
        write_row (sheet, 3, { "№", annual ? "Бюджетность" : "Б / ВБ", "Категория" }, header);
        if (annual) {
            sheet.write_string (3, 3, "Завтраков", header);
            sheet.write_string (3, 4, "Обедов", header);
            sheet.write_string (3, 5, "Всего приёмов пищи", header);
        } else {
            for (int day = 1; day <= day_count; day++) {
                sheet.write_number (3, (uint16) (day + 2), day, header);
            }
            sheet.write_string (3, last_col, "Дето/дни", header);
        }
        sheet.set_row (3, 32);

        uint32 row = 4;
        for (int group = 0; group < 3; group++) {
            var group_name = group == 0 ? "БЮДЖЕТ" : group == 1 ? "НЕ БЮДЖЕТ (ВБ)" : "БЮДЖЕТНОСТЬ НЕ УКАЗАНА";
            var first_row = row;
            for (int category = 0; category < report.category_count; category++) {
                sheet.set_row (row, 28);
                sheet.write_number (row, 0, category + 1, cell);
                sheet.write_string (row, 2, category < Student.BENEFIT_CATEGORIES.length
                    ? Student.BENEFIT_CATEGORIES[category] : "Категория не указана", label);
                write_category_numbers (sheet, row, report, month, meal, day_count, group, category, category, cell, total);
                row++;
            }
            sheet.merge_range (first_row, 1, row - 1, 1, group_name, budget);
            write_category_total (sheet, row++, @"Итого: $group_name", report, month, meal, day_count, group, 0, report.category_count - 1, total);
        }
        write_category_total (sheet, row++, "Итого льготное питание", report, month, meal, day_count,
            -1, 0, Student.BENEFIT_CATEGORIES.length - 2, total);
        write_category_total (sheet, row++, "Итого нельготное питание", report, month, meal, day_count,
            -1, Student.BENEFIT_CATEGORIES.length - 1, Student.BENEFIT_CATEGORIES.length - 1, total);
        write_category_total (sheet, row++, "Категория не указана", report, month, meal, day_count,
            -1, report.category_count - 1, report.category_count - 1, total);
        write_category_total (sheet, row++, annual ? "Всего за учебный год" : @"Всего: $meal_name", report,
            month, meal, day_count, -1, 0, report.category_count - 1, total);

        sheet.merge_range (row + 1, 0, row + 1, last_col, "Социальный педагог: __________________________", label);
        sheet.merge_range (row + 2, 0, row + 2, last_col, "Заместитель директора по УВР: __________________________", label);
        sheet.set_row (row + 1, 25);
        sheet.set_row (row + 2, 25);
        sheet.freeze_panes (4, 3);
        sheet.repeat_rows (0, 3);
        sheet.set_landscape ();
        sheet.set_paper (annual ? 9 : 8);  // A4 / A3, как в образце
        sheet.fit_to_pages (1, 0);
    }

    private static void write_category_total (Xlsx.Worksheet sheet, uint32 row, string text, CategoryReport report,
                                              int month, int meal, int days, int budget, int first, int last,
                                              Xlsx.Format total) {
        sheet.merge_range (row, 0, row, 2, text, total);
        sheet.set_row (row, 28);
        write_category_numbers (sheet, row, report, month, meal, days, budget, first, last, total, total);
    }

    private static void write_category_numbers (Xlsx.Worksheet sheet, uint32 row, CategoryReport report,
                                                int month, int meal, int days, int budget, int first, int last,
                                                Xlsx.Format cell, Xlsx.Format total) {
        if (month < 0) {
            var breakfasts = sum (report.counts_for (-1, 0, budget, first, last));
            var lunches = sum (report.counts_for (-1, 1, budget, first, last));
            sheet.write_number (row, 3, breakfasts, cell);
            sheet.write_number (row, 4, lunches, cell);
            sheet.write_number (row, 5, breakfasts + lunches, total);
        } else {
            var counts = report.counts_for (month, meal, budget, first, last);
            for (int day = 0; day < days; day++) {
                sheet.write_number (row, (uint16) (day + 3), counts[day], cell);
            }
            sheet.write_number (row, (uint16) (days + 3), sum (counts), total);
        }
    }

    private static int sum (int[] values) {
        int result = 0;
        foreach (var value in values) result += value;
        return result;
    }

    // Предупреждение NOTE в первой строке на ширину таблицы (столбцы 0..last_col).
    // Высоту строки Excel для объединённых ячеек сам не подбирает — задаём
    // по числу строк текста. Предупреждение и шапка закреплены при прокрутке.
    // Справа от таблицы оно попало бы в печать и fit_to_pages ужал бы таблицу,
    // а область печати libxlsxwriter пишет без кавычек вокруг имени листа
    // «01.09.2026», и LibreOffice её не понимает.
    private static void write_note (Xlsx.Worksheet sheet, uint16 last_col, int lines, Xlsx.Format note) {
        sheet.merge_range (0, 0, 0, last_col, NOTE, note);
        sheet.set_row (0, 15 * lines + 3);
        sheet.freeze_panes (2, 0);
    }

    // Ширина столбца (в знаках) под то, что пишет write_changed, с запасом:
    // кириллица шире латиницы, по которой Excel считает знаки
    private static double shown_width (string then, string now) {
        var length = then == now ? now.char_count () : then.char_count () + 1 + now.char_count ();
        return length * 1.1 + 2;
    }

    // Нынешнее значение, а если в день выдачи было другое — перед ним
    // прежнее, зачёркнутое серым
    private static void write_changed (Xlsx.Worksheet sheet, uint32 row, uint16 col,
                                       string then, string now, Xlsx.Format struck) {
        if (then == now) {
            sheet.write_string (row, col, now);
            return;
        }
        var rest = @" $now";
        var old_part = Xlsx.RichString () { format = struck, text = then };
        var new_part = Xlsx.RichString () { format = null, text = rest };
        Xlsx.RichString*[] parts = { &old_part, &new_part, null };
        sheet.write_rich_string (row, col, parts);
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

// Счётчики строятся из снимков выдач, а не из нынешних карточек студентов.
private class CategoryReport {
    public int category_count { get { return Student.BENEFIT_CATEGORIES.length + 1; } }
    private int[] counts;

    public CategoryReport () {
        counts = new int[12 * 2 * 3 * category_count * 31];
    }

    private int index (int month, int meal, int budget, int category, int day) {
        return ((((month * 2 + meal) * 3 + budget) * category_count + category) * 31) + day;
    }

    public void add (DateTime date, DayRecord record) {
        add_state (date, 0, record.breakfast_state);
        add_state (date, 1, record.lunch_state);
    }

    private void add_state (DateTime date, int meal, StudentState? state) {
        if (state == null) return;
        int category = category_count - 1;
        for (int i = 0; i < Student.BENEFIT_CATEGORIES.length; i++) {
            if (state.benefit_category == Student.BENEFIT_CATEGORIES[i]) {
                category = i;
                break;
            }
        }
        var budget = state.is_budget == null ? 2 : state.is_budget ? 0 : 1;
        counts[index ((date.get_month () + 3) % 12, meal, budget, category, date.get_day_of_month () - 1)]++;
    }

    public int[] counts_for (int month, int meal, int budget, int first_category, int last_category) {
        var result = new int[31];
        for (int m = month < 0 ? 0 : month; m <= (month < 0 ? 11 : month); m++) {
            for (int b = budget < 0 ? 0 : budget; b <= (budget < 0 ? 2 : budget); b++) {
                for (int c = first_category; c <= last_category; c++) {
                    for (int day = 0; day < 31; day++) {
                        result[day] += counts[index (m, meal, b, c, day)];
                    }
                }
            }
        }
        return result;
    }
}
