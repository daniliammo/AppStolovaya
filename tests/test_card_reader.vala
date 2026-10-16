// Тесты разбора строк считывателя EM-Marine. Запуск: meson test -C build

void test_parse_card () {
    // Строка, снятая с настоящего считывателя
    var card = CardRead.parse ("Em-Marine[5500] 120,09886\r");
    assert_nonnull (card);
    assert_cmpstr (card.card_type, CompareOperator.EQ, "Em-Marine");
    assert_cmpstr (card.code, CompareOperator.EQ, "5500");
    assert_cmpint (card.series, CompareOperator.EQ, 120);
    assert_cmpint (card.number, CompareOperator.EQ, 9886);
    assert_true (card.uid == 120 * 65536 + 9886);  // 7874206
    assert_cmpstr (card.raw, CompareOperator.EQ, "Em-Marine[5500] 120,09886");
}

void test_parse_mifare () {
    var card = CardRead.parse ("Mifare[658E6180045D85] 004,23941 UL (0144,00)\r");
    assert_nonnull (card);
    assert_cmpstr (card.card_type, CompareOperator.EQ, "Mifare");
    assert_cmpstr (card.code, CompareOperator.EQ, "658E6180045D85");
    assert_true (card.uid == 4 * 65536 + 23941);

    card = CardRead.parse ("Mifare[01020304] 003,00513  (0004,20)");
    assert_nonnull (card);
    assert_true (card.uid == 3 * 65536 + 513);
}

void test_parse_bounds () {
    assert_true (CardRead.parse ("Em-Marine[0000] 255,65535").uid == 0xFFFFFF);
    assert_true (CardRead.parse ("Em-Marine[0000] 000,00000").uid == 0);
    assert_null (CardRead.parse ("Em-Marine[5500] 256,00001"));  // серия больше байта
    assert_null (CardRead.parse ("Em-Marine[5500] 1,65536"));    // номер больше 16 бит
}

void test_parse_other_lines () {
    assert_null (CardRead.parse ("No card"));
    assert_null (CardRead.parse (""));
    assert_null (CardRead.parse ("Em-Marine 120,09886"));
    assert_null (CardRead.parse ("\xf8\x98\xfe мусор"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/card-reader/parse-card", test_parse_card);
    Test.add_func ("/card-reader/parse-mifare", test_parse_mifare);
    Test.add_func ("/card-reader/parse-bounds", test_parse_bounds);
    Test.add_func ("/card-reader/parse-other-lines", test_parse_other_lines);
    return Test.run ();
}
