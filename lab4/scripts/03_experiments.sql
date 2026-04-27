\timing on
\pset pager off

DROP INDEX IF EXISTS idx_rentals_status_price;
DROP INDEX IF EXISTS idx_equipment_avail_price;
DROP INDEX IF EXISTS idx_rentals_created_btree;
DROP INDEX IF EXISTS idx_rentals_created_brin;
DROP INDEX IF EXISTS idx_equipment_title_pattern;
DROP INDEX IF EXISTS idx_equipment_title_trgm;
DROP INDEX IF EXISTS idx_rentals_status_created;
DROP INDEX IF EXISTS idx_rentals_status;

SELECT indexname, tablename FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- ===================================================================================
-- EXPERIMENT 1: Complex filter
-- Query: status = exact match + total_price range + start_date range

EXPLAIN ANALYZE
SELECT rental_id, equipment_id, renter_id, start_date, total_price
FROM rentals
WHERE status = 'confirmed'
  AND total_price BETWEEN 500 AND 3000
  AND start_date >= '2024-01-01';

-- create composite index
-- Hypothesis: (status, total_price) covers the two most selective conditions
CREATE INDEX idx_rentals_status_price ON rentals(status, total_price);

EXPLAIN ANALYZE
SELECT rental_id, equipment_id, renter_id, start_date, total_price
FROM rentals
WHERE status = 'confirmed'
  AND total_price BETWEEN 500 AND 3000
  AND start_date >= '2024-01-01';


-- ===================================================================================
-- EXPERIMENT 2: Sort with limit
-- Query: filter by boolean + ORDER BY numeric DESC + LIMIT

DROP INDEX IF EXISTS idx_equipment_avail_price;

EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day, location
FROM equipment
WHERE is_available = TRUE
ORDER BY price_per_day DESC
LIMIT 10;

-- Step 2: composite index covering filter + sort direction
CREATE INDEX idx_equipment_avail_price ON equipment(is_available, price_per_day DESC);

EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day, location
FROM equipment
WHERE is_available = TRUE
ORDER BY price_per_day DESC
LIMIT 10;


-- ===================================================================================
-- EXPERIMENT 3: Alternative indexing — B-tree vs BRIN on created_at
-- created_at was inserted sequentially, which makes BRIN viable

DROP INDEX IF EXISTS idx_rentals_created_btree;
DROP INDEX IF EXISTS idx_rentals_created_brin;

EXPLAIN ANALYZE
SELECT rental_id, renter_id, start_date, total_price
FROM rentals
WHERE created_at BETWEEN '2024-01-01' AND '2024-06-30';

-- Step 2a: B-tree index
CREATE INDEX idx_rentals_created_btree ON rentals USING btree(created_at);

EXPLAIN ANALYZE
SELECT rental_id, renter_id, start_date, total_price
FROM rentals
WHERE created_at BETWEEN '2024-01-01' AND '2024-06-30';

-- Check B-tree index size
SELECT pg_size_pretty(pg_relation_size('idx_rentals_created_btree')) AS btree_size;

DROP INDEX idx_rentals_created_btree;

-- Step 2b: BRIN index (128 pages per range summary)
CREATE INDEX idx_rentals_created_brin ON rentals USING brin(created_at) WITH (pages_per_range = 128);

EXPLAIN ANALYZE
SELECT rental_id, renter_id, start_date, total_price
FROM rentals
WHERE created_at BETWEEN '2024-01-01' AND '2024-06-30';

-- Check BRIN index size
SELECT pg_size_pretty(pg_relation_size('idx_rentals_created_brin')) AS brin_size;

DROP INDEX idx_rentals_created_brin;


-- ===================================================================================
-- EXPERIMENT 4: Text search — prefix, substring, suffix

DROP INDEX IF EXISTS idx_equipment_title_pattern;
DROP INDEX IF EXISTS idx_equipment_title_trgm;

-- Step 1: all three patterns without index

-- 1a. Prefix
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE 'Drill%';

-- 1b. Substring
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Heavy-Duty%';

-- 1c. Suffix
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Pro';

-- Step 2a: B-tree with text_pattern_ops (handles prefix only)
CREATE INDEX idx_equipment_title_pattern ON equipment(title text_pattern_ops);

-- Prefix — should use index
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE 'Drill%';

-- Substring — still seq scan
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Heavy-Duty%';

-- Suffix — still seq scan
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Pro';

DROP INDEX idx_equipment_title_pattern;

-- Step 2b: GIN trigram index (handles all LIKE patterns)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_equipment_title_trgm ON equipment USING gin(title gin_trgm_ops);

-- Prefix
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE 'Drill%';

-- Substring
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Heavy-Duty%';

-- Suffix
EXPLAIN ANALYZE
SELECT equipment_id, title, price_per_day FROM equipment WHERE title LIKE '%Pro';


-- ===================================================================================
-- EXPERIMENT 5: JOIN — rentals + users + equipment + payments

DROP INDEX IF EXISTS idx_rentals_status_created;

-- Step 1: without composite index on rentals
EXPLAIN ANALYZE
SELECT
    u.full_name,
    u.email,
    e.title,
    r.start_date,
    r.end_date,
    r.total_price,
    p.payment_method
FROM rentals r
JOIN users     u ON u.user_id      = r.renter_id
JOIN equipment e ON e.equipment_id = r.equipment_id
JOIN payments  p ON p.rental_id    = r.rental_id
WHERE r.status = 'completed'
  AND r.created_at >= '2024-01-01'
ORDER BY r.created_at DESC
LIMIT 100;

-- Step 2: composite index for the WHERE + ORDER BY
CREATE INDEX idx_rentals_status_created ON rentals(status, created_at DESC);

-- Step 3: with index
EXPLAIN ANALYZE
SELECT
    u.full_name,
    u.email,
    e.title,
    r.start_date,
    r.end_date,
    r.total_price,
    p.payment_method
FROM rentals r
JOIN users     u ON u.user_id      = r.renter_id
JOIN equipment e ON e.equipment_id = r.equipment_id
JOIN payments  p ON p.rental_id    = r.rental_id
WHERE r.status = 'completed'
  AND r.created_at >= '2024-01-01'
ORDER BY r.created_at DESC
LIMIT 100;


-- ===================================================================================
-- EXPERIMENT 6: Negative scenario — index ignored for low-selectivity query

DROP INDEX IF EXISTS idx_rentals_status;
 — baseline
EXPLAIN ANALYZE
SELECT rental_id, equipment_id, start_date, total_price
FROM rentals
WHERE status IN ('pending', 'confirmed', 'active', 'completed');

-- Step 2: create index on status
CREATE INDEX idx_rentals_status ON rentals(status);

-- Step 3: same query with index — planner still prefers seq scan (80% of rows)
EXPLAIN ANALYZE
SELECT rental_id, equipment_id, start_date, total_price
FROM rentals
WHERE status IN ('pending', 'confirmed', 'active', 'completed');

-- Check: even for a selective query (status = 'cancelled', ~20% of rows) with LIMIT 100
-- planner still prefers Seq Scan with early exit — index is NOT used
EXPLAIN ANALYZE
SELECT rental_id, equipment_id, start_date, total_price
FROM rentals
WHERE status = 'cancelled'
LIMIT 100;


-- ===================================================================================
-- SECTION 7: DML performance — INSERT/UPDATE with and without indexes

-- ── 7a. INSERT without extra indexes ─────────────────────────────────────────
-- Drop all non-PK indexes first
DROP INDEX IF EXISTS idx_rentals_status_price;
DROP INDEX IF EXISTS idx_rentals_created_brin;
DROP INDEX IF EXISTS idx_rentals_status_created;
DROP INDEX IF EXISTS idx_rentals_status;

-- Verify only PKs and UQ constraints remain
SELECT indexname FROM pg_indexes WHERE tablename = 'rentals' AND schemaname = 'public';

INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price, status, created_at)
SELECT
    (floor(random() * 100000) + 1)::int,
    (floor(random() * 10000) + 1)::int,
    sd,
    sd + (floor(random() * 14) + 1)::int,
    round((random() * 4950 + 50)::numeric, 2),
    (ARRAY['pending','confirmed','active','completed','cancelled'])[(s.i % 5) + 1],
    NOW()
FROM generate_series(1, 10000) s(i),
     LATERAL (SELECT ('2025-01-01'::date + (floor(random() * 365))::int) AS sd) d;

-- ── 7b. INSERT with extra indexes ────────────────────────────────────────────
CREATE INDEX idx_rentals_status_price   ON rentals(status, total_price);
CREATE INDEX idx_rentals_created_btree  ON rentals USING btree(created_at);
CREATE INDEX idx_rentals_status_created ON rentals(status, created_at DESC);
CREATE INDEX idx_rentals_status         ON rentals(status);

-- Verify indexes
SELECT indexname FROM pg_indexes WHERE tablename = 'rentals' AND schemaname = 'public';

INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price, status, created_at)
SELECT
    (floor(random() * 100000) + 1)::int,
    (floor(random() * 10000) + 1)::int,
    sd,
    sd + (floor(random() * 14) + 1)::int,
    round((random() * 4950 + 50)::numeric, 2),
    (ARRAY['pending','confirmed','active','completed','cancelled'])[(s.i % 5) + 1],
    NOW()
FROM generate_series(1, 10000) s(i),
     LATERAL (SELECT ('2025-01-01'::date + (floor(random() * 365))::int) AS sd) d;

-- ── 7c. UPDATE without vs with indexes ───────────────────────────────────────
-- Both runs use identical condition: status = 'confirmed' AND total_price < 500
-- Between runs we undo the first UPDATE so the second operates on the same rows.

-- Drop extra indexes
DROP INDEX IF EXISTS idx_rentals_status_price;
DROP INDEX IF EXISTS idx_rentals_created_btree;
DROP INDEX IF EXISTS idx_rentals_status_created;
DROP INDEX IF EXISTS idx_rentals_status;

-- How many rows will be affected
SELECT count(*) AS rows_to_update FROM rentals WHERE status = 'confirmed' AND total_price < 500;

-- UPDATE without indexes
UPDATE rentals
SET total_price = total_price * 1.05
WHERE status = 'confirmed' AND total_price < 500;

-- Reset: undo the multiplication so the second run sees the same rows
-- (not timed — this is just data preparation)
UPDATE rentals
SET total_price = ROUND(total_price / 1.05, 2)
WHERE status = 'confirmed' AND total_price < 525.01;

-- Recreate indexes
CREATE INDEX idx_rentals_status_price   ON rentals(status, total_price);
CREATE INDEX idx_rentals_created_btree  ON rentals USING btree(created_at);
CREATE INDEX idx_rentals_status_created ON rentals(status, created_at DESC);
CREATE INDEX idx_rentals_status         ON rentals(status);

-- UPDATE with indexes (same condition as above)
UPDATE rentals
SET total_price = total_price * 1.05
WHERE status = 'confirmed' AND total_price < 500;
