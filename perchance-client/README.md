# Perchance для iOS 12 (iPad/iPhone, джейлбрейк)

Нативное приложение-клиент: открывает [perchance.org](https://perchance.org) целиком,
но переписывает современный JavaScript под Safari 12 на лету — поэтому интерфейс
сайта (меню, редактор, генераторы, аккаунт) работает, хотя обычный Safari на iOS 12
падает на первом `?.`.

> Неофициальный клиент. Не связан с Perchance. Используйте на свой риск.

---

## Зачем это нужно

Причина «пустого интерфейса» на iOS 12:

| Файл perchance.org | Проблема |
|---|---|
| `appExtras.js` (~300 КБ, строит интерфейс) | 195 × `?.`, `??`, `replaceAll`, `AbortSignal.timeout` |
| `perchance-engine.js` | в целом ES2017, но есть `?.` внутри `eval`-шаблонов |
| разметка страницы | `AbortSignal.timeout`, `visualViewport`, `aspect-ratio`, `inset`, `light-dark()` |

`?.` — **синтаксическая** ошибка для Safari 12. Полифилл не спасает: файл
даже не парсится. Значит, код нужно переписать **до** того, как он попадёт в
WebKit. Это и делает приложение:

```
perchance.org  ──►  PCProxy (Objective-C)
                       │  скачивает файл через NSURLSession
                       ▼
                    PCJSTranspiler (WKWebView + Babel)
                       │  ES2015+ → ES2018, CSS-фолбэки, HTML-полифилы
                       ▼
                    WKWebView (ваш iPad) показывает готовую страницу
```

Никакого сервера, никакого компьютера, никакого DNS — **всё внутри приложения**.

---

## Что открывается

По умолчанию приложение работает в режиме **«Встроенный»**:

- адресная строка вверху (как в Safari), кнопки «назад» и «обновить»;
- всё, что открывает сам Perchance (меню, редактор, страница генератора,
  iframe с генератором), грузится через свой же обработчик схемы;
- кэш переписанных файлов в `Library/Caches/PCProxyCache` — второй запуск
  открывается за секунду.

Ограничение встроенного режима (особенность iOS, не баг сборки): сайт живёт
в адресном пространстве `wk://pc/…`, а не `https://perchance.org`. Из-за этого:

- вход в аккаунт: cookie сохраняются, но `localStorage` привязан к `wk://`;
- «открыть в новой вкладке» во внешнем Safari не сработает;
- сторонние приложения сайт не видят.

Если нужен настоящий `https://perchance.org` и для других приложений —
есть **системный режим** (см. ниже), он требует больше настройки.

---

## Установка (готовый .deb)

1. Скачайте `com.w3rn1ght.perchance_1.0.0_iphoneos-arm.deb` из **Actions** / **Releases**.
2. Установите через Sileo/Zebra/Cydia («Install from file») или Filza (тап по .deb → Install).
3. Если иконки нет — `uicache` или respring.

Удаление: `dpkg -r com.w3rn1ght.perchance`.

Требования:

- джейлбрейк на iOS **12.0–12.5.7** (unc0ver, checkra1n, Chimera);
- rootful-бутстрап (`iphoneos-arm`), arm64;
- ~5 МБ свободного места (Babel лежит в бандле).

---

## Сборка

### GitHub Actions

Workflow `.github/workflows/build.yml` собирает пакет на `macos-15`:
push в `main` → артефакт `perchance-deb`, тег `v*` → Release.

### Локально на macOS

```sh
brew install ldid xz
export THEOS=$HOME/theos
git clone --recursive https://github.com/theos/theos.git "$THEOS"

# SDK iOS 12.4
git clone --depth=1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/theos-sdks
cd /tmp/theos-sdks && git sparse-checkout set iPhoneOS12.4.sdk
mkdir -p "$THEOS/sdks" && cp -R iPhoneOS12.4.sdk "$THEOS/sdks/"

cd perchance-client
make package FINALPACKAGE=1
```

Готовый файл: `packages/com.w3rn1ght.perchance_1.0.0_iphoneos-arm.deb`.

---

## Структура

```
perchance-client/
├── Makefile                      # Theos; веб-ядро копируется из ../perchance-ios12/lib
├── control
├── Resources/
│   ├── Info.plist
│   └── web/
│       ├── bridge.html           # «мозг»: грузит Babel, отвечает на transformJS/patchCSS
│       ├── babel.min.js          # @babel/standalone 7.28
│       ├── transform-web.js      # тот же трансформер, что у Node-прокси
│       ├── polyfills.js          # ES5-полифилы для Safari 12
│       └── legacy.js             # рантайм-заплатки (aspect-ratio, 100vh, …)
└── Sources/
    ├── main.m
    ├── PCAppDelegate.{h,m}       # сборка зависимостей и запуск
    ├── PCJSTranspiler.{h,m}      # скрытый WKWebView с Babel + bridge
    ├── PCProxy.{h,m}             # загрузка perchance.org, кэш, переписывание
    ├── PCTranspilerProtocolHandler.{h,m}  # WKURLSchemeHandler для wk://
    ├── PCMainViewController.{h,m}         # адресная строка + WKWebView
    ├── PCDNSServer.{h,m}         # локальный DNS (системный режим)
    └── PCHttpProxy.{h,m}         # HTTPS 443 (системный режим, PC_SYSTEM_MODE=1)
```

Ключевые решения:

- **Схема `wk://` вместо `https://`.** Так WKWebView заходит в наш обработчик
  на iOS 12 без сертификата. HTML отдаётся через `loadHTMLString` с адресом
  `wk://pc/<host>/<path>` — поэтому относительные ссылки остаются внутри прокси.
- **Babel в отдельном WKWebView.** WebKit не умеет перехватывать тела ответов,
  поэтому трансформер живёт в «своём» окне, а страницу отдаём уже готовой.
- **Файлы не переписываются дважды.** Результат кладётся в дисковый кэш по SHA-1.
- **Полифилы грузятся первыми.** Скрипты страницы статически помечены
  `type="x-pc-pending"` (см. `transform-web.js`) и «оживляются» после полифилов.

---

## Системный режим (настоящий https://perchance.org)

Нужен, если хотите, чтобы сайт открывался и в Safari, и в других приложениях.
Требует:

1. **CA-сертификат** на `perchance.org` + `*.perchance.org` (генерируется
   командой `make-cert.bat` / `node make-cert.js` из проекта `perchance-ios12`,
   затем `certs/ca.crt` ставится в iOS: Настройки → Профиль → Установить →
   «Доверие сертификатам»).
2. `cert.pem` и `key.pem` положить в
   `Library/Application Support/Perchance/` на устройстве.
3. Пересобрать с `PC_SYSTEM_MODE=1` (`export ADDITIONAL_CFLAGS=-DPC_SYSTEM_MODE=1`).
4. Запустить приложение с правами root (в джейлбрейке — обычный запуск
   из `/Applications` уже root).

В этом режиме поднимаются `PCHttpProxy` (HTTPS на 127.0.0.1:443) и
`PCDNSServer` (DNS на 127.0.0.1:53). Модель iOS 12: DNS → 127.0.0.1 →
HTTPS → переписанный ответ.

> Сборка системного режима в репозитории — каркас: TLS-сессия
> (SecureTransport) и разбор HTTP подключаются в `PCHttpProxy.m`,
> весь остальной код (прокси, трансформер, кэш) уже готов.
> Если системный режим не нужен — просто не включайте `PC_SYSTEM_MODE`.

---

## Проверка трансформера без айпада

В соседнем проекте `perchance-ios12` есть Node-версия того же ядра и
браузерная самопроверка:

```sh
cd perchance-ios12
start.bat                     # сервер (нужен, чтобы отдать файлы)
# затем в браузере: http://127.0.0.1:8443/__legacy/selftest.html
```

Самопроверка прогоняет `?.`, `??`, приватные поля, `static {}`, CSS
(`inset`, `aspect-ratio`), HTML (CSP + inline-скрипты) и печатает
`N ok, M fail`. Сейчас: **8 ok, 0 fail**.

---

## Известные ограничения

- Первый запуск: ~3 МБ Babel грузится в WKWebView (1–3 сек на iPad с iOS 12).
  Дальше — из бандла, без сети.
- Редактор Perchance (CodeMirror/Monaco-подобный) может ругаться на
  отсутствующие в iOS 12 API; базовое редактирование работает, «красивости»
  (сворачивание кода) — нет.
- Cloudflare на perchance.org пускает только «браузерные» запросы.
  Приложение отправляет браузерный `User-Agent`, но если Cloudflare
  поднимет защиту — страница придёт с «Just a moment…». Это проверяется
  на устройстве; серверный тест (`node probe.js`) показывает, что
  HTTP/2 + браузерные заголовки проходят.
- Аккаунт/логин: cookie работают, но привязаны к схеме `wk://`.

---

## Лицензия

Код клиента — MIT. `babel.min.js` — MIT (© Babel contributors),
`core-js-bundle.js` — MIT (© Denis Pushkarev), polyfills — собственные.
