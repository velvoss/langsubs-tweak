// LangSubsTap (standalone) — tap any word in ANY subtitle → translation card.
// No server needed. Plain ObjC runtime, no Substrate. Inject the dylib into the Nuvio IPA.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef void mpv_handle;
static char *(*p_get)(mpv_handle *, const char *);
static int (*p_set)(mpv_handle *, const char *, const char *);
static void (*p_free)(void *);

static BOOL LSResolve(void) {
    static BOOL ok; static dispatch_once_t once;
    dispatch_once(&once, ^{
        p_get = dlsym(RTLD_DEFAULT, "mpv_get_property_string");
        p_set = dlsym(RTLD_DEFAULT, "mpv_set_property_string");
        p_free = dlsym(RTLD_DEFAULT, "mpv_free");
        ok = p_get && p_set && p_free;
        if (!ok) NSLog(@"[LangSubsTap] libmpv symbols not found (static link?)");
    });
    return ok;
}
static NSString *MPVGet(mpv_handle *h, const char *k) {
    char *s = p_get(h, k); if (!s) return nil;
    NSString *r = [NSString stringWithUTF8String:s]; p_free(s); return r;
}
// Swift stored property `mpv` of MPVPlayerViewController (registered as an ObjC ivar).
static mpv_handle *LSHandle(id vc) {
    Ivar iv = class_getInstanceVariable(object_getClass(vc), "mpv");
    if (!iv) return NULL;
    return *(mpv_handle **)((uint8_t *)(__bridge void *)vc + ivar_getOffset(iv));
}

// ---- translation (device → public API, no own server) ----
static NSString *LSLang(void) { return [NSUserDefaults.standardUserDefaults stringForKey:@"LSTargetLang"] ?: @"ar"; }
static void LSGet(NSString *url, void (^cb)(NSData *)) {
    NSURL *u = [NSURL URLWithString:url]; if (!u) { cb(nil); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u]; r.timeoutInterval = 6;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *x, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ cb(d); });
    }] resume];
}
static void LSTranslate(NSString *text, void (^cb)(NSString *)) {
    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *u = [NSString stringWithFormat:@"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%@&dt=t&q=%@", LSLang(), q];
    LSGet(u, ^(NSData *d) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSMutableString *s = [NSMutableString new];
        if ([j isKindOfClass:NSArray.class] && [j count] && [j[0] isKindOfClass:NSArray.class])
            for (id seg in j[0]) if ([seg isKindOfClass:NSArray.class] && [seg count] && [seg[0] isKindOfClass:NSString.class]) [s appendString:seg[0]];
        if (s.length) { cb(s); return; }
        NSString *u2 = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=Autodetect|%@", q, LSLang()];
        LSGet(u2, ^(NSData *d2) {
            id j2 = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil] : nil;
            id rd = [j2 isKindOfClass:NSDictionary.class] ? j2[@"responseData"] : nil;
            NSString *m = [rd isKindOfClass:NSDictionary.class] ? rd[@"translatedText"] : nil;
            cb([m isKindOfClass:NSString.class] && m.length ? m : nil);
        });
    });
}

@interface LSOverlay : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation LSOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { UIView *v = [super hitTest:p withEvent:e]; return v == self ? nil : v; }
- (void)layoutSubviews { [super layoutSubviews]; if (self.onLayout) self.onLayout(); }
@end

@interface LSController : NSObject
@property (weak) UIViewController *vc;
@property LSOverlay *overlay; @property UITextView *tv; @property UIView *card;
@property UILabel *wordL, *meaningL, *sentL; @property NSTimer *timer;
@property NSString *lastText, *curWord; @property NSMutableDictionary *words;
@property BOOL hidSubs, pausedByUs; @property NSInteger ticks;
+ (instancetype)shared;
- (void)attach:(UIViewController *)vc; - (void)detach;
@end

static NSRegularExpression *WordRE, *ArabicRE;

@implementation LSController
+ (instancetype)shared { static LSController *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [LSController new]; }); return s; }
- (BOOL)isArabic:(NSString *)s { return [ArabicRE firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil; }

- (void)attach:(UIViewController *)vc {
    if (self.vc == vc && self.overlay) return;
    [self detach];
    if (!WordRE) {
        WordRE = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{M}][\\p{L}\\p{M}'’-]*" options:0 error:nil];
        ArabicRE = [NSRegularExpression regularExpressionWithPattern:@"\\p{Arabic}" options:0 error:nil];
    }
    self.vc = vc; self.lastText = nil;
    self.words = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"LSWords"] ?: @{}) mutableCopy];
    LSOverlay *o = [[LSOverlay alloc] initWithFrame:vc.view.bounds];
    o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak LSController *w = self; o.onLayout = ^{ [w layout]; };
    UITextView *tv = [UITextView new];
    tv.editable = NO; tv.selectable = NO; tv.scrollEnabled = NO;
    tv.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    tv.layer.cornerRadius = 10; tv.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    tv.textContainer.lineFragmentPadding = 5;
    [tv addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
    [o addSubview:tv];
    UIView *c = [UIView new];
    c.backgroundColor = [UIColor colorWithRed:0.09 green:0.16 blue:0.19 alpha:0.97];
    c.layer.cornerRadius = 14; c.hidden = YES;
    UILabel *wl = [UILabel new]; wl.font = [UIFont boldSystemFontOfSize:24]; wl.textColor = UIColor.whiteColor;
    UILabel *ml = [UILabel new]; ml.font = [UIFont systemFontOfSize:20]; ml.textColor = [UIColor colorWithWhite:0.92 alpha:1]; ml.numberOfLines = 2;
    UILabel *sl = [UILabel new]; sl.font = [UIFont systemFontOfSize:15]; sl.textColor = [UIColor colorWithWhite:0.65 alpha:1]; sl.numberOfLines = 2;
    [c addSubview:wl]; [c addSubview:ml]; [c addSubview:sl];
    NSArray *titles = @[@"أتعلمها", @"أعرفها", @"إغلاق"]; NSArray *sels = @[@"onLearning", @"onKnown", @"closeCard"];
    for (NSUInteger i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal]; b.tag = 100 + i;
        b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [b addTarget:self action:NSSelectorFromString(sels[i]) forControlEvents:UIControlEventTouchUpInside];
        [c addSubview:b];
    }
    [o addSubview:c]; [vc.view addSubview:o];
    self.overlay = o; self.tv = tv; self.card = c; self.wordL = wl; self.meaningL = ml; self.sentL = sl;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)detach {
    [self.timer invalidate]; self.timer = nil;
    UIViewController *vc = self.vc;
    if (vc && LSResolve()) {
        mpv_handle *h = LSHandle(vc);
        if (h && self.hidSubs) p_set(h, "sub-visibility", "yes");
        if (h && self.pausedByUs) p_set(h, "pause", "no");
    }
    self.hidSubs = NO; self.pausedByUs = NO;
    [self.overlay removeFromSuperview]; self.overlay = nil; self.vc = nil;
}

- (void)layout {
    CGRect b = self.overlay.bounds; UIEdgeInsets si = self.overlay.safeAreaInsets;
    NSAttributedString *a = self.tv.attributedText;
    if (a.length == 0) { self.tv.hidden = YES; }
    else {
        self.tv.hidden = NO;
        CGFloat maxW = b.size.width * 0.92 - 28;
        CGRect r = [a boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading context:nil];
        CGFloat w = MIN(ceil(r.size.width) + 28, b.size.width * 0.92), h = ceil(r.size.height) + 18;
        self.tv.frame = CGRectMake((b.size.width - w) / 2, b.size.height - si.bottom - 70 - h, w, h);
    }
    CGFloat cw = MIN(b.size.width - 24, 440);
    self.card.frame = CGRectMake((b.size.width - cw) / 2, b.size.height - si.bottom - 240, cw, 196);
    self.wordL.frame = CGRectMake(14, 10, cw - 28, 30);
    self.meaningL.frame = CGRectMake(14, 42, cw - 28, 52);
    self.sentL.frame = CGRectMake(14, 96, cw - 28, 40);
    for (NSInteger i = 0; i < 3; i++) [self.card viewWithTag:100 + i].frame = CGRectMake(8 + i * (cw - 16) / 3, 144, (cw - 16) / 3, 44);
}

- (void)render {
    NSString *t = self.lastText ?: @"";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:t attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps}];
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByLines usingBlock:^(NSString *line, NSRange lr, NSRange er, BOOL *stop) {
        if ([self isArabic:line]) {
            [as addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:0.8 alpha:1] range:lr];
            [as addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:18] range:lr];
        }
    }];
    UIColor *cNew = [UIColor colorWithRed:1 green:0.84 blue:0.29 alpha:1];
    UIColor *cLearn = [UIColor colorWithRed:0.31 green:0.76 blue:0.97 alpha:1];
    for (NSTextCheckingResult *m in [WordRE matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *w = [t substringWithRange:m.range]; if ([self isArabic:w]) continue;
        NSString *st = self.words[w.lowercaseString];
        if ([st isEqualToString:@"known"]) continue;
        [as addAttribute:NSForegroundColorAttributeName value:[st isEqualToString:@"learning"] ? cLearn : cNew range:m.range];
    }
    self.tv.attributedText = as; [self layout];
}

- (void)tick {
    UIViewController *vc = self.vc;
    if (!vc || !vc.view.window) { [self detach]; return; }
    if (!LSResolve()) return;
    mpv_handle *h = LSHandle(vc); if (!h) return;
    self.ticks++;
    NSString *codec = MPVGet(h, "current-tracks/sub/codec");
    BOOL image = codec && ([codec containsString:@"pgs"] || [codec containsString:@"dvd"] || [codec containsString:@"dvb"] || [codec containsString:@"xsub"]);
    NSString *t = image ? @"" : (MPVGet(h, "sub-text") ?: @"");
    if (image || (codec.length == 0 && t.length == 0)) {
        if (self.hidSubs) { p_set(h, "sub-visibility", "yes"); self.hidSubs = NO; }   // leave image subs / no subs to the app
    } else if (!self.hidSubs || self.ticks % 10 == 0) { p_set(h, "sub-visibility", "no"); self.hidSubs = YES; }
    if (![t isEqualToString:self.lastText ?: @""]) { self.lastText = t; [self render]; }
}

- (void)onTap:(UITapGestureRecognizer *)g {
    UITextView *tv = self.tv; CGPoint p = [g locationInView:tv];
    p.x -= tv.textContainerInset.left; p.y -= tv.textContainerInset.top;
    NSUInteger idx = [tv.layoutManager characterIndexForPoint:p inTextContainer:tv.textContainer fractionOfDistanceBetweenInsertionPoints:NULL];
    NSString *t = tv.text;
    for (NSTextCheckingResult *m in [WordRE matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        if (NSLocationInRange(idx, m.range)) {
            NSString *w = [t substringWithRange:m.range]; if ([self isArabic:w]) return;
            NSString *line = [[t substringWithRange:[t lineRangeForRange:m.range]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [self showWord:w.lowercaseString line:line]; return;
        }
    }
}

- (void)showWord:(NSString *)w line:(NSString *)line {
    self.curWord = w;
    mpv_handle *h = self.vc ? LSHandle(self.vc) : NULL;
    if (h && LSResolve() && !self.pausedByUs) { p_set(h, "pause", "yes"); self.pausedByUs = YES; }
    self.wordL.text = w; self.meaningL.text = @"…"; self.sentL.text = @""; self.card.hidden = NO;
    __weak LSController *ws = self;
    LSTranslate(w, ^(NSString *tr) {
        if (![ws.curWord isEqualToString:w]) return;
        ws.meaningL.text = tr ?: @"تعذّر جلب المعنى";
    });
    LSTranslate(line, ^(NSString *tr) {
        if (![ws.curWord isEqualToString:w]) return;
        ws.sentL.text = tr ?: @"";
    });
}
- (void)setStatus:(NSString *)s {
    if (!self.curWord) return;
    self.words[self.curWord] = s;
    [NSUserDefaults.standardUserDefaults setObject:self.words forKey:@"LSWords"];
    [self render]; [self closeCard];
}
- (void)onLearning { [self setStatus:@"learning"]; }
- (void)onKnown { [self setStatus:@"known"]; }
- (void)closeCard {
    self.card.hidden = YES; self.curWord = nil;
    if (self.pausedByUs && self.vc && LSResolve()) { mpv_handle *h = LSHandle(self.vc); if (h) p_set(h, "pause", "no"); }
    self.pausedByUs = NO;
}
@end

// ---- install: swizzle MPVPlayerViewController lifecycle ----
static IMP origAppear, origDisappear;
static void newAppear(id self, SEL _cmd, BOOL a) { ((void (*)(id, SEL, BOOL))origAppear)(self, _cmd, a); [[LSController shared] attach:self]; }
static void newDisappear(id self, SEL _cmd, BOOL a) { [[LSController shared] detach]; ((void (*)(id, SEL, BOOL))origDisappear)(self, _cmd, a); }

static void LSSwizzle(Class c, SEL s, IMP n, IMP *orig) {
    Method m = class_getInstanceMethod(c, s); *orig = method_getImplementation(m);
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) method_setImplementation(class_getInstanceMethod(c, s), n);
}
static void LSInstall(void) {
    unsigned n = 0; Class *all = objc_copyClassList(&n); Class found = Nil;
    for (unsigned i = 0; i < n; i++) if (strstr(class_getName(all[i]), "MPVPlayerViewController")) { found = all[i]; break; }
    free(all);
    if (!found) { NSLog(@"[LangSubsTap] MPVPlayerViewController not found"); return; }
    LSSwizzle(found, @selector(viewDidAppear:), (IMP)newAppear, &origAppear);
    LSSwizzle(found, @selector(viewWillDisappear:), (IMP)newDisappear, &origDisappear);
    NSLog(@"[LangSubsTap] installed on %s", class_getName(found));
}
__attribute__((constructor)) static void LSInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *x) {
        static dispatch_once_t o; dispatch_once(&o, ^{ LSInstall(); });
    }];
}
