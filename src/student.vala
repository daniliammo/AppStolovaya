public class Student {
    // Категории из «лЬГОТЫ.xlsx»: исправлены регистр и незакрытые скобки.
    public const string[] BENEFIT_CATEGORIES = {
        "Сироты КРС",
        "Сироты ССЗ",
        "Сироты (ПП)",
        "Многодетные (КРС)",
        "Многодетные КРС 18+",
        "Многодетные (ССЗ)",
        "Многодетные ССЗ 18+",
        "Многодетные (ПП)",
        "Инвалиды (КРС)",
        "Инвалиды ССЗ",
        "Инвалиды (ПП)",
        "Дети мобилизованных КРС",
        "Дети мобилизованных ССЗ",
        "КРС нельготная категория"
    };

    public int64 id;
    public int64? card_uid;  // null — карточка ещё не привязана
    public string full_name;
    public string group_name;
    public string? benefit_category;  // null — категория ещё не указана
    public bool? is_budget;  // true — бюджет, false — не бюджет, null — ещё не указано
}
