project('Stolovaya', 'vala', 'c',
  version: '0.9.6',
  meson_version: '>= 0.62.0',
)

glib_deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
]
sqlite_dep = dependency('sqlite3')
xlsxwriter_dep = dependency('xlsxwriter')
# Чтение .xlsx при импорте учеников; minizip всё равно нужен libxlsxwriter
minizip_dep = dependency('minizip')
gio_dep = dependency('gio-2.0')
# Posix.open, termios — для последовательного порта считывателя
posix_dep = meson.get_compiler('vala').find_library('posix')

# Тестовые части программы (ручной ввод карточки, --demo-data) — только
# в отладочной сборке: в коде они под #if DEBUG
if get_option('debug')
  add_project_arguments('-D', 'DEBUG', language: 'vala')
endif

gtk_dep = dependency('gtk4')
# gtk_calendar_set_date () — с GTK 4.20, а, например, в Debian 13 GTK 4.18
if gtk_dep.version().version_compare('>= 4.20')
  add_project_arguments('-D', 'GTK_4_20', language: 'vala')
endif

# Свои .vapi для библиотек без привязок к Vala (xlsxwriter)
add_project_arguments('--vapidir', meson.project_source_root() / 'vapi', language: 'vala')

# Переносимая сборка (./build.sh --package): программа
# и .so libadwaita и libxlsxwriter — в одной папке, её путь — prefix
portable = get_option('portable')
app_dir = portable ? get_option('prefix') : get_option('bindir')
# Библиотеки ищутся рядом с программой. DT_RPATH, а не RUNPATH: RUNPATH
# не действует на зависимости библиотек (minizip у libxlsxwriter и т. п.)
app_link_args = portable ? ['-Wl,--disable-new-dtags,-rpath,$ORIGIN'] : []

conf = configuration_data()
conf.set('PORTABLE', portable.to_string())
conf.set_quoted('DATABASE_PATH', meson.project_source_root() / 'canteen.db')
conf.set_quoted('VERSION', meson.project_version())
config_vala = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: conf,
)

# Значок программы встраивается в неё саму (см. src/desktop_entry.vala)
resources = import('gnome').compile_resources('resources',
  'data/stolovaya.gresource.xml',
  source_dir: 'data',
)

# База и её типы — нужны всем, кто собирает src/database.vala
database_sources = files(
  'src/database.vala',
  'src/database_error.vala',
  'src/student.vala',
  'src/meal_type.vala',
  'src/card_read.vala',
  'src/day_record.vala',
  'src/meal_counts.vala',
)

app = executable('Столовая',
  'src/main.vala',
  resources,
  config_vala,
  database_sources,
  'src/excel_export.vala',
  'src/settings.vala',
  'src/styles.vala',
  'src/main_window_ui.vala',
  'src/window.vala',
  'src/settings_dialog_ui.vala',
  'src/settings_dialog.vala',
  'src/history_panel_ui.vala',
  'src/history_panel.vala',
  'src/xlsx_reader.vala',
  'src/students_import.vala',
  'src/system_setup.vala',
  'src/card_reader.vala',
  'src/file_users.vala',
  'src/desktop_entry.vala',
  'src/reader_state.vala',
  dependencies: [
    glib_deps,
    sqlite_dep,
    xlsxwriter_dep,
    minizip_dep,
    gio_dep,
    posix_dep,
    gtk_dep,
    dependency('libadwaita-1', version: '>= 1.6'),
  ],
  link_args: app_link_args,
  install: true,
  install_dir: app_dir,
)

if portable
  meson.add_install_script('tools/bundle-libs.sh', app)
endif

test('card-reader', executable('test-card-reader',
  config_vala,
  'src/system_setup.vala',
  'src/card_read.vala',
  'src/card_reader.vala',
  'src/reader_state.vala',
  'tests/test_card_reader.vala',
  dependencies: [glib_deps, gio_dep, posix_dep],
))

test('database', executable('test-database',
  database_sources,
  'tests/test_database.vala',
  dependencies: [glib_deps, sqlite_dep],
))

test('excel-export', executable('test-excel-export',
  database_sources,
  'src/excel_export.vala',
  'tests/test_excel_export.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep, posix_dep],
))

test('students-import', executable('test-students-import',
  database_sources,
  'src/xlsx_reader.vala',
  'src/students_import.vala',
  'tests/test_students_import.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep, minizip_dep],
))

test('settings', executable('test-settings',
  database_sources,
  'src/settings.vala',
  'tests/test_settings.vala',
  dependencies: [glib_deps, sqlite_dep],
))

test('file-users', executable('test-file-users',
  'src/file_users.vala',
  'tests/test_file_users.vala',
  dependencies: [glib_deps, posix_dep],
))

# Пример выгрузки на выдуманных данных: ./build/demo-excel [папка]
executable('demo-excel',
  database_sources,
  'src/excel_export.vala',
  'tools/demo_excel.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep, posix_dep],
)
