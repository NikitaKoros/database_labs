-- 1. Суммарная выручка по категориям оборудования
SELECT
    ec.name                          AS category,
    COUNT(r.rental_id)               AS total_rentals,
    SUM(r.total_price)               AS total_revenue,
    ROUND(AVG(r.total_price), 2)     AS avg_rental_price
FROM rentals r
JOIN equipment e        ON r.equipment_id = e.equipment_id
JOIN equipment_categories ec ON e.category_id   = ec.category_id
WHERE r.status = 'completed'
GROUP BY ec.name
ORDER BY total_revenue DESC;

-- 2. Средний рейтинг и количество отзывов по категории оборудования
SELECT
    ec.name                        AS category,
    COUNT(rv.review_id)            AS review_count,
    ROUND(AVG(rv.rating), 2)       AS avg_rating,
    MIN(rv.rating)                 AS min_rating,
    MAX(rv.rating)                 AS max_rating
FROM reviews rv
JOIN rentals r         ON rv.rental_id    = r.rental_id
JOIN equipment e       ON r.equipment_id  = e.equipment_id
JOIN equipment_categories ec ON e.category_id = ec.category_id
GROUP BY ec.name
HAVING COUNT(rv.review_id) >= 1
ORDER BY avg_rating DESC;

-- 3. Топ-5 владельцев по суммарной выручке (только завершённые аренды)
SELECT
    u.full_name                      AS owner,
    COUNT(r.rental_id)               AS completed_rentals,
    SUM(r.total_price)               AS total_earned,
    ROUND(AVG(r.total_price), 2)     AS avg_per_rental
FROM rentals r
JOIN equipment e ON r.equipment_id = e.equipment_id
JOIN users u     ON e.owner_id     = u.user_id
WHERE r.status = 'completed'
GROUP BY u.user_id, u.full_name
ORDER BY total_earned DESC
LIMIT 5;

-- 4. Самый популярный способ оплаты и общая сумма по нему
SELECT
    payment_method,
    COUNT(*)                AS payment_count,
    SUM(amount)             AS total_paid
FROM payments
WHERE status = 'paid'
GROUP BY payment_method
ORDER BY payment_count DESC;

-- 5. Месячная динамика количества аренд и выручки
SELECT
    DATE_TRUNC('month', r.created_at)  AS month,
    COUNT(r.rental_id)                  AS rentals_count,
    SUM(r.total_price)                  AS total_revenue,
    ROUND(AVG(r.total_price), 2)        AS avg_price
FROM rentals r
WHERE r.status != 'cancelled'
GROUP BY DATE_TRUNC('month', r.created_at)
ORDER BY month;

-- 6. Оборудование с высоким рейтингом (avg >= 4) и более одной аренды
SELECT
    e.title,
    COUNT(r.rental_id)           AS rental_count,
    ROUND(AVG(rv.rating), 2)     AS avg_rating
FROM equipment e
JOIN rentals r  ON e.equipment_id = r.equipment_id
JOIN reviews rv ON r.rental_id    = rv.rental_id
GROUP BY e.equipment_id, e.title
HAVING COUNT(r.rental_id) > 1 AND AVG(rv.rating) >= 4
ORDER BY avg_rating DESC;
