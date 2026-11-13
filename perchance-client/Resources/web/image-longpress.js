// Долгое нажатие на картинку -> предложить сохранить её в «Фото».
//
// Картинка конвертируется в data:-URL, потому что:
//  - blob:-ссылки нативному коду недоступны;
//  - сторонние CDN могут не отдать файл без куки/Referer, а fetch идёт
//    из контекста страницы, где куки уже есть.
// Если fetch не удался (CORS), отправляем исходный URL — нативная часть
// скачает его сама через NSURLSession.
(function () {
    'use strict';

    if (window.__perchanceImageLongPress) {
        return;
    }
    window.__perchanceImageLongPress = true;

    var LONG_PRESS_MS = 600;
    var MOVE_LIMIT_SQ = 100; // 10 pt в квадрате

    var timer = null;
    var startX = 0;
    var startY = 0;
    var target = null;

    function clearTimer() {
        if (timer !== null) {
            clearTimeout(timer);
            timer = null;
        }
    }

    function reset() {
        clearTimer();
        target = null;
    }

    function post(payload) {
        try {
            window.webkit.messageHandlers.pcimage.postMessage(payload);
        } catch (error) {
            // Обработчика нет — работаем как обычная страница.
        }
    }

    function sendSource(src, alt) {
        if (!src) {
            return;
        }
        if (src.indexOf('data:') === 0) {
            post({ type: 'image', src: src, alt: alt || '' });
            return;
        }
        if (typeof fetch !== 'function' || typeof FileReader !== 'function') {
            post({ type: 'image', src: src, alt: alt || '' });
            return;
        }
        fetch(src, { credentials: 'include' }).then(function (response) {
            if (!response.ok) {
                throw new Error('HTTP ' + response.status);
            }
            return response.blob();
        }).then(function (blob) {
            var reader = new FileReader();
            reader.onloadend = function () {
                post({ type: 'image', src: reader.result || src, alt: alt || '' });
            };
            reader.onerror = function () {
                post({ type: 'image', src: src, alt: alt || '' });
            };
            reader.readAsDataURL(blob);
        }).then(null, function () {
            post({ type: 'image', src: src, alt: alt || '' });
        });
    }

    document.addEventListener('touchstart', function (event) {
        var element = event.target;
        if (!element || element.tagName !== 'IMG' || !element.src || event.touches.length !== 1) {
            reset();
            return;
        }
        clearTimer();
        startX = event.touches[0].clientX;
        startY = event.touches[0].clientY;
        target = element;
        timer = setTimeout(function () {
            timer = null;
            var image = target;
            target = null;
            if (!image) {
                return;
            }
            sendSource(image.currentSrc || image.src, image.alt);
        }, LONG_PRESS_MS);
    }, true);

    document.addEventListener('touchmove', function (event) {
        if (timer === null) {
            return;
        }
        if (event.touches.length !== 1) {
            reset();
            return;
        }
        var dx = event.touches[0].clientX - startX;
        var dy = event.touches[0].clientY - startY;
        if (dx * dx + dy * dy > MOVE_LIMIT_SQ) {
            reset();
        }
    }, true);

    document.addEventListener('touchend', reset, true);
    document.addEventListener('touchcancel', reset, true);
    window.addEventListener('scroll', reset, true);
})();
