//
//  BrowserViewController.m
//  TVBrowser
//
//  tvOS stellt Apps offiziell keine Web-Ansicht zur Verfügung. Die WebKit-
//  Bibliothek ist aber auf dem Gerät vorhanden. Wir laden sie zur Laufzeit
//  und sprechen WKWebView über die Objective-C-Runtime an (private API –
//  geht nur für Eigengebrauch, nicht für den App Store).
//

#import "BrowserViewController.h"
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - Einstellungen

// Startseite beim allerersten Start (im Menü änderbar).
static NSString * const kDefaultHomeURL = @"https://www.srf.ch/sport";

// Suchmaschine für Eingaben, die keine Adresse sind.
static NSString * const kSearchURL = @"https://www.google.ch/search";

// Lesezeichen beim allerersten Start.
static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserDefaultBookmarks(void) {
    return @[
        @{@"title": @"SRF Sport",  @"url": @"https://www.srf.ch/sport"},
        @{@"title": @"SRF News",   @"url": @"https://www.srf.ch/news"},
        @{@"title": @"Play SRF",   @"url": @"https://www.srf.ch/play/tv"},
        @{@"title": @"SRF Meteo",  @"url": @"https://www.srf.ch/meteo"},
        @{@"title": @"Google",     @"url": @"https://www.google.ch"},
        @{@"title": @"Wikipedia",  @"url": @"https://de.wikipedia.org"},
    ];
}

static NSString * const kDefaultsHomeURL   = @"homeURL";
static NSString * const kDefaultsLastURL   = @"lastURL";
static NSString * const kDefaultsBookmarks = @"bookmarks";
static NSString * const kDefaultsZoom      = @"pageZoom";

// Desktop-Safari, damit SRF die normale Website ausliefert.
static NSString * const kUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/18.0 Safari/605.1.15";

static const CGFloat kCursorSize      = 34.0;
static const CGFloat kCursorSpeed     = 1.6;   // Zeiger-Tempo beim Wischen
static const CGFloat kScrollSpeed     = 2.5;   // Tempo im Scroll-Modus
static const CGFloat kArrowScrollStep = 500.0; // Oben/Unten auf dem Clickpad

#pragma mark - WebKit zur Laufzeit laden

static BOOL BrowserLoadWebKit(void) {
    if (NSClassFromString(@"WKWebView") != Nil) {
        return YES;
    }
    NSArray<NSString *> *candidates = @[
        @"/System/Library/Frameworks/WebKit.framework/WebKit",
        @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
        @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
    ];
    for (NSString *path in candidates) {
        if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Fokussierbare Grundansicht

// Damit die Fernbedienung ihre Eingaben an uns schickt, braucht tvOS
// eine fokussierbare Ansicht.
@interface BrowserHostView : UIView
@end

@implementation BrowserHostView
- (BOOL)canBecomeFocused {
    return YES;
}
@end

#pragma mark - Controller

@interface BrowserViewController ()
@property (nonatomic, strong) UIView *webView;            // eigentlich ein WKWebView
@property (nonatomic, strong) UIImageView *cursorView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, assign) BOOL scrollMode;
@property (nonatomic, assign) BOOL didPlaceCursor;
@property (nonatomic, assign) CGPoint lastTouchLocation;
@property (nonatomic, readonly) NSURL *currentURL;
@property (nonatomic, readonly) NSString *currentTitle;
@end

@implementation BrowserViewController

- (void)loadView {
    BrowserHostView *host = [[BrowserHostView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    host.backgroundColor = UIColor.blackColor;
    self.view = host;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (![self createWebView]) {
        [self showFatalMessage:@"Die Web-Komponente konnte auf diesem Apple TV nicht geladen werden."];
        return;
    }

    [self createCursor];
    [self createSpinner];
    [self createToast];

    [self applyPageZoom:[self storedPageZoom] announce:NO];

    // Dort weitermachen, wo man aufgehört hat – sonst Startseite.
    NSString *lastURL = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsLastURL];
    NSURL *startURL = lastURL.length ? [NSURL URLWithString:lastURL] : nil;
    [self loadURL:startURL ?: [self homeURL]];

    [self showToast:@"Wischen: Zeiger  ·  Klicken: auswählen  ·  ⏯ Play/Pause: Menü (Adresse, Lesezeichen …)  ·  Zurück: vorherige Seite"
           duration:6.0];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.didPlaceCursor && self.cursorView != nil) {
        self.cursorView.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
        self.didPlaceCursor = YES;
    }
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.view];
}

#pragma mark - Aufbau

- (BOOL)createWebView {
    if (!BrowserLoadWebKit()) {
        return NO;
    }

    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (configurationClass == Nil || webViewClass == Nil) {
        return NO;
    }

    id configuration = [configurationClass new];

    // Videos direkt in der Seite abspielen und ohne extra Antippen starten.
    SEL inlineSel = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if ([configuration respondsToSelector:inlineSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, inlineSel, YES);
    }
    SEL mediaSel = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([configuration respondsToSelector:mediaSel]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaSel, 0);
    }

    SEL initSel = NSSelectorFromString(@"initWithFrame:configuration:");
    id webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)([webViewClass alloc], initSel, self.view.bounds, configuration);
    if (webView == nil) {
        return NO;
    }

    self.webView = (UIView *)webView;
    self.webView.frame = self.view.bounds;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = UIColor.blackColor;
    // Alle Eingaben laufen über uns, nicht über den Fokus-Mechanismus von tvOS.
    self.webView.userInteractionEnabled = NO;

    if ([webView respondsToSelector:NSSelectorFromString(@"setCustomUserAgent:")]) {
        [webView setValue:kUserAgent forKey:@"customUserAgent"];
    }

    SEL navDelegateSel = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webView respondsToSelector:navDelegateSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webView, navDelegateSel, self);
    }
    SEL uiDelegateSel = NSSelectorFromString(@"setUIDelegate:");
    if ([webView respondsToSelector:uiDelegateSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webView, uiDelegateSel, self);
    }

    [self.view addSubview:self.webView];
    return YES;
}

- (void)createCursor {
    CGSize size = CGSizeMake(kCursorSize, kCursorSize);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect outer = CGRectInset(CGRectMake(0, 0, size.width, size.height), 2, 2);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:outer];
        [[UIColor colorWithWhite:1.0 alpha:0.85] setFill];
        [circle fill];
        circle.lineWidth = 3;
        [[UIColor colorWithWhite:0.1 alpha:0.9] setStroke];
        [circle stroke];
        UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(outer, 11, 11)];
        [[UIColor colorWithRed:0.80 green:0.0 blue:0.0 alpha:1.0] setFill]; // SRF-Rot
        [dot fill];
    }];

    self.cursorView = [[UIImageView alloc] initWithImage:image];
    self.cursorView.userInteractionEnabled = NO;
    self.cursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.cursorView.layer.shadowOpacity = 0.5;
    self.cursorView.layer.shadowRadius = 4;
    self.cursorView.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:self.cursorView];
}

- (void)createSpinner {
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:40],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-60],
    ]];
}

- (void)createToast {
    self.toastLabel = [[UILabel alloc] init];
    self.toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.toastLabel.textColor = UIColor.whiteColor;
    self.toastLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    self.toastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    self.toastLabel.layer.cornerRadius = 16;
    self.toastLabel.layer.masksToBounds = YES;
    self.toastLabel.alpha = 0;
    [self.view addSubview:self.toastLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.toastLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.toastLabel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-60],
        [self.toastLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-200],
        [self.toastLabel.heightAnchor constraintGreaterThanOrEqualToConstant:64],
    ]];
}

- (void)showToast:(NSString *)text duration:(NSTimeInterval)duration {
    self.toastLabel.text = [NSString stringWithFormat:@"   %@   ", text];
    [self.toastLabel.layer removeAllAnimations];
    [UIView animateWithDuration:0.25 animations:^{
        self.toastLabel.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.5 delay:duration options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.toastLabel.alpha = 0;
        } completion:nil];
    }];
}

- (void)showFatalMessage:(NSString *)message {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 160, 160)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = message;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:36 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [self.view addSubview:label];
}

#pragma mark - WebView-Helfer (alles über die Runtime)

- (void)loadURL:(NSURL *)url {
    if (url == nil) {
        return;
    }
    [self loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)loadRequest:(NSURLRequest *)request {
    SEL sel = NSSelectorFromString(@"loadRequest:");
    if (request != nil && [self.webView respondsToSelector:sel]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.webView, sel, request);
    }
}

- (BOOL)canGoBack {
    if (self.webView == nil) {
        return NO;
    }
    return [[self.webView valueForKey:@"canGoBack"] boolValue];
}

- (void)goBack {
    SEL sel = NSSelectorFromString(@"goBack");
    if ([self.webView respondsToSelector:sel]) {
        ((id (*)(id, SEL))objc_msgSend)(self.webView, sel);
    }
}

- (BOOL)canGoForward {
    if (self.webView == nil) {
        return NO;
    }
    return [[self.webView valueForKey:@"canGoForward"] boolValue];
}

- (void)goForward {
    SEL sel = NSSelectorFromString(@"goForward");
    if ([self.webView respondsToSelector:sel]) {
        ((id (*)(id, SEL))objc_msgSend)(self.webView, sel);
    }
}

- (void)reload {
    SEL sel = NSSelectorFromString(@"reload");
    if ([self.webView respondsToSelector:sel]) {
        ((id (*)(id, SEL))objc_msgSend)(self.webView, sel);
    }
}

- (NSURL *)currentURL {
    id url = [self.webView valueForKey:@"URL"];
    return [url isKindOfClass:[NSURL class]] ? url : nil;
}

- (NSString *)currentTitle {
    id title = [self.webView valueForKey:@"title"];
    return [title isKindOfClass:[NSString class]] ? title : @"";
}

#pragma mark - Zoom

- (CGFloat)storedPageZoom {
    NSNumber *zoom = [NSUserDefaults.standardUserDefaults objectForKey:kDefaultsZoom];
    return [zoom isKindOfClass:[NSNumber class]] ? zoom.doubleValue : 1.0;
}

- (void)applyPageZoom:(CGFloat)zoom announce:(BOOL)announce {
    zoom = MIN(MAX(zoom, 0.5), 3.0);
    [NSUserDefaults.standardUserDefaults setObject:@(zoom) forKey:kDefaultsZoom];
    if ([self.webView respondsToSelector:NSSelectorFromString(@"setPageZoom:")]) {
        [self.webView setValue:@(zoom) forKey:@"pageZoom"];
    }
    if (announce) {
        [self showToast:[NSString stringWithFormat:@"Zoom: %.0f %%", zoom * 100.0] duration:1.5];
    }
}

- (UIScrollView *)webScrollView {
    id scrollView = [self.webView valueForKey:@"scrollView"];
    return [scrollView isKindOfClass:[UIScrollView class]] ? scrollView : nil;
}

- (void)runJavaScript:(NSString *)script completion:(void (^)(id result))completion {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.webView respondsToSelector:sel]) {
        return;
    }
    void (^handler)(id, NSError *) = ^(id result, NSError *error) {
        if (completion) {
            completion(error == nil ? result : nil);
        }
    };
    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(self.webView, sel, script, handler);
}

#pragma mark - Scrollen

- (void)scrollBy:(CGPoint)delta animated:(BOOL)animated {
    UIScrollView *scrollView = [self webScrollView];
    if (scrollView == nil) {
        return;
    }
    UIEdgeInsets inset = scrollView.adjustedContentInset;
    CGFloat minX = -inset.left;
    CGFloat minY = -inset.top;
    CGFloat maxX = MAX(minX, scrollView.contentSize.width  - CGRectGetWidth(scrollView.bounds)  + inset.right);
    CGFloat maxY = MAX(minY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + inset.bottom);

    CGPoint offset = scrollView.contentOffset;
    offset.x = MIN(MAX(offset.x + delta.x, minX), maxX);
    offset.y = MIN(MAX(offset.y + delta.y, minY), maxY);
    [scrollView setContentOffset:offset animated:animated];
}

#pragma mark - Touch-Fläche der Fernbedienung

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.lastTouchLocation = [touches.anyObject locationInView:self.view];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint location = [touches.anyObject locationInView:self.view];
    CGFloat dx = location.x - self.lastTouchLocation.x;
    CGFloat dy = location.y - self.lastTouchLocation.y;
    self.lastTouchLocation = location;

    if (self.cursorView == nil) {
        return;
    }

    if (self.scrollMode) {
        // Natürliches Scrollen: nach oben wischen = Seite wandert nach oben.
        [self scrollBy:CGPointMake(-dx * kScrollSpeed, -dy * kScrollSpeed) animated:NO];
        return;
    }

    [self moveCursorByX:dx * kCursorSpeed y:dy * kCursorSpeed];
}

- (void)moveCursorByX:(CGFloat)dx y:(CGFloat)dy {
    CGRect bounds = self.view.bounds;
    CGFloat half = kCursorSize / 2.0;
    CGPoint target = CGPointMake(self.cursorView.center.x + dx, self.cursorView.center.y + dy);

    // Am Bildschirmrand schiebt der Zeiger die Seite weiter.
    CGFloat overflowX = 0, overflowY = 0;
    if (target.x < half)                      { overflowX = target.x - half; target.x = half; }
    if (target.x > CGRectGetMaxX(bounds) - half) { overflowX = target.x - (CGRectGetMaxX(bounds) - half); target.x = CGRectGetMaxX(bounds) - half; }
    if (target.y < half)                      { overflowY = target.y - half; target.y = half; }
    if (target.y > CGRectGetMaxY(bounds) - half) { overflowY = target.y - (CGRectGetMaxY(bounds) - half); target.y = CGRectGetMaxY(bounds) - half; }

    self.cursorView.center = target;
    if (overflowX != 0 || overflowY != 0) {
        [self scrollBy:CGPointMake(overflowX * 2.0, overflowY * 2.0) animated:NO];
    }
}

#pragma mark - Tasten der Fernbedienung

- (BOOL)handlesPress:(UIPress *)press {
    if (self.webView == nil) {
        return NO;
    }
    switch (press.type) {
        case UIPressTypeSelect:
        case UIPressTypePlayPause:
        case UIPressTypeUpArrow:
        case UIPressTypeDownArrow:
            return YES;
        case UIPressTypeMenu:
            // Auf der ersten Seite darf «Zurück» die App verlassen.
            return [self canGoBack];
        default:
            return NO;
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL forward = NO;
    for (UIPress *press in presses) {
        if (![self handlesPress:press]) {
            forward = YES;
        }
    }
    if (forward) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL forward = NO;
    for (UIPress *press in presses) {
        if ([self handlesPress:press]) {
            [self performPress:press];
        } else {
            forward = YES;
        }
    }
    if (forward) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [super pressesCancelled:presses withEvent:event];
}

- (void)performPress:(UIPress *)press {
    switch (press.type) {
        case UIPressTypeSelect:
            if (self.scrollMode) {
                [self setScrollMode:NO announce:YES];
            } else {
                [self clickAtCursor];
            }
            break;
        case UIPressTypePlayPause:
            [self showMainMenu];
            break;
        case UIPressTypeUpArrow:
            [self scrollBy:CGPointMake(0, -kArrowScrollStep) animated:YES];
            break;
        case UIPressTypeDownArrow:
            [self scrollBy:CGPointMake(0, kArrowScrollStep) animated:YES];
            break;
        case UIPressTypeMenu:
            [self goBack];
            break;
        default:
            break;
    }
}

- (void)setScrollMode:(BOOL)scrollMode announce:(BOOL)announce {
    _scrollMode = scrollMode;
    [UIView animateWithDuration:0.2 animations:^{
        self.cursorView.alpha = scrollMode ? 0.25 : 1.0;
    }];
    if (announce) {
        [self showToast:scrollMode ? @"Scroll-Modus: wischen zum Scrollen, Klicken beendet ihn" : @"Zeiger-Modus" duration:1.5];
    }
}

#pragma mark - Menü (Play/Pause)

- (UIAlertAction *)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(void))handler {
    return [UIAlertAction actionWithTitle:title style:style handler:^(UIAlertAction *action) {
        if (handler) {
            // Erst nach dem Schliessen des Menüs weitermachen (z.B. nächstes Menü öffnen).
            dispatch_async(dispatch_get_main_queue(), handler);
        }
    }];
}

- (void)presentSheet:(UIAlertController *)sheet {
    if (self.presentedViewController != nil) {
        return;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showMainMenu {
    NSString *title = self.currentTitle.length ? self.currentTitle : @"Browser";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:title
                                                                  message:self.currentURL.absoluteString
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    CGFloat zoom = [self storedPageZoom];

    [menu addAction:[self actionWithTitle:@"Adresse oder Suche eingeben" style:UIAlertActionStyleDefault handler:^{
        [weakSelf promptForAddress];
    }]];
    [menu addAction:[self actionWithTitle:@"Lesezeichen" style:UIAlertActionStyleDefault handler:^{
        [weakSelf showBookmarks];
    }]];
    [menu addAction:[self actionWithTitle:@"Startseite" style:UIAlertActionStyleDefault handler:^{
        [weakSelf loadURL:[weakSelf homeURL]];
    }]];
    if ([self canGoForward]) {
        [menu addAction:[self actionWithTitle:@"Vorwärts" style:UIAlertActionStyleDefault handler:^{
            [weakSelf goForward];
        }]];
    }
    [menu addAction:[self actionWithTitle:@"Neu laden" style:UIAlertActionStyleDefault handler:^{
        [weakSelf reload];
    }]];
    [menu addAction:[self actionWithTitle:self.scrollMode ? @"Scroll-Modus beenden" : @"Scroll-Modus (wischen scrollt die Seite)"
                                    style:UIAlertActionStyleDefault handler:^{
        [weakSelf setScrollMode:!weakSelf.scrollMode announce:YES];
    }]];
    [menu addAction:[self actionWithTitle:[NSString stringWithFormat:@"Grösser (Zoom jetzt %.0f %%)", zoom * 100.0]
                                    style:UIAlertActionStyleDefault handler:^{
        [weakSelf applyPageZoom:[weakSelf storedPageZoom] + 0.25 announce:YES];
    }]];
    [menu addAction:[self actionWithTitle:@"Kleiner" style:UIAlertActionStyleDefault handler:^{
        [weakSelf applyPageZoom:[weakSelf storedPageZoom] - 0.25 announce:YES];
    }]];
    if (self.currentURL != nil) {
        [menu addAction:[self actionWithTitle:@"Diese Seite als Startseite" style:UIAlertActionStyleDefault handler:^{
            NSURL *url = weakSelf.currentURL;
            if (url != nil) {
                [NSUserDefaults.standardUserDefaults setObject:url.absoluteString forKey:kDefaultsHomeURL];
                [weakSelf showToast:@"Startseite gespeichert" duration:1.5];
            }
        }]];
    }
    [menu addAction:[self actionWithTitle:@"Schliessen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:menu];
}

#pragma mark - Adresse eingeben

- (NSURL *)homeURL {
    NSString *home = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsHomeURL];
    NSURL *url = home.length ? [NSURL URLWithString:home] : nil;
    return url ?: [NSURL URLWithString:kDefaultHomeURL];
}

- (void)promptForAddress {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Adresse oder Suchbegriff"
                                                                   message:@"z.B. srf.ch/news – oder einfach ein Suchbegriff"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSString *current = self.currentURL.absoluteString;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = current.length ? current : @"srf.ch/news";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.returnKeyType = UIReturnKeyGo;
    }];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[self actionWithTitle:@"Öffnen" style:UIAlertActionStyleDefault handler:^{
        NSURL *url = [weakSelf urlFromInput:weakAlert.textFields.firstObject.text];
        if (url != nil) {
            [weakSelf loadURL:url];
        }
    }]];
    [alert addAction:[self actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:alert];
}

// Macht aus «srf.ch/news» eine Adresse und aus «Wetter Zürich» eine Suche.
- (NSURL *)urlFromInput:(NSString *)input {
    NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        return nil;
    }

    BOOL hasSpace = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound;
    if (!hasSpace) {
        NSString *lower = text.lowercaseString;
        if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) {
            NSURL *url = [NSURL URLWithString:text];
            if (url.host.length) {
                return url;
            }
        } else if ([text containsString:@"."] && ![text hasSuffix:@"."]) {
            NSURL *url = [NSURL URLWithString:[@"https://" stringByAppendingString:text]];
            if (url.host.length) {
                return url;
            }
        }
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:kSearchURL];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:text]];
    // «+» würde sonst als Leerzeichen gelesen.
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return components.URL;
}

#pragma mark - Lesezeichen

- (NSArray<NSDictionary<NSString *, NSString *> *> *)bookmarks {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:kDefaultsBookmarks];
    if (stored == nil) {
        return BrowserDefaultBookmarks();
    }
    NSMutableArray *valid = [NSMutableArray array];
    for (id entry in stored) {
        if ([entry isKindOfClass:[NSDictionary class]] &&
            [entry[@"title"] isKindOfClass:[NSString class]] &&
            [entry[@"url"] isKindOfClass:[NSString class]]) {
            [valid addObject:entry];
        }
    }
    return valid;
}

- (void)saveBookmarks:(NSArray *)bookmarks {
    [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:kDefaultsBookmarks];
}

- (void)showBookmarks {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Lesezeichen"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *bookmarks = [self bookmarks];

    for (NSDictionary *bookmark in bookmarks) {
        NSString *urlString = bookmark[@"url"];
        [sheet addAction:[self actionWithTitle:bookmark[@"title"] style:UIAlertActionStyleDefault handler:^{
            [weakSelf loadURL:[NSURL URLWithString:urlString]];
        }]];
    }

    if (self.currentURL != nil) {
        [sheet addAction:[self actionWithTitle:@"＋ Diese Seite hinzufügen" style:UIAlertActionStyleDefault handler:^{
            [weakSelf addCurrentPageAsBookmark];
        }]];
    }
    if (bookmarks.count > 0) {
        [sheet addAction:[self actionWithTitle:@"Lesezeichen löschen …" style:UIAlertActionStyleDefault handler:^{
            [weakSelf showDeleteBookmarks];
        }]];
    }
    [sheet addAction:[self actionWithTitle:@"Schliessen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)addCurrentPageAsBookmark {
    NSURL *url = self.currentURL;
    if (url == nil) {
        return;
    }
    NSString *title = self.currentTitle.length ? self.currentTitle : (url.host ?: url.absoluteString);
    if (title.length > 60) {
        title = [[title substringToIndex:60] stringByAppendingString:@"…"];
    }

    NSMutableArray *bookmarks = [[self bookmarks] mutableCopy];
    for (NSDictionary *bookmark in bookmarks) {
        if ([bookmark[@"url"] isEqualToString:url.absoluteString]) {
            [self showToast:@"Diese Seite ist schon gespeichert" duration:1.5];
            return;
        }
    }
    [bookmarks addObject:@{@"title": title, @"url": url.absoluteString}];
    [self saveBookmarks:bookmarks];
    [self showToast:[NSString stringWithFormat:@"Gespeichert: %@", title] duration:2.0];
}

- (void)showDeleteBookmarks {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Welches Lesezeichen löschen?"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *bookmarks = [self bookmarks];
    [bookmarks enumerateObjectsUsingBlock:^(NSDictionary *bookmark, NSUInteger index, BOOL *stop) {
        [sheet addAction:[self actionWithTitle:bookmark[@"title"] style:UIAlertActionStyleDestructive handler:^{
            NSMutableArray *updated = [[weakSelf bookmarks] mutableCopy];
            if (index < updated.count) {
                [updated removeObjectAtIndex:index];
                [weakSelf saveBookmarks:updated];
                [weakSelf showToast:[NSString stringWithFormat:@"Gelöscht: %@", bookmark[@"title"]] duration:1.5];
            }
        }]];
    }];
    [sheet addAction:[self actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

#pragma mark - Klicken

- (void)clickAtCursor {
    CGPoint point = [self.view convertPoint:self.cursorView.center toView:self.webView];
    CGFloat width = MAX(1.0, CGRectGetWidth(self.webView.bounds));
    CGFloat height = MAX(1.0, CGRectGetHeight(self.webView.bounds));

    // Kurzes «Drücken»-Feedback am Zeiger.
    [UIView animateWithDuration:0.08 animations:^{
        self.cursorView.transform = CGAffineTransformMakeScale(0.75, 0.75);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            self.cursorView.transform = CGAffineTransformIdentity;
        }];
    }];

    // Wir rechnen mit Anteilen (0…1) statt Pixeln, so passt es bei jedem Seiten-Zoom.
    NSString *script = [NSString stringWithFormat:
        @"(function(fx, fy) {"
         "  var x = fx * window.innerWidth, y = fy * window.innerHeight;"
         "  var doc = document, el = doc.elementFromPoint(x, y);"
         "  while (el && el.shadowRoot) {"
         "    var inner = el.shadowRoot.elementFromPoint(x, y);"
         "    if (!inner || inner === el) break; el = inner;"
         "  }"
         "  if (el && el.tagName === 'IFRAME') {"
         "    try {"
         "      var r = el.getBoundingClientRect(), d = el.contentDocument;"
         "      var hit = d && d.elementFromPoint(x - r.left, y - r.top);"
         "      if (hit) { x -= r.left; y -= r.top; el = hit; }"
         "    } catch (e) {}"
         "  }"
         "  if (!el) return null;"
         "  var opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, isPrimary: true, pointerType: 'mouse' };"
         "  ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function(t) {"
         "    var E = (t.indexOf('pointer') === 0 && window.PointerEvent) ? PointerEvent : MouseEvent;"
         "    try { el.dispatchEvent(new E(t, opts)); } catch (e) {}"
         "  });"
         "  if (typeof el.focus === 'function') el.focus();"
         "  if (typeof el.click === 'function') el.click();"
         "  var tag = el.tagName, type = (el.type || '').toLowerCase();"
         "  var textTypes = ['', 'text', 'search', 'email', 'url', 'tel', 'password', 'number'];"
         "  var editable = el.isContentEditable || tag === 'TEXTAREA' || (tag === 'INPUT' && textTypes.indexOf(type) >= 0);"
         "  if (!editable) return { editable: false };"
         "  window.__tvTarget = el;"
         "  return { editable: true,"
         "           value: el.isContentEditable ? el.textContent : (el.value || ''),"
         "           placeholder: el.placeholder || el.getAttribute('aria-label') || '',"
         "           secure: type === 'password' };"
         "})(%f, %f)", point.x / width, point.y / height];

    __weak typeof(self) weakSelf = self;
    [self runJavaScript:script completion:^(id result) {
        if ([result isKindOfClass:[NSDictionary class]] && [result[@"editable"] boolValue]) {
            [weakSelf promptForTextWithInfo:result];
        }
    }];
}

#pragma mark - Texteingabe (z.B. Suche)

- (void)promptForTextWithInfo:(NSDictionary *)info {
    NSString *value = [info[@"value"] isKindOfClass:[NSString class]] ? info[@"value"] : @"";
    NSString *placeholder = [info[@"placeholder"] isKindOfClass:[NSString class]] ? info[@"placeholder"] : @"";
    BOOL secure = [info[@"secure"] boolValue];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Text eingeben"
                                                                   message:placeholder.length ? placeholder : nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = value;
        textField.placeholder = placeholder;
        textField.secureTextEntry = secure;
    }];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Senden" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf applyText:weakAlert.textFields.firstObject.text submit:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Nur eintragen" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf applyText:weakAlert.textFields.firstObject.text submit:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyText:(NSString *)text submit:(BOOL)submit {
    // Text sicher als JavaScript-String verpacken.
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[text ?: @""] options:0 error:nil];
    NSString *jsonArray = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[\"\"]";

    NSString *script = [NSString stringWithFormat:
        @"(function(v, submit) {"
         "  var el = window.__tvTarget; if (!el) return;"
         "  el.focus();"
         "  if (el.isContentEditable) { el.textContent = v; }"
         "  else {"
         "    var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;"
         "    var desc = Object.getOwnPropertyDescriptor(proto, 'value');"
         "    if (desc && desc.set) desc.set.call(el, v); else el.value = v;"
         "  }"
         "  el.dispatchEvent(new Event('input', { bubbles: true }));"
         "  el.dispatchEvent(new Event('change', { bubbles: true }));"
         "  if (!submit) return;"
         "  var k = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };"
         "  var notCancelled = el.dispatchEvent(new KeyboardEvent('keydown', k));"
         "  el.dispatchEvent(new KeyboardEvent('keypress', k));"
         "  el.dispatchEvent(new KeyboardEvent('keyup', k));"
         "  if (notCancelled && el.form) {"
         "    if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();"
         "  }"
         "})(%@[0], %@)", jsonArray, submit ? @"true" : @"false"];

    [self runJavaScript:script completion:nil];
}

#pragma mark - WKNavigationDelegate (wird von WebKit zur Laufzeit aufgerufen)

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    [self.spinner startAnimating];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.spinner stopAnimating];
    // Merken, damit der Browser beim nächsten Start hier weitermacht.
    NSString *url = self.currentURL.absoluteString;
    if ([url hasPrefix:@"http"]) {
        [NSUserDefaults.standardUserDefaults setObject:url forKey:kDefaultsLastURL];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self reload];
}

- (void)handleLoadError:(NSError *)error {
    [self.spinner stopAnimating];
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return;
    }
    [self showToast:[NSString stringWithFormat:@"Seite konnte nicht geladen werden: %@", error.localizedDescription]
           duration:4.0];
}

#pragma mark - WKUIDelegate

// Links mit target="_blank" einfach im selben Fenster öffnen.
- (id)webView:(id)webView createWebViewWithConfiguration:(id)configuration
                                    forNavigationAction:(id)navigationAction
                                         windowFeatures:(id)windowFeatures {
    id request = [navigationAction valueForKey:@"request"];
    if ([request isKindOfClass:[NSURLRequest class]]) {
        [self loadRequest:request];
    }
    return nil;
}

@end
