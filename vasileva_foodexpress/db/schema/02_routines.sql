-- FOOD-102/103/104/105/106/107/108
SET search_path TO vasileva_food, exts, public;

-- Проверка позиций заказа.
CREATE OR REPLACE FUNCTION validate_order_structure() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_order_rest uuid; v_product_rest uuid;
BEGIN
  SELECT restaurant_id INTO v_order_rest FROM vasileva_food."order" WHERE order_id = NEW.order_id;
  SELECT restaurant_id INTO v_product_rest FROM vasileva_food.product WHERE product_id = NEW.product_id;
  IF v_order_rest IS NULL OR v_product_rest IS NULL OR v_order_rest <> v_product_rest THEN
    RAISE EXCEPTION 'Блюдо должно принадлежать ресторану заказа';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_validate_order_structure ON order_structure;
CREATE TRIGGER trg_validate_order_structure BEFORE INSERT OR UPDATE ON order_structure
FOR EACH ROW EXECUTE FUNCTION validate_order_structure();

CREATE OR REPLACE FUNCTION validate_review() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_client uuid; v_rest uuid; v_found boolean;
BEGIN
  SELECT client_id, restaurant_id INTO v_client, v_rest
  FROM "order" WHERE order_id = NEW.order_id;
  IF v_client IS NULL OR v_client <> NEW.client_id THEN
    RAISE EXCEPTION 'Отзыв может оставить только клиент данного заказа';
  END IF;
  IF NEW.entity_type = 'заказ' THEN
    IF NEW.entity_id <> NEW.order_id THEN RAISE EXCEPTION 'Для отзыва на заказ entity_id должен совпадать с order_id'; END IF;
  ELSIF NEW.entity_type = 'ресторан' THEN
    IF NEW.entity_id <> v_rest THEN RAISE EXCEPTION 'Отзыв должен относиться к ресторану из заказа'; END IF;
  ELSIF NEW.entity_type = 'блюдо' THEN
    SELECT EXISTS (
      SELECT 1 FROM order_structure os
      WHERE os.order_id = NEW.order_id AND os.product_id = NEW.entity_id
    ) INTO v_found;
    IF NOT v_found THEN RAISE EXCEPTION 'Клиент может оценить только блюдо из данного заказа'; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_validate_review ON review;
CREATE TRIGGER trg_validate_review BEFORE INSERT OR UPDATE ON review
FOR EACH ROW EXECUTE FUNCTION validate_review();

-- FOOD-105: пересчёт агрегированного рейтинга для затронутых сущностей.
CREATE OR REPLACE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE old_type review_entity_type; old_id uuid; new_type review_entity_type; new_id uuid;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN old_type := OLD.entity_type; old_id := OLD.entity_id; END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN new_type := NEW.entity_type; new_id := NEW.entity_id; END IF;

  IF old_type = 'блюдо' THEN
    UPDATE product SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='блюдо' AND entity_id=old_id)
    WHERE product_id=old_id;
  ELSIF old_type = 'ресторан' THEN
    UPDATE restaurant SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='ресторан' AND entity_id=old_id)
    WHERE restaurant_id=old_id;
  END IF;

  IF new_type = 'блюдо' AND (old_type IS DISTINCT FROM new_type OR old_id IS DISTINCT FROM new_id OR TG_OP='INSERT') THEN
    UPDATE product SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='блюдо' AND entity_id=new_id)
    WHERE product_id=new_id;
  ELSIF new_type = 'ресторан' AND (old_type IS DISTINCT FROM new_type OR old_id IS DISTINCT FROM new_id OR TG_OP='INSERT') THEN
    UPDATE restaurant SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='ресторан' AND entity_id=new_id)
    WHERE restaurant_id=new_id;
  ELSIF new_type = 'блюдо' AND old_type='блюдо' AND old_id=new_id THEN
    UPDATE product SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='блюдо' AND entity_id=new_id)
    WHERE product_id=new_id;
  ELSIF new_type = 'ресторан' AND old_type='ресторан' AND old_id=new_id THEN
    UPDATE restaurant SET rating = (SELECT round(avg(rating),2) FROM review WHERE entity_type='ресторан' AND entity_id=new_id)
    WHERE restaurant_id=new_id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_rating_change ON review;
CREATE TRIGGER trg_rating_change AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION rating_change();


CREATE OR REPLACE FUNCTION validate_payment_amount() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_total numeric(12,2);
BEGIN
  SELECT total_amount INTO v_total FROM "order" WHERE order_id=NEW.order_id;
  IF v_total IS NULL OR NEW.amount <> v_total THEN
    RAISE EXCEPTION 'Сумма платежа должна совпадать с total_amount заказа';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_validate_payment_amount ON payment;
CREATE TRIGGER trg_validate_payment_amount
BEFORE INSERT OR UPDATE ON payment
FOR EACH ROW EXECUTE FUNCTION validate_payment_amount();

-- Синхронизация агрегированного статуса оплаты заказа.
CREATE OR REPLACE FUNCTION sync_order_pay_status() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_order uuid; v_status order_pay_status;
BEGIN
  v_order := COALESCE(NEW.order_id, OLD.order_id);
  SELECT CASE
    WHEN bool_or(status='успех') THEN 'оплачен'::order_pay_status
    WHEN count(*) > 0 AND bool_and(status='ошибка') THEN 'ошибка'::order_pay_status
    ELSE 'ожидает'::order_pay_status END
  INTO v_status FROM payment WHERE order_id=v_order;
  UPDATE "order" SET pay_status=COALESCE(v_status,'ожидает') WHERE order_id=v_order;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_sync_order_pay_status ON payment;
CREATE TRIGGER trg_sync_order_pay_status AFTER INSERT OR UPDATE OR DELETE ON payment
FOR EACH ROW EXECUTE FUNCTION sync_order_pay_status();


-- BR-8.1: к моменту COMMIT у каждого заказа должна быть ровно одна успешная попытка.
-- Проверка отложенная, чтобы заказ и его платёж можно было создать в одной транзакции.
CREATE OR REPLACE FUNCTION assert_one_successful_payment() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_order uuid; v_count integer;
BEGIN
  v_order := COALESCE(NEW.order_id, OLD.order_id);
  IF NOT EXISTS (SELECT 1 FROM "order" WHERE order_id=v_order) THEN
    RETURN NULL;
  END IF;
  SELECT count(*) INTO v_count FROM payment
    WHERE order_id=v_order AND status='успех';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Для заказа % требуется ровно одна успешная попытка оплаты (сейчас %)',v_order,v_count;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_exactly_one_success_payment ON payment;
CREATE CONSTRAINT TRIGGER trg_exactly_one_success_payment
AFTER INSERT OR UPDATE OR DELETE ON payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION assert_one_successful_payment();
DROP TRIGGER IF EXISTS trg_order_requires_payment ON "order";
CREATE CONSTRAINT TRIGGER trg_order_requires_payment
AFTER INSERT ON "order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION assert_one_successful_payment();

-- FOOD-103: очистка тестовых данных.
CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE review, payment, order_structure, courier_pay, "order",
    product, restaurant, client_address, client, courier, product_category, address
    RESTART IDENTITY CASCADE;
END $$;

-- FOOD-102: генератор добавляет value новых комплектов данных при каждом вызове.
CREATE OR REPLACE PROCEDURE insert_test_data(p_value integer)
LANGUAGE plpgsql AS $$
DECLARE
  i integer; j integer; v_client uuid; v_courier uuid; v_cat uuid; v_rest uuid;
  v_addr uuid; v_prod uuid; v_order uuid; v_client_ids uuid[]; v_courier_ids uuid[];
  v_cat_ids uuid[]; v_rest_ids uuid[]; v_addr_ids uuid[]; v_prod_ids uuid[];
  v_order_ids uuid[]; v_order_client uuid[]; v_order_rest uuid[];
  v_price numeric(12,2); v_qty numeric(10,3); v_amount numeric(12,2);
  v_status order_status; v_delivered timestamp; v_ts timestamp;
  v_month date; v_coef numeric(2,1); v_cnt integer; v_comm numeric(14,2);
BEGIN
  IF p_value IS NULL OR p_value < 1 OR p_value > 1000 THEN
    RAISE EXCEPTION 'p_value должен быть в диапазоне 1..1000';
  END IF;

  -- Идентификаторы записей текущего вызова.
  v_cat_ids := ARRAY[]::uuid[];
  v_courier_ids := ARRAY[]::uuid[];
  v_addr_ids := ARRAY[]::uuid[];
  v_rest_ids := ARRAY[]::uuid[];
  v_prod_ids := ARRAY[]::uuid[];
  v_client_ids := ARRAY[]::uuid[];

  FOR i IN 1..p_value LOOP
    INSERT INTO product_category(product_category_name)
      VALUES ('Категория_'||md5(random()::text)||'_'||i)
      RETURNING product_category_id INTO v_cat;
    v_cat_ids := array_append(v_cat_ids,v_cat);
  END LOOP;

  FOR i IN 1..p_value LOOP
    INSERT INTO courier(fio,phone_number,status,hire_date,dismissal_date,coefficient)
    VALUES ('Курьер '||md5(random()::text), '+7'||lpad((floor(random()*10000000000))::bigint::text,10,'0'),
      'свободен', current_date-(floor(random()*180)::int), NULL, 0.1)
    RETURNING courier_id INTO v_courier;
    v_courier_ids := array_append(v_courier_ids,v_courier);
  END LOOP;

  -- Адреса ресторанов и клиентов.
  FOR i IN 1..(p_value*5) LOOP
    INSERT INTO address(street,house_number,apartment_office)
    VALUES ('Улица_'||md5(random()::text), (i::text), CASE WHEN i%3=0 THEN NULL ELSE (i::text) END)
    RETURNING address_id INTO v_addr;
    v_addr_ids := array_append(v_addr_ids,v_addr);
  END LOOP;

  FOR i IN 1..p_value LOOP
    v_addr := v_addr_ids[i];
    INSERT INTO restaurant(restaurant_name,address_id,description,work_start,work_end,company_details,status)
    VALUES ('Ресторан_'||md5(random()::text),v_addr,'Описание ресторана',time '09:00',time '23:00',
      'ИНН '||lpad(i::text,10,'0')||'; ОГРН '||lpad(i::text,13,'0'),'активен')
    RETURNING restaurant_id INTO v_rest;
    v_rest_ids := array_append(v_rest_ids,v_rest);
  END LOOP;

  -- Блюда распределяются по ресторанам и категориям.
  FOR i IN 1..(p_value*5) LOOP
    v_rest := v_rest_ids[((i-1)/5)+1];
    v_cat := v_cat_ids[((i-1)%p_value)+1];
    INSERT INTO product(product_name,product_category_id,price,restaurant_id,photo_url,status,description)
    VALUES ('Блюдо_'||md5(random()::text),v_cat,round((1000+random()*1500)::numeric,2),v_rest,
      CASE WHEN random()<0.2 THEN NULL ELSE 'https://example.test/'||md5(random()::text)||'.jpg' END,
      'доступно','Тестовое описание блюда')
    RETURNING product_id INTO v_prod;
    v_prod_ids := array_append(v_prod_ids,v_prod);
  END LOOP;

  FOR i IN 1..p_value LOOP
    INSERT INTO client(login,password,phone_number)
    VALUES ('user_'||md5(random()::text),md5(random()::text),
      '+7'||lpad((floor(random()*10000000000))::bigint::text,10,'0'))
    RETURNING client_id INTO v_client;
    v_client_ids := array_append(v_client_ids,v_client);
  END LOOP;

  -- Четыре адреса на клиента, с уникальностью пары.
  FOR i IN 1..p_value LOOP
    FOR j IN 1..4 LOOP
      v_addr := v_addr_ids[p_value + (i-1)*4 + j];
      INSERT INTO client_address(client_id,address_id) VALUES (v_client_ids[i],v_addr)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  -- Заказы и связанные записи.
  FOR i IN 1..(p_value*5) LOOP
    v_client := v_client_ids[((i-1)%p_value)+1];
    v_courier := v_courier_ids[((i-1)%p_value)+1];
    v_rest := v_rest_ids[((i-1)%p_value)+1];
    v_addr := v_addr_ids[p_value + (((i-1)%p_value)*4) + 1];
    SELECT product_id, price INTO v_prod, v_price FROM product
      WHERE restaurant_id=v_rest ORDER BY product_id DESC LIMIT 1;
    v_qty := round((1+random()*2)::numeric,3);
    v_amount := round(v_price*v_qty,2);
    v_ts := localtimestamp - (floor(random()*150)::int * interval '1 day');
    v_status := CASE WHEN random()<0.75 THEN 'доставлен'::order_status
                     WHEN random()<0.5 THEN 'в_доставке'::order_status ELSE 'готовится'::order_status END;
    v_delivered := CASE WHEN v_status='доставлен' THEN v_ts + interval '20 minutes' ELSE NULL END;
    INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_timestamp,delivery_timestamp,
      order_amount,commission,total_amount,status,pay_status,description)
    VALUES (v_courier,v_client,v_addr,v_rest,v_ts,v_delivered,v_amount,
      round(v_amount*0.10,2),round(v_amount*1.10,2),v_status,'ожидает','Тестовый заказ')
    RETURNING order_id INTO v_order;
    INSERT INTO order_structure(order_id,product_id,quantity) VALUES (v_order,v_prod,v_qty);
    INSERT INTO payment(order_id,payment_type,amount,transaction_id,transaction_timestamp,status)
    VALUES (v_order,(enum_range(NULL::payment_type))[1+floor(random()*3)::int],
      round(v_amount*1.10,2),'tx_'||md5(random()::text)||'_'||i,v_ts,
      'успех');
    INSERT INTO review(client_id,review_timestamp,entity_id,entity_type,order_id,description,rating)
    VALUES (v_client,v_ts+interval '1 hour',v_order,'заказ',v_order,'Тестовый отзыв',round((1+random()*4)::numeric,1));
  END LOOP;

  -- История выплат за последние 6 календарных месяцев; коэффициент применённый 0.1.
  FOR i IN 1..p_value LOOP
    FOR j IN 0..5 LOOP
      v_month := (date_trunc('month',current_date)::date - (j||' months')::interval)::date;
      SELECT COALESCE(sum(o.commission),0) INTO v_comm
      FROM "order" o
      WHERE o.courier_id=v_courier_ids[i] AND o.status='доставлен'
        AND date_trunc('month',o.order_timestamp)=date_trunc('month',v_month::timestamp);
      INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
      VALUES (extract(year from v_month)::int,extract(month from v_month)::int,v_courier_ids[i],
        round(v_comm*0.1,2),0.1)
      ON CONFLICT (year,month,courier_id) DO UPDATE SET amount=EXCLUDED.amount, coefficient_used=EXCLUDED.coefficient_used;
    END LOOP;
    SELECT count(*) INTO v_cnt FROM "order" o
      WHERE o.courier_id=v_courier_ids[i] AND o.status='доставлен'
      AND date_trunc('month',o.order_timestamp)=date_trunc('month',current_date::timestamp);
    v_coef := CASE WHEN v_cnt<=150 THEN 0.1 WHEN v_cnt<=250 THEN 0.2 WHEN v_cnt<=500 THEN 0.3 ELSE 0.5 END;
    UPDATE courier SET coefficient=v_coef WHERE courier_id=v_courier_ids[i] AND status<>'уволен';
  END LOOP;
END $$;

-- FOOD-104: добавление блюда.
CREATE OR REPLACE PROCEDURE add_product(
  p_restaurant_id uuid, p_product_category_id uuid, p_name varchar,
  p_price numeric, p_rating numeric, p_status product_status,
  p_description text, p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id=p_restaurant_id) THEN
    RAISE EXCEPTION 'Ресторан % не существует',p_restaurant_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM product_category WHERE product_category_id=p_product_category_id) THEN
    RAISE EXCEPTION 'Категория % не существует',p_product_category_id;
  END IF;
  INSERT INTO product(product_name,product_category_id,price,restaurant_id,photo_url,rating,status,description)
  VALUES(p_name,p_product_category_id,p_price,p_restaurant_id,p_photo_url,p_rating,p_status,p_description);
END $$;

-- FOOD-106: статистика ресторанов.
CREATE OR REPLACE FUNCTION get_statistic()
RETURNS TABLE(restaurant_name varchar, best_product_name varchar, total_amount numeric, avg_amount numeric, best_user varchar)
LANGUAGE sql STABLE AS $$
WITH order_totals AS (
  SELECT restaurant_id, sum(total_amount) AS total_amount, avg(total_amount) AS avg_amount
  FROM "order" WHERE status='доставлен' GROUP BY restaurant_id
),
product_sales AS (
  SELECT o.restaurant_id, p.product_name, sum(os.quantity) AS qty
  FROM "order" o JOIN order_structure os ON os.order_id=o.order_id
  JOIN product p ON p.product_id=os.product_id
  WHERE o.status='доставлен'
  GROUP BY o.restaurant_id,p.product_id,p.product_name
),
best_products AS (
  SELECT DISTINCT ON (restaurant_id) restaurant_id, product_name
  FROM product_sales ORDER BY restaurant_id,qty DESC,random()
),
client_sales AS (
  SELECT o.restaurant_id,c.login,count(*) AS cnt
  FROM "order" o JOIN client c ON c.client_id=o.client_id
  WHERE o.status='доставлен'
  GROUP BY o.restaurant_id,c.client_id,c.login
),
best_clients AS (
  SELECT DISTINCT ON (restaurant_id) restaurant_id,login
  FROM client_sales ORDER BY restaurant_id,cnt DESC,random()
)
SELECT r.restaurant_name,bp.product_name,COALESCE(ot.total_amount,0),COALESCE(ot.avg_amount,0),bc.login
FROM restaurant r
LEFT JOIN order_totals ot USING(restaurant_id)
LEFT JOIN best_products bp USING(restaurant_id)
LEFT JOIN best_clients bc USING(restaurant_id)
ORDER BY r.restaurant_name
$$;

-- FOOD-107: выплаты курьерам за текущий месяц.
CREATE OR REPLACE PROCEDURE courier_salary()
LANGUAGE plpgsql AS $$
DECLARE rec record; v_count integer; v_amount numeric(14,2); v_new numeric(2,1);
BEGIN
  FOR rec IN SELECT courier_id,status,coefficient FROM courier LOOP
    SELECT count(*),COALESCE(sum(commission),0) INTO v_count,v_amount
    FROM "order"
    WHERE courier_id=rec.courier_id AND status='доставлен'
      AND extract(year from order_timestamp)=extract(year from current_date)
      AND extract(month from order_timestamp)=extract(month from current_date);
    INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
    VALUES(extract(year from current_date)::int,extract(month from current_date)::int,
      rec.courier_id,round(v_amount*rec.coefficient,2),rec.coefficient)
    ON CONFLICT(year,month,courier_id) DO UPDATE
      SET amount=EXCLUDED.amount,coefficient_used=EXCLUDED.coefficient_used;
    v_new := CASE WHEN v_count<=150 THEN 0.1 WHEN v_count<=250 THEN 0.2
                  WHEN v_count<=500 THEN 0.3 ELSE 0.5 END;
    IF rec.status<>'уволен' THEN
      UPDATE courier SET coefficient=v_new WHERE courier_id=rec.courier_id;
    END IF;
  END LOOP;
END $$;

-- FOOD-108: непрерывный календарь месяцев через рекурсивный CTE.
CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE bounds AS (
  SELECT date_trunc('month',min(order_timestamp))::date AS first_month,
         date_trunc('month',max(order_timestamp))::date AS last_month
  FROM "order" WHERE status='доставлен'
),
months(month_start,last_month) AS (
  SELECT first_month,last_month FROM bounds WHERE first_month IS NOT NULL
  UNION ALL
  SELECT (month_start + interval '1 month')::date,last_month
  FROM months WHERE month_start < last_month
),
monthly_orders AS (
  SELECT date_trunc('month',order_timestamp)::date AS month_start,
         sum(order_amount)::numeric AS sum_no_commission,
         sum(total_amount)::numeric AS sum_with_commission
  FROM "order" WHERE status='доставлен' GROUP BY 1
),
monthly_pay AS (
  SELECT make_date(year,month,1) AS month_start,sum(amount)::numeric AS courier_pay
  FROM courier_pay GROUP BY 1
),
base AS (
  SELECT to_char(m.month_start,'YYYY-MM') AS year_month,m.month_start,
    COALESCE(o.sum_no_commission,0)::numeric AS sum_no_commission,
    COALESCE(o.sum_with_commission,0)::numeric AS sum_with_commission,
    (COALESCE(o.sum_with_commission,0)-COALESCE(o.sum_no_commission,0))::numeric AS commission,
    COALESCE(p.courier_pay,0)::numeric AS courier_pay
  FROM months m LEFT JOIN monthly_orders o USING(month_start)
  LEFT JOIN monthly_pay p USING(month_start)
),
lagged AS (
  SELECT *,lag(commission) OVER(ORDER BY month_start) AS prev_commission FROM base
)
SELECT year_month,sum_no_commission,sum_with_commission,commission,prev_commission,
       (commission-prev_commission)::numeric AS commission_diff,courier_pay,
       (commission-courier_pay)::numeric AS net_profit
FROM lagged;

-- Явный search_path для функций и процедур.
ALTER FUNCTION vasileva_food.validate_order_structure() SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.validate_review() SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.rating_change() SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.validate_payment_amount() SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.sync_order_pay_status() SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.assert_one_successful_payment() SET search_path TO vasileva_food, pg_catalog;
ALTER PROCEDURE vasileva_food.erase_test_data() SET search_path TO vasileva_food, pg_catalog;
ALTER PROCEDURE vasileva_food.insert_test_data(integer) SET search_path TO vasileva_food, pg_catalog;
ALTER PROCEDURE vasileva_food.add_product(uuid, uuid, varchar, numeric, numeric, vasileva_food.product_status, text, text) SET search_path TO vasileva_food, pg_catalog;
ALTER FUNCTION vasileva_food.get_statistic() SET search_path TO vasileva_food, public;
ALTER PROCEDURE vasileva_food.courier_salary() SET search_path TO vasileva_food, pg_catalog;
