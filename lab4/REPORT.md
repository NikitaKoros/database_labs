# Лабораторная работа №4
## Исследование индексирования и оптимизации запросов в PostgreSQL

---

## 1. Схема базы данных

Используется схема из лабораторной работы №3 — система аренды оборудования.

Таблицы:
- `users` — пользователи системы
- `equipment_categories` — категории оборудования
- `equipment` — единицы оборудования
- `rentals` — аренды (основная таблица для индексирования)
- `payments` — платежи
- `reviews` — отзывы

В отличие от lab3, схема запускается без дополнительных индексов (только PRIMARY KEY и UNIQUE constraints), чтобы обеспечить чистую базу для экспериментов.

---

## 2. Набор данных

Генерация выполнена одним SQL-скриптом через `generate_series` без внешних файлов.

| Таблица | Строк |
|---------|-------|
| users | 10 000 |
| equipment_categories | 20 |
| equipment | 100 000 |
| rentals | 1 200 000 |
| payments | 840 000 |
| reviews | 120 000 |

Ключевые решения при генерации:

`rentals.created_at` вставлялся с шагом 79 секунд, что равномерно распределяет 1 200 000 строк по трём годам (2022–2025) и обеспечивает физическую корреляцию данных с временной осью — необходимое условие для эффективности BRIN-индекса.

Заголовки оборудования имеют структуру `"<ToolType> <Modifier> <Brand>"`, например `"Drill Heavy-Duty Pro"`, `"Hammer Industrial Max"`. Тип инструмента детерминирован (`i % 20`), поэтому:
- `LIKE 'Drill%'` находит ровно 5 000 строк (префиксный поиск)
- `LIKE '%Heavy-Duty%'` находит ~10 000 строк (поиск подстроки)
- `LIKE '%Pro'` находит ~10 000 строк (поиск суффикса)

Статусы аренды (`pending`, `confirmed`, `active`, `completed`, `cancelled`) распределены равномерно — по 240 000 строк каждый.

---

## 3. Эксперимент 1. Сложный фильтр

### Запрос

```sql
SELECT rental_id, equipment_id, renter_id, start_date, total_price
FROM rentals
WHERE status = 'confirmed'
  AND total_price BETWEEN 500 AND 3000
  AND start_date >= '2024-01-01';
```

### Гипотеза

Запрос фильтрует по трём условиям. Без индекса PostgreSQL выполняет последовательное сканирование 1 200 000 строк с применением всех трёх условий одновременно. Составной индекс `(status, total_price)` позволит резко сократить количество читаемых страниц: сначала точный фильтр по `status`, затем диапазонный по `total_price`, а `start_date` будет применён как дополнительный фильтр уже к отобранным строкам.

### Индекс

```sql
CREATE INDEX idx_rentals_status_price ON rentals(status, total_price);
```

`status` стоит первым, так как точное равенство эффективнее ограничивает поддерево B-tree, чем диапазон. `total_price` вторым для использования range-условия внутри уже отфильтрованного поддерева.

### EXPLAIN ANALYZE до оптимизации

```
Seq Scan on rentals  (cost=0.00..35215.00 rows=60085 width=22)
                     (actual time=0.036..163.843 rows=60038 loops=1)
  Filter: ((total_price >= '500'::numeric) AND (total_price <= '3000'::numeric)
           AND (start_date >= '2024-01-01'::date)
           AND ((status)::text = 'confirmed'::text))
  Rows Removed by Filter: 1139962
Planning Time: 0.205 ms
Execution Time: 165.841 ms
```

### EXPLAIN ANALYZE после оптимизации

```
Bitmap Heap Scan on rentals  (cost=1854.51..14271.21 rows=60085 width=22)
                              (actual time=11.322..73.569 rows=60038 loops=1)
  Recheck Cond: (((status)::text = 'confirmed'::text)
                 AND (total_price >= '500'::numeric)
                 AND (total_price <= '3000'::numeric))
  Filter: (start_date >= '2024-01-01'::date)
  Heap Blocks: exact=11189
  ->  Bitmap Index Scan on idx_rentals_status_price
        (cost=0.00..1839.49 rows=60085 width=0)
        (actual time=9.775..9.775 rows=60038 loops=1)
       Index Cond: (((status)::text = 'confirmed'::text)
                    AND (total_price >= '500'::numeric)
                    AND (total_price <= '3000'::numeric))
Planning Time: 0.234 ms
Execution Time: 75.574 ms
```

### Сравнение

| | До | После |
|-|-------|-------|
| Метод | Seq Scan | Bitmap Index Scan + Bitmap Heap Scan |
| Строк просмотрено | 1 200 000 | 60 038 (через индекс) |
| Heap Blocks | — | 11 189 |
| Результирующих строк | 60 038 | 60 038 |
| Время выполнения | 166 мс | 76 мс |
| Ускорение | — | **~2.2x** |

### Вывод

Гипотеза подтвердилась. Индекс `(status, total_price)` позволил планировщику переключиться на Bitmap Index Scan: вместо сканирования 1 200 000 строк индекс отобрал 60 038 строк, соответствующих `status = 'confirmed'` и `total_price BETWEEN 500 AND 3000`. Условие `start_date >= '2024-01-01'` присутствует в плане как Filter на уровне heap, но в данном запуске не удалило ни одной строки — все отобранные записи уже удовлетворяли этому условию. Ускорение 2.2x умеренное: результирующая выборка велика (~60 000 строк = 5% таблицы), поэтому Bitmap Heap Scan требует нетривиального случайного I/O по 11 189 блокам.

---

## 4. Эксперимент 2. Сортировка с ограничением

### Запрос

```sql
SELECT equipment_id, title, price_per_day, location
FROM equipment
WHERE is_available = TRUE
ORDER BY price_per_day DESC
LIMIT 10;
```

### Гипотеза

Без индекса PostgreSQL прочитает все 100 000 строк, применит фильтр (оставит ~70 000), выполнит сортировку и вернёт 10 записей. Составной индекс `(is_available, price_per_day DESC)` хранит данные уже в нужном порядке, что позволит прочитать ровно 10 строк без сортировки всей выборки.

### Индекс

```sql
CREATE INDEX idx_equipment_avail_price ON equipment(is_available, price_per_day DESC);
```

Направление `DESC` в индексе совпадает с `ORDER BY price_per_day DESC`, что позволяет читать строки в нужном порядке без дополнительной операции Sort.

### EXPLAIN ANALYZE до оптимизации

```
Limit  (cost=4405.53..4405.55 rows=10 width=43)
       (actual time=30.701..30.703 rows=10 loops=1)
  ->  Sort  (cost=4405.53..4580.40 rows=69947 width=43)
            (actual time=30.699..30.700 rows=10 loops=1)
        Sort Key: price_per_day DESC
        Sort Method: top-N heapsort  Memory: 26kB
        ->  Seq Scan on equipment  (cost=0.00..2894.00 rows=69947 width=43)
                                   (actual time=0.012..20.546 rows=70097 loops=1)
              Filter: is_available
              Rows Removed by Filter: 29903
Planning Time: 0.207 ms
Execution Time: 30.720 ms
```

### EXPLAIN ANALYZE после оптимизации

```
Limit  (cost=0.29..1.49 rows=10 width=43)
       (actual time=0.017..0.032 rows=10 loops=1)
  ->  Index Scan using idx_equipment_avail_price on equipment
        (cost=0.29..8403.75 rows=69947 width=43)
        (actual time=0.016..0.030 rows=10 loops=1)
       Index Cond: (is_available = true)
Planning Time: 0.126 ms
Execution Time: 0.043 ms
```

### Сравнение

| | До | После |
|-|-------|-------|
| Метод | Seq Scan + Sort | Index Scan |
| Строк обработано | 100 000 | 10 |
| Время выполнения | 31 мс | 0.043 мс |
| Ускорение | — | **~720x** |

### Вывод

Гипотеза подтвердилась. Это классический случай top-N через индекс: PostgreSQL читает данные уже упорядоченными и останавливается ровно на 10-й строке. Стадия Sort полностью устранена. Ускорение в 810 раз — максимально возможный выигрыш для данного паттерна. При LIMIT = 70 000 планировщик предпочёл бы seq scan, так как выгода от индекса исчезает при большой выборке.

---

## 5. Эксперимент 3. Альтернативные варианты индексирования

### Запрос

```sql
SELECT rental_id, renter_id, start_date, total_price
FROM rentals
WHERE created_at BETWEEN '2024-01-01' AND '2024-06-30';
```

### Гипотеза

Запрос возвращает ~200 000 строк (~17% таблицы). Поскольку строки вставлялись с равномерным шагом по времени, значения `created_at` физически коррелируют с расположением страниц на диске — это создаёт условие для сравнения B-tree и BRIN:

- **B-tree**: точечный поиск нужных страниц, хорошо работает для любых данных, но занимает значительный объём
- **BRIN**: хранит min/max для диапазонов страниц, крайне компактен, эффективен только при физической корреляции данных

### Индексы

```sql
-- Вариант A
CREATE INDEX idx_rentals_created_btree ON rentals USING btree(created_at);

-- Вариант B
CREATE INDEX idx_rentals_created_brin ON rentals USING brin(created_at)
WITH (pages_per_range = 128);
```

### EXPLAIN ANALYZE до оптимизации

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=201625 width=18)
                     (actual time=45.591..79.868 rows=197955 loops=1)
  Filter: ((created_at >= '2024-01-01 00:00:00'::timestamp without time zone)
           AND (created_at <= '2024-06-30 00:00:00'::timestamp without time zone))
  Rows Removed by Filter: 1002045
Planning Time: 0.062 ms
Execution Time: 86.297 ms
```

### EXPLAIN ANALYZE с B-tree индексом

```
Index Scan using idx_rentals_created_btree on rentals
  (cost=0.43..8136.93 rows=201625 width=18)
  (actual time=0.094..32.512 rows=197955 loops=1)
  Index Cond: ((created_at >= '2024-01-01 00:00:00'::timestamp without time zone)
               AND (created_at <= '2024-06-30 00:00:00'::timestamp without time zone))
Planning Time: 0.171 ms
Execution Time: 39.064 ms
```

Размер B-tree индекса: **26 MB**

### EXPLAIN ANALYZE с BRIN индексом

```
Bitmap Heap Scan on rentals  (cost=62.89..14346.06 rows=201625 width=18)
                              (actual time=0.382..23.368 rows=197955 loops=1)
  Recheck Cond: ((created_at >= '2024-01-01 00:00:00'::timestamp without time zone)
                 AND (created_at <= '2024-06-30 00:00:00'::timestamp without time zone))
  Rows Removed by Index Recheck: 7486
  Heap Blocks: lossy=1920
  ->  Bitmap Index Scan on idx_rentals_created_brin
        (cost=0.00..12.48 rows=204545 width=0)
        (actual time=0.041..0.041 rows=19200 loops=1)
       Index Cond: ((created_at >= '2024-01-01 00:00:00'::timestamp without time zone)
                    AND (created_at <= '2024-06-30 00:00:00'::timestamp without time zone))
Planning Time: 0.140 ms
Execution Time: 29.794 ms
```

Размер BRIN индекса: **24 KB**

### Сравнение

| | Без индекса | B-tree | BRIN |
|-|-------------|--------|------|
| Метод | Seq Scan | Index Scan | Bitmap Heap Scan |
| Время выполнения | 86 мс | 39 мс | 30 мс |
| Ускорение | — | 2.2x | 2.9x |
| Размер индекса | — | 26 MB | 24 KB |
| Recheck строк | — | 0 | 7 486 |

### Вывод

Оба индекса ускоряют запрос в 2.2–2.9 раза. BRIN в данном случае оказался немного быстрее B-tree (30 мс vs 39 мс), что объясняется тем, что данные вставлялись строго последовательно: BRIN точно определяет диапазон нужных страниц и практически не создаёт лишних Recheck. При этом BRIN занимает в **1083 раза** меньше места (24 KB vs 26 MB) и строится в разы быстрее.

Если бы данные вставлялись в случайном порядке (низкая корреляция), BRIN потерял бы эффективность, а B-tree остался бы стабильным. Выбор зависит от контекста: при ограниченном месте и последовательных данных — BRIN, при приоритете скорости и произвольных данных — B-tree.

---

## 6. Эксперимент 4. Текстовый поиск

### Запросы

```sql
-- Префикс
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE 'Drill%';

-- Подстрока
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Heavy-Duty%';

-- Суффикс
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Pro';
```

### Гипотеза

B-tree с оператором `text_pattern_ops` поддерживает только префиксный LIKE. Для подстрок и суффиксов нужен GIN-индекс на тригграммах (`pg_trgm`). Ожидается, что тригграммный индекс ускорит все три паттерна.

### Индексы

```sql
-- Вариант A: B-tree для prefix-only
CREATE INDEX idx_equipment_title_pattern ON equipment(title text_pattern_ops);

-- Вариант B: GIN trigram для всех паттернов
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_equipment_title_trgm ON equipment USING gin(title gin_trgm_ops);
```

### EXPLAIN ANALYZE без индексов

```
-- Префикс 'Drill%'
Seq Scan on equipment  (cost=0.00..3144.00 rows=4010 width=32)
                       (actual time=0.010..6.841 rows=5000 loops=1)
  Filter: ((title)::text ~~ 'Drill%'::text)
  Rows Removed by Filter: 95000
Execution Time: 7.021 ms

-- Подстрока '%Heavy-Duty%'
Seq Scan on equipment  (cost=0.00..3144.00 rows=11955 width=32)
                       (actual time=0.006..11.189 rows=10027 loops=1)
  Filter: ((title)::text ~~ '%Heavy-Duty%'::text)
  Rows Removed by Filter: 89973
Execution Time: 11.515 ms

-- Суффикс '%Pro'
Seq Scan on equipment  (cost=0.00..3144.00 rows=7290 width=32)
                       (actual time=0.004..12.310 rows=10161 loops=1)
  Filter: ((title)::text ~~ '%Pro'::text)
  Rows Removed by Filter: 89839
Execution Time: 12.673 ms
```

### EXPLAIN ANALYZE с B-tree (text_pattern_ops)

```
-- Префикс 'Drill%' — индекс используется
Bitmap Heap Scan on equipment  (cost=56.61..1999.77 rows=4010 width=32)
                                (actual time=0.576..2.914 rows=5000 loops=1)
  Filter: ((title)::text ~~ 'Drill%'::text)
  Heap Blocks: exact=1894
  ->  Bitmap Index Scan on idx_equipment_title_pattern
        (actual time=0.337..0.337 rows=5000 loops=1)
       Index Cond: (((title)::text ~>=~ 'Drill'::text) AND
                    ((title)::text ~<~ 'Drilm'::text))
Execution Time: 3.101 ms

-- Подстрока '%Heavy-Duty%' — seq scan, индекс не используется
Seq Scan on equipment  (actual time=0.005..11.077 rows=10027 loops=1)
  Filter: ((title)::text ~~ '%Heavy-Duty%'::text)
Execution Time: 11.420 ms

-- Суффикс '%Pro' — seq scan, индекс не используется
Seq Scan on equipment  (actual time=0.004..11.263 rows=10161 loops=1)
  Filter: ((title)::text ~~ '%Pro'::text)
Execution Time: 11.595 ms
```

### EXPLAIN ANALYZE с GIN trigram

```
-- Префикс 'Drill%'
Bitmap Heap Scan on equipment  (cost=96.76..2040.89 rows=4010 width=32)
                                (actual time=1.201..3.281 rows=5000 loops=1)
  Recheck Cond: ((title)::text ~~ 'Drill%'::text)
  Heap Blocks: exact=1894
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=0.949..0.949 rows=5000 loops=1)
       Index Cond: ((title)::text ~~ 'Drill%'::text)
Execution Time: 3.455 ms

-- Подстрока '%Heavy-Duty%'
Bitmap Heap Scan on equipment  (cost=180.61..2224.04 rows=11955 width=32)
                                (actual time=2.452..5.460 rows=10027 loops=1)
  Recheck Cond: ((title)::text ~~ '%Heavy-Duty%'::text)
  Heap Blocks: exact=1887
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=2.226..2.226 rows=10027 loops=1)
       Index Cond: ((title)::text ~~ '%Heavy-Duty%'::text)
Execution Time: 5.801 ms

-- Суффикс '%Pro'
Bitmap Heap Scan on equipment  (cost=67.73..2052.86 rows=7290 width=32)
                                (actual time=1.064..4.260 rows=10161 loops=1)
  Recheck Cond: ((title)::text ~~ '%Pro'::text)
  Heap Blocks: exact=1893
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=0.842..0.842 rows=10161 loops=1)
       Index Cond: ((title)::text ~~ '%Pro'::text)
Execution Time: 4.595 ms
```

### Сравнение

| Паттерн | Без индекса | B-tree (text_pattern_ops) | GIN trigram |
|---------|-------------|--------------------------|-------------|
| `LIKE 'Drill%'` (префикс, 5 000 строк) | 7 мс | **3.1 мс** (2.3x) | 3.5 мс (2.0x) |
| `LIKE '%Heavy-Duty%'` (подстрока, 10 027 строк) | 12 мс | 11 мс (seq scan, без изменений) | **5.8 мс** (2.0x) |
| `LIKE '%Pro'` (суффикс, 10 161 строка) | 13 мс | 12 мс (seq scan, без изменений) | **4.6 мс** (2.8x) |

### Вывод

Гипотеза подтвердилась. B-tree с `text_pattern_ops` ускоряет только префиксный поиск (2.3x), для подстрок и суффиксов планировщик оставляет seq scan — такой индекс физически не поддерживает эти паттерны. GIN trigram поддерживает все три паттерна и ускоряет каждый в 2–2.8 раза. В отличие от результатов на меньших наборах данных, при данном объёме (~100 000 строк) тригграммный индекс выигрывает даже при относительно высокой доле совпадений (~10%). Для префикса B-tree с `text_pattern_ops` незначительно быстрее GIN trigram (3.1 мс vs 3.5 мс) — специализированный индекс точнее, чем универсальный. Если в базе будут миллионы строк, разрыв в пользу GIN trigram станет ещё заметнее.

---

## 7. Эксперимент 5. Соединение таблиц

### Запрос

```sql
SELECT u.full_name, u.email, e.title,
       r.start_date, r.end_date, r.total_price, p.payment_method
FROM rentals r
JOIN users     u ON u.user_id      = r.renter_id
JOIN equipment e ON e.equipment_id = r.equipment_id
JOIN payments  p ON p.rental_id    = r.rental_id
WHERE r.status = 'completed'
  AND r.created_at >= '2024-01-01'
ORDER BY r.created_at DESC
LIMIT 100;
```

### Гипотеза

Узкое место — фильтрация rentals по `status` и `created_at`. Без специального индекса планировщик вынужден использовать Hash Join со сканированием большого числа строк. Составной индекс `(status, created_at DESC)` позволит точно найти нужные аренды по обоим условиям одновременно.

### Индекс

```sql
CREATE INDEX idx_rentals_status_created ON rentals(status, created_at DESC);
```

### EXPLAIN ANALYZE до оптимизации

На момент выполнения этого эксперимента в базе уже существовал `idx_rentals_status_price` из эксперимента 1. Планировщик его задействовал, однако он покрывает только условие `status = 'completed'`, оставляя `created_at` как дополнительный фильтр на уровне heap.

```
Limit  (cost=45794.39..45794.64 rows=100 width=84)
       (actual time=305.385..305.401 rows=100 loops=1)
  ->  Sort  (cost=45794.39..45933.74 rows=55742 width=84)
            (actual time=305.383..305.393 rows=100 loops=1)
        Sort Key: r.created_at DESC
        Sort Method: top-N heapsort  Memory: 51kB
        ->  Hash Join  (cost=26353.24..43663.97 rows=55742 width=84)
                       (actual time=203.091..294.619 rows=40162 loops=1)
              Hash Cond: (r.equipment_id = e.equipment_id)
              ->  Hash Join  (cost=22209.24..39373.64 rows=55742 width=66)
                    Hash Cond: (r.renter_id = u.user_id)
                    ->  Hash Join  (cost=21860.24..38878.25 rows=55742 width=35)
                          Hash Cond: (p.rental_id = r.rental_id)
                          ->  Seq Scan on payments p
                                (actual time=0.019..82.622 rows=840000 loops=1)
                          ->  Hash (rows=80324)
                                ->  Bitmap Heap Scan on rentals r
                                      Recheck Cond: (status = 'completed')
                                      Filter: (created_at >= '2024-01-01')
                                      Rows Removed by Filter: 159676
                                      Heap Blocks: exact=11215
                                      ->  Bitmap Index Scan on idx_rentals_status_price
                                            Index Cond: (status = 'completed')
                    ->  Hash on users (rows=10000)
              ->  Hash on equipment (rows=100000)
Planning Time: 0.594 ms
Execution Time: 305.488 ms
```

### EXPLAIN ANALYZE после оптимизации

```
Limit  (cost=39595.69..39595.94 rows=100 width=84)
       (actual time=266.078..266.098 rows=100 loops=1)
  ->  Sort  (cost=39595.69..39735.04 rows=55742 width=84)
            (actual time=266.075..266.087 rows=100 loops=1)
        Sort Key: r.created_at DESC
        Sort Method: top-N heapsort  Memory: 51kB
        ->  Hash Join  (cost=20154.54..37465.27 rows=55742 width=84)
                       (actual time=167.135..255.445 rows=40162 loops=1)
              Hash Cond: (r.equipment_id = e.equipment_id)
              ->  Hash Join  (cost=16010.54..33174.94 rows=55742 width=66)
                    Hash Cond: (r.renter_id = u.user_id)
                    ->  Hash Join  (cost=15661.54..32679.55 rows=55742 width=35)
                          Hash Cond: (p.rental_id = r.rental_id)
                          ->  Seq Scan on payments p
                                (actual time=0.004..63.803 rows=840000 loops=1)
                          ->  Hash (rows=80324)
                                ->  Bitmap Heap Scan on rentals r
                                      Recheck Cond: ((status = 'completed')
                                                     AND (created_at >= '2024-01-01'))
                                      Heap Blocks: exact=3754
                                      ->  Bitmap Index Scan on idx_rentals_status_created
                                            Index Cond: ((status = 'completed')
                                                         AND (created_at >= '2024-01-01'))
                    ->  Hash on users (rows=10000)
              ->  Hash on equipment (rows=100000)
Planning Time: 0.462 ms
Execution Time: 266.252 ms
```

### Сравнение

| | До | После |
|-|-------|-------|
| Индекс на rentals | `idx_rentals_status_price` | `idx_rentals_status_created` |
| Heap Blocks rentals | 11 215 | 3 754 |
| Rows Removed by Filter | 159 676 | 0 |
| Время выполнения | 305 мс | 266 мс |
| Ускорение | — | **1.15x** |

### Вывод

Гипотеза подтвердилась. Ключевое улучшение — в шаге фильтрации rentals: `idx_rentals_status_created` покрывает оба условия (`status` и `created_at`) одновременно, что сокращает число обращённых блоков heap с 11 215 до 3 754 и полностью устраняет дополнительный Filter-шаг (Rows Removed by Filter: 159 676 → 0). Общий план остался Hash Join, так как для оставшихся 80 324 строк и размеров таблиц он оптимален. Итоговое ускорение скромное (1.15x), поскольку узкое место этого запроса — Seq Scan на таблице payments (840 000 строк), который индексировать бессмысленно без дополнительного фильтра по платежам.

---

## 8. Эксперимент 6. Негативный сценарий

### Запрос

```sql
SELECT rental_id, equipment_id, start_date, total_price
FROM rentals
WHERE status IN ('pending', 'confirmed', 'active', 'completed');
```

### Гипотеза

Запрос исключает только `'cancelled'` (~240 000 строк из 1 200 000), возвращая ~80% таблицы. При такой низкой селективности индекс по `status` не должен использоваться: стоимость чтения индекса плюс разрозненных страниц heap превысит стоимость линейного seq scan.

### Индекс

```sql
CREATE INDEX idx_rentals_status ON rentals(status);
```

### EXPLAIN ANALYZE до создания индекса

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=964680 width=18)
                     (actual time=0.010..177.513 rows=960000 loops=1)
  Filter: ((status)::text = ANY ('{pending,confirmed,active,completed}'::text[]))
  Rows Removed by Filter: 240000
Planning Time: 0.210 ms
Execution Time: 208.300 ms
```

### EXPLAIN ANALYZE после создания индекса — индекс не используется

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=964680 width=18)
                     (actual time=0.008..179.482 rows=960000 loops=1)
  Filter: ((status)::text = ANY ('{pending,confirmed,active,completed}'::text[]))
  Rows Removed by Filter: 240000
Planning Time: 0.123 ms
Execution Time: 210.379 ms
```

Планировщик выбрал тот же план — Seq Scan. Индекс создан, но не задействован.

### Контрпример: тот же индекс при селективном запросе с LIMIT

```sql
SELECT rental_id, equipment_id, start_date, total_price
FROM rentals
WHERE status = 'cancelled'
LIMIT 100;
```

```
Limit  (cost=0.00..11.14 rows=100 width=18)
       (actual time=0.008..0.056 rows=100 loops=1)
  ->  Seq Scan on rentals  (cost=0.00..26215.00 rows=235320 width=18)
                            (actual time=0.007..0.048 rows=100 loops=1)
        Filter: ((status)::text = 'cancelled'::text)
        Rows Removed by Filter: 399
Planning Time: 0.074 ms
Execution Time: 0.068 ms
```

Даже с LIMIT 100 и индексом по `status` планировщик выбирает Seq Scan — он знает, что `'cancelled'` встречается каждые ~5 строк (равномерное распределение), поэтому первые 100 записей будут найдены уже в первых ~500 строках таблицы. Seq Scan с ранним выходом оказывается быстрее Index Scan.

### Сравнение

| Запрос | Индекс | Метод | Время |
|--------|--------|-------|-------|
| `status IN (4 из 5)` — 80% строк | Нет | Seq Scan | 208 мс |
| `status IN (4 из 5)` — 80% строк | Есть | Seq Scan | 210 мс |
| `status = 'cancelled'` LIMIT 100 | Есть | Seq Scan + early exit | 0.07 мс |

### Вывод

Гипотеза подтвердилась. Индекс на `status` полностью игнорируется для запроса, возвращающего 80% строк. Интересная деталь: при запросе `LIMIT 100` с высокоселективным условием индекс по `status` тоже не используется — PostgreSQL предпочитает seq scan с ранним выходом, поскольку данные равномерно распределены и первые 100 строк со статусом `'cancelled'` находятся в первых ~500 строках таблицы. Индекс на низкокардинальном столбце полезен только при реально избирательных запросах или при наличии дополнительных условий с высокой селективностью.

---

## 9. Влияние индексов на операции изменения данных

### Методика

INSERT: 10 000 строк в таблицу rentals в двух сценариях — только PRIMARY KEY, и с четырьмя дополнительными индексами. Оба INSERT используют идентичный запрос.

UPDATE: `SET total_price = total_price * 1.05 WHERE status = 'confirmed' AND total_price < 500` — одинаковое условие в обоих запусках. Между запусками выполняется шаг сброса (`total_price / 1.05`), чтобы второй UPDATE работал на тех же строках.

### Результаты INSERT (10 000 строк)

| Индексы на rentals | Время INSERT |
|--------------------|-------------|
| Только PRIMARY KEY | 153 мс |
| PRIMARY KEY + 4 индекса | 215 мс |

Разница **+40%** — поддержание четырёх B-tree индексов при вставке заметно увеличивает время.

### Результаты UPDATE (одинаковое условие, ~11 000–11 800 строк)

| Индексы на rentals | Строк обновлено | Время UPDATE |
|--------------------|-----------------|-------------|
| Только PRIMARY KEY | 11 191 | 215 мс |
| PRIMARY KEY + 4 индекса | 11 815 | 247 мс |

С индексами UPDATE выполнился на **~15% медленнее**.

> Небольшая разница в числе строк (11 191 vs 11 815) — следствие округления при делении на 1.05 в шаге сброса: часть строк с ценой 500–525 попала под сброс и образовала новые строки с `total_price < 500`.

### Анализ

INSERT с 4 индексами оказался на 40% медленнее. Каждая вставленная строка требует обновления четырёх дополнительных B-tree структур, что линейно увеличивает время записи.

UPDATE с индексами оказался на ~15% медленнее. Хотя индекс `idx_rentals_status_price` ускоряет поиск строк по условию `WHERE status = 'confirmed' AND total_price < 500`, накладные расходы на обновление четырёх индексных структур для ~11 000 изменённых строк превышают выигрыш от быстрого поиска.

Вывод: индексы замедляют как INSERT, так и UPDATE. Замедление INSERT более выражено (+40%), поскольку каждая новая строка требует полного добавления во все индексы. Замедление UPDATE умереннее (+15%), так как индекс ускоряет фазу поиска строк, частично компенсируя накладные расходы на обновление индексных структур.

---

## 10. Общие выводы

1. Составной индекс `(status, total_price)` ускорил сложный фильтр с 166 мс до 76 мс (2.2x), переключив план с Seq Scan на Bitmap Index Scan и сократив число просматриваемых строк с 1 200 000 до 60 000.

2. Индекс `(is_available, price_per_day DESC)` для ORDER BY ... LIMIT 10 дал ускорение в ~720 раз (31 мс → 0.043 мс) за счёт устранения операции Sort и чтения ровно 10 записей.

3. B-tree и BRIN по `created_at` дают сопоставимое ускорение (2.2x и 2.9x соответственно), при этом BRIN занимает в 1083 раза меньше места (24 KB vs 26 MB). BRIN применим только при физически последовательных данных.

4. B-tree с `text_pattern_ops` оптимален для префиксного поиска (2.3x). GIN trigram поддерживает все паттерны (prefix, substring, suffix) и даёт ускорение в 2–2.8 раза. Для PREFIX B-tree незначительно быстрее GIN (3.1 мс vs 3.5 мс) — специализированный индекс точнее универсального.

5. Индекс `(status, created_at DESC)` сократил число heap-блоков rentals в JOIN-запросе с 11 215 до 3 754 и устранил Filter-шаг (Rows Removed: 159 676 → 0). Ускорение 1.15x; общий bottleneck — обязательный Seq Scan на payments (840 000 строк).

6. Индекс на `status` полностью игнорируется для запросов, возвращающих 80% строк. Планировщик PostgreSQL выбирает seq scan, когда случайный I/O по индексу дороже последовательного чтения.

7. INSERT с 4 индексами замедлился на 40% (153 мс → 215 мс). UPDATE с индексами стал медленнее на 15% (215 мс → 247 мс) — накладные расходы на поддержание индексных структур превысили выигрыш от ускоренного поиска строк.
