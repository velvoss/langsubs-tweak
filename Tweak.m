// LangSubsTap (standalone) — tap any word in ANY subtitle → translation card + settings & saved words.
// No server. Plain ObjC runtime, no Substrate. Inject the dylib into the Nuvio IPA.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ================= libmpv access =================
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
static mpv_handle *LSHandle(id vc) {   // Swift stored property `mpv` registered as ObjC ivar
    Ivar iv = class_getInstanceVariable(object_getClass(vc), "mpv");
    if (!iv) return NULL;
    return *(mpv_handle **)((uint8_t *)(__bridge void *)vc + ivar_getOffset(iv));
}
static BOOL LSIsPaused(mpv_handle *h) { return [MPVGet(h, "pause") isEqualToString:@"yes"]; }

// ================= prefs =================
static NSUserDefaults *UD(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL LSB(NSString *k, BOOL d) { return [UD() objectForKey:k] ? [UD() boolForKey:k] : d; }
static double LSF(NSString *k, double d) { return [UD() objectForKey:k] ? [UD() doubleForKey:k] : d; }
static NSString *LSLang(void) { return [UD() stringForKey:@"LSTargetLang"] ?: @"ar"; }
static NSArray *LSLangs(void) {
    return @[@[@"ar", @"العربية"], @[@"en", @"English"], @[@"fr", @"Français"], @[@"es", @"Español"], @[@"de", @"Deutsch"],
             @[@"it", @"Italiano"], @[@"pt", @"Português"], @[@"tr", @"Türkçe"], @[@"ru", @"Русский"], @[@"fa", @"فارسی"],
             @[@"ur", @"اردو"], @[@"hi", @"हिन्दी"], @[@"ja", @"日本語"], @[@"ko", @"한국어"], @[@"zh-CN", @"中文"]];
}
static UIColor *LSHex(NSString *h, UIColor *fb) {
    if (![h hasPrefix:@"#"] || h.length != 7) return fb;
    unsigned v = 0; [[NSScanner scannerWithString:[h substringFromIndex:1]] scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}
static NSString *LSHexStr(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0; [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
}
static UIColor *LSColorNew(void) { return LSHex([UD() stringForKey:@"LSColorNew"], [UIColor colorWithRed:1 green:0.84 blue:0.29 alpha:1]); }
static UIColor *LSColorLearn(void) { return LSHex([UD() stringForKey:@"LSColorLearn"], [UIColor colorWithRed:0.31 green:0.76 blue:0.97 alpha:1]); }

// ================= translation (device → public API) =================
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

// ================= saved words store =================
@interface LSStore : NSObject
@property NSMutableDictionary *words;   // word -> {s: learning|known, m: meaning, c: context, t: time}
+ (instancetype)shared; - (void)save;
@end
@implementation LSStore
+ (instancetype)shared { static LSStore *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [LSStore new]; [s load]; }); return s; }
- (void)load {
    self.words = [NSMutableDictionary new];
    NSDictionary *raw = [UD() dictionaryForKey:@"LSWordsV2"];
    [raw enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *st) { if ([v isKindOfClass:NSDictionary.class]) self.words[k] = [v mutableCopy]; }];
    NSDictionary *old = [UD() dictionaryForKey:@"LSWords"];
    if (!raw && old.count) {
        [old enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *st) { if ([v isKindOfClass:NSString.class]) self.words[k] = [@{@"s": v} mutableCopy]; }];
        [self save];
    }
}
- (void)save { [UD() setObject:self.words forKey:@"LSWordsV2"]; }
@end

static UIViewController *LSTop(UIWindow *w) {
    UIViewController *t = w.rootViewController; while (t.presentedViewController) t = t.presentedViewController; return t;
}

// ================= saved words screen =================
@interface LSWordsVC : UITableViewController <UISearchBarDelegate>
@property NSArray *keys; @property UISegmentedControl *seg; @property UISearchBar *bar;
@end
@implementation LSWordsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"أتعلمها", @"أعرفها", @"الكل"]];
    self.seg.selectedSegmentIndex = 0;
    [self.seg addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.seg;
    self.bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
    self.bar.delegate = self; self.bar.placeholder = @"بحث";
    self.tableView.tableHeaderView = self.bar;
    [self reload];
}
- (void)searchBar:(UISearchBar *)b textDidChange:(NSString *)t { [self reload]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)b { [b resignFirstResponder]; }
- (void)reload {
    NSString *q = self.bar.text.lowercaseString ?: @""; NSInteger m = self.seg.selectedSegmentIndex;
    NSDictionary *W = [LSStore shared].words; NSMutableArray *a = [NSMutableArray new];
    for (NSString *k in W) {
        NSString *s = W[k][@"s"], *mm = W[k][@"m"] ?: @"";
        if (m == 0 && ![s isEqualToString:@"learning"]) continue;
        if (m == 1 && ![s isEqualToString:@"known"]) continue;
        if (q.length && [k rangeOfString:q].location == NSNotFound && [mm rangeOfString:q].location == NSNotFound) continue;
        [a addObject:k];
    }
    self.keys = [a sortedArrayUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.keys.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *k = self.keys[ip.row]; NSDictionary *e = [LSStore shared].words[k];
    c.textLabel.text = k; c.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    c.textLabel.textColor = [e[@"s"] isEqualToString:@"known"] ? [UIColor colorWithRed:0.45 green:0.85 blue:0.55 alpha:1] : LSColorLearn();
    c.detailTextLabel.text = e[@"m"] ?: @"—";
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st != UITableViewCellEditingStyleDelete) return;
    [[LSStore shared].words removeObjectForKey:self.keys[ip.row]]; [[LSStore shared] save]; [self reload];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *k = self.keys[ip.row]; NSMutableDictionary *e = [LSStore shared].words[k];
    __weak LSWordsVC *ws = self;
    void (^show)(NSString *) = ^(NSString *meaning) {
        NSString *msg = meaning ?: @""; NSString *c = e[@"c"];
        if (c.length) msg = [msg stringByAppendingFormat:@"\n\n%@", c];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:k message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"أتعلمها" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { e[@"s"] = @"learning"; [[LSStore shared] save]; [ws reload]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"أعرفها" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { e[@"s"] = @"known"; [[LSStore shared] save]; [ws reload]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [[LSStore shared].words removeObjectForKey:k]; [[LSStore shared] save]; [ws reload]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
        [ws presentViewController:ac animated:YES completion:nil];
    };
    if (e[@"m"]) show(e[@"m"]);
    else LSTranslate(k, ^(NSString *tr) { if (tr) { e[@"m"] = tr; [[LSStore shared] save]; [ws reload]; } show(tr); });
}
@end

// ================= settings screen =================
@interface LSSettingsVC : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property (copy) void (^onClose)(void);
@end
@implementation LSSettingsVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Lang Subs Tap";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; self.navigationController.presentationController.delegate = self; [self.tableView reloadData]; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)p { if (self.onClose) self.onClose(); }
- (void)done { [self.navigationController dismissViewControllerAnimated:YES completion:^{ if (self.onClose) self.onClose(); }]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger[]){1, 6, 2, 2}[s]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @[@"الكلمات", @"العرض", @"الترجمة", @"البيانات"][s]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger s = ip.section, r = ip.row;
    if (s == 0) {
        c.textLabel.text = @"الكلمات المحفوظة";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[LSStore shared].words.count];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; c.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (s == 1) {
        if (r == 0 || r == 1 || r == 2) {
            c.textLabel.text = @[@"تفعيل التويك", @"لون الكلمات الجديدة", @"لون كلمات «أتعلمها»"][r];
            if (r == 0) {
                UISwitch *sw = [UISwitch new]; sw.on = LSB(@"LSEnabled", YES); sw.tag = 1;
                [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sw;
            } else {
                UIColorWell *w = [UIColorWell new]; w.supportsAlpha = NO; w.tag = 30 + (r - 1);
                w.selectedColor = r == 1 ? LSColorNew() : LSColorLearn();
                [w addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = w;
            }
        } else if (r == 3) {
            UIStepper *st = [UIStepper new]; st.minimumValue = 14; st.maximumValue = 40; st.value = LSF(@"LSFont", 22);
            [st addTarget:self action:@selector(stChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = st; c.textLabel.text = [NSString stringWithFormat:@"حجم الخط (%d)", (int)st.value];
        } else {
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
            if (r == 4) { sl.minimumValue = 0; sl.maximumValue = 0.9; sl.value = LSF(@"LSBg", 0.45); sl.tag = 10; c.textLabel.text = @"شفافية الخلفية"; }
            else { sl.minimumValue = 20; sl.maximumValue = 220; sl.value = LSF(@"LSBottom", 70); sl.tag = 11; c.textLabel.text = @"ارتفاع الترجمة"; }
            [sl addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sl;
        }
    } else if (s == 2) {
        if (r == 0) {
            c.textLabel.text = @"لغة الترجمة"; c.selectionStyle = UITableViewCellSelectionStyleDefault;
            for (NSArray *p in LSLangs()) if ([p[0] isEqualToString:LSLang()]) c.detailTextLabel.text = p[1];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            c.textLabel.text = @"ترجمة الجملة كاملة";
            UISwitch *sw = [UISwitch new]; sw.on = LSB(@"LSSentence", YES); sw.tag = 2;
            [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sw;
        }
    } else {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.textLabel.text = r == 0 ? @"تصدير الكلمات" : @"مسح كل الكلمات";
        c.textLabel.textColor = r == 0 ? c.tintColor : UIColor.systemRedColor;
    }
    return c;
}
- (void)swChanged:(UISwitch *)s { [UD() setBool:s.on forKey:s.tag == 1 ? @"LSEnabled" : @"LSSentence"]; }
- (void)slChanged:(UISlider *)s { [UD() setDouble:s.value forKey:s.tag == 10 ? @"LSBg" : @"LSBottom"]; }
- (void)colorChanged:(UIColorWell *)w { [UD() setObject:LSHexStr(w.selectedColor) forKey:w.tag == 30 ? @"LSColorNew" : @"LSColorLearn"]; }
- (void)stChanged:(UIStepper *)s {
    [UD() setDouble:s.value forKey:@"LSFont"];
    [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:1]].textLabel.text = [NSString stringWithFormat:@"حجم الخط (%d)", (int)s.value];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    if (ip.section == 0) { [self.navigationController pushViewController:[LSWordsVC new] animated:YES]; }
    else if (ip.section == 2 && ip.row == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"لغة الترجمة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSArray *p in LSLangs())
            [ac addAction:[UIAlertAction actionWithTitle:p[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [UD() setObject:p[0] forKey:@"LSTargetLang"]; [tv reloadData]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        ac.popoverPresentationController.sourceView = cell; ac.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:ac animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 0) {
        NSDictionary *W = [LSStore shared].words; NSMutableString *t = [NSMutableString new];
        for (NSString *k in [W.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [t appendFormat:@"%@ — %@ (%@)\n", k, W[k][@"m"] ?: @"", W[k][@"s"] ?: @""];
        if (!t.length) { [t appendString:@"لا توجد كلمات محفوظة"]; }
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[t] applicationActivities:nil];
        av.popoverPresentationController.sourceView = cell; av.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:av animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 1) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"مسح كل الكلمات؟" message:@"لا يمكن التراجع عن هذا الإجراء." preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[LSStore shared].words removeAllObjects]; [[LSStore shared] save]; [tv reloadData]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}
@end

// ================= overlay + controller =================
@interface LSOverlay : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation LSOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { UIView *v = [super hitTest:p withEvent:e]; return v == self ? nil : v; }
- (void)layoutSubviews { [super layoutSubviews]; if (self.onLayout) self.onLayout(); }
@end

@interface LSController : NSObject
@property (weak) UIViewController *vc;
@property LSOverlay *overlay; @property UITextView *tv; @property UIView *card; @property UIButton *gear;
@property UILabel *wordL, *meaningL, *sentL; @property NSTimer *timer;
@property NSString *lastText, *curWord, *curLine;
@property BOOL hidSubs, pausedByUs; @property NSInteger ticks;
+ (instancetype)shared;
- (void)attach:(UIViewController *)vc; - (void)detach;
@end

static NSRegularExpression *WordRE, *ArabicRE;

@implementation LSController
+ (instancetype)shared { static LSController *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [LSController new]; }); return s; }
- (BOOL)isArabic:(NSString *)s { return [ArabicRE firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil; }

- (void)attach:(UIViewController *)vc {
    UIWindow *win = vc.view.window; if (!win) return;
    if (self.vc == vc && self.overlay) return;
    [self detach];
    if (!WordRE) {
        WordRE = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{M}][\\p{L}\\p{M}'’-]*" options:0 error:nil];
        ArabicRE = [NSRegularExpression regularExpressionWithPattern:@"\\p{Arabic}" options:0 error:nil];
    }
    self.vc = vc; self.lastText = nil;
    LSOverlay *o = [[LSOverlay alloc] initWithFrame:win.bounds];
    o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak LSController *w = self; o.onLayout = ^{ [w layout]; };
    UITextView *tv = [UITextView new];
    tv.editable = NO; tv.selectable = NO; tv.scrollEnabled = NO;
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
    [o addSubview:c];
    UIButton *g = [UIButton buttonWithType:UIButtonTypeSystem];
    [g setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    g.tintColor = [UIColor colorWithWhite:1 alpha:0.8]; g.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    g.layer.cornerRadius = 20; g.alpha = 0.55;
    [g addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [o addSubview:g];
    [win addSubview:o];   // window level: above Nuvio's Compose layer so taps reach us
    self.overlay = o; self.tv = tv; self.card = c; self.gear = g; self.wordL = wl; self.meaningL = ml; self.sentL = sl;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)resumeIfPaused {
    if (self.pausedByUs && self.vc && LSResolve()) { mpv_handle *h = LSHandle(self.vc); if (h) p_set(h, "pause", "no"); }
    self.pausedByUs = NO;
}
- (void)pauseIfPlaying {
    mpv_handle *h = self.vc ? LSHandle(self.vc) : NULL;
    if (h && LSResolve() && !self.pausedByUs && !LSIsPaused(h)) { p_set(h, "pause", "yes"); self.pausedByUs = YES; }
}

- (void)detach {
    [self.timer invalidate]; self.timer = nil;
    UIViewController *vc = self.vc;
    if (vc && LSResolve()) { mpv_handle *h = LSHandle(vc); if (h && self.hidSubs) p_set(h, "sub-visibility", "yes"); }
    [self resumeIfPaused];
    self.hidSubs = NO;
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
        self.tv.frame = CGRectMake((b.size.width - w) / 2, b.size.height - si.bottom - LSF(@"LSBottom", 70) - h, w, h);
    }
    self.gear.frame = CGRectMake(si.left + 14, b.size.height - si.bottom - 62, 40, 40);
    CGFloat cw = MIN(b.size.width - 24, 440);
    self.card.frame = CGRectMake((b.size.width - cw) / 2, b.size.height - si.bottom - 240, cw, 196);
    self.wordL.frame = CGRectMake(14, 10, cw - 28, 30);
    self.meaningL.frame = CGRectMake(14, 42, cw - 28, 52);
    self.sentL.frame = CGRectMake(14, 96, cw - 28, 40);
    for (NSInteger i = 0; i < 3; i++) [self.card viewWithTag:100 + i].frame = CGRectMake(8 + i * (cw - 16) / 3, 144, (cw - 16) / 3, 44);
}

- (void)render {
    NSString *t = self.lastText ?: @""; double fs = LSF(@"LSFont", 22);
    self.tv.backgroundColor = [UIColor colorWithWhite:0 alpha:LSF(@"LSBg", 0.45)];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:t attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:fs weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps}];
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByLines usingBlock:^(NSString *line, NSRange lr, NSRange er, BOOL *stop) {
        if ([self isArabic:line]) {
            [as addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:0.8 alpha:1] range:lr];
            [as addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:MAX(fs - 4, 12)] range:lr];
        }
    }];
    UIColor *cNew = LSColorNew(), *cLearn = LSColorLearn(); NSDictionary *W = [LSStore shared].words;
    for (NSTextCheckingResult *m in [WordRE matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *w = [t substringWithRange:m.range]; if ([self isArabic:w]) continue;
        NSString *st = W[w.lowercaseString][@"s"];
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
    if (!LSB(@"LSEnabled", YES)) {
        if (self.hidSubs) { p_set(h, "sub-visibility", "yes"); self.hidSubs = NO; }
        if (self.lastText.length) { self.lastText = @""; [self render]; }
        return;
    }
    NSString *codec = MPVGet(h, "current-tracks/sub/codec");
    BOOL image = codec && ([codec containsString:@"pgs"] || [codec containsString:@"dvd"] || [codec containsString:@"dvb"] || [codec containsString:@"xsub"]);
    NSString *t = image ? @"" : (MPVGet(h, "sub-text") ?: @"");
    if (image || (codec.length == 0 && t.length == 0)) {
        if (self.hidSubs) { p_set(h, "sub-visibility", "yes"); self.hidSubs = NO; }
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
    self.curWord = w; self.curLine = line;
    [self pauseIfPlaying];
    self.wordL.text = w; self.meaningL.text = @"…"; self.sentL.text = @""; self.card.hidden = NO;
    __weak LSController *ws = self;
    LSTranslate(w, ^(NSString *tr) { if ([ws.curWord isEqualToString:w]) ws.meaningL.text = tr ?: @"تعذّر جلب المعنى"; });
    if (LSB(@"LSSentence", YES))
        LSTranslate(line, ^(NSString *tr) { if ([ws.curWord isEqualToString:w]) ws.sentL.text = tr ?: @""; });
}
- (void)setStatus:(NSString *)s {
    if (!self.curWord) return;
    LSStore *st = [LSStore shared];
    NSMutableDictionary *e = st.words[self.curWord] ?: [NSMutableDictionary new];
    e[@"s"] = s;
    NSString *m = self.meaningL.text;
    if (m.length && ![m isEqualToString:@"…"] && ![m hasPrefix:@"تعذّر"]) e[@"m"] = m;
    if (self.curLine.length) e[@"c"] = self.curLine;
    if (!e[@"t"]) e[@"t"] = @([NSDate date].timeIntervalSince1970);
    st.words[self.curWord] = e; [st save];
    [self render]; [self closeCard];
}
- (void)onLearning { [self setStatus:@"learning"]; }
- (void)onKnown { [self setStatus:@"known"]; }
- (void)closeCard { self.card.hidden = YES; self.curWord = nil; [self resumeIfPaused]; }

- (void)openSettings {
    if (!self.vc || !self.overlay) return;
    UIWindow *w = self.overlay.window; if (!w) return;
    [self pauseIfPlaying];
    LSSettingsVC *s = [LSSettingsVC new];
    __weak LSController *ws = self;
    s.onClose = ^{ ws.overlay.hidden = NO; [ws render]; [ws resumeIfPaused]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.overlay.hidden = YES;
    [LSTop(w) presentViewController:nav animated:YES completion:nil];
}
@end

// ================= install: swizzle MPVPlayerViewController lifecycle =================
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
