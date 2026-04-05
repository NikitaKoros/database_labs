-- Вспомогательная таблица для аудита (используется в триггерах)
CREATE TABLE audit_log (
    log_id      SERIAL PRIMARY KEY,
    table_name  VARCHAR(100) NOT NULL,
    operation   VARCHAR(10)  NOT NULL,  -- INSERT / UPDATE / DELETE
    record_id   INTEGER,
    description TEXT,
    happened_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ФУНКЦИЯ 1: Вычислить стоимость аренды
--   Принимает equipment_id, start_date, end_date.
--   Возвращает итоговую цену (price_per_day * кол-во дней).
--   EXCEPTION: если оборудование не найдено или даты некорректны.
CREATE OR REPLACE FUNCTION fn_calculate_rental_price(
    p_equipment_id INTEGER,
    p_start_date   DATE,
    p_end_date     DATE
) RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_price_per_day NUMERIC(10,2);
    v_days          INTEGER;
BEGIN
    IF p_end_date < p_start_date THEN
        RAISE EXCEPTION 'Дата окончания (%) не может быть раньше даты начала (%)',
            p_end_date, p_start_date
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT price_per_day
    INTO STRICT v_price_per_day
    FROM equipment
    WHERE equipment_id = p_equipment_id;

    v_days := p_end_date - p_start_date;
    IF v_days = 0 THEN v_days := 1; END IF;

    RETURN v_price_per_day * v_days;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Оборудование с id=% не найдено', p_equipment_id
            USING ERRCODE = 'no_data_found';
END;
$$ LANGUAGE plpgsql;


-- ФУНКЦИЯ 2: Проверить, доступно ли оборудование в период
--   Возвращает TRUE если нет пересекающихся активных/подтверждённых аренд.
CREATE OR REPLACE FUNCTION fn_is_equipment_available(
    p_equipment_id INTEGER,
    p_start_date   DATE,
    p_end_date     DATE,
    p_exclude_rental_id INTEGER DEFAULT NULL  -- при UPDATE пропустить текущую аренду
) RETURNS BOOLEAN AS $$
DECLARE
    v_conflict INTEGER;
    v_is_available BOOLEAN;
BEGIN
    -- Проверяем флаг is_available
    SELECT is_available INTO v_is_available
    FROM equipment WHERE equipment_id = p_equipment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Оборудование с id=% не найдено', p_equipment_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT v_is_available THEN
        RETURN FALSE;
    END IF;

    -- Проверяем пересечение дат с существующими арендами
    SELECT COUNT(*) INTO v_conflict
    FROM rentals
    WHERE equipment_id = p_equipment_id
      AND status IN ('confirmed', 'active', 'pending')
      AND (p_exclude_rental_id IS NULL OR rental_id <> p_exclude_rental_id)
      AND start_date < p_end_date
      AND end_date   > p_start_date;

    RETURN v_conflict = 0;
END;
$$ LANGUAGE plpgsql;


-- ПРОЦЕДУРА 1: Создать аренду с полной проверкой бизнес-логики
--   - Проверяет доступность оборудования
--   - Вычисляет итоговую цену через fn_calculate_rental_price
--   - Создаёт запись в rentals
--   - Возвращает rental_id через OUT-параметр
CREATE OR REPLACE PROCEDURE sp_create_rental(
    p_equipment_id INTEGER,
    p_renter_id    INTEGER,
    p_start_date   DATE,
    p_end_date     DATE,
    INOUT p_rental_id INTEGER DEFAULT NULL
) AS $$
DECLARE
    v_total_price NUMERIC(10,2);
    v_owner_id    INTEGER;
BEGIN
    -- Владелец не может арендовать своё же оборудование
    SELECT owner_id INTO v_owner_id FROM equipment WHERE equipment_id = p_equipment_id;
    IF v_owner_id = p_renter_id THEN
        RAISE EXCEPTION 'Пользователь не может арендовать собственное оборудование'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Проверка доступности
    IF NOT fn_is_equipment_available(p_equipment_id, p_start_date, p_end_date) THEN
        RAISE EXCEPTION 'Оборудование id=% недоступно в период % – %',
            p_equipment_id, p_start_date, p_end_date
            USING ERRCODE = 'check_violation';
    END IF;

    -- Вычисление стоимости
    v_total_price := fn_calculate_rental_price(p_equipment_id, p_start_date, p_end_date);

    INSERT INTO rentals (equipment_id, renter_id, start_date, end_date, total_price, status)
    VALUES (p_equipment_id, p_renter_id, p_start_date, p_end_date, v_total_price, 'pending')
    RETURNING rental_id INTO p_rental_id;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Пользователь id=% или оборудование id=% не существует',
            p_renter_id, p_equipment_id;
    WHEN check_violation THEN
        RAISE;  -- пробрасываем бизнес-исключения как есть
END;
$$ LANGUAGE plpgsql;


-- ПРОЦЕДУРА 2: Завершить аренду и обновить рейтинг пользователя
--   - Переводит статус аренды в 'completed'
--   - Опционально сохраняет отзыв
--   - Пересчитывает рейтинг владельца оборудования
CREATE OR REPLACE PROCEDURE sp_complete_rental(
    p_rental_id  INTEGER,
    p_rating     SMALLINT DEFAULT NULL,
    p_comment    TEXT     DEFAULT NULL
) AS $$
DECLARE
    v_status     VARCHAR(20);
    v_owner_id   INTEGER;
    v_new_rating NUMERIC(3,2);
BEGIN
    SELECT r.status, e.owner_id
    INTO STRICT v_status, v_owner_id
    FROM rentals r
    JOIN equipment e ON r.equipment_id = e.equipment_id
    WHERE r.rental_id = p_rental_id;

    IF v_status NOT IN ('active', 'confirmed') THEN
        RAISE EXCEPTION 'Нельзя завершить аренду со статусом "%". Ожидается active или confirmed',
            v_status
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE rentals SET status = 'completed' WHERE rental_id = p_rental_id;

    -- Сохранить отзыв если передан рейтинг
    IF p_rating IS NOT NULL THEN
        IF p_rating NOT BETWEEN 1 AND 5 THEN
            RAISE EXCEPTION 'Рейтинг должен быть от 1 до 5, получено: %', p_rating
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        INSERT INTO reviews (rental_id, rating, comment)
        VALUES (p_rental_id, p_rating, p_comment);
    END IF;

    -- Пересчитать рейтинг владельца
    SELECT ROUND(AVG(rv.rating)::NUMERIC, 2) INTO v_new_rating
    FROM reviews rv
    JOIN rentals r  ON rv.rental_id  = r.rental_id
    JOIN equipment e ON r.equipment_id = e.equipment_id
    WHERE e.owner_id = v_owner_id;

    IF v_new_rating IS NOT NULL THEN
        UPDATE users SET rating = v_new_rating WHERE user_id = v_owner_id;
    END IF;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Аренда с id=% не найдена', p_rental_id;
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Отзыв для аренды id=% уже существует', p_rental_id;
END;
$$ LANGUAGE plpgsql;


-- ПРОЦЕДУРА 3: Отменить аренду и вернуть платёж
--   - Переводит статус аренды в 'cancelled'
--   - Переводит связанный платёж в 'refunded' (если был paid)
CREATE OR REPLACE PROCEDURE sp_cancel_rental(
    p_rental_id INTEGER
) AS $$
DECLARE
    v_status VARCHAR(20);
BEGIN
    SELECT status INTO STRICT v_status
    FROM rentals WHERE rental_id = p_rental_id;

    IF v_status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Нельзя отменить аренду со статусом "%"', v_status
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE rentals SET status = 'cancelled' WHERE rental_id = p_rental_id;

    -- Вернуть деньги если платёж уже прошёл
    UPDATE payments
    SET status = 'refunded'
    WHERE rental_id = p_rental_id AND status = 'paid';

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Аренда с id=% не найдена', p_rental_id;
END;
$$ LANGUAGE plpgsql;
