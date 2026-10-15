project('hello-gtk4', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.62.0',
)

glib_deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
]
sqlite_dep = dependency('sqlite3')

executable('hello-gtk4',
  'src/main.vala',
  'src/database.vala',
  'src/main_window_ui.vala',
  'src/window.vala',
  dependencies: [
    glib_deps,
    sqlite_dep,
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
