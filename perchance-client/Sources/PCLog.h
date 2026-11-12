#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Файловый лог приложения.
///
/// Зачем: на iOS 12 без Cydia нельзя посмотреть консоль, а crash-репорты
/// системы лежат в /var/mobile/Library/Logs/CrashReporter и часто недоступны.
/// Поэтому пишем свой лог в Documents/PerchanceLogs и показываем его прямо
/// в приложении при следующем запуске, если прошлый сеанс завершился аварийно.

/// Открыть новую сессию лога. Вызывать самым первым делом в main().
/// Если прошлая сессия не отметилась как «чистое завершение», её лог
/// сохраняется как previous.log и потом показывается на экране.
FOUNDATION_EXPORT void PCLogBeginSession(void);

/// Поставить обработчики исключений и фатальных сигналов (SIGSEGV/SIGABRT/…).
FOUNDATION_EXPORT void PCLogInstallCrashHandlers(void);

FOUNDATION_EXPORT void PCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void PCLogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Записать текущее потребление памяти (для диагностики jetsam).
FOUNDATION_EXPORT void PCLogMemory(NSString *tag);

/// Отметить, что сессия идёт (флаг «приложение работает»).
FOUNDATION_EXPORT void PCLogMarkRunning(void);

/// Отметить чистое завершение (приложение ушло в фон / закрылось штатно).
FOUNDATION_EXPORT void PCLogMarkCleanExit(void);

/// Лог аварийно завершившейся сессии или nil, если прошлый запуск был чистым.
FOUNDATION_EXPORT NSString * _Nullable PCLogPreviousCrashText(void);

FOUNDATION_EXPORT NSString *PCLogDirectoryPath(void);
FOUNDATION_EXPORT NSString *PCLogSessionPath(void);

/// Очистить накопленные логи (кнопка «Очистить» на экране лога).
FOUNDATION_EXPORT void PCLogClearAll(void);

NS_ASSUME_NONNULL_END
