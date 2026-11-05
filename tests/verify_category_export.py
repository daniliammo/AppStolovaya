"""Check the generated workbook, including cached numeric values, using only stdlib."""

import calendar
import collections
import posixpath
import sys
import xml.etree.ElementTree as ET
import zipfile

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
MONTHS = ["Сентябрь", "Октябрь", "Ноябрь", "Декабрь", "Январь", "Февраль",
          "Март", "Апрель", "Май", "Июнь", "Июль", "Август"]
CATEGORIES = ["Сироты КРС", "Сироты ССЗ", "Сироты (ПП)", "Многодетные (КРС)",
              "Многодетные КРС 18+", "Многодетные (ССЗ)", "Многодетные ССЗ 18+",
              "Многодетные (ПП)", "Инвалиды (КРС)", "Инвалиды ССЗ", "Инвалиды (ПП)",
              "Дети мобилизованных КРС", "Дети мобилизованных ССЗ",
              "КРС нельготная категория", "Категория не указана"]
GROUPS = ["БЮДЖЕТ", "НЕ БЮДЖЕТ (ВБ)", "БЮДЖЕТНОСТЬ НЕ УКАЗАНА"]


def coordinate(ref):
    letters = ref.rstrip("0123456789")
    col = 0
    for letter in letters:
        col = col * 26 + ord(letter) - ord("A") + 1
    return int(ref[len(letters):]), col - 1


def read_book(path):
    sheets = {}
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        strings = ["".join(t.itertext()) for t in shared.findall("s:si", NS)]
        relations = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        targets = {r.attrib["Id"]: r.attrib["Target"] for r in relations}
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        for sheet in workbook.findall("s:sheets/s:sheet", NS):
            target = targets[sheet.attrib[f"{{{REL}}}id"]]
            target = target.lstrip("/") if target.startswith("/") else posixpath.join("xl", target)
            root = ET.fromstring(archive.read(target))
            values = {}
            for cell in root.findall("s:sheetData/s:row/s:c", NS):
                value = cell.find("s:v", NS)
                if value is not None:
                    values[coordinate(cell.attrib["r"])] = (
                        strings[int(value.text)] if cell.attrib.get("t") == "s" else int(float(value.text))
                    )
            sheets[sheet.attrib["name"]] = values, root
    return sheets


def category_rows(grid, root):
    rows = {}
    for merge in root.findall("s:mergeCells/s:mergeCell", NS):
        start, end = map(coordinate, merge.attrib["ref"].split(":"))
        if start[1] == end[1] == 1:
            group = grid[start]
            assert group in GROUPS
            for row in range(start[0], end[0] + 1):
                rows[group, grid[row, 2]] = row
    assert set(rows) == {(group, category) for group in GROUPS for category in CATEGORIES}
    return rows


# (month in school year, meal, budget group, category, calendar day) -> actual issues.
expected = collections.Counter()


def issue(month, meal, group, category, day):
    expected[month, meal, GROUPS[group], category, day] += 1


for meal in [0, 1]:
    issue(0, meal, 0, "Сироты КРС", 1)
    issue(0, meal, 0, "КРС нельготная категория", 1)
issue(0, 0, 2, "Инвалиды ССЗ", 1)
issue(0, 0, 1, "Категория не указана", 1)
issue(0, 1, 1, "Многодетные (ССЗ)", 1)
issue(0, 1, 2, "Категория не указана", 1)
issue(0, 0, 0, "Сироты КРС", 2)
issue(0, 1, 1, "Дети мобилизованных ССЗ", 2)
issue(1, 0, 1, "Многодетные (ССЗ)", 1)
issue(4, 1, 1, "Дети мобилизованных ССЗ", 1)
for meal in [0, 1]:
    issue(5, meal, 1, "Дети мобилизованных ССЗ", 29)
issue(5, 0, 1, "Многодетные (ССЗ)", 29)
issue(11, 1, 0, "КРС нельготная категория", 31)


def check_book(book):
    report_names = {"Категории за год"}
    for month, title in enumerate(MONTHS):
        year, calendar_month = (2023 if month < 4 else 2024), (month + 8) % 12 + 1
        day_count = calendar.monthrange(year, calendar_month)[1]
        for meal, meal_name in enumerate(["завтраки", "обеды"]):
            name = f"{title} {year} {meal_name}"
            report_names.add(name)
            grid, root = book[name]
            rows = category_rows(grid, root)
            assert [grid[4, day + 2] for day in range(1, day_count + 1)] == list(range(1, day_count + 1))
            assert grid[4, day_count + 3] == "Дето/дни"
            assert (4, day_count + 4) not in grid
            for (group, category), row in rows.items():
                for day in range(1, day_count + 1):
                    assert grid[row, day + 2] == expected[month, meal, group, category, day], (name, group, category, day)
                assert grid[row, day_count + 3] == sum(grid[row, d + 2] for d in range(1, day_count + 1))
            for label, predicate in [
                *[(f"Итого: {group}", lambda g, c, target=group: g == target) for group in GROUPS],
                ("Итого льготное питание", lambda g, c: c not in CATEGORIES[-2:]),
                ("Итого нельготное питание", lambda g, c: c == CATEGORIES[-2]),
                ("Категория не указана", lambda g, c: c == CATEGORIES[-1]),
                (f"Всего: {meal_name}", lambda g, c: True),
            ]:
                row = next(r for (r, c), value in grid.items() if c == 0 and value == label)
                for day in range(1, day_count + 1):
                    count = sum(v for (m, t, g, c, d), v in expected.items()
                                if m == month and t == meal and d == day and predicate(g, c))
                    assert grid[row, day + 2] == count, (name, label, day)
                assert grid[row, day_count + 3] == sum(grid[row, d + 2] for d in range(1, day_count + 1))
            pane = root.find("s:sheetViews/s:sheetView/s:pane", NS)
            assert pane.attrib["topLeftCell"] == "D5"
            assert root.find("s:pageSetup", NS).attrib["orientation"] == "landscape"

    annual, root = book["Категории за год"]
    for (group, category), row in category_rows(annual, root).items():
        for meal in [0, 1]:
            count = sum(v for (m, t, g, c, d), v in expected.items() if t == meal and g == group and c == category)
            assert annual[row, 3 + meal] == count
        assert annual[row, 5] == annual[row, 3] + annual[row, 4]
    year_row = next(r for (r, c), value in annual.items() if c == 0 and value == "Всего за учебный год")
    assert [annual[year_row, col] for col in [3, 4, 5]] == [8, 8, 16]

    daily_totals = [0, 0]
    for name, (grid, _) in book.items():
        if name[:2].isdigit():
            assert name.endswith(("2023", "2024"))
            for (row, col), value in grid.items():
                if col == 0 and value == "Итого":
                    daily_totals[0] += grid[row, 3]
                    daily_totals[1] += grid[row, 4]
    assert daily_totals == [8, 8]
    assert "31.08.2023" not in book and "01.09.2024" not in book
    september, _ = book["02.09.2023"]
    rows = [r for (r, c), v in september.items() if c == 2 and v == "02.09.2023"]
    assert len(rows) == 2  # состояние поменялось между завтраком и обедом
    assert [(september[r, 3], september[r, 4], september[r, 5], september[r, 6]) for r in rows] == [
        ("08:00", "—", "Сироты КРС", "Бюджет"),
        ("—", "12:00", "Дети мобилизованных ССЗ", "Не бюджет (ВБ)"),
    ]
    assert "Алексеев Алексей" in september[rows[0], 0] and "5А" in september[rows[0], 1]
    assert "Алексеев Андрей" in september[rows[1], 0] and "6А" in september[rows[1], 1]
    february, _ = book["29.02.2024"]
    assert len([v for (r, c), v in february.items() if c == 2 and v == "29.02.2024"]) == 2
    summary, _ = book["Итого"]
    row = next(r for (r, c), v in summary.items() if c == 0 and v == "Всего за учебный год")
    assert [summary[row, 1], summary[row, 2]] == daily_totals
    return report_names


before, after = map(read_book, sys.argv[1:3])
report_names = check_book(before)
assert report_names == check_book(after)
for name in report_names:
    assert before[name][0] == after[name][0], f"Historical report changed: {name}"
print("Monthly reports, annual totals, daily snapshots and historical stability OK.")
