
-- Топ арендаторов по обороту
-- Для каждого пользователя: сколько аренд, суммарные траты, средний рейтинг отзывов
CREATE VIEW v_top_renters AS
SELECT
    u.user_id,
    u.full_name,
    u.email,
    u.rating                             AS user_rating,
    COUNT(r.rental_id)                   AS total_rentals,
    COALESCE(SUM(r.total_price), 0)      AS total_spent,
    ROUND(COALESCE(AVG(rv.rating), 0), 2) AS avg_review_given,
    MAX(r.end_date)                       AS last_rental_date
FROM users u
LEFT JOIN rentals r  ON u.user_id    = r.renter_id AND r.status = 'completed'
LEFT JOIN reviews rv ON r.rental_id  = rv.rental_id
GROUP BY u.user_id, u.full_name, u.email, u.rating
ORDER BY total_spent DESC;

-- Сводка по категориям оборудования
-- Количество объявлений, среднее количество аренд, средняя выручка и рейтинг
CREATE VIEW v_category_stats AS
SELECT
    ec.category_id,
    ec.name                              AS category,
    COUNT(DISTINCT e.equipment_id)       AS equipment_count, -- DISTINCT нужен из за LEFT JOIN, тк при каждом присоединении увеличивается количество записей с одинаковым equipment_id и rental_id
    COUNT(DISTINCT r.rental_id)          AS total_rentals,
    COALESCE(SUM(r.total_price), 0)      AS total_revenue,
    ROUND(COALESCE(AVG(r.total_price), 0), 2) AS avg_rental_price,
    ROUND(COALESCE(AVG(rv.rating), 0), 2)     AS avg_rating
FROM equipment_categories ec
LEFT JOIN equipment e  ON ec.category_id  = e.category_id
LEFT JOIN rentals r    ON e.equipment_id  = r.equipment_id AND r.status = 'completed'
LEFT JOIN reviews rv   ON r.rental_id     = rv.rental_id
GROUP BY ec.category_id, ec.name
ORDER BY total_revenue DESC;

-- Активность владельцев за последние 90 дней
-- Список объявлений с количеством активных/завершённых аренд, выручкой и средней оценкой
CREATE VIEW v_owner_activity AS
SELECT
    u.user_id,
    u.full_name                          AS owner,
    e.equipment_id,
    e.title,
    e.price_per_day,
    e.is_available,
    COUNT(r.rental_id)                   AS rentals_last_90d,
    COALESCE(SUM(r.total_price), 0)      AS revenue_last_90d,
    ROUND(COALESCE(AVG(rv.rating), 0), 2) AS avg_rating,
    MAX(r.end_date)                       AS last_rented
FROM users u
JOIN equipment e    ON u.user_id      = e.owner_id
LEFT JOIN rentals r ON e.equipment_id = r.equipment_id
    AND r.status IN ('completed', 'active') -- если поменяем на WHERE то для тех equipment у которых нет rental будет NULL IN ('completed', 'active') -> NULL, и LEFT JOIN превратится в INNER JOIN
    AND r.created_at >= NOW() - INTERVAL '90 days'
LEFT JOIN reviews rv ON r.rental_id   = rv.rental_id
GROUP BY u.user_id, u.full_name, e.equipment_id, e.title, e.price_per_day, e.is_available
ORDER BY revenue_last_90d DESC;
