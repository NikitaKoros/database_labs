-- Все пользователи и количество их аренд (включая тех, кто ничего не арендовал)
SELECT
    u.user_id,
    u.full_name,
    u.rating,
    COUNT(r.rental_id)   AS rentals_count,
    COALESCE(SUM(r.total_price), 0) AS total_spent
FROM users u
LEFT JOIN rentals r ON u.user_id = r.renter_id
GROUP BY u.user_id, u.full_name, u.rating
ORDER BY total_spent DESC;

-- Все объявления с последней датой аренды (NULL если не арендовалось)
SELECT
    e.equipment_id,
    e.title,
    u.full_name          AS owner,
    e.price_per_day,
    e.is_available,
    MAX(r.end_date)      AS last_rental_date
FROM equipment e
INNER JOIN users u       ON e.owner_id     = u.user_id
LEFT JOIN  rentals r     ON e.equipment_id = r.equipment_id
GROUP BY e.equipment_id, e.title, u.full_name, e.price_per_day, e.is_available
ORDER BY last_rental_date DESC NULLS LAST;

-- Аренды без отзыва (завершённые, но не оценённые)
SELECT
    r.rental_id,
    u.full_name              AS renter,
    e.title                  AS equipment,
    r.end_date
FROM rentals r
JOIN users u     ON r.renter_id    = u.user_id
JOIN equipment e ON r.equipment_id = e.equipment_id
LEFT JOIN reviews rv ON r.rental_id = rv.rental_id
WHERE r.status = 'completed'
  AND rv.review_id IS NULL
ORDER BY r.end_date;

-- Аренда со статусом платежа и оценкой
SELECT
    r.rental_id,
    u_renter.full_name       AS renter,
    u_owner.full_name        AS owner,
    e.title                  AS equipment,
    r.total_price,
    p.payment_method,
    p.status                 AS payment_status,
    rv.rating
FROM rentals r
JOIN users u_renter     ON r.renter_id    = u_renter.user_id
JOIN equipment e        ON r.equipment_id = e.equipment_id
JOIN users u_owner      ON e.owner_id     = u_owner.user_id
LEFT JOIN payments p    ON r.rental_id    = p.rental_id
LEFT JOIN reviews rv    ON r.rental_id    = rv.rental_id
ORDER BY r.rental_id;
