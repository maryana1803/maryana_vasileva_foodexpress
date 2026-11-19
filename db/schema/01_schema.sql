-- FOOD-101: физическая схема FoodExpress
-- Схема студента: vasileva_food
-- PostgreSQL 15+. Расширение exts.uuid-ossp создаётся отдельно (BR-13.3).
CREATE SCHEMA IF NOT EXISTS vasileva_food;
SET search_path TO vasileva_food, exts, public;

DO $$ BEGIN CREATE TYPE restaurant_status AS ENUM ('активен','неактивен');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE product_status AS ENUM ('доступно','нет_в_наличии','архив');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE courier_status AS ENUM ('свободен','занят','на_доставке','уволен');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE order_status AS ENUM ('создан','готовится','в_доставке','доставлен','отменён');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE order_pay_status AS ENUM ('ожидает','оплачен','ошибка');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE payment_status AS ENUM ('успех','ошибка','в_обработке');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE payment_type AS ENUM ('карта','наличные','безнал');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE review_entity_type AS ENUM ('блюдо','ресторан','заказ');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(120) NOT NULL CHECK (length(trim(street)) BETWEEN 1 AND 120),
    house_number varchar(20) NOT NULL CHECK (length(trim(house_number)) BETWEEN 1 AND 20),
    apartment_office varchar(20) CHECK (apartment_office IS NULL OR length(trim(apartment_office)) BETWEEN 1 AND 20),
    UNIQUE (street, house_number, apartment_office)
);

CREATE TABLE IF NOT EXISTS client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(50) NOT NULL UNIQUE CHECK (length(trim(login)) BETWEEN 1 AND 50),
    password varchar(32) NOT NULL CHECK (password ~ '^[0-9a-f]{32}$'),
    phone_number varchar(20) NOT NULL UNIQUE CHECK (length(trim(phone_number)) BETWEEN 1 AND 20)
);

CREATE TABLE IF NOT EXISTS client_address (
    client_id uuid NOT NULL REFERENCES client(client_id) ON DELETE CASCADE,
    address_id uuid NOT NULL REFERENCES address(address_id) ON DELETE RESTRICT,
    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE IF NOT EXISTS restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(120) NOT NULL CHECK (length(trim(restaurant_name)) BETWEEN 1 AND 120),
    address_id uuid NOT NULL UNIQUE REFERENCES address(address_id) ON DELETE RESTRICT,
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status restaurant_status NOT NULL DEFAULT 'активен',
    CHECK (work_end > work_start)
);

CREATE TABLE IF NOT EXISTS courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    fio varchar(150) NOT NULL CHECK (length(trim(fio)) BETWEEN 1 AND 150),
    phone_number varchar(20) NOT NULL UNIQUE CHECK (length(trim(phone_number)) BETWEEN 1 AND 20),
    status courier_status NOT NULL DEFAULT 'свободен',
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1 CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    CHECK ((status = 'уволен' AND dismissal_date IS NOT NULL) OR (status <> 'уволен' AND dismissal_date IS NULL))
);

CREATE TABLE IF NOT EXISTS product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(80) NOT NULL UNIQUE CHECK (length(trim(product_category_name)) BETWEEN 1 AND 80)
);

CREATE TABLE IF NOT EXISTS product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(120) NOT NULL CHECK (length(trim(product_name)) BETWEEN 1 AND 120),
    product_category_id uuid NOT NULL REFERENCES product_category(product_category_id) ON DELETE RESTRICT,
    price numeric(12,2) NOT NULL CHECK (price >= 0),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id) ON DELETE RESTRICT,
    photo_url text,
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status product_status NOT NULL DEFAULT 'доступно',
    description text NOT NULL,
    UNIQUE (product_id, restaurant_id)
);

CREATE TABLE IF NOT EXISTS "order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES courier(courier_id) ON DELETE RESTRICT,
    client_id uuid NOT NULL,
    address_id uuid NOT NULL,
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id) ON DELETE RESTRICT,
    order_timestamp timestamp NOT NULL,
    delivery_timestamp timestamp,
    order_amount numeric(12,2) NOT NULL CHECK (order_amount >= 0),
    commission numeric(12,2) NOT NULL CHECK (commission >= 0),
    total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 1000),
    status order_status NOT NULL,
    pay_status order_pay_status NOT NULL DEFAULT 'ожидает',
    description text NOT NULL,
    FOREIGN KEY (client_id, address_id) REFERENCES client_address(client_id, address_id) ON DELETE RESTRICT,
    CHECK (commission = round(order_amount * 0.10, 2)),
    CHECK (total_amount = order_amount + commission),
    CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CHECK ((status = 'доставлен' AND delivery_timestamp IS NOT NULL) OR status <> 'доставлен')
);

CREATE TABLE IF NOT EXISTS order_structure (
    order_id uuid NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    product_id uuid NOT NULL REFERENCES product(product_id) ON DELETE RESTRICT,
    quantity numeric(10,3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE IF NOT EXISTS payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    payment_type payment_type NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    transaction_id varchar(120) NOT NULL UNIQUE CHECK (length(trim(transaction_id)) BETWEEN 1 AND 120),
    transaction_timestamp timestamp NOT NULL,
    status payment_status NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_one_success_per_order
    ON payment(order_id) WHERE status = 'успех';

CREATE TABLE IF NOT EXISTS review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL REFERENCES client(client_id) ON DELETE CASCADE,
    review_timestamp timestamp NOT NULL,
    entity_id uuid NOT NULL,
    entity_type review_entity_type NOT NULL,
    order_id uuid NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    description text NOT NULL,
    photo_url text,
    rating numeric(2,1) NOT NULL CHECK (rating BETWEEN 1 AND 5),
    UNIQUE (order_id, entity_type, entity_id)
);

CREATE TABLE IF NOT EXISTS courier_pay (
    year integer NOT NULL CHECK (year BETWEEN 2000 AND 2200),
    month integer NOT NULL CHECK (month BETWEEN 1 AND 12),
    courier_id uuid NOT NULL REFERENCES courier(courier_id) ON DELETE RESTRICT,
    amount numeric(14,2) NOT NULL CHECK (amount >= 0),
    coefficient_used numeric(2,1) NOT NULL CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);

CREATE INDEX IF NOT EXISTS ix_order_restaurant_status ON "order"(restaurant_id, status);
CREATE INDEX IF NOT EXISTS ix_order_courier_date ON "order"(courier_id, order_timestamp);
CREATE INDEX IF NOT EXISTS ix_review_entity ON review(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS ix_product_restaurant ON product(restaurant_id);
