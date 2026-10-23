// Дата и время хранятся строками в местном времени:
// дата 'YYYY-MM-DD', время 'HH:MM:SS'. Их можно сравнивать как строки.

// Кто и когда получил питание в выбранный день (для истории и выгрузки)
public class DayRecord {
    public Student student;       // каким ученик записан в базе сейчас
    public string? breakfast_at;  // 'HH:MM:SS' или null, если не получал
    public string? lunch_at;
    // ФИО и группа в день выдачи — их могли поменять после
    public string issued_name;
    public string issued_group;

    public bool name_changed {
        get { return issued_name != student.full_name; }
    }

    public bool group_changed {
        get { return issued_group != student.group_name; }
    }

    // Почему ФИО или группа показаны дважды (подсказка в окне, примечание
    // в Excel); null — ничего не меняли
    public string? change_note () {
        string[] lines = {};
        if (name_changed) {
            lines += @"ФИО изменили после выдачи: в день выдачи — «$issued_name», сейчас — «$(student.full_name)».";
        }
        if (group_changed) {
            lines += @"Группу изменили после выдачи: в день выдачи — «$issued_group», сейчас — «$(student.group_name)».";
        }
        if (lines.length == 0) {
            return null;
        }
        lines += "Зачёркнуто — как было в день выдачи.";
        return string.joinv ("\n", lines);
    }
}
