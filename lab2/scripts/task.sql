SELECT
    u.full_name AS rental_name,
    ec.name AS equipment_category_name,
    SUM(r.total_price) AS total_amount
FROM users u
JOIN rentals r ON r.renter_id = u.user_id
JOIN equipment e ON r.equipment_id = e.equipment_id
JOIN equipment_categories ec ON e.category_id = ec.category_id
GROUP BY u.full_name, ec.name
ORDER BY total_amount DESC
LIMIT 10;