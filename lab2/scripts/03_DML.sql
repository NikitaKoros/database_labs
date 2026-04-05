-- 1. Добавление нового пользователя
INSERT INTO users (email, full_name, phone, rating)
VALUES ('sergey.volkov@gmail.com', 'Сергей Волков', '+79009998877', 4.00);

-- 2. Добавление нового объявления от существующего владельца
INSERT INTO equipment (owner_id, category_id, title, description, price_per_day, location)
VALUES (
    (SELECT user_id FROM users WHERE email = 'ivan.petrov@mail.ru'),
    1,
    'Угловая шлифмашина Makita GA5030',
    'Болгарка 125 мм, 720 Вт',
    250.00,
    'Москва'
);

-- 3. Создание новой аренды для нового пользователя
INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price, status)
VALUES (
    (SELECT equipment_id FROM equipment WHERE title = 'Угловая шлифмашина Makita GA5030'),
    (SELECT user_id FROM users WHERE email = 'sergey.volkov@gmail.com'),
    '2026-04-05',
    '2026-04-07',
    500.00,
    'confirmed'
);

-- 4. Обновление: снять с доступности оборудование, которое сейчас в активной аренде
UPDATE equipment
SET is_available = FALSE
WHERE equipment_id IN (
    SELECT equipment_id FROM rentals WHERE status = 'active'
);

-- 5. Обновление: пересчитать итоговую цену аренды если изменилась цена за день
--    (имитация: Велосипед Trek подорожал до 700 руб/день — пересчитываем незакрытые аренды)
UPDATE rentals
SET total_price = (
    SELECT e.price_per_day FROM equipment e WHERE e.equipment_id = rentals.equipment_id
) * (end_date - start_date)
WHERE equipment_id = (SELECT equipment_id FROM equipment WHERE title = 'Велосипед Trek Marlin 7')
  AND status IN ('pending', 'confirmed', 'active');

-- 6. Обновление рейтинга пользователя на основе средней оценки его оборудования
UPDATE users u
SET rating = (
    SELECT ROUND(AVG(rv.rating)::NUMERIC, 2)
    FROM reviews rv
    JOIN rentals r  ON rv.rental_id  = r.rental_id
    JOIN equipment e ON r.equipment_id = e.equipment_id
    WHERE e.owner_id = u.user_id
)
WHERE EXISTS ( -- нужно чтобы не было SET rating = NULL если не найдутся записи
    SELECT 1
    FROM reviews rv
    JOIN rentals r  ON rv.rental_id  = r.rental_id
    JOIN equipment e ON r.equipment_id = e.equipment_id
    WHERE e.owner_id = u.user_id
);

-- 7. Удаление: убрать отменённые аренды старше 30 дней
DELETE FROM rentals
WHERE status = 'cancelled'
  AND created_at < NOW() - INTERVAL '30 days';

-- 8. Удаление: снять объявление, если владелец пожелал его убрать
--    (мягкое удаление через флаг is_available вместо DELETE, чтобы не ломать историю аренд)
UPDATE equipment
SET is_available = FALSE
WHERE title = 'Самокат Xiaomi Mi Pro 2';
