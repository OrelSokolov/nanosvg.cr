# NanoSVG — инвентаризация upstream для порта на Crystal

Источник: `/home/oleg/nanosvg` (форк memononen/nanosvg с расширениями).
Лицензия: zlib. Статус upstream: «not actively maintained».

## 1. Скелет проекта

```
nanosvg/
├── src/
│   ├── nanosvg.h        # 3278 строк — парсер SVG (stb-style single header)
│   └── nanosvgrast.h    # 1472 строки — растеризатор (форк stb_truetype rasterizer)
├── example/
│   ├── example1.c       # GLFW/OpenGL-вьювер: парсинг + своя тесселляция безье, отрисовка полилиний
│   ├── example2.c       # Канонический пример: parse → rasterize → PNG (stb_image_write)
│   ├── 23.svg, nano.svg, drawing.svg — тестовые SVG
├── CMakeLists.txt       # .h копируются в .c, NANOSVG_IMPLEMENTATION, таргеты nanosvg/nanosvgrast
├── premake4.lua         # Альтернативная сборка демо
├── AI_POLICY.md         # Политика по AI-контрибуциям (важна только для PR в upstream)
└── LICENSE.txt          # zlib
```

Обе библиотеки — header-only, реализация раскрывается через
`NANOSVG_IMPLEMENTATION` / `NANOSVGRAST_IMPLEMENTATION`.
Зависимости: только `stdio.h`, `string.h`, `math.h`.

Это **не ванильный upstream** — здесь есть расширения:
`paint-order`, `<style>` с CSS-классами, `stroke-miterlimit`.

## 2. Модель данных (парсер)

Всё сводится к кубическим безье, вывод — связные списки:

- `NSVGimage` → `width/height` + список `NSVGshape`
- `NSVGshape`:
  - `id[64]`
  - `fill` / `stroke` (`NSVGpaint`)
  - `opacity`, `strokeWidth`
  - `strokeDashArray[8]`, `strokeDashOffset`
  - `lineCap` (butt/round/square), `lineJoin` (miter/round/bevel), `miterLimit`
  - `fillRule` (nonzero / evenodd)
  - `paintOrder` (3×2 бита)
  - `flags` (visible)
  - `bounds[4]`
  - корневая `xform[6]`
  - список `NSVGpath`
- `NSVGpath`:
  - плоский `float[] pts` формата «1 точка + N×3» (всегда `npts % 3 == 1`)
  - `closed`, `bounds[4]`
- `NSVGpaint` — тегированный union:
  `NONE | COLOR | LINEAR_GRADIENT | RADIAL_GRADIENT`
- `NSVGgradient`:
  - инвертированная `xform[6]` (пиксели → пространство 0..1)
  - `spread`, фокус `fx/fy`
  - отсортированные stops
- Цвет: `0xAABBGGRR` (D3D-порядок, не web!), альфа в старшем байте.

## 3. Фичи парсера

### Элементы

`svg, g, path, rect (rx/ry), circle, ellipse, line, polyline, polygon,
defs, linearGradient, radialGradient, stop, style`.
Остальные теги молча игнорируются.

### Path

Все команды `M m L l H h V v C c S s Q q T t A a Z z`, включая:

- эллиптические дуги `A` → конверсия в кубики по F.6.5 из SVG-спеки
  (разбиение на сегменты ≤90°, каппа, защита от degenerate-радиусов)
- `m` после первой пары → неявный `l`
- повторный `M` коммитит подпуть
- `S`/`T` — отражение контрольных точек
- `Q` → `C` по формуле 2/3
- спец-лексер флагов дуг (`nsvg__getNextPathItemWhenArcFlag`)
  для минифицированных путей

### Стили

Presentation-атрибуты + inline `style="..."` + CSS-классы из `<style>`
(только `.name`, без каскада/специфичности). Поддержаны:

`fill, stroke, stroke-width, stroke-dasharray, stroke-dashoffset,
stroke-linecap, stroke-linejoin, stroke-miterlimit, fill-rule, opacity,
fill-opacity, stroke-opacity, display, font-size (для em/ex),
stop-color, stop-opacity, stop-offset, paint-order, id, class`.

`display:none` — необратимо скрывает поддерево.

### Трансформации

`matrix, translate, scale, rotate (с опциональным центром), skewX, skewY`;
аффинные `float[6]`, накопление через attr-стек при вложенности групп
(глубина ≤ 128).

### viewBox / единицы

- `viewBox`
- `preserveAspectRatio` (`none / xMin|xMid|xMax yMin|yMid|yMax [meet|slice]`)
- единицы `px pt pc mm cm in em ex %`
- DPI (обычно 96)
- вывод в заданных целевых единицах

### Цвета

- `#rgb`, `#rrggbb`
- `rgb(r,g,b)`, `rgb(r%,g%,b%)`
- базовых 10 имён; с `NANOSVG_ALL_COLOR_KEYWORDS` — 147
- fallback при ошибке — серый `rgb(128,128,128)`

### Градиенты

- linear / radial
- `gradientUnits`:
  - objectBoundingBox — дефолт, с расчётом локального bbox через
    инверсию xform шейпа
  - userSpaceOnUse
- `gradientTransform`
- `spreadMethod` (парсится, но растеризатор всегда делает pad)
- `xlink:href` — наследуются **только stops** (с защитой от циклов,
  ≤ 32 итерации)
- резолв отложенный, после полного прохода
- ненашедшаяся ссылка → `NONE`

### Внутренние детали реализации

- Собственный потоковый XML-парсер:
  - вставляет `\0` в буфер — вход портится
  - сущности и CDATA не декодируются
  - до 256 атрибутов
- Собственный `atof` из-за проблем с локалями
- Обработка ошибок — тихие дефолты

## 4. Фичи растеризатора

API:

- `nsvgCreateRasterizer()`
- `nsvgRasterize(r, image, tx, ty, scale, dst RGBA8, w, h, stride)`
- `nsvgDeleteRasterizer(r)`

### Flattening

Адаптивная рекурсивная субдивизия де Кастельжа:

- критерий `(d2+d3)² < tessTol·(dx²+dy²)`
- `tessTol = 0.25` в экранных единицах
- лимит глубины 10
- схлопывание точек ближе `distTol = 0.01`

### Fill

- рёбра сортируются по y0
- scanline с 5 субсканлайнами по Y и fixed-point 1/1024 по X
- active edge list с пузырьковой пересортировкой
- покрытие через `maxWeight = 51` на субсканлайн (~8 бит AA)
- правила nonzero **и** evenodd

### Stroke — полностью поддерживается

- программная обводка полигонами
- caps: butt / square / round
- joins: miter (с внутренней складкой через LEFT-флаг) / round / bevel
- `miterLimit`, clamp `s2 <= 600`
- **dash** с чётностью паттерна и нормализацией offset

### Градиенты

- LUT 256 записей с линейной интерполяцией стопов
- premultiplied source-over блендинг
- `div255` через `(x + 1) * 257 >> 16`

### Пост-обработка

- unpremultiply
- defringe (средний цвет соседей для a == 0)

### paint-order

Цикл по 3 слоям; stroke если `strokeWidth·scale > 0.01`;
stroke всегда nonzero.

### Память

- пул страниц по 1024 байта + freelist для активных рёбер
- reset на каждом шейпе

## 5. Что НЕ поддерживается

`text`/`tspan`, `<use>`/`<symbol>`, `clipPath`, маски, фильтры, паттерны,
маркеры, `visibility`, `currentColor`/`inherit`, `hsl()`/`rgba()`/hex
с альфой, вложенные `<svg>`, XML-сущности/CDATA/неймспейсы,
CSS-каскад (только классы), SMIL-анимации, spread-режимы градиентов
в рендере, фокус радиальных градиентов в рендере, дэши > 8.

## 6. Ловушки при портировании на Crystal

- **Баг-совместимость:**
  - `nsvg__xformInverse` при вырожденной матрице пишет identity
    **в `t`, а не в `inv`**
  - в defringe условия `x - 1 > 0` вместо `>= 0` пропускают
    строку/столбец 0
  - `moveTo` перезаписывает последнюю точку — воспроизвести
    или осознанно исправить
- Порядок путей внутри фигуры — вставка в голову списка (реверс)
- Формат точек строго `npts % 3 == 1`; цвет `0xAABBGGRR`
- Матрица градиента инвертируется дважды по ходу пайплайна
  (в резолве и в scaleToViewbox)
- Fallback-серый, `d < 1e-6` в дугах, спец-парсинг флагов `A` — легко сломать
- Идиомы Crystal:
  - linked lists → `Array`
  - union-paint → закрытый union-тип
  - `stops[1]` → `Array(GradientStop)`
  - пул → простой reuse-массив
  - `Float32` везде или осознанный переход на `Float64`
- Шаблон использования — `example2.c`: parse → rasterize → PNG —
  его и стоит воспроизвести как минимальный спек порта
