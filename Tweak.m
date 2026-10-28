// LangSubsTap 3.0 — learn languages from any subtitle.
// Tap a word inside the player, hear it, keep it, and review it later.
// Plain Objective-C runtime, no Substrate. Inject the dylib into the Nuvio IPA.
//
// 3.0 highlights
//  • Completely redesigned word card (blur, gradients, spring animation)
//  • Pronunciation via AVSpeechSynthesizer (word + translation, auto-speak)
//  • Dictionary lookup (phonetic, part of speech, definition) for English
//  • Rich saved-word store (phonetic/definition/review stats + migration)
//  • Redesigned Settings, Saved Words, Word Details and Flashcard Review
//  • Floating launcher on the app home screen (draggable, review badge)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <NaturalLanguage/NaturalLanguage.h>

static NSString *const LSVersion = @"3.0";

// =====================================================================
#pragma mark - libmpv access

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

// =====================================================================
#pragma mark - preferences

static NSUserDefaults *UD(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL LSB(NSString *k, BOOL d) { return [UD() objectForKey:k] ? [UD() boolForKey:k] : d; }
static double LSF(NSString *k, double d) { return [UD() objectForKey:k] ? [UD() doubleForKey:k] : d; }
static NSString *LSS(NSString *k, NSString *d) { return [UD() stringForKey:k] ?: d; }
static NSString *LSLang(void) { return LSS(@"LSTargetLang", @"ar"); }
static NSArray *LSLangs(void) {
    return @[@[@"ar", @"العربية"], @[@"en", @"English"], @[@"fr", @"Français"], @[@"es", @"Español"], @[@"de", @"Deutsch"],
             @[@"it", @"Italiano"], @[@"pt", @"Português"], @[@"tr", @"Türkçe"], @[@"ru", @"Русский"], @[@"fa", @"فارسی"],
             @[@"ur", @"اردو"], @[@"hi", @"हिन्दी"], @[@"ja", @"日本語"], @[@"ko", @"한국어"], @[@"zh-CN", @"中文"],
             @[@"nl", @"Nederlands"], @[@"pl", @"Polski"], @[@"id", @"Indonesia"], @[@"vi", @"Tiếng Việt"], @[@"th", @"ไทย"]];
}
static NSString *LSLangName(NSString *code) {
    for (NSArray *p in LSLangs()) if ([p[0] isEqualToString:code]) return p[1];
    return code.uppercaseString;
}

// =====================================================================
#pragma mark - colors & theme

static UIColor *LSHex(NSString *h, UIColor *fb) {
    if (![h hasPrefix:@"#"] || h.length != 7) return fb;
    unsigned v = 0; [[NSScanner scannerWithString:[h substringFromIndex:1]] scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}
static NSString *LSHexStr(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0; [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
}
static UIColor *LSColorNew(void)   { return LSHex(LSS(@"LSColorNew", @"#FFD65E"), [UIColor colorWithRed:1 green:0.84 blue:0.29 alpha:1]); }
static UIColor *LSColorLearn(void) { return LSHex(LSS(@"LSColorLearn", @"#5CC8F5"), [UIColor colorWithRed:0.31 green:0.76 blue:0.97 alpha:1]); }
static UIColor *LSBackground(void) { return [UIColor colorWithRed:0.043 green:0.055 blue:0.067 alpha:1]; }
static UIColor *LSCardColor(void)  { return [UIColor colorWithRed:0.078 green:0.098 blue:0.118 alpha:1]; }
static UIColor *LSSecText(void)    { return [UIColor colorWithWhite:0.62 alpha:1]; }
static UIColor *LSGreen(void)      { return [UIColor colorWithRed:0.30 green:0.84 blue:0.55 alpha:1]; }
static UIColor *LSBlue(void)       { return [UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:1]; }
static UIColor *LSPurple(void)     { return [UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1]; }
static UIColor *LSTeal(void)       { return [UIColor colorWithRed:0.08 green:0.72 blue:0.65 alpha:1]; }
static UIColor *LSOrange(void)     { return [UIColor colorWithRed:0.96 green:0.62 blue:0.04 alpha:1]; }
static UIColor *LSPink(void)       { return [UIColor colorWithRed:0.93 green:0.28 blue:0.60 alpha:1]; }
static UIColor *LSGray(void)       { return [UIColor colorWithWhite:0.45 alpha:1]; }
static UIColor *LSRed(void)        { return [UIColor colorWithRed:0.94 green:0.27 blue:0.27 alpha:1]; }
static UIColor *LSAccent(void)     { return LSHex(LSS(@"LSAccent", @"#5CC8F5"), [UIColor colorWithRed:0.36 green:0.78 blue:0.96 alpha:1]); }

static NSString *LSStatusName(NSString *s) {
    if ([s isEqualToString:@"learning"]) return @"أتعلمها";
    if ([s isEqualToString:@"known"]) return @"أعرفها";
    return @"جديدة";
}
static UIColor *LSStatusColor(NSString *s) {
    if ([s isEqualToString:@"learning"]) return LSColorLearn();
    if ([s isEqualToString:@"known"]) return LSGreen();
    return LSColorNew();
}

static void LSHaptic(UIImpactFeedbackStyle style) {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        [g impactOccurred];
    }
}

// =====================================================================
#pragma mark - pronunciation

static NSString *LSVoiceLang(NSString *code) {
    if (!code.length) return @"en-US";
    static NSDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"ar":@"ar-SA", @"en":@"en-US", @"fr":@"fr-FR", @"es":@"es-ES", @"de":@"de-DE",
              @"it":@"it-IT", @"pt":@"pt-PT", @"tr":@"tr-TR", @"ru":@"ru-RU", @"fa":@"fa-IR",
              @"ur":@"ur-PK", @"hi":@"hi-IN", @"ja":@"ja-JP", @"ko":@"ko-KR", @"zh-CN":@"zh-CN",
              @"zh":@"zh-CN", @"he":@"he-IL", @"nl":@"nl-NL", @"pl":@"pl-PL", @"id":@"id-ID",
              @"vi":@"vi-VN", @"th":@"th-TH", @"el":@"el-GR", @"sv":@"sv-SE", @"uk":@"uk-UA",
              @"ro":@"ro-RO", @"cs":@"cs-CZ", @"hu":@"hu-HU", @"da":@"da-DK", @"fi":@"fi-FI",
              @"nb":@"nb-NO", @"no":@"nb-NO", @"sk":@"sk-SK", @"bg":@"bg-BG", @"hr":@"hr-HR",
              @"bn":@"bn-IN", @"ta":@"ta-IN", @"te":@"te-IN", @"ml":@"ml-IN", @"ms":@"ms-MY"};
    });
    NSString *base = [[code componentsSeparatedByString:@"-"] firstObject].lowercaseString;
    return m[code] ?: m[base] ?: [NSString stringWithFormat:@"%@-%@", base, base.uppercaseString];
}
static NSString *LSDetectVoiceLang(NSString *text) {
    if (@available(iOS 12.0, *)) {
        if (text.length >= 2) {
            NLLanguageRecognizer *r = [NLLanguageRecognizer new];
            [r processString:text];
            NSString *lang = (NSString *)r.dominantLanguage;
            if (lang.length) return LSVoiceLang(lang);
        }
    }
    return @"en-US";
}

@interface LSSpeech : NSObject
@property (nonatomic, strong) AVSpeechSynthesizer *synth;
+ (instancetype)shared;
- (void)speak:(NSString *)text language:(NSString *)lang;
- (void)speakWord:(NSString *)word;
- (void)speakTranslation:(NSString *)text;
- (void)stop;
@end
@implementation LSSpeech
+ (instancetype)shared {
    static LSSpeech *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [LSSpeech new]; s.synth = [AVSpeechSynthesizer new]; });
    return s;
}
- (void)speak:(NSString *)text language:(NSString *)lang {
    if (!text.length) return;
    [self.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithLanguage:lang];
    if (!v) v = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.voice = v;
    u.rate = (float)LSF(@"LSSpeechRate", 0.47);
    u.pitchMultiplier = 1.0;
    [self.synth speakUtterance:u];
}
- (void)speakWord:(NSString *)word { [self speak:word language:LSDetectVoiceLang(word)]; }
- (void)speakTranslation:(NSString *)text { [self speak:text language:LSVoiceLang(LSLang())]; }
- (void)stop { [self.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
@end

// =====================================================================
#pragma mark - networking

static void LSGet(NSString *url, void (^cb)(NSData *)) {
    NSURL *u = [NSURL URLWithString:url]; if (!u) { cb(nil); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u]; r.timeoutInterval = 8;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *x, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ cb(d); });
    }] resume];
}

static NSString *LSUrlEncode(NSString *s) {
    NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [set removeCharactersInString:@"&=?+#%"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:set] ?: @"";
}

static NSCache *LSTransCache(void) {
    static NSCache *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [NSCache new]; c.countLimit = 400; });
    return c;
}

static void LSTranslate(NSString *text, void (^cb)(NSString *)) {
    if (!text.length) { cb(nil); return; }
    NSString *key = [NSString stringWithFormat:@"%@|%@", LSLang(), text];
    NSString *hit = [LSTransCache() objectForKey:key];
    if (hit) { cb(hit); return; }
    NSString *q = LSUrlEncode(text);
    NSString *u = [NSString stringWithFormat:@"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%@&dt=t&q=%@", LSLang(), q];
    LSGet(u, ^(NSData *d) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSMutableString *s = [NSMutableString new];
        if ([j isKindOfClass:NSArray.class] && [j count] && [j[0] isKindOfClass:NSArray.class])
            for (id seg in j[0])
                if ([seg isKindOfClass:NSArray.class] && [seg count] && [seg[0] isKindOfClass:NSString.class])
                    [s appendString:seg[0]];
        if (s.length) { [LSTransCache() setObject:s forKey:key]; cb(s); return; }
        NSString *u2 = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=Autodetect|%@", q, LSLang()];
        LSGet(u2, ^(NSData *d2) {
            id j2 = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil] : nil;
            id rd = [j2 isKindOfClass:NSDictionary.class] ? j2[@"responseData"] : nil;
            NSString *m = [rd isKindOfClass:NSDictionary.class] ? rd[@"translatedText"] : nil;
            if ([m isKindOfClass:NSString.class] && m.length) [LSTransCache() setObject:m forKey:key];
            cb([m isKindOfClass:NSString.class] && m.length ? m : nil);
        });
    });
}

// Free dictionary lookup (English) → phonetic / part of speech / definition
typedef void (^LSDictBlock)(NSString *phonetic, NSString *pos, NSString *definition);

static void LSDictionaryLookup(NSString *word, LSDictBlock cb) {
    if (!word.length) { cb(nil, nil, nil); return; }
    static NSMutableDictionary *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSString *key = word.lowercaseString;
    NSDictionary *c = cache[key];
    if (c) { cb(c[@"p"], c[@"pos"], c[@"d"]); return; }
    NSString *q = LSUrlEncode(key);
    NSString *u = [NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", q];
    LSGet(u, ^(NSData *d) {
        NSString *ph = nil, *pos = nil, *def = nil;
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([j isKindOfClass:NSArray.class] && [((NSArray *)j) count]) {
            NSDictionary *e = j[0];
            if ([e isKindOfClass:NSDictionary.class]) {
                id p = e[@"phonetic"];
                if ([p isKindOfClass:NSString.class] && [p length]) ph = p;
                if (!ph && [e[@"phonetics"] isKindOfClass:NSArray.class])
                    for (NSDictionary *x in e[@"phonetics"])
                        if ([x isKindOfClass:NSDictionary.class] && [x[@"text"] isKindOfClass:NSString.class]) { ph = x[@"text"]; break; }
                NSArray *meanings = e[@"meanings"];
                if ([meanings isKindOfClass:NSArray.class] && meanings.count) {
                    NSDictionary *m0 = meanings.firstObject;
                    if ([m0 isKindOfClass:NSDictionary.class]) {
                        if ([m0[@"partOfSpeech"] isKindOfClass:NSString.class]) pos = m0[@"partOfSpeech"];
                        NSArray *defs = m0[@"definitions"];
                        if ([defs isKindOfClass:NSArray.class] && defs.count) {
                            NSDictionary *d0 = defs.firstObject;
                            if ([d0 isKindOfClass:NSDictionary.class] && [d0[@"definition"] isKindOfClass:NSString.class])
                                def = d0[@"definition"];
                        }
                    }
                }
            }
        }
        if (ph || pos || def) cache[key] = @{@"p": ph ?: @"", @"pos": pos ?: @"", @"d": def ?: @""};
        cb(ph, pos, def);
    });
}

// =====================================================================
#pragma mark - saved words store

@interface LSStore : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *words;
+ (instancetype)shared;
- (void)save;
- (NSMutableDictionary *)entryFor:(NSString *)word create:(BOOL)create;
- (void)setStatus:(NSString *)status forWord:(NSString *)word meaning:(NSString *)meaning
          context:(NSString *)context phonetic:(NSString *)phonetic pos:(NSString *)pos definition:(NSString *)definition;
- (void)setMetaForWord:(NSString *)word phonetic:(NSString *)phonetic pos:(NSString *)pos definition:(NSString *)definition;
- (void)markReviewed:(NSString *)word;
- (void)removeWord:(NSString *)word;
- (void)removeAll;
- (NSArray<NSString *> *)keysSorted;
- (NSInteger)total;
- (NSInteger)countWithStatus:(NSString *)status;
- (NSArray<NSString *> *)reviewQueue;
- (NSString *)exportJSON;
- (BOOL)importJSON:(NSString *)text;
@end

@implementation LSStore
+ (instancetype)shared {
    static LSStore *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [LSStore new]; [s load]; });
    return s;
}
- (void)load {
    self.words = [NSMutableDictionary new];
    NSDictionary *v3 = [UD() dictionaryForKey:@"LSWordsV3"];
    if (!v3) v3 = [UD() dictionaryForKey:@"LSWordsV2"];
    if (v3.count) {
        [v3 enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *st) {
            if ([v isKindOfClass:NSDictionary.class]) self.words[k] = [v mutableCopy];
        }];
    }
    if (!v3) {
        NSDictionary *v1 = [UD() dictionaryForKey:@"LSWords"];
        if (v1.count) {
            [v1 enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *st) {
                if ([v isKindOfClass:NSString.class]) self.words[k] = [@{@"s": v} mutableCopy];
            }];
        }
        [self save];
    }
}
- (void)save { [UD() setObject:self.words forKey:@"LSWordsV3"]; }
- (NSMutableDictionary *)entryFor:(NSString *)word create:(BOOL)create {
    if (!word.length) return nil;
    NSMutableDictionary *e = self.words[word];
    if (!e && create) {
        e = [NSMutableDictionary new];
        e[@"t"] = @([NSDate date].timeIntervalSince1970);
        e[@"r"] = @0;
        self.words[word] = e;
    }
    return e;
}
- (void)setStatus:(NSString *)status forWord:(NSString *)word meaning:(NSString *)meaning
          context:(NSString *)context phonetic:(NSString *)phonetic pos:(NSString *)pos definition:(NSString *)definition {
    NSMutableDictionary *e = [self entryFor:word create:YES];
    if (!e) return;
    e[@"s"] = status;
    if (meaning.length) e[@"m"] = meaning;
    if (context.length) e[@"c"] = context;
    if (phonetic.length) e[@"ph"] = phonetic;
    if (pos.length) e[@"pos"] = pos;
    if (definition.length) e[@"def"] = definition;
    if (!e[@"t"]) e[@"t"] = @([NSDate date].timeIntervalSince1970);
    if (!e[@"r"]) e[@"r"] = @0;
    [self save];
}
- (void)setMetaForWord:(NSString *)word phonetic:(NSString *)phonetic pos:(NSString *)pos definition:(NSString *)definition {
    NSMutableDictionary *e = self.words[word];
    if (!e) return;
    if (phonetic.length) e[@"ph"] = phonetic;
    if (pos.length) e[@"pos"] = pos;
    if (definition.length) e[@"def"] = definition;
    [self save];
}
- (void)markReviewed:(NSString *)word {
    NSMutableDictionary *e = self.words[word];
    if (!e) return;
    e[@"lr"] = @([NSDate date].timeIntervalSince1970);
    e[@"r"] = @([e[@"r"] integerValue] + 1);
    [self save];
}
- (void)removeWord:(NSString *)word { if (word.length) { [self.words removeObjectForKey:word]; [self save]; } }
- (void)removeAll { [self.words removeAllObjects]; [self save]; }
- (NSArray<NSString *> *)keysSorted { return [self.words.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]; }
- (NSInteger)total { return (NSInteger)self.words.count; }
- (NSInteger)countWithStatus:(NSString *)status {
    NSInteger n = 0;
    for (NSDictionary *e in self.words.allValues)
        if ([e[@"s"] isEqualToString:status]) n++;
    return n;
}
- (NSArray<NSString *> *)reviewQueue {
    NSMutableArray *a = [NSMutableArray new];
    for (NSString *k in self.words)
        if ([self.words[k][@"s"] isEqualToString:@"learning"]) [a addObject:k];
    [a sortUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {
        double lx = [self.words[x][@"lr"] doubleValue];
        double ly = [self.words[y][@"lr"] doubleValue];
        if (lx == ly) return [x localizedCaseInsensitiveCompare:y];
        return lx < ly ? NSOrderedAscending : NSOrderedDescending;
    }];
    return a;
}
- (NSString *)exportJSON {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.words options:NSJSONWritingPrettyPrinted error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}
- (BOOL)importJSON:(NSString *)text {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return NO;
    [j enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *st) {
        if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSDictionary.class])
            self.words[k] = [v mutableCopy];
    }];
    [self save];
    return YES;
}
@end

// =====================================================================
#pragma mark - small UI building blocks

static UIImage *LSBadge(NSString *symbol, UIColor *color) {
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 30, 30) cornerRadius:8];
        [color setFill]; [p fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        img = [img imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (img) {
            CGSize is = img.size;
            [img drawInRect:CGRectMake((30 - is.width) / 2, (30 - is.height) / 2, is.width, is.height)];
        }
    }];
}

static UIButton *LSSpeakerButton(CGFloat size, CGFloat iconSize) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:iconSize weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill" withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = LSAccent();
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = size / 2;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:size],
        [b.heightAnchor constraintEqualToConstant:size],
    ]];
    return b;
}

static UIButton *LSActionButton(NSString *title, UIColor *bg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 13;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    return b;
}

@interface LSPaddedLabel : UILabel
@property (nonatomic) UIEdgeInsets insets;
@end
@implementation LSPaddedLabel
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _insets = UIEdgeInsetsMake(3, 9, 3, 9);
        self.textAlignment = NSTextAlignmentCenter;
    }
    return self;
}
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + _insets.left + _insets.right, s.height + _insets.top + _insets.bottom);
}
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize s = [super sizeThatFits:size];
    return CGSizeMake(s.width + _insets.left + _insets.right, s.height + _insets.top + _insets.bottom);
}
- (void)drawTextInRect:(CGRect)rect { [super drawTextInRect:UIEdgeInsetsInsetRect(rect, _insets)]; }
@end

@interface LSGradientView : UIView @end
@implementation LSGradientView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *l = (CAGradientLayer *)self.layer;
        l.colors = @[(id)[UIColor colorWithRed:0.05 green:0.09 blue:0.12 alpha:1].CGColor,
                     (id)LSBackground().CGColor,
                     (id)[UIColor colorWithRed:0.035 green:0.045 blue:0.055 alpha:1].CGColor];
        l.locations = @[@0.0, @0.42, @1.0];
        l.startPoint = CGPointMake(0.5, 0);
        l.endPoint = CGPointMake(0.5, 1);
    }
    return self;
}
@end

@interface LSGradientBar : UIView @end
@implementation LSGradientBar
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *l = (CAGradientLayer *)self.layer;
        l.colors = @[(id)LSAccent().CGColor, (id)LSColorLearn().CGColor, (id)LSColorNew().CGColor];
        l.startPoint = CGPointMake(0, 0.5);
        l.endPoint = CGPointMake(1, 0.5);
    }
    return self;
}
@end

// =====================================================================
#pragma mark - stats header

@interface LSStatsHeader : UIView
@property (nonatomic, strong) UILabel *totalL, *learningL, *knownL;
@property (nonatomic, strong) UIButton *reviewBtn;
@property (nonatomic, copy) void (^onReview)(void);
- (void)reload;
@end

@implementation LSStatsHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *card = [UIView new];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = LSCardColor();
        card.layer.cornerRadius = 22;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:card];

        UILabel *title = [UILabel new];
        title.text = @"مكتبتك اللغوية";
        title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        title.textColor = UIColor.whiteColor;

        UILabel *sub = [UILabel new];
        sub.text = @"تابع تقدمك في تعلّم الكلمات";
        sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        sub.textColor = LSSecText();

        _totalL = [self statValue];
        _learningL = [self statValue];
        _knownL = [self statValue];
        UIStackView *stats = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self statColumn:_totalL title:@"الكل"],
            [self statColumn:_learningL title:@"أتعلمها"],
            [self statColumn:_knownL title:@"أعرفها"],
        ]];
        stats.axis = UILayoutConstraintAxisHorizontal;
        stats.distribution = UIStackViewDistributionFillEqually;
        stats.spacing = 8;

        _reviewBtn = LSActionButton(@"مراجعة سريعة", LSAccent());
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
        [_reviewBtn setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:cfg] forState:UIControlStateNormal];
        _reviewBtn.tintColor = UIColor.whiteColor;
        _reviewBtn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
        _reviewBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
        [_reviewBtn.heightAnchor constraintEqualToConstant:44].active = YES;
        [_reviewBtn addTarget:self action:@selector(reviewTapped) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[title, sub, stats, _reviewBtn]];
        v.axis = UILayoutConstraintAxisVertical;
        v.alignment = UIStackViewAlignmentFill;
        v.spacing = 10;
        [v setCustomSpacing:4 afterView:title];
        [v setCustomSpacing:16 afterView:stats];
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:v];

        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

            [v.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
            [v.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
            [v.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
            [v.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        ]];
        [self reload];
    }
    return self;
}
- (UILabel *)statValue {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.text = @"0";
    return l;
}
- (UIView *)statColumn:(UILabel *)value title:(NSString *)title {
    UILabel *l = [UILabel new];
    l.text = title;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    l.textColor = LSSecText();
    l.textAlignment = NSTextAlignmentCenter;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[value, l]];
    s.axis = UILayoutConstraintAxisVertical;
    s.alignment = UIStackViewAlignmentFill;
    s.spacing = 2;
    return s;
}
- (void)reviewTapped { if (self.onReview) self.onReview(); }
- (void)reload {
    LSStore *st = [LSStore shared];
    _totalL.text = [NSString stringWithFormat:@"%ld", (long)[st total]];
    _learningL.text = [NSString stringWithFormat:@"%ld", (long)[st countWithStatus:@"learning"]];
    _knownL.text = [NSString stringWithFormat:@"%ld", (long)[st countWithStatus:@"known"]];
}
- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat w = size.width > 0 ? size.width : UIScreen.mainScreen.bounds.size.width;
    CGSize s = [self systemLayoutSizeFittingSize:CGSizeMake(w, 0)
                  withHorizontalFittingPriority:UILayoutPriorityRequired
                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return CGSizeMake(w, ceil(s.height));
}
@end

// =====================================================================
#pragma mark - word card (player overlay)

@interface LSWordCard : UIView
@property (nonatomic, strong) UILabel *wordL, *phL, *meaningL, *defL, *ctxL;
@property (nonatomic, strong) LSPaddedLabel *chipL;
@property (nonatomic, strong) UIButton *speakWord, *speakMeaning, *learnBtn, *knownBtn, *closeBtn;
@property (nonatomic, copy) void (^onSpeakWord)(void);
@property (nonatomic, copy) void (^onSpeakMeaning)(void);
@property (nonatomic, copy) void (^onLearning)(void);
@property (nonatomic, copy) void (^onKnown)(void);
@property (nonatomic, copy) void (^onClose)(void);
- (void)showWord:(NSString *)word phonetic:(NSString *)phonetic meaning:(NSString *)meaning
      definition:(NSString *)definition context:(NSString *)context status:(NSString *)status loading:(BOOL)loading;
- (void)updateMeaning:(NSString *)meaning;
- (void)updatePhonetic:(NSString *)phonetic definition:(NSString *)definition;
- (void)updateContext:(NSString *)context;
- (void)updateStatus:(NSString *)status;
- (CGSize)sizeThatFits:(CGSize)size;
@end

@implementation LSWordCard

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = 24;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.userInteractionEnabled = NO;
        [self addSubview:blur];

        UIView *dim = [UIView new];
        dim.translatesAutoresizingMaskIntoConstraints = NO;
        dim.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.45];
        dim.userInteractionEnabled = NO;
        [self addSubview:dim];

        LSGradientBar *accent = [LSGradientBar new];
        accent.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:accent];

        _wordL = [UILabel new];
        _wordL.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        _wordL.textColor = UIColor.whiteColor;
        _wordL.numberOfLines = 1;
        _wordL.adjustsFontSizeToFitWidth = YES;
        _wordL.minimumScaleFactor = 0.65;

        _phL = [UILabel new];
        _phL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _phL.textColor = [UIColor colorWithWhite:0.62 alpha:1];

        _chipL = [LSPaddedLabel new];
        _chipL.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _chipL.layer.cornerRadius = 10;
        _chipL.clipsToBounds = YES;

        _speakWord = LSSpeakerButton(40, 16);
        _speakMeaning = LSSpeakerButton(34, 14);
        _speakMeaning.hidden = YES;

        _meaningL = [UILabel new];
        _meaningL.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
        _meaningL.textColor = UIColor.whiteColor;
        _meaningL.numberOfLines = 3;

        _defL = [UILabel new];
        _defL.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _defL.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        _defL.numberOfLines = 3;

        _ctxL = [UILabel new];
        _ctxL.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _ctxL.textColor = [UIColor colorWithWhite:0.58 alpha:1];
        _ctxL.numberOfLines = 3;

        UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_wordL, _speakWord]];
        header.axis = UILayoutConstraintAxisHorizontal;
        header.alignment = UIStackViewAlignmentCenter;
        header.spacing = 10;

        UIView *subSpacer = [UIView new];
        [subSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [subSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *sub = [[UIStackView alloc] initWithArrangedSubviews:@[_phL, subSpacer, _chipL]];
        sub.axis = UILayoutConstraintAxisHorizontal;
        sub.alignment = UIStackViewAlignmentCenter;
        sub.spacing = 8;

        UIStackView *meaningRow = [[UIStackView alloc] initWithArrangedSubviews:@[_meaningL, _speakMeaning]];
        meaningRow.axis = UILayoutConstraintAxisHorizontal;
        meaningRow.alignment = UIStackViewAlignmentCenter;
        meaningRow.spacing = 10;

        _learnBtn = LSActionButton(@"أتعلمها", LSColorLearn());
        _knownBtn = LSActionButton(@"أعرفها", LSGreen());
        _closeBtn = LSActionButton(@"إغلاق", [UIColor colorWithWhite:1 alpha:0.12]);
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[_learnBtn, _knownBtn, _closeBtn]];
        actions.axis = UILayoutConstraintAxisHorizontal;
        actions.distribution = UIStackViewDistributionFillEqually;
        actions.spacing = 8;
        [actions.heightAnchor constraintEqualToConstant:46].active = YES;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, sub, meaningRow, _defL, _ctxL, actions]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 12;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [dim.topAnchor constraintEqualToAnchor:self.topAnchor],
            [dim.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [dim.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [dim.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [accent.topAnchor constraintEqualToAnchor:self.topAnchor],
            [accent.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [accent.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [accent.heightAnchor constraintEqualToConstant:3],

            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:20],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-18],
        ]];

        [_speakWord addTarget:self action:@selector(speakWordTapped) forControlEvents:UIControlEventTouchUpInside];
        [_speakMeaning addTarget:self action:@selector(speakMeaningTapped) forControlEvents:UIControlEventTouchUpInside];
        [_learnBtn addTarget:self action:@selector(learningTapped) forControlEvents:UIControlEventTouchUpInside];
        [_knownBtn addTarget:self action:@selector(knownTapped) forControlEvents:UIControlEventTouchUpInside];
        [_closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)speakWordTapped { if (self.onSpeakWord) self.onSpeakWord(); }
- (void)speakMeaningTapped { if (self.onSpeakMeaning) self.onSpeakMeaning(); }
- (void)learningTapped { if (self.onLearning) self.onLearning(); }
- (void)knownTapped { if (self.onKnown) self.onKnown(); }
- (void)closeTapped { if (self.onClose) self.onClose(); }

- (void)showWord:(NSString *)word phonetic:(NSString *)phonetic meaning:(NSString *)meaning
      definition:(NSString *)definition context:(NSString *)context status:(NSString *)status loading:(BOOL)loading {
    _wordL.text = word;
    _phL.text = phonetic.length ? phonetic : @"";
    _phL.hidden = !phonetic.length;
    [self updateStatus:status];
    _meaningL.text = meaning.length ? meaning : @"…";
    _speakMeaning.hidden = loading || !meaning.length;
    _defL.text = definition.length ? definition : @"";
    _defL.hidden = !definition.length;
    _ctxL.text = context.length ? [NSString stringWithFormat:@"«%@»", context] : @"";
    _ctxL.hidden = !context.length;
    [self setNeedsLayout];
}
- (void)updateMeaning:(NSString *)meaning {
    _meaningL.text = meaning.length ? meaning : @"…";
    _speakMeaning.hidden = !meaning.length;
    [self setNeedsLayout];
}
- (void)updatePhonetic:(NSString *)phonetic definition:(NSString *)definition {
    if (phonetic.length) { _phL.text = phonetic; _phL.hidden = NO; }
    if (definition.length) { _defL.text = definition; _defL.hidden = NO; }
    [self setNeedsLayout];
}
- (void)updateContext:(NSString *)context {
    _ctxL.text = context.length ? [NSString stringWithFormat:@"«%@»", context] : @"";
    _ctxL.hidden = !context.length;
    [self setNeedsLayout];
}
- (void)updateStatus:(NSString *)status {
    UIColor *col = LSStatusColor(status);
    _chipL.text = LSStatusName(status);
    _chipL.textColor = col;
    _chipL.backgroundColor = [col colorWithAlphaComponent:0.16];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat w = MIN(size.width, 520);
    if (w <= 0) w = 320;
    CGSize s = [self systemLayoutSizeFittingSize:CGSizeMake(w, 0)
                  withHorizontalFittingPriority:UILayoutPriorityRequired
                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return CGSizeMake(w, ceil(s.height));
}
@end

// =====================================================================
#pragma mark - word details

@interface LSWordDetailVC : UIViewController
@property (nonatomic, copy) NSString *word;
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation LSWordDetailVC {
    UILabel *_wordL, *_phL, *_meaningL, *_defL, *_ctxL;
    UILabel *_defTitle, *_ctxTitle;
    LSPaddedLabel *_chip;
    UIButton *_speakWord, *_speakMeaning, *_learnBtn, *_knownBtn, *_deleteBtn;
    BOOL _didLoad;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"تفاصيل الكلمة";
    self.view.backgroundColor = LSBackground();

    LSGradientView *bg = [[LSGradientView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:bg atIndex:0];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = LSCardColor();
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [content addSubview:card];

    _wordL = [UILabel new];
    _wordL.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    _wordL.textColor = UIColor.whiteColor;
    _wordL.numberOfLines = 1;
    _wordL.adjustsFontSizeToFitWidth = YES;
    _wordL.minimumScaleFactor = 0.6;

    _phL = [UILabel new];
    _phL.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _phL.textColor = LSSecText();

    _speakWord = LSSpeakerButton(42, 17);
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_wordL, _speakWord]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;

    _chip = [LSPaddedLabel new];
    _chip.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _chip.layer.cornerRadius = 10;
    _chip.clipsToBounds = YES;

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *chipRow = [[UIStackView alloc] initWithArrangedSubviews:@[_chip, spacer]];
    chipRow.axis = UILayoutConstraintAxisHorizontal;
    chipRow.alignment = UIStackViewAlignmentCenter;

    UIView *sep1 = [self separator];
    UIView *sep2 = [self separator];

    UILabel *meaningTitle = [self sectionTitle:@"المعنى"];
    _meaningL = [UILabel new];
    _meaningL.font = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    _meaningL.textColor = UIColor.whiteColor;
    _meaningL.numberOfLines = 0;

    _speakMeaning = LSSpeakerButton(36, 15);
    UIStackView *meaningRow = [[UIStackView alloc] initWithArrangedSubviews:@[_meaningL, _speakMeaning]];
    meaningRow.axis = UILayoutConstraintAxisHorizontal;
    meaningRow.alignment = UIStackViewAlignmentCenter;
    meaningRow.spacing = 10;

    _defTitle = [self sectionTitle:@"التعريف"];
    _defL = [UILabel new];
    _defL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _defL.textColor = [UIColor colorWithWhite:0.70 alpha:1];
    _defL.numberOfLines = 0;

    _ctxTitle = [self sectionTitle:@"السياق"];
    _ctxL = [UILabel new];
    _ctxL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _ctxL.textColor = [UIColor colorWithWhite:0.66 alpha:1];
    _ctxL.numberOfLines = 0;

    _learnBtn = LSActionButton(@"أتعلمها", LSColorLearn());
    _knownBtn = LSActionButton(@"أعرفها", LSGreen());
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[_learnBtn, _knownBtn]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 10;
    [actions.heightAnchor constraintEqualToConstant:46].active = YES;

    _deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_deleteBtn setTitle:@"حذف الكلمة" forState:UIControlStateNormal];
    [_deleteBtn setTitleColor:LSRed() forState:UIControlStateNormal];
    _deleteBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _deleteBtn.backgroundColor = [LSRed() colorWithAlphaComponent:0.12];
    _deleteBtn.layer.cornerRadius = 12;
    [_deleteBtn.heightAnchor constraintEqualToConstant:44].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, _phL, chipRow, sep1, meaningTitle, meaningRow, _defTitle, _defL,
        _ctxTitle, _ctxL, sep2, actions, _deleteBtn
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12;
    [stack setCustomSpacing:4 afterView:header];
    [stack setCustomSpacing:10 afterView:_phL];
    [stack setCustomSpacing:16 afterView:chipRow];
    [stack setCustomSpacing:6 afterView:meaningTitle];
    [stack setCustomSpacing:6 afterView:_defTitle];
    [stack setCustomSpacing:6 afterView:_ctxTitle];
    [stack setCustomSpacing:18 afterView:sep2];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [card.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [card.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],

        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];

    [_speakWord addTarget:self action:@selector(speakWordTapped) forControlEvents:UIControlEventTouchUpInside];
    [_speakMeaning addTarget:self action:@selector(speakMeaningTapped) forControlEvents:UIControlEventTouchUpInside];
    [_learnBtn addTarget:self action:@selector(learningTapped) forControlEvents:UIControlEventTouchUpInside];
    [_knownBtn addTarget:self action:@selector(knownTapped) forControlEvents:UIControlEventTouchUpInside];
    [_deleteBtn addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];

    _didLoad = YES;
    [self reload];
    [self loadMissing];
}
- (UIView *)separator {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    [v.heightAnchor constraintEqualToConstant:1].active = YES;
    return v;
}
- (UILabel *)sectionTitle:(NSString *)t {
    UILabel *l = [UILabel new];
    l.text = t;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = LSAccent();
    return l;
}
- (void)reload {
    if (!_didLoad) return;
    NSMutableDictionary *e = [LSStore shared].words[_word];
    _wordL.text = _word;
    _phL.text = [e[@"ph"] length] ? e[@"ph"] : @"";
    _phL.hidden = ![e[@"ph"] length];
    NSString *status = e[@"s"] ?: @"new";
    UIColor *col = LSStatusColor(status);
    _chip.text = LSStatusName(status);
    _chip.textColor = col;
    _chip.backgroundColor = [col colorWithAlphaComponent:0.16];
    _meaningL.text = [e[@"m"] length] ? e[@"m"] : @"…";
    _speakMeaning.hidden = ![e[@"m"] length];
    _defTitle.hidden = ![e[@"def"] length];
    _defL.hidden = ![e[@"def"] length];
    _defL.text = e[@"def"];
    _ctxTitle.hidden = ![e[@"c"] length];
    _ctxL.hidden = ![e[@"c"] length];
    _ctxL.text = [e[@"c"] length] ? [NSString stringWithFormat:@"«%@»", e[@"c"]] : @"";
    _learnBtn.backgroundColor = [LSColorLearn() colorWithAlphaComponent:[status isEqualToString:@"learning"] ? 1.0 : 0.35];
    _knownBtn.backgroundColor = [LSGreen() colorWithAlphaComponent:[status isEqualToString:@"known"] ? 1.0 : 0.35];
    [self.view setNeedsLayout];
}
- (void)loadMissing {
    NSMutableDictionary *e = [LSStore shared].words[_word];
    if (!e) return;
    if (![e[@"m"] length]) {
        __weak typeof(self) ws = self;
        LSTranslate(_word, ^(NSString *tr) {
            if (!tr.length) return;
            NSMutableDictionary *ee = [LSStore shared].words[ws.word];
            if (!ee) return;
            ee[@"m"] = tr; [[LSStore shared] save];
            [ws reload];
            if (ws.onChange) ws.onChange();
        });
    }
    if (LSB(@"LSDict", YES) && ![e[@"def"] length]) {
        __weak typeof(self) ws = self;
        LSDictionaryLookup(_word, ^(NSString *ph, NSString *pos, NSString *def) {
            if (!ph && !pos && !def) return;
            [[LSStore shared] setMetaForWord:ws.word phonetic:ph pos:pos definition:def];
            [ws reload];
            if (ws.onChange) ws.onChange();
        });
    }
}
- (void)speakWordTapped { [[LSSpeech shared] speakWord:_word]; LSHaptic(UIImpactFeedbackStyleLight); }
- (void)speakMeaningTapped {
    NSDictionary *e = [LSStore shared].words[_word];
    [[LSSpeech shared] speakTranslation:e[@"m"] ?: @""];
}
- (void)setStatus:(NSString *)s {
    NSDictionary *e = [LSStore shared].words[_word] ?: @{};
    [[LSStore shared] setStatus:s forWord:_word meaning:e[@"m"] context:e[@"c"] phonetic:e[@"ph"] pos:e[@"pos"] definition:e[@"def"]];
    LSHaptic(UIImpactFeedbackStyleMedium);
    [self reload];
    if (self.onChange) self.onChange();
}
- (void)learningTapped { [self setStatus:@"learning"]; }
- (void)knownTapped { [self setStatus:@"known"]; }
- (void)deleteTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"حذف الكلمة؟" message:_word preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[LSStore shared] removeWord:self.word];
        if (self.onChange) self.onChange();
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

// =====================================================================
#pragma mark - saved words list

@interface LSWordCell : UITableViewCell
@property (nonatomic, strong) UIView *card, *bar;
@property (nonatomic, strong) UILabel *wordL, *metaL, *meaningL;
@property (nonatomic, strong) UIButton *speakBtn;
@property (nonatomic, copy) void (^onSpeak)(void);
- (void)configureWithWord:(NSString *)word entry:(NSDictionary *)entry;
@end

@implementation LSWordCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [UIView new];
        _card.backgroundColor = LSCardColor();
        _card.layer.cornerRadius = 16;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_card];

        _bar = [UIView new];
        _bar.layer.cornerRadius = 2;
        [_card addSubview:_bar];

        _wordL = [UILabel new];
        _wordL.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        _wordL.textColor = UIColor.whiteColor;
        [_card addSubview:_wordL];

        _metaL = [UILabel new];
        _metaL.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        _metaL.textColor = LSSecText();
        [_card addSubview:_metaL];

        _meaningL = [UILabel new];
        _meaningL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _meaningL.textColor = [UIColor colorWithWhite:0.80 alpha:1];
        _meaningL.numberOfLines = 2;
        [_card addSubview:_meaningL];

        _speakBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        [_speakBtn setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill" withConfiguration:cfg] forState:UIControlStateNormal];
        _speakBtn.tintColor = LSAccent();
        _speakBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        _speakBtn.layer.cornerRadius = 19;
        [_speakBtn addTarget:self action:@selector(speakTapped) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_speakBtn];
    }
    return self;
}
- (void)speakTapped { if (self.onSpeak) self.onSpeak(); }
- (void)configureWithWord:(NSString *)word entry:(NSDictionary *)entry {
    NSString *status = entry[@"s"] ?: @"new";
    _wordL.text = word;
    _wordL.textColor = LSStatusColor(status);
    NSString *ph = entry[@"ph"];
    _metaL.text = ph.length ? [NSString stringWithFormat:@"%@ · %@", ph, LSStatusName(status)] : LSStatusName(status);
    _meaningL.text = [entry[@"m"] length] ? entry[@"m"] : @"—";
    _bar.backgroundColor = LSStatusColor(status);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _card.frame = CGRectMake(16, 5, w - 32, h - 10);
    CGFloat cw = _card.bounds.size.width, ch = _card.bounds.size.height;
    _bar.frame = CGRectMake(0, 12, 4, ch - 24);
    _speakBtn.frame = CGRectMake(cw - 50, (ch - 38) / 2, 38, 38);
    _wordL.frame = CGRectMake(16, 12, cw - 16 - 52, 24);
    _metaL.frame = CGRectMake(16, 37, cw - 16 - 52, 17);
    _meaningL.frame = CGRectMake(16, 58, cw - 16 - 52, 34);
}
@end

@interface LSWordsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation LSWordsVC {
    UISegmentedControl *_seg;
    UISearchBar *_search;
    UITableView *_table;
    UILabel *_empty;
    NSArray<NSString *> *_keys;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"الكلمات المحفوظة";
    self.view.backgroundColor = LSBackground();
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeTapped)];
    }

    LSGradientView *bg = [[LSGradientView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:bg];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"أتعلمها", @"أعرفها", @"الكل"]];
    _seg.selectedSegmentIndex = 0;
    _seg.selectedSegmentTintColor = LSAccent();
    [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [_seg addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_seg];

    _search = [[UISearchBar alloc] init];
    _search.delegate = self;
    _search.placeholder = @"ابحث عن كلمة أو معنى";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.tintColor = LSAccent();
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_search];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = 104;
    _table.contentInset = UIEdgeInsetsMake(4, 0, 24, 0);
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_table];

    _empty = [UILabel new];
    _empty.text = @"لا توجد كلمات هنا بعد";
    _empty.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _empty.textColor = LSSecText();
    _empty.textAlignment = NSTextAlignmentCenter;
    _empty.translatesAutoresizingMaskIntoConstraints = NO;
    _empty.hidden = YES;
    [self.view addSubview:_empty];

    [NSLayoutConstraint activateConstraints:@[
        [_seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_seg.heightAnchor constraintEqualToConstant:36],

        [_search.topAnchor constraintEqualToAnchor:_seg.bottomAnchor constant:8],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_table.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:4],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_empty.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_empty.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    [self reload];
}
- (void)closeTapped { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)searchBar:(UISearchBar *)b textDidChange:(NSString *)t { [self reload]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)b { [b resignFirstResponder]; }
- (void)reload {
    NSString *q = _search.text.lowercaseString ?: @"";
    NSInteger m = _seg.selectedSegmentIndex;
    LSStore *st = [LSStore shared];
    NSMutableArray *a = [NSMutableArray new];
    for (NSString *k in [st keysSorted]) {
        NSDictionary *e = st.words[k];
        NSString *s = e[@"s"], *mm = e[@"m"] ?: @"";
        if (m == 0 && ![s isEqualToString:@"learning"]) continue;
        if (m == 1 && ![s isEqualToString:@"known"]) continue;
        if (q.length && [k rangeOfString:q].location == NSNotFound && [mm rangeOfString:q].location == NSNotFound) continue;
        [a addObject:k];
    }
    _keys = a;
    _empty.hidden = _keys.count > 0;
    [_table reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_keys.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"LSWordCell";
    LSWordCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[LSWordCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSString *k = _keys[ip.row];
    NSDictionary *e = [LSStore shared].words[k];
    [c configureWithWord:k entry:e];
    c.onSpeak = ^{ [[LSSpeech shared] speakWord:k]; LSHaptic(UIImpactFeedbackStyleLight); };
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    LSWordDetailVC *d = [LSWordDetailVC new];
    d.word = _keys[ip.row];
    __weak typeof(self) ws = self;
    d.onChange = ^{ [ws reload]; };
    [self.navigationController pushViewController:d animated:YES];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *k = _keys[ip.row];
    NSDictionary *e = [LSStore shared].words[k];
    BOOL learning = [e[@"s"] isEqualToString:@"learning"];
    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:learning ? @"أعرفها" : @"أتعلمها" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[LSStore shared] setStatus:learning ? @"known" : @"learning" forWord:k meaning:e[@"m"] context:e[@"c"] phonetic:e[@"ph"] pos:e[@"pos"] definition:e[@"def"]];
        [self reload]; done(YES);
    }];
    toggle.backgroundColor = learning ? LSGreen() : LSColorLearn();
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"حذف" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[LSStore shared] removeWord:k];
        [self reload]; done(YES);
    }];
    del.backgroundColor = LSRed();
    return [UISwipeActionsConfiguration configurationWithActions:@[del, toggle]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *k = _keys[ip.row];
    UIContextualAction *speak = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"نطق" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[LSSpeech shared] speakWord:k]; done(YES);
    }];
    speak.backgroundColor = LSAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[speak]];
}
@end

// =====================================================================
#pragma mark - flashcard review

@interface LSReviewVC : UIViewController
@end

@implementation LSReviewVC {
    NSArray<NSString *> *_queue;
    NSInteger _index;
    UILabel *_progressL, *_wordL, *_phL, *_meaningL, *_ctxL, *_hintL;
    UIProgressView *_bar;
    UIButton *_speakBtn, *_revealBtn, *_knownBtn, *_learnBtn;
    UIView *_card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"مراجعة سريعة";
    self.view.backgroundColor = LSBackground();
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeTapped)];
    }
    LSGradientView *bg = [[LSGradientView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:bg];

    _progressL = [UILabel new];
    _progressL.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _progressL.textColor = LSSecText();
    _progressL.textAlignment = NSTextAlignmentCenter;

    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _bar.progressTintColor = LSAccent();
    _bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.10];
    _bar.layer.cornerRadius = 3;
    _bar.clipsToBounds = YES;

    _card = [UIView new];
    _card.backgroundColor = LSCardColor();
    _card.layer.cornerRadius = 24;
    _card.layer.cornerCurve = kCACornerCurveContinuous;

    _wordL = [UILabel new];
    _wordL.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    _wordL.textColor = UIColor.whiteColor;
    _wordL.textAlignment = NSTextAlignmentCenter;
    _wordL.adjustsFontSizeToFitWidth = YES;
    _wordL.minimumScaleFactor = 0.6;

    _speakBtn = LSSpeakerButton(46, 19);
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_wordL, _speakBtn]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;

    _phL = [UILabel new];
    _phL.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _phL.textColor = LSSecText();
    _phL.textAlignment = NSTextAlignmentCenter;

    _hintL = [UILabel new];
    _hintL.text = @"اضغط «إظهار المعنى» لاختبار نفسك";
    _hintL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _hintL.textColor = LSSecText();
    _hintL.textAlignment = NSTextAlignmentCenter;
    _hintL.numberOfLines = 0;

    _meaningL = [UILabel new];
    _meaningL.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    _meaningL.textColor = UIColor.whiteColor;
    _meaningL.textAlignment = NSTextAlignmentCenter;
    _meaningL.numberOfLines = 0;

    _ctxL = [UILabel new];
    _ctxL.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _ctxL.textColor = [UIColor colorWithWhite:0.60 alpha:1];
    _ctxL.textAlignment = NSTextAlignmentCenter;
    _ctxL.numberOfLines = 0;

    _revealBtn = LSActionButton(@"إظهار المعنى", LSAccent());
    _learnBtn = LSActionButton(@"أتعلمها", LSColorLearn());
    _knownBtn = LSActionButton(@"أعرفها", LSGreen());
    [_revealBtn.heightAnchor constraintEqualToConstant:48].active = YES;
    [_learnBtn.heightAnchor constraintEqualToConstant:48].active = YES;
    [_knownBtn.heightAnchor constraintEqualToConstant:48].active = YES;

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[_learnBtn, _knownBtn]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 10;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, _phL, _hintL, _meaningL, _ctxL, _revealBtn, actions]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12;
    [stack setCustomSpacing:6 afterView:header];
    [stack setCustomSpacing:18 afterView:_phL];
    [stack setCustomSpacing:18 afterView:_meaningL];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];

    [self.view addSubview:_progressL];
    [self.view addSubview:_bar];
    [self.view addSubview:_card];
    _progressL.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _card.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [_progressL.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [_progressL.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_progressL.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_bar.topAnchor constraintEqualToAnchor:_progressL.bottomAnchor constant:8],
        [_bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_bar.heightAnchor constraintEqualToConstant:6],

        [_card.topAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:20],
        [_card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_card.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:26],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-22],
    ]];

    [_revealBtn addTarget:self action:@selector(revealTapped) forControlEvents:UIControlEventTouchUpInside];
    [_learnBtn addTarget:self action:@selector(learningTapped) forControlEvents:UIControlEventTouchUpInside];
    [_knownBtn addTarget:self action:@selector(knownTapped) forControlEvents:UIControlEventTouchUpInside];
    [_speakBtn addTarget:self action:@selector(speakTapped) forControlEvents:UIControlEventTouchUpInside];

    _queue = [[LSStore shared] reviewQueue];
    _index = 0;
    [self reload];
}
- (void)closeTapped { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload {
    LSStore *st = [LSStore shared];
    if (_index >= (NSInteger)_queue.count) {
        _progressL.text = @"اكتملت المراجعة";
        _bar.progress = 1;
        _wordL.text = @"أحسنت!";
        _wordL.textColor = LSGreen();
        _phL.text = @"";
        _phL.hidden = YES;
        _hintL.text = @"راجعت كل الكلمات المستحقة الآن. عد لاحقاً لمراجعة المزيد.";
        _hintL.hidden = NO;
        _meaningL.text = @"";
        _meaningL.hidden = YES;
        _ctxL.text = @"";
        _ctxL.hidden = YES;
        _speakBtn.hidden = YES;
        _revealBtn.hidden = YES;
        _learnBtn.hidden = YES;
        _knownBtn.hidden = YES;
        return;
    }
    NSString *word = _queue[_index];
    NSDictionary *e = st.words[word];
    _progressL.text = [NSString stringWithFormat:@"%ld / %ld", (long)(_index + 1), (long)_queue.count];
    _bar.progress = _queue.count ? (float)_index / (float)_queue.count : 0;
    _wordL.text = word;
    _wordL.textColor = UIColor.whiteColor;
    _phL.text = [e[@"ph"] length] ? e[@"ph"] : @"";
    _phL.hidden = ![e[@"ph"] length];
    _speakBtn.hidden = NO;
    _meaningL.text = [e[@"m"] length] ? e[@"m"] : @"—";
    _meaningL.hidden = YES;
    _ctxL.text = [e[@"c"] length] ? [NSString stringWithFormat:@"«%@»", e[@"c"]] : @"";
    _ctxL.hidden = YES;
    _hintL.hidden = NO;
    _revealBtn.hidden = NO;
    _learnBtn.hidden = YES;
    _knownBtn.hidden = YES;
    _card.alpha = 0;
    _card.transform = CGAffineTransformMakeScale(0.98, 0.98);
    [UIView animateWithDuration:0.22 animations:^{
        self->_card.alpha = 1;
        self->_card.transform = CGAffineTransformIdentity;
    }];
}
- (void)revealTapped {
    _hintL.hidden = YES;
    _meaningL.hidden = NO;
    _ctxL.hidden = (_ctxL.text.length == 0);
    _revealBtn.hidden = YES;
    _learnBtn.hidden = NO;
    _knownBtn.hidden = NO;
    [UIView transitionWithView:_card duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self->_card layoutIfNeeded];
    } completion:nil];
}
- (void)speakTapped {
    if (_index < (NSInteger)_queue.count) [[LSSpeech shared] speakWord:_queue[_index]];
}
- (void)advanceWithStatus:(NSString *)status haptic:(UIImpactFeedbackStyle)style {
    if (_index >= (NSInteger)_queue.count) return;
    NSString *w = _queue[_index];
    NSDictionary *e = [LSStore shared].words[w] ?: @{};
    [[LSStore shared] setStatus:status forWord:w meaning:e[@"m"] context:e[@"c"] phonetic:e[@"ph"] pos:e[@"pos"] definition:e[@"def"]];
    [[LSStore shared] markReviewed:w];
    _index++;
    LSHaptic(style);
    [self reload];
}
- (void)learningTapped { [self advanceWithStatus:@"learning" haptic:UIImpactFeedbackStyleLight]; }
- (void)knownTapped { [self advanceWithStatus:@"known" haptic:UIImpactFeedbackStyleMedium]; }
@end

// =====================================================================
#pragma mark - settings

@interface LSSettingsVC : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) dispatch_block_t onClose;
@end

@implementation LSSettingsVC {
    LSStatsHeader *_header;
    CGFloat _lastWidth;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lang Subs";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.view.backgroundColor = LSBackground();
    self.tableView.backgroundColor = UIColor.clearColor;
    LSGradientView *bg = [[LSGradientView alloc] initWithFrame:self.tableView.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundView = bg;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 64, 0, 16);
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 28, 0);
    self.tableView.estimatedRowHeight = 60;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    _header = [[LSStatsHeader alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 1)];
    __weak typeof(self) ws = self;
    _header.onReview = ^{
        [ws.navigationController pushViewController:[LSReviewVC new] animated:YES];
    };
    [self sizeHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController.presentationController) self.navigationController.presentationController.delegate = self;
    [_header reload];
    [self sizeHeader];
    [self.tableView reloadData];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _lastWidth) > 1) [self sizeHeader];
}
- (void)sizeHeader {
    CGFloat w = self.tableView.bounds.size.width;
    if (w <= 0) w = UIScreen.mainScreen.bounds.size.width;
    _lastWidth = w;
    CGSize s = [_header sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _header.frame = CGRectMake(0, 0, w, s.height);
    self.tableView.tableHeaderView = _header;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)p { [self fireClose]; }
- (void)done { [self.navigationController dismissViewControllerAnimated:YES completion:^{ [self fireClose]; }]; }
- (void)fireClose { if (self.onClose) self.onClose(); }

// ---- table data
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger[]){4, 3, 6, 5}[s]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"التعلّم", @"الترجمة", @"العرض", @"الوصول والبيانات"][s];
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        h.textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    }
}

- (UITableViewCell *)basicCell:(NSString *)title sub:(NSString *)sub symbol:(NSString *)sym color:(UIColor *)color {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text = title;
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.text = sub;
    c.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    c.detailTextLabel.textColor = LSSecText();
    c.detailTextLabel.numberOfLines = 2;
    c.imageView.image = LSBadge(sym, color);
    c.tintColor = LSAccent();
    c.backgroundColor = UIColor.clearColor;
    return c;
}
- (void)applyCardBackground:(UITableViewCell *)c indexPath:(NSIndexPath *)ip last:(NSInteger)last {
    UIView *bg = [UIView new];
    bg.backgroundColor = LSCardColor();
    bg.layer.cornerRadius = 16;
    bg.layer.cornerCurve = kCACornerCurveContinuous;
    CACornerMask m = 0;
    if (ip.row == 0) m |= kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    if (ip.row == last) m |= kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    bg.layer.maskedCorners = m;
    c.backgroundView = bg;
}
- (UISwitch *)mkSwitch:(BOOL)on action:(SEL)sel {
    UISwitch *sw = [UISwitch new];
    sw.onTintColor = LSAccent();
    sw.on = on;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sw;
}
- (UISlider *)mkSlider:(double)v min:(double)mn max:(double)mx action:(SEL)sel {
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 148, 30)];
    sl.minimumValue = mn; sl.maximumValue = mx; sl.value = v;
    sl.minimumTrackTintColor = LSAccent();
    sl.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.14];
    [sl addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sl;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSInteger s = ip.section, r = ip.row;
    NSInteger last = [self tableView:tv numberOfRowsInSection:s] - 1;
    UITableViewCell *c = nil;
    if (s == 0) {
        LSStore *st = [LSStore shared];
        if (r == 0) {
            c = [self basicCell:@"الكلمات المحفوظة" sub:[NSString stringWithFormat:@"%ld كلمة محفوظة", (long)[st total]] symbol:@"book.fill" color:LSBlue()];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (r == 1) {
            c = [self basicCell:@"مراجعة سريعة" sub:@"بطاقات تعليمية لمراجعة كلماتك" symbol:@"rectangle.stack.fill" color:LSPurple()];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (r == 2) {
            c = [self basicCell:@"النطق التلقائي" sub:@"نطق الكلمة فور النقر عليها" symbol:@"speaker.wave.2.fill" color:LSTeal()];
            c.accessoryView = [self mkSwitch:LSB(@"LSAutoSpeak", NO) action:@selector(autoSpeakChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c = [self basicCell:@"سرعة النطق" sub:@"اسحب لضبط سرعة الصوت" symbol:@"speedometer" color:LSOrange()];
            c.accessoryView = [self mkSlider:LSF(@"LSSpeechRate", 0.47) min:0.30 max:0.62 action:@selector(rateChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (s == 1) {
        if (r == 0) {
            c = [self basicCell:@"لغة الترجمة" sub:LSLangName(LSLang()) symbol:@"globe" color:LSBlue()];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (r == 1) {
            c = [self basicCell:@"ترجمة الجملة كاملة" sub:@"اعرض معنى الجملة كاملة تحت الكلمة" symbol:@"text.bubble.fill" color:LSPurple()];
            c.accessoryView = [self mkSwitch:LSB(@"LSSentence", YES) action:@selector(sentenceChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c = [self basicCell:@"النطق والتعريف" sub:@"جلب الرمز الصوتي والتعريف من القاموس" symbol:@"character.book.closed" color:LSTeal()];
            c.accessoryView = [self mkSwitch:LSB(@"LSDict", YES) action:@selector(dictChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (s == 2) {
        if (r == 0) {
            c = [self basicCell:@"تفعيل داخل المشغّل" sub:@"اعرض الترجمة التفاعلية أثناء التشغيل" symbol:@"power" color:LSGreen()];
            c.accessoryView = [self mkSwitch:LSB(@"LSEnabled", YES) action:@selector(enabledChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (r == 1) {
            c = [self basicCell:@"لون الكلمات الجديدة" sub:@"الكلمات التي لم تحفظها بعد" symbol:@"paintpalette.fill" color:LSPink()];
            UIColorWell *w = [UIColorWell new];
            w.supportsAlpha = NO; w.tag = 30; w.selectedColor = LSColorNew();
            [w addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = w;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (r == 2) {
            c = [self basicCell:@"لون كلمات «أتعلمها»" sub:@"الكلمات التي أضفتها لقائمة التعلم" symbol:@"paintpalette.fill" color:LSPurple()];
            UIColorWell *w = [UIColorWell new];
            w.supportsAlpha = NO; w.tag = 31; w.selectedColor = LSColorLearn();
            [w addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = w;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (r == 3) {
            c = [self basicCell:@"حجم خط الترجمة" sub:[NSString stringWithFormat:@"%d نقطة", (int)LSF(@"LSFont", 22)] symbol:@"textformat.size" color:LSOrange()];
            UIStepper *st = [UIStepper new];
            st.minimumValue = 14; st.maximumValue = 40; st.stepValue = 1; st.value = LSF(@"LSFont", 22);
            st.tintColor = LSAccent();
            [st addTarget:self action:@selector(fontChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = st;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (r == 4) {
            c = [self basicCell:@"شفافية الخلفية" sub:@"خلفية النص فوق الفيديو" symbol:@"circle.lefthalf.filled" color:LSGray()];
            c.accessoryView = [self mkSlider:LSF(@"LSBg", 0.45) min:0 max:0.9 action:@selector(bgChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c = [self basicCell:@"ارتفاع الترجمة" sub:@"المسافة من أسفل الشاشة" symbol:@"arrow.up.and.down" color:LSBlue()];
            c.accessoryView = [self mkSlider:LSF(@"LSBottom", 70) min:20 max:220 action:@selector(bottomChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else {
        if (r == 0) {
            c = [self basicCell:@"زر الوصول السريع" sub:@"أيقونة عائمة للوصول من الشاشة الرئيسية" symbol:@"hand.tap.fill" color:LSGreen()];
            c.accessoryView = [self mkSwitch:LSB(@"LSShowFAB", YES) action:@selector(fabChanged:)];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (r == 1) {
            c = [self basicCell:@"تصدير الكلمات" sub:@"مشاركة نسخة احتياطية بصيغة JSON" symbol:@"square.and.arrow.up" color:LSBlue()];
        } else if (r == 2) {
            c = [self basicCell:@"استيراد من الحافظة" sub:@"الصق نسخة JSON سابقة" symbol:@"square.and.arrow.down" color:LSTeal()];
        } else if (r == 3) {
            c = [self basicCell:@"مسح كل الكلمات" sub:@"لا يمكن التراجع عن هذا الإجراء" symbol:@"trash.fill" color:LSRed()];
            c.textLabel.textColor = LSRed();
        } else {
            c = [self basicCell:@"حول Lang Subs" sub:[NSString stringWithFormat:@"الإصدار %@", LSVersion] symbol:@"info.circle.fill" color:LSGray()];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    [self applyCardBackground:c indexPath:ip last:last];
    return c;
}

- (void)autoSpeakChanged:(UISwitch *)s { [UD() setBool:s.on forKey:@"LSAutoSpeak"]; }
- (void)sentenceChanged:(UISwitch *)s { [UD() setBool:s.on forKey:@"LSSentence"]; }
- (void)dictChanged:(UISwitch *)s { [UD() setBool:s.on forKey:@"LSDict"]; }
- (void)enabledChanged:(UISwitch *)s { [UD() setBool:s.on forKey:@"LSEnabled"]; }
- (void)fabChanged:(UISwitch *)s { [UD() setBool:s.on forKey:@"LSShowFAB"]; }
- (void)rateChanged:(UISlider *)s { [UD() setDouble:s.value forKey:@"LSSpeechRate"]; }
- (void)bgChanged:(UISlider *)s { [UD() setDouble:s.value forKey:@"LSBg"]; }
- (void)bottomChanged:(UISlider *)s { [UD() setDouble:s.value forKey:@"LSBottom"]; }
- (void)colorChanged:(UIColorWell *)w { [UD() setObject:LSHexStr(w.selectedColor) forKey:w.tag == 30 ? @"LSColorNew" : @"LSColorLearn"]; }
- (void)fontChanged:(UIStepper *)s {
    [UD() setDouble:s.value forKey:@"LSFont"];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:3 inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    if (ip.section == 0 && ip.row == 0) {
        [self.navigationController pushViewController:[LSWordsVC new] animated:YES];
    } else if (ip.section == 0 && ip.row == 1) {
        [self.navigationController pushViewController:[LSReviewVC new] animated:YES];
    } else if (ip.section == 1 && ip.row == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"لغة الترجمة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSArray *p in LSLangs())
            [ac addAction:[UIAlertAction actionWithTitle:p[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [UD() setObject:p[0] forKey:@"LSTargetLang"];
                [tv reloadData];
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        ac.popoverPresentationController.sourceView = cell;
        ac.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:ac animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 1) {
        NSString *txt = [[LSStore shared] exportJSON];
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[txt] applicationActivities:nil];
        av.popoverPresentationController.sourceView = cell;
        av.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:av animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 2) {
        NSString *clip = UIPasteboard.generalPasteboard.string;
        BOOL ok = clip.length && [[LSStore shared] importJSON:clip];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:ok ? @"تم الاستيراد" : @"تعذّر الاستيراد"
                                                                   message:ok ? @"تم دمج الكلمات في مكتبتك." : @"الحافظة لا تحتوي على JSON صالح."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [tv reloadData];
            [self->_header reload];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 3) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"مسح كل الكلمات؟" message:@"لا يمكن التراجع عن هذا الإجراء." preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[LSStore shared] removeAll];
            [tv reloadData];
            [self->_header reload];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } else if (ip.section == 3 && ip.row == 4) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Lang Subs" message:[NSString stringWithFormat:@"الإصدار %@\nتعلم الكلمات من أي ترجمة، انطقها، وراجعها لاحقاً.", LSVersion] preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}
@end

// =====================================================================
#pragma mark - presentation helpers

static UIWindow *LSKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}
static UIViewController *LSTopPresented(void) {
    UIWindow *w = LSKeyWindow(); if (!w) return nil;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
static UINavigationController *LSNavFor(UIViewController *root) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.navigationBar.tintColor = LSAccent();
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.prefersGrabberVisible = YES;
        nav.sheetPresentationController.preferredCornerRadius = 28;
    }
    return nav;
}
static void LSPresentRoot(UIViewController *root) {
    UIViewController *top = LSTopPresented();
    if (!top || !root) return;
    [top presentViewController:LSNavFor(root) animated:YES completion:nil];
}
static UIViewController *LSMakeSettings(dispatch_block_t onClose) {
    LSSettingsVC *s = [LSSettingsVC new];
    s.onClose = onClose;
    return s;
}
static void LSPresentSettings(void) { LSPresentRoot(LSMakeSettings(nil)); }
static void LSPresentWords(void) { LSPresentRoot([LSWordsVC new]); }
static void LSPresentReview(void) { LSPresentRoot([LSReviewVC new]); }

// =====================================================================
#pragma mark - player overlay

@interface LSOverlay : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation LSOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;
}
- (void)layoutSubviews { [super layoutSubviews]; if (self.onLayout) self.onLayout(); }
@end

@interface LSController : NSObject
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, strong) LSOverlay *overlay;
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) LSWordCard *card;
@property (nonatomic, strong) UIButton *gear;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastText, *curWord, *curLine, *curMeaning, *curPhonetic, *curPos, *curDef;
@property (nonatomic) NSRange curRange;
@property (nonatomic) BOOL hidSubs, pausedByUs;
@property (nonatomic) NSInteger ticks;
+ (instancetype)shared;
- (BOOL)attached;
- (void)attach:(UIViewController *)vc;
- (void)detach;
- (void)openSettings;
@end

static NSRegularExpression *WordRE, *ArabicRE;

@implementation LSController
+ (instancetype)shared { static LSController *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [LSController new]; }); return s; }
- (BOOL)attached { return self.overlay != nil; }
- (BOOL)isArabic:(NSString *)s { return [ArabicRE firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil; }

- (void)attach:(UIViewController *)vc {
    UIWindow *win = vc.view.window; if (!win) return;
    if (self.vc == vc && self.overlay) return;
    [self detach];
    if (!WordRE) {
        WordRE = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{M}][\\p{L}\\p{M}'’-]*" options:0 error:nil];
        ArabicRE = [NSRegularExpression regularExpressionWithPattern:@"\\p{Arabic}" options:0 error:nil];
    }
    self.vc = vc; self.lastText = nil; self.curWord = nil; self.curMeaning = nil;
    self.curPhonetic = nil; self.curPos = nil; self.curDef = nil;
    self.curRange = NSMakeRange(NSNotFound, 0);

    LSOverlay *o = [[LSOverlay alloc] initWithFrame:win.bounds];
    o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak LSController *w = self;
    o.onLayout = ^{ [w layout]; };
    self.overlay = o;

    UITextView *tv = [UITextView new];
    tv.editable = NO; tv.selectable = NO; tv.scrollEnabled = NO;
    tv.backgroundColor = UIColor.clearColor;
    tv.layer.cornerRadius = 12;
    tv.layer.cornerCurve = kCACornerCurveContinuous;
    tv.textContainerInset = UIEdgeInsetsMake(9, 10, 9, 10);
    tv.textContainer.lineFragmentPadding = 4;
    [tv addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
    [o addSubview:tv];
    self.tv = tv;

    LSWordCard *card = [[LSWordCard alloc] initWithFrame:CGRectZero];
    card.hidden = YES;
    card.alpha = 0;
    card.onSpeakWord = ^{ [[LSSpeech shared] speakWord:w.curWord ?: @""]; };
    card.onSpeakMeaning = ^{ [[LSSpeech shared] speakTranslation:w.curMeaning ?: @""]; };
    card.onLearning = ^{ [w setStatus:@"learning"]; };
    card.onKnown = ^{ [w setStatus:@"known"]; };
    card.onClose = ^{ [w closeCard]; };
    [o addSubview:card];
    self.card = card;

    UIButton *g = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [g setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg] forState:UIControlStateNormal];
    g.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
    g.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    g.layer.cornerRadius = 20;
    g.alpha = 0.55;
    [g addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [o addSubview:g];
    self.gear = g;

    [win addSubview:o];   // window level: above Nuvio's Compose layer so taps reach us
    self.timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self layout];
}

- (void)resumeIfPaused {
    if (self.pausedByUs && self.vc && LSResolve()) {
        mpv_handle *h = LSHandle(self.vc);
        if (h) p_set(h, "pause", "no");
    }
    self.pausedByUs = NO;
}
- (void)pauseIfPlaying {
    mpv_handle *h = self.vc ? LSHandle(self.vc) : NULL;
    if (h && LSResolve() && !self.pausedByUs && !LSIsPaused(h)) {
        p_set(h, "pause", "yes");
        self.pausedByUs = YES;
    }
}

- (void)detach {
    [self.timer invalidate]; self.timer = nil;
    UIViewController *vc = self.vc;
    if (vc && LSResolve()) {
        mpv_handle *h = LSHandle(vc);
        if (h && self.hidSubs) p_set(h, "sub-visibility", "yes");
    }
    [self resumeIfPaused];
    [[LSSpeech shared] stop];
    self.hidSubs = NO;
    self.curWord = nil;
    self.curRange = NSMakeRange(NSNotFound, 0);
    [self.overlay removeFromSuperview];
    self.overlay = nil; self.tv = nil; self.card = nil; self.gear = nil; self.vc = nil;
}

- (void)layout {
    if (!self.overlay || !self.tv || !self.card) return;
    CGRect b = self.overlay.bounds;
    UIEdgeInsets si = self.overlay.safeAreaInsets;

    NSAttributedString *a = self.tv.attributedText;
    CGFloat maxW = b.size.width * 0.92 - 28;
    CGRect tr = CGRectZero;
    CGSize ts = CGSizeZero;
    if (a.length) {
        tr = [a boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                             options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                             context:nil];
        ts = CGSizeMake(MIN(ceil(tr.size.width) + 28, b.size.width * 0.92), ceil(tr.size.height) + 18);
    } else {
        self.tv.hidden = YES;
    }

    CGSize cs = [self.card sizeThatFits:CGSizeMake(MIN(b.size.width - 28, 520), CGFLOAT_MAX)];
    CGFloat ch = cs.height, cw = cs.width;
    CGFloat cy = b.size.height - si.bottom - 14 - ch;
    self.card.frame = CGRectMake((b.size.width - cw) / 2, cy, cw, ch);

    CGFloat bottomLimit = self.card.hidden ? (b.size.height - si.bottom - LSF(@"LSBottom", 70)) : (cy - 10);
    if (a.length) {
        self.tv.hidden = NO;
        self.tv.frame = CGRectMake((b.size.width - ts.width) / 2, bottomLimit - ts.height, ts.width, ts.height);
    }
    self.gear.frame = CGRectMake(si.left + 14, b.size.height - si.bottom - 62, 40, 40);
    self.gear.hidden = !self.card.hidden;
}

- (void)render {
    NSString *t = self.lastText ?: @"";
    double fs = LSF(@"LSFont", 22);
    self.tv.backgroundColor = [UIColor colorWithWhite:0 alpha:LSF(@"LSBg", 0.45)];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:t attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:fs weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSParagraphStyleAttributeName: ps,
    }];
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByLines usingBlock:^(NSString *line, NSRange lr, NSRange er, BOOL *stop) {
        if ([self isArabic:line]) {
            [as addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:0.80 alpha:1] range:lr];
            [as addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:MAX(fs - 4, 12)] range:lr];
        }
    }];
    UIColor *cNew = LSColorNew(), *cLearn = LSColorLearn();
    NSDictionary *W = [LSStore shared].words;
    for (NSTextCheckingResult *m in [WordRE matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *w = [t substringWithRange:m.range];
        if ([self isArabic:w]) continue;
        NSString *st = W[w.lowercaseString][@"s"];
        if ([st isEqualToString:@"known"]) continue;
        [as addAttribute:NSForegroundColorAttributeName value:[st isEqualToString:@"learning"] ? cLearn : cNew range:m.range];
    }
    if (self.curRange.location != NSNotFound && NSMaxRange(self.curRange) <= t.length) {
        [as addAttribute:NSBackgroundColorAttributeName value:[LSAccent() colorWithAlphaComponent:0.30] range:self.curRange];
    }
    self.tv.attributedText = as;
    [self layout];
}

- (void)tick {
    UIViewController *vc = self.vc;
    if (!vc || !vc.view.window) { [self detach]; return; }
    if (!LSResolve()) return;
    mpv_handle *h = LSHandle(vc); if (!h) return;
    self.ticks++;
    if (!LSB(@"LSEnabled", YES)) {
        if (self.hidSubs) { p_set(h, "sub-visibility", "yes"); self.hidSubs = NO; }
        if (self.lastText.length) { self.lastText = @""; self.curRange = NSMakeRange(NSNotFound, 0); [self render]; }
        return;
    }
    NSString *codec = MPVGet(h, "current-tracks/sub/codec");
    BOOL image = codec && ([codec containsString:@"pgs"] || [codec containsString:@"dvd"] || [codec containsString:@"dvb"] || [codec containsString:@"xsub"]);
    NSString *t = image ? @"" : (MPVGet(h, "sub-text") ?: @"");
    if (image || (codec.length == 0 && t.length == 0)) {
        if (self.hidSubs) { p_set(h, "sub-visibility", "yes"); self.hidSubs = NO; }
    } else if (!self.hidSubs || self.ticks % 10 == 0) {
        p_set(h, "sub-visibility", "no");
        self.hidSubs = YES;
    }
    if (![t isEqualToString:self.lastText ?: @""]) {
        self.lastText = t;
        if (self.curRange.location != NSNotFound && NSMaxRange(self.curRange) > t.length)
            self.curRange = NSMakeRange(NSNotFound, 0);
        [self render];
    }
}

- (void)onTap:(UITapGestureRecognizer *)g {
    UITextView *tv = self.tv;
    if (!tv || !tv.text.length) return;
    CGPoint p = [g locationInView:tv];
    p.x -= tv.textContainerInset.left; p.y -= tv.textContainerInset.top;
    NSUInteger idx = [tv.layoutManager characterIndexForPoint:p inTextContainer:tv.textContainer fractionOfDistanceBetweenInsertionPoints:NULL];
    NSString *t = tv.text;
    for (NSTextCheckingResult *m in [WordRE matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        if (NSLocationInRange(idx, m.range)) {
            NSString *w = [t substringWithRange:m.range];
            if ([self isArabic:w]) return;
            NSString *line = [[t substringWithRange:[t lineRangeForRange:m.range]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            self.curRange = m.range;
            [self render];
            [self showWord:w.lowercaseString line:line];
            return;
        }
    }
}

- (void)showWord:(NSString *)w line:(NSString *)line {
    self.curWord = w; self.curLine = line;
    self.curMeaning = nil; self.curPhonetic = nil; self.curPos = nil; self.curDef = nil;
    NSDictionary *e = [LSStore shared].words[w];
    NSString *status = e[@"s"] ?: @"new";
    NSString *cached = e[@"m"];
    self.curPhonetic = e[@"ph"]; self.curPos = e[@"pos"]; self.curDef = e[@"def"];
    [self pauseIfPlaying];
    [self.card showWord:w phonetic:self.curPhonetic meaning:cached ?: @"…" definition:self.curDef context:line status:status loading:!cached.length];
    self.card.hidden = NO;
    self.card.alpha = 0;
    self.card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [self layout];
    [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.7 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.card.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
    if (LSB(@"LSAutoSpeak", NO)) [[LSSpeech shared] speakWord:w];

    __weak LSController *ws = self;
    if (!cached.length) {
        LSTranslate(w, ^(NSString *tr) {
            if (![ws.curWord isEqualToString:w]) return;
            ws.curMeaning = tr;
            [ws.card updateMeaning:tr.length ? tr : @"تعذّر جلب المعنى"];
            [ws layout];
            NSMutableDictionary *ent = [LSStore shared].words[w];
            if (ent) { ent[@"m"] = tr.length ? tr : @""; [[LSStore shared] save]; }
        });
    } else {
        self.curMeaning = cached;
    }
    if (LSB(@"LSSentence", YES)) {
        LSTranslate(line, ^(NSString *tr) {
            if (![ws.curWord isEqualToString:w] || ![ws.curLine isEqualToString:line] || !tr.length) return;
            [ws.card updateContext:tr];
            [ws layout];
        });
    }
    if (LSB(@"LSDict", YES)) {
        LSDictionaryLookup(w, ^(NSString *ph, NSString *pos, NSString *def) {
            if (![ws.curWord isEqualToString:w]) return;
            if (ph) ws.curPhonetic = ph;
            if (pos) ws.curPos = pos;
            if (def) ws.curDef = def;
            [ws.card updatePhonetic:ph definition:def];
            [[LSStore shared] setMetaForWord:w phonetic:ph pos:pos definition:def];
            [ws layout];
        });
    }
}

- (void)setStatus:(NSString *)s {
    if (!self.curWord) return;
    [[LSStore shared] setStatus:s forWord:self.curWord meaning:self.curMeaning context:self.curLine
                       phonetic:self.curPhonetic pos:self.curPos definition:self.curDef];
    LSHaptic(UIImpactFeedbackStyleMedium);
    [self render];
    [self closeCard];
}
- (void)onLearning { [self setStatus:@"learning"]; }
- (void)onKnown { [self setStatus:@"known"]; }
- (void)closeCard {
    if (!self.card) return;
    [UIView animateWithDuration:0.18 animations:^{
        self.card.alpha = 0;
        self.card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        self.card.hidden = YES;
        self.card.transform = CGAffineTransformIdentity;
        [self render];
    }];
    self.curWord = nil;
    self.curRange = NSMakeRange(NSNotFound, 0);
    [self resumeIfPaused];
}

- (void)openSettings {
    if (!self.vc || !self.overlay) return;
    UIWindow *w = self.overlay.window; if (!w) return;
    UIViewController *top = LSTopPresented(); if (!top) return;
    [self pauseIfPlaying];
    __weak LSController *ws = self;
    UIViewController *s = LSMakeSettings(^{
        ws.overlay.hidden = NO;
        [ws render];
        [ws resumeIfPaused];
    });
    self.overlay.hidden = YES;
    [top presentViewController:LSNavFor(s) animated:YES completion:nil];
}
@end

// =====================================================================
#pragma mark - floating home launcher

@interface LSFAB : UIButton
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UILabel *badge;
- (void)setBadgeCount:(NSInteger)c;
@end

@implementation LSFAB
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 56, 56)])) {
        self.layer.cornerRadius = 28;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;

        _grad = [CAGradientLayer layer];
        _grad.cornerRadius = 28;
        _grad.masksToBounds = YES;
        _grad.colors = @[(id)LSAccent().CGColor, (id)LSColorLearn().CGColor];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        [self.layer insertSublayer:_grad atIndex:0];

        self.tintColor = UIColor.whiteColor;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightBold];
        [self setImage:[UIImage systemImageNamed:@"graduationcap.fill" withConfiguration:cfg] forState:UIControlStateNormal];

        _badge = [UILabel new];
        _badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        _badge.textColor = UIColor.whiteColor;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.backgroundColor = LSRed();
        _badge.layer.cornerRadius = 10;
        _badge.clipsToBounds = YES;
        _badge.hidden = YES;
        [self addSubview:_badge];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _grad.frame = self.bounds;
    _badge.frame = CGRectMake(self.bounds.size.width - 24, -2, 22, 22);
    self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;
}
- (void)setBadgeCount:(NSInteger)c {
    if (c <= 0) { _badge.hidden = YES; return; }
    _badge.hidden = NO;
    _badge.text = c > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)c];
}
@end

@interface LSFABController : NSObject
+ (instancetype)shared;
- (void)install;
@end

@implementation LSFABController {
    LSFAB *_button;
    NSTimer *_timer;
    BOOL _dragging;
}
+ (instancetype)shared { static LSFABController *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [LSFABController new]; }); return s; }
- (void)install {
    if (_button) return;
    _button = [LSFAB new];
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [_button addGestureRecognizer:pan];
    _timer = [NSTimer timerWithTimeInterval:0.4 target:self selector:@selector(update) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self update];
}
- (void)update {
    if (!_button) return;
    UIWindow *w = LSKeyWindow();
    if (!w) return;
    if (_button.superview != w) [w addSubview:_button];
    [w bringSubviewToFront:_button];
    UIViewController *root = w.rootViewController;
    UIViewController *top = LSTopPresented();
    BOOL modal = top && root && top != root;
    BOOL hide = !LSB(@"LSShowFAB", YES)
        || [LSController shared].attached
        || UIApplication.sharedApplication.applicationState != UIApplicationStateActive
        || modal;
    _button.hidden = hide;
    if (hide) return;
    if (!_dragging) [self placeIn:w];
    [_button setBadgeCount:[[LSStore shared] countWithStatus:@"learning"]];
}
- (void)placeIn:(UIWindow *)w {
    UIEdgeInsets si = w.safeAreaInsets;
    CGFloat W = w.bounds.size.width, H = w.bounds.size.height, s = 56;
    double fx = LSF(@"LSFABX", -1), fy = LSF(@"LSFABY", -1);
    CGFloat cx, cy;
    if (fx < 0 || fy < 0) {
        cx = W - si.right - s / 2 - 18;
        cy = H - si.bottom - s / 2 - 112;
    } else {
        cx = si.left + s / 2 + fx * MAX(1, W - si.left - si.right - s);
        cy = si.top + s / 2 + fy * MAX(1, H - si.top - si.bottom - s);
    }
    _button.center = CGPointMake(cx, cy);
}
- (void)panned:(UIPanGestureRecognizer *)g {
    UIView *w = _button.superview;
    if (!w) return;
    CGPoint t = [g translationInView:w];
    CGPoint c = _button.center;
    c.x += t.x; c.y += t.y;
    [g setTranslation:CGPointZero inView:w];
    UIEdgeInsets si = w.safeAreaInsets;
    CGFloat s = 56;
    c.x = MIN(MAX(c.x, si.left + s / 2 + 6), w.bounds.size.width - si.right - s / 2 - 6);
    c.y = MIN(MAX(c.y, si.top + s / 2 + 6), w.bounds.size.height - si.bottom - s / 2 - 6);
    _button.center = c;
    _dragging = (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat spanX = MAX(1, w.bounds.size.width - si.left - si.right - s);
        CGFloat spanY = MAX(1, w.bounds.size.height - si.top - si.bottom - s);
        [UD() setDouble:(c.x - si.left - s / 2) / spanX forKey:@"LSFABX"];
        [UD() setDouble:(c.y - si.top - s / 2) / spanY forKey:@"LSFABY"];
        _dragging = NO;
    }
}
- (void)tapped {
    UIViewController *top = LSTopPresented();
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Lang Subs" message:@"مكتبتك اللغوية" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"الكلمات المحفوظة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LSPresentWords(); });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"مراجعة سريعة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LSPresentReview(); });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"الإعدادات" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LSPresentSettings(); });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = _button;
    ac.popoverPresentationController.sourceRect = _button.bounds;
    [top presentViewController:ac animated:YES completion:nil];
}
@end

// =====================================================================
#pragma mark - install & hooks

static void LSOpenSettingsStandalone(void) {
    LSController *c = [LSController shared];
    if (c.attached) {
        if (c.overlay.hidden) return;   // our panel is already open
        [c openSettings];
        return;
    }
    LSPresentSettings();
}

@interface LSGesture : NSObject
+ (void)fire:(UILongPressGestureRecognizer *)g;
@end
@implementation LSGesture
+ (void)fire:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) LSOpenSettingsStandalone();
}
@end

static void LSInstallGesture(void) {
    static char key;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (objc_getAssociatedObject(w, &key)) continue;
            UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[LSGesture class] action:@selector(fire:)];
            g.numberOfTouchesRequired = 3;
            g.minimumPressDuration = 0.7;
            g.cancelsTouchesInView = NO;
            g.delaysTouchesBegan = NO;
            g.delaysTouchesEnded = NO;
            [w addGestureRecognizer:g];
            objc_setAssociatedObject(w, &key, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static IMP origAppear, origDisappear;
static void newAppear(id self, SEL _cmd, BOOL a) {
    ((void (*)(id, SEL, BOOL))origAppear)(self, _cmd, a);
    [[LSController shared] attach:self];
}
static void newDisappear(id self, SEL _cmd, BOOL a) {
    [[LSController shared] detach];
    ((void (*)(id, SEL, BOOL))origDisappear)(self, _cmd, a);
}

static void LSSwizzle(Class c, SEL s, IMP n, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    *orig = method_getImplementation(m);
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m)))
        method_setImplementation(class_getInstanceMethod(c, s), n);
}
static BOOL LSInstalled;
static void LSInstall(void) {
    if (LSInstalled) return;
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    Class found = Nil;
    for (unsigned i = 0; i < n; i++)
        if (strstr(class_getName(all[i]), "MPVPlayerViewController")) { found = all[i]; break; }
    free(all);
    if (!found) { NSLog(@"[LangSubsTap] MPVPlayerViewController not found"); return; }
    LSSwizzle(found, @selector(viewDidAppear:), (IMP)newAppear, &origAppear);
    LSSwizzle(found, @selector(viewWillDisappear:), (IMP)newDisappear, &origDisappear);
    LSInstalled = YES;
    NSLog(@"[LangSubsTap] installed on %s", class_getName(found));
}

static void LSBootstrap(void) {
    LSInstall();
    LSInstallGesture();
    [[LSFABController shared] install];
}

__attribute__((constructor)) static void LSInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *x) {
        LSBootstrap();
    }];
    // Fire even if the dylib is injected after the app became active.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LSBootstrap(); });
    // Optional bridge: a host app can post this to open our panel.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"LangSubsTapOpenSettings" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        LSOpenSettingsStandalone();
    }];
}
