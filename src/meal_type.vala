public enum MealType {
    BREAKFAST,
    LUNCH;

    // встроенный to_string() вернет такое MEAL_TYPE_BREAKFAST поэтому метод написан вручную
    public string to_db () {
        return this == BREAKFAST ? "breakfast" : "lunch";
    }
}
