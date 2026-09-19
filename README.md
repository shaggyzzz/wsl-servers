# WSL Laravel & Caddy Servers Manager

Удобный инструмент для запуска нескольких проектов Laravel из WSL с доступом по коротким доменным именам с поддержкой HTTPS (`https://shop.test/`, `https://crm.test/`).

---

## 📁 Файлы в этой папке

* **`projects.json`** — ваша персональная конфигурация проектов, портов, доменов и БД (в `.gitignore`).
* **`projects.example.json`** — файл-пример со всеми возможными вариантами настроек для быстрого копирования.
* **`.gitignore`** — исключает ваш личный `projects.json` и логи из репозитория.
* **`menu.bat`** — запуск интерактивного консольного меню (рекомендуется).
* **`start.bat`** — быстрый запуск всех серверов в 1 клик.
* **`stop.bat`** — быстрая остановка всех серверов в 1 клик.
* **`status.bat`** — проверка статуса серверов и баз данных.
* **`add-hosts.bat`** — добавление доменов в Windows hosts и доверие SSL-сертификату Caddy (запуск от имени администратора).
* **`manage-servers.ps1`** — основной движок на PowerShell.

---

## 🚀 Быстрый старт

### 1. Установка Caddy в WSL (выполняется один раз)
Откройте терминал Ubuntu в WSL и выполните:
```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

#### Важно для порта 80:
Чтобы Caddy мог слушать 80-й порт от обычного пользователя (без `sudo`), выполните в WSL:
```bash
sudo setcap 'cap_net_bind_service=+ep' $(which caddy)
```

---

### 2. Настройка проектов в `projects.json`
Откройте `projects.json` в любом редакторе и настройте свои проекты:

```json
{
  "wsl_distro": "Ubuntu",
  "wsl_user": "username",
  "projects": [
    {
      "name": "shop",
      "domain": "shop.test",
      "path": "/home/username/shop",
      "port": 8001,
      "queue": true,
      "schedule": true,
      "database": {
        "type": "docker",
        "container": "mysql-shop",
        "auto_start": true
      }
    },
    {
      "name": "crm",
      "domain": "crm.test",
      "path": "/home/username/crm",
      "port": 8002,
      "queue": true,
      "database": {
        "type": "port",
        "port": 3306,
        "name": "MySQL"
      }
    }
  ]
}
```

#### Параметры проектов:
* `"queue": true` — запускает фоновый воркер очередей `php artisan queue:listen --tries=3`. (Для dev-режима `queue:listen` перечитывает код при каждом задании без перезапуска!).
* `"schedule": true` — запускает встроенный планировщик задач `php artisan schedule:work` (каждую минуту проверяет и выполняет запланированные задачи).
* `"database"`:
  * `"type": "docker"` — проверяет запущен ли Docker контейнер. Если `"auto_start": true`, скрипт сам выполнит `docker start <container>`.
  * `"type": "port"` — проверяет доступность порта (например `3306` для MySQL, `5432` для Postgres).
  * Если проект не требует БД, поле `database` можно удалить.

#### Защита от распухания логов:
* Логи пишутся в `~/.wsl-servers/logs/`.
* При перезапуске сервисов лог начинается заново.
* Если любой лог-файл превышает **5 МБ**, он автоматически обрезается до **последних 2000 строк**.
* В меню доступен пункт **`[8] Clear all logs`** для моментальной очистки всех логов.

---

### 3. Записи в Windows `hosts`
Чтобы браузер понимал домены вроде `shop.test`, они должны вести на `127.0.0.1`.
* Запустите `menu.bat` и нажмите **[6]** — скрипт сам предложит добавить недостающие домены в `C:\Windows\System32\drivers\etc\hosts`.

---

### 4. Запуск и работа
* Запустите **`menu.bat`** (или дважды кликните **`start.bat`**).
* Серверы запустятся в фоне.
* Логи каждого проекта сохраняются в WSL в каталоге `~/.wsl-servers/logs/<project_name>.log`.
