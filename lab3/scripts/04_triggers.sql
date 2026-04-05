-- ТРИГГЕР 1: Проверка пересечения дат при INSERT/UPDATE аренды
--   Блокирует создание аренды если даты пересекаются с существующей.
--   Дополнительно запрещает арендовать своё оборудование.
CREATE OR REPLACE FUNCTION trg_fn_check_rental_overlap()
RETURNS TRIGGER AS $$
DECLARE
    v_conflict_count INTEGER;
    v_owner_id       INTEGER;
BEGIN
    -- Запрет аренды собственного оборудования
    SELECT owner_id INTO v_owner_id
    FROM equipment WHERE equipment_id = NEW.equipment_id;

    IF v_owner_id = NEW.renter_id THEN
        RAISE EXCEPTION 'Владелец не может арендовать собственное оборудование (equipment_id=%)',
            NEW.equipment_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Проверка пересечения дат (исключаем отменённые и завершённые)
    SELECT COUNT(*) INTO v_conflict_count
    FROM rentals
    WHERE equipment_id = NEW.equipment_id
      AND rental_id   <> COALESCE(NEW.rental_id, -1)
      AND status NOT IN ('cancelled', 'completed')
      AND start_date < NEW.end_date
      AND end_date   > NEW.start_date;

    IF v_conflict_count > 0 THEN
        RAISE EXCEPTION 'Оборудование id=% уже забронировано на период % – %',
            NEW.equipment_id, NEW.start_date, NEW.end_date
            USING ERRCODE = 'exclusion_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_rental_overlap
    BEFORE INSERT OR UPDATE ON rentals
    FOR EACH ROW EXECUTE FUNCTION trg_fn_check_rental_overlap();


-- ТРИГГЕР 2: Автоматически менять is_available при смене статуса аренды
--   active -> equipment.is_available = FALSE
--   completed / cancelled -> equipment.is_available = TRUE
--     (только если нет других активных аренд)
CREATE OR REPLACE FUNCTION trg_fn_sync_equipment_availability()
RETURNS TRIGGER AS $$
DECLARE
    v_active_count INTEGER;
BEGIN
    -- Считаем активные аренды кроме текущей
    SELECT COUNT(*) INTO v_active_count
    FROM rentals
    WHERE equipment_id = NEW.equipment_id
      AND rental_id   <> NEW.rental_id
      AND status IN ('active', 'confirmed', 'pending');

    IF NEW.status = 'active' THEN
        UPDATE equipment SET is_available = FALSE WHERE equipment_id = NEW.equipment_id;

    ELSIF NEW.status IN ('completed', 'cancelled') AND v_active_count = 0 THEN
        UPDATE equipment SET is_available = TRUE  WHERE equipment_id = NEW.equipment_id;
    END IF;

    -- Аудит изменения статуса
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO audit_log (table_name, operation, record_id, description)
        VALUES (
            'rentals',
            'UPDATE',
            NEW.rental_id,
            FORMAT('Статус аренды изменён: %s -> %s (equipment_id=%s)',
                OLD.status, NEW.status, NEW.equipment_id)
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_equipment_availability
    AFTER INSERT OR UPDATE ON rentals
    FOR EACH ROW EXECUTE FUNCTION trg_fn_sync_equipment_availability();


-- ТРИГГЕР 3: Аудит платежей
--   Логирует каждый новый платёж и переход в статус 'refunded'.
--   При попытке изменить сумму уже оплаченного платежа — блокирует.
CREATE OR REPLACE FUNCTION trg_fn_audit_payment()
RETURNS TRIGGER AS $$
BEGIN
    -- Запрет изменения суммы после оплаты
    IF TG_OP = 'UPDATE'
       AND OLD.status = 'paid'
       AND OLD.amount IS DISTINCT FROM NEW.amount THEN
        RAISE EXCEPTION 'Нельзя изменить сумму платежа id=% со статусом "paid"',
            OLD.payment_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Аудит
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, operation, record_id, description)
        VALUES (
            'payments',
            'INSERT',
            NEW.payment_id,
            FORMAT('Новый платёж: rental_id=%s, сумма=%s, метод=%s',
                NEW.rental_id, NEW.amount, NEW.payment_method)
        );
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO audit_log (table_name, operation, record_id, description)
        VALUES (
            'payments',
            'UPDATE',
            NEW.payment_id,
            FORMAT('Статус платежа изменён: %s -> %s (rental_id=%s)',
                OLD.status, NEW.status, NEW.rental_id)
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_payment
    AFTER INSERT OR UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_payment();
