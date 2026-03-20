CREATE TABLE users (
    user_id    SERIAL PRIMARY KEY,
    email      VARCHAR(255) UNIQUE NOT NULL,
    full_name  VARCHAR(255) NOT NULL,
    phone      VARCHAR(20),
    rating     NUMERIC(3,2) CHECK (rating >= 0 AND rating <= 5),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE equipment_categories (
    category_id SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    description TEXT
);

CREATE TABLE equipment (
    equipment_id  SERIAL PRIMARY KEY,
    owner_id      INTEGER NOT NULL REFERENCES users(user_id),
    category_id   INTEGER NOT NULL REFERENCES equipment_categories(category_id),
    title         VARCHAR(255) NOT NULL,
    description   TEXT,
    price_per_day NUMERIC(10,2) NOT NULL CHECK (price_per_day > 0),
    is_available  BOOLEAN NOT NULL DEFAULT TRUE,
    location      VARCHAR(255),
    created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE rentals (
    rental_id    SERIAL PRIMARY KEY,
    equipment_id INTEGER NOT NULL REFERENCES equipment(equipment_id),
    renter_id    INTEGER NOT NULL REFERENCES users(user_id),
    start_date   DATE NOT NULL,
    end_date     DATE NOT NULL,
    total_price  NUMERIC(10,2) NOT NULL CHECK (total_price >= 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'confirmed', 'active', 'completed', 'cancelled')),
    created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_dates CHECK (end_date >= start_date)
);

CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    rental_id      INTEGER NOT NULL REFERENCES rentals(rental_id),
    amount         NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    payment_method VARCHAR(50),
    status         VARCHAR(20) NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'paid', 'refunded')),
    paid_at        TIMESTAMP
);

CREATE TABLE reviews (
    review_id  SERIAL PRIMARY KEY,
    rental_id  INTEGER NOT NULL UNIQUE REFERENCES rentals(rental_id),
    rating     SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment    TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- список объявлений владельца
CREATE INDEX idx_equipment_owner ON equipment(owner_id);

-- поиск доступного инвентаря
CREATE INDEX idx_equipment_available ON equipment(is_available);

-- проверка пересечения дат при бронировании + история аренд конкретного инвентаря
CREATE INDEX idx_rentals_equipment ON rentals(equipment_id);

-- история аренд пользователя
CREATE INDEX idx_rentals_renter ON rentals(renter_id);
