project('hello-gtk4', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.62.0',
)

glib_deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
]
sqlite_dep = dependency('sqlite3')
xlsxwriter_dep = dependency('xlsxwriter')
gio_dep = dependency('gio-2.0')
# Posix.open, termios — для последовательного порта считывателя
posix_dep = meson.get_compiler('vala').find_library('posix')

# Тестовые части программы (ручной ввод карточки, --demo-data) — только
# в отладочной сборке: в коде они под #if DEBUG
if get_option('debug')
  add_project_arguments('-D', 'DEBUG', language: 'vala')
endif

gtk_dep = dependency('gtk4')
# gtk_calendar_set_date () — с GTK 4.20; в 32-битной сборке (Debian) GTK 4.18
if gtk_dep.version().version_compare('>= 4.20')
  add_project_arguments('-D', 'GTK_4_20', language: 'vala')
endif

# Свои .vapi для библиотек без привязок к Vala (xlsxwriter)
add_project_arguments('--vapidir', meson.project_source_root() / 'vapi', language: 'vala')

conf = configuration_data()
conf.set_quoted('DATABASE_PATH', meson.project_source_root() / 'canteen.db')
conf.set_quoted('SETUP_PROGRAM', meson.project_build_root() / 'stolovaya-setup')
config_vala = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: conf,
)

executable('hello-gtk4',
  'src/main.vala',
  config_vala,
  'src/database.vala',
  'src/excel_export.vala',
  'src/settings.vala',
  'src/styles.vala',
  'src/main_window_ui.vala',
  'src/window.vala',
  'src/settings_dialog_ui.vala',
  'src/settings_dialog.vala',
  'src/history_dialog_ui.vala',
  'src/history_dialog.vala',
  'src/system_setup.vala',
  'src/card_reader.vala',
  dependencies: [
    glib_deps,
    sqlite_dep,
    xlsxwriter_dep,
    gio_dep,
    posix_dep,
    gtk_dep,
    dependency('libadwaita-1', version: '>= 1.5'),
  ],
  install: true,
)

test('card-reader', executable('test-card-reader',
  config_vala,
  'src/system_setup.vala',
  'src/card_reader.vala',
  'tests/test_card_reader.vala',
  dependencies: [glib_deps, gio_dep, posix_dep],
))

test('database', executable('test-database',
  'src/database.vala',
  'tests/test_database.vala',
  dependencies: [glib_deps, sqlite_dep],
))

test('excel-export', executable('test-excel-export',
  'src/database.vala',
  'src/excel_export.vala',
  'tests/test_excel_export.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep],
))

test('settings', executable('test-settings',
  'src/database.vala',
  'src/settings.vala',
  'tests/test_settings.vala',
  dependencies: [glib_deps, sqlite_dep],
))

# Настройка системы под считыватель, запускается программой через pkexec
executable('stolovaya-setup',
  'tools/setup_system.vala',
  dependencies: [glib_deps, posix_dep],
)

# Пример выгрузки на выдуманных данных: ./build/demo-excel [папка]
executable('demo-excel',
  'src/database.vala',
  'src/excel_export.vala',
  'tools/demo_excel.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep],
)
