# LangSubsTap

تويك (dylib) يُحقن في Nuvio: يرسم الترجمة بنفسه فوق الفيديو بكلمات قابلة للنقر.
عند النقر على كلمة يوقف الفيديو ويعرض بطاقة بمعناها (من سيرفر Lang Subs) مع أزرار «أتعلمها / أعرفها / إغلاق».
ويرسل أيضاً موضع التشغيل كل ثانية إلى `/api/position` للصفحة المرافقة.

يعمل فقط عندما تكون ترجمة Lang Subs هي المختارة (رابطها ينتهي بـ `/sub.ass`)، وغير ذلك لا يتدخل.

## البناء
- على ماك: `./build.sh`
- أو ارفع المجلد إلى GitHub: الـ workflow يبني `LangSubsTap.dylib` ويعطيك الملف كـ artifact.

## الحقن
Sideloadly: Advanced Options → Inject dylibs/frameworks → أضف `LangSubsTap.dylib`.
أو LiveContainer: أضفه كتويك للتطبيق.

## قبل ما تجرّب (افتراضات لم أتحقق منها)
1. **libmpv لازم تكون ظاهرة للـ dlsym**: إذا كانت MPVKit مدمجة ستاتيكياً ومخفية الرموز، السجل يطبع
   `libmpv symbols not found` ولا يظهر شيء. افحص: `otool -L Nuvio.app/Nuvio` و`nm -gU` على الإطار.
2. **اسم الخاصية `mpv`**: يقرأ مقبض mpv من الـ ivar المسمّى `mpv` في `MPVPlayerViewController` (Swift يسجّله كـ ivar لأن الكلاس يرث UIViewController).
3. يخفي ترجمة mpv الأصلية (`sub-visibility=no`) ويرسم بدلها، ويعيدها عند الخروج.
4. السيرفر لازم HTTPS (أو استثناء ATS إذا HTTP).
اقرأ السجل بـ Console على الماك: ابحث عن `[LangSubsTap]`.
