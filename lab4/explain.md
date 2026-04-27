# Результаты экспериментов — Lab 4

Запуск: свежий контейнер (docker-compose down -v && docker-compose up -d),
затем `\timing on` + `\i scripts/03_experiments.sql`.

---

## Состояние индексов перед экспериментами

```
         indexname         |      tablename
---------------------------+----------------------
 equipment_pkey            | equipment
 equipment_categories_pkey | equipment_categories
 payments_pkey             | payments
 rentals_pkey              | rentals
 reviews_pkey              | reviews
 reviews_rental_id_key     | reviews
 users_email_key           | users
 users_pkey                | users
```

---

## Эксперимент 1. Сложный фильтр

### До индекса

```
Seq Scan on rentals  (cost=0.00..35215.00 rows=60085 width=22)
                     (actual time=0.036..163.843 rows=60038 loops=1)
  Filter: ((total_price >= '500'::numeric) AND (total_price <= '3000'::numeric)
           AND (start_date >= '2024-01-01'::date)
           AND ((status)::text = 'confirmed'::text))
  Rows Removed by Filter: 1139962
Planning Time: 0.205 ms
Execution Time: 165.841 ms
Time: 168.148 ms
```

### Создание индекса

```
CREATE INDEX idx_rentals_status_price ON rentals(status, total_price);
Time: 1277.189 ms
```

### После индекса

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
Time: 76.936 ms
```

---

## Эксперимент 2. Сортировка с ограничением

### До индекса

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
Time: 31.974 ms
```

### Создание индекса

```
CREATE INDEX idx_equipment_avail_price ON equipment(is_available, price_per_day DESC);
Time: 83.363 ms
```

### После индекса

```
Limit  (cost=0.29..1.49 rows=10 width=43)
       (actual time=0.017..0.032 rows=10 loops=1)
  ->  Index Scan using idx_equipment_avail_price on equipment
        (cost=0.29..8403.75 rows=69947 width=43)
        (actual time=0.016..0.030 rows=10 loops=1)
       Index Cond: (is_available = true)
Planning Time: 0.126 ms
Execution Time: 0.043 ms
Time: 0.595 ms
```

---

## Эксперимент 3. Альтернативные варианты индексирования (B-tree vs BRIN)

### До индекса

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=201625 width=18)
                     (actual time=45.591..79.868 rows=197955 loops=1)
  Filter: ((created_at >= '2024-01-01 00:00:00') AND (created_at <= '2024-06-30 00:00:00'))
  Rows Removed by Filter: 1002045
Planning Time: 0.062 ms
Execution Time: 86.297 ms
Time: 86.996 ms
```

### B-tree индекс

```
CREATE INDEX idx_rentals_created_btree ON rentals USING btree(created_at);
Time: 234.546 ms
```

```
Index Scan using idx_rentals_created_btree on rentals
  (cost=0.43..8136.93 rows=201625 width=18)
  (actual time=0.094..32.512 rows=197955 loops=1)
  Index Cond: ((created_at >= '2024-01-01 00:00:00') AND (created_at <= '2024-06-30 00:00:00'))
Planning Time: 0.171 ms
Execution Time: 39.064 ms
Time: 39.977 ms
```

```
 btree_size
------------
 26 MB
```

### BRIN индекс

```
CREATE INDEX idx_rentals_created_brin ON rentals USING brin(created_at) WITH (pages_per_range=128);
Time: 139.555 ms
```

```
Bitmap Heap Scan on rentals  (cost=62.89..14346.06 rows=201625 width=18)
                              (actual time=0.382..23.368 rows=197955 loops=1)
  Recheck Cond: ((created_at >= '2024-01-01 00:00:00') AND (created_at <= '2024-06-30 00:00:00'))
  Rows Removed by Index Recheck: 7486
  Heap Blocks: lossy=1920
  ->  Bitmap Index Scan on idx_rentals_created_brin
        (cost=0.00..12.48 rows=204545 width=0)
        (actual time=0.041..0.041 rows=19200 loops=1)
       Index Cond: ((created_at >= '2024-01-01 00:00:00') AND (created_at <= '2024-06-30 00:00:00'))
Planning Time: 0.140 ms
Execution Time: 29.794 ms
Time: 30.603 ms
```

```
 brin_size
-----------
 24 kB
```

---

## Эксперимент 4. Текстовый поиск

### Без индексов

```
-- Префикс 'Drill%'
Seq Scan on equipment  (cost=0.00..3144.00 rows=4010 width=32)
                       (actual time=0.010..6.841 rows=5000 loops=1)
  Filter: ((title)::text ~~ 'Drill%'::text)
  Rows Removed by Filter: 95000
Execution Time: 7.021 ms  |  Time: 7.570 ms

-- Подстрока '%Heavy-Duty%'
Seq Scan on equipment  (cost=0.00..3144.00 rows=11955 width=32)
                       (actual time=0.006..11.189 rows=10027 loops=1)
  Filter: ((title)::text ~~ '%Heavy-Duty%'::text)
  Rows Removed by Filter: 89973
Execution Time: 11.515 ms  |  Time: 11.988 ms

-- Суффикс '%Pro'
Seq Scan on equipment  (cost=0.00..3144.00 rows=7290 width=32)
                       (actual time=0.004..12.310 rows=10161 loops=1)
  Filter: ((title)::text ~~ '%Pro'::text)
  Rows Removed by Filter: 89839
Execution Time: 12.673 ms  |  Time: 13.130 ms
```

### B-tree (text_pattern_ops)

```
CREATE INDEX idx_equipment_title_pattern ON equipment(title text_pattern_ops);
Time: 54.528 ms
```

```
-- Префикс 'Drill%' — индекс используется
Bitmap Heap Scan on equipment  (cost=56.61..1999.77 rows=4010 width=32)
                                (actual time=0.576..2.914 rows=5000 loops=1)
  Filter: ((title)::text ~~ 'Drill%'::text)
  Heap Blocks: exact=1894
  ->  Bitmap Index Scan on idx_equipment_title_pattern
        (actual time=0.337..0.337 rows=5000 loops=1)
       Index Cond: (((title)::text ~>=~ 'Drill'::text) AND ((title)::text ~<~ 'Drilm'::text))
Execution Time: 3.101 ms  |  Time: 3.764 ms

-- Подстрока '%Heavy-Duty%' — seq scan, индекс не используется
Seq Scan on equipment  (actual time=0.005..11.077 rows=10027 loops=1)
  Filter: ((title)::text ~~ '%Heavy-Duty%'::text)
Execution Time: 11.420 ms  |  Time: 11.841 ms

-- Суффикс '%Pro' — seq scan, индекс не используется
Seq Scan on equipment  (actual time=0.004..11.263 rows=10161 loops=1)
  Filter: ((title)::text ~~ '%Pro'::text)
Execution Time: 11.595 ms  |  Time: 12.039 ms
```

### GIN trigram

```
CREATE EXTENSION IF NOT EXISTS pg_trgm;  Time: 5.157 ms
CREATE INDEX idx_equipment_title_trgm ON equipment USING gin(title gin_trgm_ops);
Time: 357.922 ms
```

```
-- Префикс 'Drill%'
Bitmap Heap Scan on equipment  (cost=96.76..2040.89 rows=4010 width=32)
                                (actual time=1.201..3.281 rows=5000 loops=1)
  Recheck Cond: ((title)::text ~~ 'Drill%'::text)
  Heap Blocks: exact=1894
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=0.949..0.949 rows=5000 loops=1)
       Index Cond: ((title)::text ~~ 'Drill%'::text)
Execution Time: 3.455 ms  |  Time: 4.027 ms

-- Подстрока '%Heavy-Duty%'
Bitmap Heap Scan on equipment  (cost=180.61..2224.04 rows=11955 width=32)
                                (actual time=2.452..5.460 rows=10027 loops=1)
  Recheck Cond: ((title)::text ~~ '%Heavy-Duty%'::text)
  Heap Blocks: exact=1887
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=2.226..2.226 rows=10027 loops=1)
       Index Cond: ((title)::text ~~ '%Heavy-Duty%'::text)
Execution Time: 5.801 ms  |  Time: 6.182 ms

-- Суффикс '%Pro'
Bitmap Heap Scan on equipment  (cost=67.73..2052.86 rows=7290 width=32)
                                (actual time=1.064..4.260 rows=10161 loops=1)
  Recheck Cond: ((title)::text ~~ '%Pro'::text)
  Heap Blocks: exact=1893
  ->  Bitmap Index Scan on idx_equipment_title_trgm
        (actual time=0.842..0.842 rows=10161 loops=1)
       Index Cond: ((title)::text ~~ '%Pro'::text)
Execution Time: 4.595 ms  |  Time: 4.994 ms
```

---

## Эксперимент 5. Соединение таблиц

### До индекса (idx_rentals_status_price уже есть из эксперимента 1)

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
Time: 307.039 ms
```

### Создание индекса

```
CREATE INDEX idx_rentals_status_created ON rentals(status, created_at DESC);
Time: 859.873 ms
```

### После индекса

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
Time: 267.902 ms
```

---

## Эксперимент 6. Негативный сценарий

### До индекса

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=964680 width=18)
                     (actual time=0.010..177.513 rows=960000 loops=1)
  Filter: ((status)::text = ANY ('{pending,confirmed,active,completed}'::text[]))
  Rows Removed by Filter: 240000
Planning Time: 0.210 ms
Execution Time: 208.300 ms
Time: 209.218 ms
```

### Создание индекса

```
CREATE INDEX idx_rentals_status ON rentals(status);
Time: 530.870 ms
```

### После индекса — план не изменился

```
Seq Scan on rentals  (cost=0.00..29215.00 rows=964680 width=18)
                     (actual time=0.008..179.482 rows=960000 loops=1)
  Filter: ((status)::text = ANY ('{pending,confirmed,active,completed}'::text[]))
  Rows Removed by Filter: 240000
Planning Time: 0.123 ms
Execution Time: 210.379 ms
Time: 211.308 ms
```

### Контрпример: status = 'cancelled' LIMIT 100

```
Limit  (cost=0.00..11.14 rows=100 width=18)
       (actual time=0.008..0.056 rows=100 loops=1)
  ->  Seq Scan on rentals  (cost=0.00..26215.00 rows=235320 width=18)
                            (actual time=0.007..0.048 rows=100 loops=1)
        Filter: ((status)::text = 'cancelled'::text)
        Rows Removed by Filter: 399
Planning Time: 0.074 ms
Execution Time: 0.068 ms
Time: 0.645 ms
```

---

## Раздел 7. Влияние индексов на DML

### Состояние перед экспериментом

```
  indexname
--------------
 rentals_pkey
```

### INSERT без дополнительных индексов (10 000 строк)

```
INSERT 0 10000
Time: 152.661 ms
```

### Создание 4 индексов

```
CREATE INDEX idx_rentals_status_price    Time: 2259.957 ms
CREATE INDEX idx_rentals_created_btree   Time: 217.280 ms
CREATE INDEX idx_rentals_status_created  Time: 863.436 ms
CREATE INDEX idx_rentals_status          Time: 537.745 ms
```

```
         indexname
----------------------------
 rentals_pkey
 idx_rentals_status_price
 idx_rentals_created_btree
 idx_rentals_status_created
 idx_rentals_status
```

### INSERT с 4 индексами (10 000 строк)

```
INSERT 0 10000
Time: 214.894 ms
```

### UPDATE — подготовка (количество строк с status='confirmed' AND total_price < 500)

```
 rows_to_update
----------------
          11191
Time: 95.344 ms
```

### UPDATE без индексов (все 4 дополнительных сброшены)

```
UPDATE 11191
Time: 214.698 ms
```

### Сброс данных (undo, не замеряется)

```
UPDATE 11815
Time: 150.380 ms
```

### Пересоздание 4 индексов

```
CREATE INDEX idx_rentals_status_price    Time: 1393.202 ms
CREATE INDEX idx_rentals_created_btree   Time: 319.870 ms
CREATE INDEX idx_rentals_status_created  Time: 1009.962 ms
CREATE INDEX idx_rentals_status          Time: 609.719 ms
```

### UPDATE с 4 индексами (то же условие: status='confirmed' AND total_price < 500)

```
UPDATE 11815
Time: 246.759 ms
```

> Разница в количестве строк (11191 vs 11815) — результат округления при делении на 1.05
> при сбросе: часть строк с ценой 500–525 также попала под сброс, образовав
> дополнительные строки с total_price < 500.
