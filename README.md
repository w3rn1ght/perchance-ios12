# Perchance для iOS 12 — два варианта

Здесь два независимых решения одной проблемы: **perchance.org не грузит интерфейс
на iOS 12, потому что Safari 12 не понимает `?.`, `??` и `class { #private }`**.

| Проект | Что это | Когда нужен |
|---|---|---|
| [`perchance-ios12/`](./perchance-ios12) | Node-прокси для ПК/ноутбука | Быстро проверить, что всё работает; если iPhone/iPad в одной Wi-Fi с ПК |
| [`perchance-client/`](./perchance-client) | **iOS-приложение (.deb)**, всё внутри айпада | Основной вариант: ничего дополнительного не требуется, другие устройства не участвуют |

Оба проекта используют **одно и то же ядро** (`perchance-ios12/lib/web/transform-web.js`),
поэтому правки в трансформере автоматически подхватываются приложением
(см. `copy:web` в Makefile).

---

## Как это работает

```
   perchance.org
        │  (JS с ?. , ?? , #private , CSS aspect-ratio/inset/light-dark)
        ▼
 ┌───────────────────────┐
 │  Транспайлер (Babel)  │  ES2015+ → ES2018 (target: Safari 12)
 │  + CSS-фолбэки        │  inset → top/right/bottom/left, gap → grid-gap,
 │  + полифилы           │  ResizeObserver, AbortSignal.timeout, visualViewport…
 └───────────────────────┘
        │  уже совместимый код
        ▼
   WKWebView (Safari 12) — интерфейс Perchance работает как обычно
```

---

## Вариант 1: приложение на айпаде (рекомендуется)

См. [`perchance-client/README.md`](./perchance-client/README.md).

Коротко:

1. Скачать `com.w3rn1ght.perchance_1.0.0_iphoneos-arm.deb` из Actions/Releases.
2. Установить через Sileo/Zebra/Cydia или Filza.
3. Открыть — приложение само прогреет Babel (~3 МБ, один раз) и покажет
   `perchance.org/welcome` с адресной строкой, кнопками «назад/обновить».

Никакого DNS, сертификатов и ПК. Все запросы идут через `wk://`, страницы
отдаются после переписывания (см. `PCProxy.m` + `PCTranspilerProtocolHandler.m`).

---

## Вариант 2: прокси на компьютере

См. [`perchance-ios12/README.md`](./perchance-ios12/README.md).

Коротко:

```bat
cd perchance-ios12
start.bat            :: или: node server.js
node selftest.js     :: проверка: 8 проверок, всё должно быть OK
```

На iPhone: открыть `http://<IP-ПК>:8443/` — там кнопка скачать сертификат
и инструкция по DNS.

Полезные команды:

```bat
node diag.js      :: может ли этот компьютер вообще достать perchance.org
node probe.js     :: Cloudflare: HTTP/2 против HTTP/1.1
node selftest.js  :: реально ли прокси переписал appExtras.js под Safari 12
```

---

## Проверка без устройства

В обоих вариантах используется одна и та же функция `PCTransform.transformHTML`.
Её можно проверить в любом браузере (в том числе в Safari на iOS 12):

```
http://127.0.0.1:8443/__legacy/selftest.html
```

Сейчас самопроверка выдаёт **8 ok, 0 fail**: `?.`, `??`, `??=`, `||=`, `&&=`,
`#private`, `static {}`, CSS-фолбэки, HTML-полифилы и inline-скрипты.

---

## Что именно ломалось (диагностика)

```
appExtras.js (298 КБ — строит меню, модалки, сохранение)
   195 × ?.        ← синтаксическая ошибка для Safari 12
     2 × ??        ← то же
     + replaceAll, fromEntries, Promise.allSettled, AbortSignal.timeout,
       ResizeObserver, visualViewport …

perchance-engine.js (115 КБ — движок генераторов)
   в целом ES2017, но `?.` встречается внутри eval-шаблонов

HTML страницы
   AbortSignal.timeout, navigator.connection?.saveData, CSS.supports,
   aspect-ratio, inset, light-dark()
```

Полифилами это не лечится: файл с `?.` не парсится, движок JS падает
на этапе синтаксического анализа до выполнения любого кода.
Поэтому нужна транспиляция до попадания в WebKit — это и есть суть проекта.

---

## Лицензия

Код — MIT. `babel.min.js` — MIT (© Babel contributors),
`core-js-bundle.js` — MIT (© Denis Pushkarev).
