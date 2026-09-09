<p align="center">
  <img src=".github/assets/icon.png" width="120" alt="لَقْطة icon">
</p>

<h1 align="center">لَقْطة (Laqta)</h1>

<p align="center">
  سجل الحافظة لنظام macOS — نسخة عربية من ميزة Windows+V، مع بحث وتحديد متعدد وتثبيت دائم ودعم لغتين.
</p>

<p align="center">
  <a href="#العربية">العربية</a> · <a href="#english">English</a>
</p>

---

## العربية

### الغرض من التطبيق

كل ما تنسخه على الماك يضيع بمجرد ما تنسخ شي جديد. **لَقْطة** تحتفظ بسجل كامل لكل ما نسخته — نصوصًا وصورًا — وتعرضه بلوحة عائمة سريعة تفتحها باختصار واحد، مع بحث فوري وإمكانية تثبيت أي عنصر مهم حتى لا ينتهي أبدًا.

مبني كملف Swift واحد بدون Xcode، ويعمل من شريط القوائم بدون أيقونة Dock. الواجهة تدعم العربية والإنجليزية، قابلة للتبديل من الإعدادات.

### الاستخدام

| الإجراء | النتيجة |
|---|---|
| `⌃⌘V` | فتح/إغلاق لوحة السجل (قابل للتغيير من الإعدادات) |
| اكتب بمربع البحث | يفلتر السجل فورًا (يتجاهل التشكيل العربي) |
| `↑` `↓` | التنقل بين العناصر |
| `Shift + ↑/↓` | تحديد أكثر من عنصر |
| `↵` Enter | لصق العنصر المحدد — أو دمج عدة عناصر محددة بسطر فاضي بينها |
| `→` | تثبيت العنصر المحدد |
| `←` أو `⌫` | حذف العنصر — يتجاهل المثبّت تلقائيًا |
| نقرة على عنصر | يلصقه مباشرة بمكان تكتب فيه |
| 📌 بجانب العنصر | تثبيت — لا ينتهي أبدًا مهما طالت مدته |
| ✕ بجانب العنصر | حذف نهائي، حتى لو كان مثبّتًا |
| 📋 بجانب العنصر | نسخ للحافظة فقط، بدون لصق تلقائي |
| سحب الشريط العلوي | نقل اللوحة — تتذكر مكانها |

#### الإعدادات
عدد العناصر المحفوظة (٥–٢٠٠)، مدة حفظ غير المثبت (ساعة إلى أسبوع)، شفافية اللوحة، اختصار قابل للتسجيل، لغة الواجهة (عربي/إنجليزي)، والتشغيل التلقائي عند بدء الماك.

#### الصلاحيات
تحتاج **Accessibility** لأنها تحاكي ⌘V عند اللصق التلقائي — تطلبها تلقائيًا أول ما تفتح التطبيق.

### البناء من المصدر

```bash
git clone https://github.com/omaralmutairi-afk/Laqta.git
cd Laqta
./build.sh   # يبني Laqta.app ويثبّته على سطح المكتب، موقّعًا محليًا
```

يحتاج macOS 13 فأعلى. لا يوجد مشروع Xcode — `build.sh` يستخدم `swiftc` مباشرة.

### الحالة

مكتمل، ومرّ بسبع مراجعات كود كاملة اكتشفت وأصلحت أخطاء حقيقية — منها خلل كان يفقد آخر نسخة عند إنهاء التطبيق فجأة، خلل بترتيب العناصر عند اللصق، وتكرار بصري بالنصوص بعد تبديل اللغة. كل إصلاح مؤكَّد باختبارات تعمل على المخزن الحقيقي والحافظة الحقيقية، لا محاكاة.

---

## English

### Purpose

Everything you copy on a Mac disappears the moment you copy something new. **Laqta** keeps a full history of everything you've copied — text and images — in a fast floating panel opened with one shortcut, with instant search and the ability to pin anything important so it never expires.

Built as a single Swift file with no Xcode project, running from the menu bar with no Dock icon. The interface supports both Arabic and English, switchable from Settings.

### Usage

| Action | Result |
|---|---|
| `⌃⌘V` | Open/close the history panel (changeable in Settings) |
| Type in the search box | Filters the history live |
| `↑` `↓` | Navigate between items |
| `Shift + ↑/↓` | Select more than one item |
| `↵` Enter | Paste the selected item — or join several selected items with a blank line between them |
| `→` | Pin the selected item |
| `←` or `⌫` | Delete the item — automatically skips anything pinned |
| Click an item | Pastes it directly wherever you're typing |
| 📌 next to an item | Pin — never expires no matter how long it sits |
| ✕ next to an item | Delete outright, even if pinned |
| 📋 next to an item | Copy to clipboard only, no auto-paste |
| Drag the top bar | Move the panel — it remembers where you put it |

#### Settings
Items to keep (5–200), retention window for unpinned items (1 hour to 1 week), panel opacity, a recordable hotkey, interface language (Arabic/English), and launch at startup.

#### Permissions
Requires **Accessibility** because it simulates ⌘V for auto-paste — requested automatically the first time the app opens.

### Building from source

```bash
git clone https://github.com/omaralmutairi-afk/Laqta.git
cd Laqta
./build.sh   # builds Laqta.app and installs it to the Desktop, locally signed
```

Requires macOS 13 or later. No Xcode project — `build.sh` calls `swiftc` directly.

### Status

Feature-complete, and has been through seven full code review passes that found and fixed real bugs — including one that could lose the last copy if the app quit abruptly, one that reordered items on paste, and a visual text-duplication bug after switching languages. Every fix is verified against the real store and the real system pasteboard, not a stand-in.
