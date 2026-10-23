public errordomain DatabaseError {
    OPEN,
    QUERY,
    // Нарушено ограничение: номер карточки уже занят, пустое ФИО и т.п.
    CONSTRAINT,
    // Базу держит другая программа (DB Browser с незаписанными изменениями)
    BUSY
}
