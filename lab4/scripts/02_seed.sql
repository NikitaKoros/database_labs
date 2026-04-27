-- disable FK checks 
SET session_replication_role = replica;

-- equipment_categories (20 rows)

INSERT INTO equipment_categories (name, description)
VALUES
    ('Construction Tools',    'Power and hand tools for construction'),
    ('Gardening Equipment',   'Tools and machines for garden work'),
    ('Cleaning Machines',     'Industrial and domestic cleaning equipment'),
    ('Lifting Equipment',     'Hoists, jacks, and lifting platforms'),
    ('Measuring Instruments', 'Precision measuring and surveying tools'),
    ('Welding Equipment',     'Welders, cutters, and related accessories'),
    ('Compressors & Pumps',   'Air compressors and water pumps'),
    ('Generators',            'Portable and stationary power generators'),
    ('Lighting Equipment',    'Work lights and lighting towers'),
    ('Scaffolding',           'Modular scaffolding systems'),
    ('Concrete Equipment',    'Mixers, vibrators, and screeds'),
    ('Drilling Machines',     'Core drills and rotary hammers'),
    ('Cutting Tools',         'Angle grinders, saws, and cutters'),
    ('Heating Equipment',     'Heaters, heat guns, and dehumidifiers'),
    ('Painting Equipment',    'Sprayers and surface preparation tools'),
    ('Safety Equipment',      'Fall protection and safety gear'),
    ('Transport Equipment',   'Trolleys, carts, and hand trucks'),
    ('Earthmoving',           'Plate compactors and soil tampers'),
    ('Roofing Tools',         'Roofing nailers and heat welders'),
    ('HVAC Equipment',        'Ventilation and air conditioning tools');

-- users (10,000 rows)

INSERT INTO users (email, full_name, phone, rating, created_at)
SELECT
    'user_' || s.i || '@example.com',
    (ARRAY['Ivan','Alexei','Dmitry','Sergey','Andrei','Mikhail','Nikolai','Pavel','Viktor','Oleg'])
        [(s.i % 10) + 1]
    || ' '
    || (ARRAY['Ivanov','Petrov','Sidorov','Kozlov','Novikov','Morozov','Volkov','Sokolov','Popov','Lebedev'])
        [(floor(random() * 10) + 1)::int],
    '+7' || lpad((9000000000 + s.i)::text, 10, '0'),
    round((random() * 4 + 1)::numeric, 2),
    '2021-01-01'::timestamp + (floor(random() * 1460)::int || ' days')::interval
FROM generate_series(1, 10000) s(i);

-- ─── equipment (100,000 rows) ────────────────────────────────────────────────
-- Title format: "ToolType Modifier Brand"
-- ToolType is deterministic (i % 20), Modifier and Brand are random
-- This ensures:
--   LIKE 'Drill%'       → ~5,000 rows  (prefix search)
--   LIKE '%Heavy-Duty%' → ~10,000 rows (substring search)
--   LIKE '%Pro'         → ~10,000 rows (suffix search)

INSERT INTO equipment (owner_id, category_id, title, description, price_per_day, is_available, location, created_at)
SELECT
    (floor(random() * 10000) + 1)::int,
    (floor(random() * 20) + 1)::int,
    tool_types[(s.i % 20) + 1]
        || ' '
        || modifiers[(floor(random() * 10) + 1)::int]
        || ' '
        || brands[(floor(random() * 10) + 1)::int],
    'Professional ' || tool_types[(s.i % 20) + 1] || ' available for daily rental. Item #' || s.i,
    round((random() * 4950 + 50)::numeric, 2),
    random() > 0.3,
    cities[(floor(random() * 10) + 1)::int],
    '2021-01-01'::timestamp + (floor(random() * 1460)::int || ' days')::interval
FROM generate_series(1, 100000) s(i),
     LATERAL (SELECT
        ARRAY['Drill','Hammer','Saw','Screwdriver','Wrench',
              'Ladder','Generator','Compressor','Welder','Grinder',
              'Sander','Nailer','Level','Cutter','Blower',
              'Mixer','Pump','Heater','Sprayer','Jack'] AS tool_types,
        ARRAY['Heavy-Duty','Industrial','Portable','Electric','Manual',
              'Cordless','Pneumatic','Hydraulic','Thermal','Digital'] AS modifiers,
        ARRAY['Pro','Max','Elite','Master','Expert',
              'Premium','Ultra','Basic','Advanced','Classic'] AS brands,
        ARRAY['Moscow','Saint Petersburg','Novosibirsk','Yekaterinburg','Kazan',
              'Nizhny Novgorod','Chelyabinsk','Samara','Omsk','Rostov-on-Don'] AS cities
     ) const;

-- ─── rentals (1,200,000 rows) ─────────────────────────────────────────────────
-- created_at is sequential (26 ms step) so BRIN index will be effective
-- start_date is random across 3 years

INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price, status, created_at)
SELECT
    (floor(random() * 100000) + 1)::int,
    (floor(random() * 10000) + 1)::int,
    sd,
    sd + (floor(random() * 29) + 1)::int,
    round((random() * 9950 + 50)::numeric, 2),
    statuses[(s.i % 5) + 1],
    '2022-01-01'::timestamp + (s.i * interval '79 seconds')
FROM generate_series(1, 1200000) s(i),
     LATERAL (SELECT ('2022-01-01'::date + (floor(random() * 1095))::int) AS sd) d,
     LATERAL (SELECT ARRAY['pending','confirmed','active','completed','cancelled'] AS statuses) t;

-- ─── payments (~840,000 rows, 70% of rentals) ────────────────────────────────

INSERT INTO payments (rental_id, amount, payment_method, status, paid_at)
SELECT
    r.rental_id,
    r.total_price,
    (ARRAY['card','cash','online'])[(r.rental_id % 3) + 1],
    CASE r.status
        WHEN 'completed' THEN 'paid'
        WHEN 'cancelled' THEN (ARRAY['refunded','paid'])[(r.rental_id % 2) + 1]
        ELSE 'pending'
    END,
    CASE WHEN r.status IN ('completed','cancelled')
         THEN r.created_at + interval '2 hours'
         ELSE NULL
    END
FROM rentals r
WHERE r.rental_id % 10 < 7;

-- ─── reviews (~144,000 rows, 60% of completed rentals) ───────────────────────

INSERT INTO reviews (rental_id, rating, comment, created_at)
SELECT
    r.rental_id,
    ((r.rental_id % 5) + 1)::smallint,
    (ARRAY[
        'Great equipment, worked perfectly.',
        'Good condition, will rent again.',
        'Acceptable quality for the price.',
        'Had some issues but overall fine.',
        'Excellent, highly recommend!'
    ])[(r.rental_id % 5) + 1],
    r.created_at + interval '14 days'
FROM rentals r
WHERE r.status = 'completed'
  AND r.rental_id % 10 < 6;

-- Restore FK checks
SET session_replication_role = DEFAULT;

-- Update statistics for the query planner
ANALYZE;
