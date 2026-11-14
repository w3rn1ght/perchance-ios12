#import "PCLogViewController.h"
#import "PCLog.h"

@interface PCLogViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic, strong) UIButton *clipboardButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *diagnosticsButton;
@end

@implementation PCLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"Прошлый запуск завершился вылетом";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.text = @"Это лог последних секунд работы. Скопируйте его "
                          @"и пришлите разработчику, если приложение снова упадёт.";
    self.hintLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.hintLabel];

    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.textView.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    self.textView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.layer.cornerRadius = 8;
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    self.textView.text = self.logText ?: @"(лог пуст)";
    [self.view addSubview:self.textView];

    self.clipboardButton = [self buttonWithTitle:@"Копировать" action:@selector(copyLogTapped)];
    self.clearButton = [self buttonWithTitle:@"Очистить" action:@selector(clearLog)];
    self.continueButton = [self buttonWithTitle:@"Продолжить" action:@selector(continueTapped)];
    self.continueButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.44 blue:0.88 alpha:1];
    [self.view addSubview:self.clipboardButton];
    [self.view addSubview:self.clearButton];
    [self.view addSubview:self.continueButton];

    self.diagnosticsButton = [self buttonWithTitle:@"Проверить runtime-hooks" action:@selector(diagnosticsTapped)];
    self.diagnosticsButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.55 blue:0.33 alpha:1];
    [self.view addSubview:self.diagnosticsButton];

    PCLog(@"лог показан пользователю (%lu символов)", (unsigned long)self.logText.length);
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    button.tintColor = [UIColor whiteColor];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat margin = 16;
    CGFloat buttonHeight = 42;
    CGFloat gap = 10;
    CGFloat bottomInset = 20;
    if (@available(iOS 11.0, *)) {
        bottomInset = self.view.safeAreaInsets.bottom + 10;
    }

    CGFloat y = 28;
    if (@available(iOS 11.0, *)) {
        y = self.view.safeAreaInsets.top + 16;
    }

    self.titleLabel.frame = CGRectMake(margin, y, width - margin * 2, 44);
    y += 44;
    self.hintLabel.frame = CGRectMake(margin, y, width - margin * 2, 46);
    y += 46 + 10;

    CGFloat buttonsY = height - bottomInset - buttonHeight;
    self.continueButton.frame = CGRectMake(margin, buttonsY, width - margin * 2, buttonHeight);

    CGFloat half = (width - margin * 2 - gap) / 2.0;
    CGFloat smallY = buttonsY - gap - 36;
    self.clipboardButton.frame = CGRectMake(margin, smallY, half, 36);
    self.clearButton.frame = CGRectMake(margin + half + gap, smallY, half, 36);

    CGFloat diagY = smallY - gap - 36;
    self.diagnosticsButton.frame = CGRectMake(margin, diagY, width - margin * 2, 36);

    self.textView.frame = CGRectMake(margin, y, width - margin * 2,
                                     diagY - 10 - y);
}

- (void)copyLogTapped {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = self.logText ?: @"";
    PCLog(@"лог скопирован в буфер обмена");
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Скопировано"
                                            message:@"Лог в буфере обмена — вставьте его в чат."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLog {
    PCLogClearAll();
    self.logText = @"(логи очищены)";
    self.textView.text = self.logText;
}

- (void)diagnosticsTapped {
    if (!self.onDiagnostics) {
        [self showAlert:@"Диагностика недоступна" message:@"WebView ещё не готов"];
        return;
    }
    self.diagnosticsButton.enabled = NO;
    [self.diagnosticsButton setTitle:@"Проверка..." forState:UIControlStateNormal];
    self.onDiagnostics(^(NSString *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.diagnosticsButton.enabled = YES;
            [self.diagnosticsButton setTitle:@"Проверить runtime-hooks" forState:UIControlStateNormal];
            [self showAlert:@"runtime-hooks маркеры" message:result ?: @"(нет данных)"];
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Копировать"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = message ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)continueTapped {
    PCLog(@"продолжаем запуск после показа лога");
    void (^block)(void) = self.onContinue;
    self.onContinue = nil;
    if (block) { block(); }
}

@end
