# Окружение для 32-битной сборки (i386). В Ubuntu нет i386-пакетов
# libadwaita и libxlsxwriter, поэтому собираем в Debian, где они есть.
FROM i386/debian:trixie

# IPv4: при неработающем IPv6 apt подолгу висит на адресах deb.debian.org
RUN printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "5";\n' \
      > /etc/apt/apt.conf.d/90network \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc \
      meson \
      ninja-build \
      pkg-config \
      valac \
      libglib2.0-dev \
      libgtk-4-dev \
      libadwaita-1-dev \
      libsqlite3-dev \
      libxlsxwriter-dev \
      libminizip-dev \
 && rm -rf /var/lib/apt/lists/*
