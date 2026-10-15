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

# Свои .vapi для библиотек без привязок к Vala (xlsxwriter)
add_project_arguments('--vapidir', meson.project_source_root() / 'vapi', language: 'vala')

conf = configuration_data()
conf.set_quoted('DATABASE_PATH', meson.project_source_root() / 'canteen.db')
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
  'src/main_window_ui.vala',
  'src/window.vala',
  dependencies: [
    glib_deps,
    sqlite_dep,
    xlsxwriter_dep,
    dependency('gtk4'),
    dependency('libadwaita-1', version: '>= 1.5'),
  ],
  install: true,
)

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

# Пример выгрузки на выдуманных данных: ./build/demo-excel [папка]
executable('demo-excel',
  'src/database.vala',
  'src/excel_export.vala',
  'tools/demo_excel.vala',
  dependencies: [glib_deps, sqlite_dep, xlsxwriter_dep],
)
