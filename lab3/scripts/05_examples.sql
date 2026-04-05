-- 1. Вычисление стоимости аренды через функцию
SELECT fn_calculate_rental_price(1, '2026-05-01', '2026-05-05') AS estimated_price;

-- Ошибка: некорректные даты
DO $$
BEGIN
    PERFORM fn_calculate_rental_price(1, '2026-05-10', '2026-05-01');
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Обработана ошибка: %', SQLERRM;
END;
$$;

-- Ошибка: оборудование не существует
DO $$
BEGIN
    PERFORM fn_calculate_rental_price(9999, '2026-05-01', '2026-05-05');
EXCEPTION
    WHEN no_data_found THEN
        RAISE NOTICE 'Обработана ошибка: %', SQLERRM;
END;
$$;


-- 2. Проверка доступности оборудования
SELECT fn_is_equipment_available(1, '2026-05-01', '2026-05-05') AS is_available;

SELECT fn_is_equipment_available(7, '2026-03-10', '2026-03-12') AS is_available;

-- 3. Создание аренды через процедуру (успешный сценарий)
DO $$
DECLARE
    v_rental_id INTEGER;
BEGIN
    CALL sp_create_rental(
        p_equipment_id => 1,
        p_renter_id    => 5,
        p_start_date   => '2026-05-01',
        p_end_date     => '2026-05-04',
        p_rental_id    => v_rental_id
    );
    RAISE NOTICE 'Аренда создана, rental_id=%', v_rental_id;
END;
$$;

-- 4. Попытка арендовать своё оборудование — триггер блокирует
DO $$
BEGIN
    -- user_id=1 является владельцем equipment_id=1
    CALL sp_create_rental(1, 1, '2026-06-01', '2026-06-03');
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'Бизнес-правило нарушено: %', SQLERRM;
END;
$$;

-- 5. Попытка создать аренду на занятый период — триггер блокирует
DO $$
BEGIN
    -- rental_id=10 активна: equipment_id=7, 2026-03-10 – 2026-03-12
    INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price)
    VALUES (7, 3, '2026-03-11', '2026-03-13', 600.00);
EXCEPTION
    WHEN exclusion_violation THEN
        RAISE NOTICE 'Конфликт дат перехвачен: %', SQLERRM;
END;
$$;

-- 6. Завершение аренды с отзывом -> рейтинг владельца пересчитается
-- Сначала переведём аренду в active, чтобы можно было завершить
UPDATE rentals SET status = 'active' WHERE rental_id = 9;

DO $$
BEGIN
    CALL sp_complete_rental(
        p_rental_id => 9,
        p_rating    => 5,
        p_comment   => 'Камера в идеальном состоянии!'
    );
    RAISE NOTICE 'Аренда 9 завершена, рейтинг владельца обновлён';
END;
$$;

-- Проверяем что рейтинг владельца камеры (user_id=3) обновился
SELECT user_id, full_name, rating FROM users WHERE user_id = 3;

-- 7. Попытка добавить второй отзыв к той же аренде
DO $$
BEGIN
    CALL sp_complete_rental(9, 3, 'Второй отзыв — не должен пройти');
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Статус аренды: %', SQLERRM;
    WHEN unique_violation THEN
        RAISE NOTICE 'Дублирующий отзыв заблокирован: %', SQLERRM;
END;
$$;

-- 8. Отмена аренды -> платёж помечается как refunded
DO $$
BEGIN
    CALL sp_cancel_rental(10);
    RAISE NOTICE 'Аренда 10 отменена';
END;
$$;

SELECT rental_id, status FROM rentals WHERE rental_id = 10;
SELECT payment_id, status FROM payments WHERE rental_id = 10;

-- 9. Попытка изменить сумму оплаченного платежа — триггер блокирует
DO $$
BEGIN
    UPDATE payments SET amount = 9999.00 WHERE payment_id = 1;
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Триггер аудита заблокировал изменение: %', SQLERRM;
END;
$$;

-- 10. Просмотр лога аудита
SELECT * FROM audit_log ORDER BY happened_at;
