# Проверка FoodExpress

SQL-запросы по задачам FOOD-101–110. Команды, изменяющие данные, запускать в отдельной тестовой базе. Для проверки прав используется роль `inspector` (FOOD-109).

## FOOD-101. Структура

```sql
SELECT table_name, table_type FROM information_schema.tables
WHERE table_schema = 'vasileva_food' ORDER BY table_name;

SELECT count(*) AS enum_count FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'vasileva_food' AND t.typtype = 'e';

SELECT count(*) AS routine_count FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'vasileva_food';

SELECT count(*) AS trigger_count FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'vasileva_food' AND NOT t.tgisinternal;
```

Ожидается: 12 таблиц, 1 представление, 8 ENUM, 11 функций/процедур, 7 пользовательских триггеров.

## FOOD-102–103. Генерация и очистка

Выполнять **только в тестовой базе**. Каждая команда должна завершиться до запуска следующей; `erase_test_data()` не запускать после вставки платежей в той же транзакции.

```sql
CALL vasileva_food.erase_test_data();
```

После завершения отдельно выполнить:

```sql
CALL vasileva_food.insert_test_data(10);

SELECT 'client' AS object_name, count(*) AS n FROM vasileva_food.client
UNION ALL SELECT 'courier', count(*) FROM vasileva_food.courier
UNION ALL SELECT 'restaurant', count(*) FROM vasileva_food.restaurant
UNION ALL SELECT 'product_category', count(*) FROM vasileva_food.product_category
UNION ALL SELECT 'product', count(*) FROM vasileva_food.product
UNION ALL SELECT 'address', count(*) FROM vasileva_food.address
UNION ALL SELECT 'client_address', count(*) FROM vasileva_food.client_address
UNION ALL SELECT 'order', count(*) FROM vasileva_food."order"
UNION ALL SELECT 'order_structure', count(*) FROM vasileva_food.order_structure
UNION ALL SELECT 'payment', count(*) FROM vasileva_food.payment
UNION ALL SELECT 'review', count(*) FROM vasileva_food.review
UNION ALL SELECT 'courier_pay', count(*) FROM vasileva_food.courier_pay
ORDER BY object_name;
```

Ожидаемые количества после одного вызова с `10`: `client`, `courier`, `restaurant`, `product_category` — по 10; `product`, `address`, `order`, `order_structure`, `payment`, `review` — по 50; `client_address` — 40; `courier_pay` — 60.

Повторный вызов `CALL vasileva_food.insert_test_data(10);` должен добавить ещё один набор без удаления предыдущего. После двух вызовов ожидается удвоение указанных количеств.

## Ограничения данных (FOOD-101, FOOD-105)

Следующие запросы должны возвращать `0`:

```sql
SELECT count(*) FROM vasileva_food."order" o
LEFT JOIN vasileva_food.client_address ca
 ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;

SELECT count(*) FROM vasileva_food.order_structure os
JOIN vasileva_food."order" o USING (order_id)
JOIN vasileva_food.product p USING (product_id)
WHERE p.restaurant_id <> o.restaurant_id;

SELECT count(*) FROM vasileva_food."order"
WHERE commission <> round(order_amount * 0.10, 2)
 OR total_amount <> order_amount + commission OR total_amount < 1000;

SELECT count(*) FROM (
 SELECT o.order_id FROM vasileva_food."order" o
 LEFT JOIN vasileva_food.payment p USING (order_id)
 GROUP BY o.order_id
 HAVING count(p.payment_id) FILTER (WHERE p.status = 'успех') <> 1
) q;
```

Пересчёт рейтинга после изменения отзывов проверяется отдельно по FOOD-105.

## FOOD-106–108. Статистика и выплаты

```sql
SELECT * FROM vasileva_food.get_statistic();
SELECT * FROM vasileva_food.how_much_money ORDER BY year_month;
```

Проверка повторного расчёта выплат (тестовая база):

```sql
BEGIN;
CALL vasileva_food.courier_salary();
CALL vasileva_food.courier_salary();
SELECT year, month, courier_id, count(*)
FROM vasileva_food.courier_pay
GROUP BY year, month, courier_id HAVING count(*) > 1;
ROLLBACK;
```

Ожидается 0 строк. Суммы выплат проверяются отдельно по формуле из BR-10.

## FOOD-109. Права inspector

`db/schema/grants.sql` выполняется администратором в проверяемой базе. Пароль роли: `NetoSQL2025`.

```sql
SELECT
 has_schema_privilege('inspector','vasileva_food','USAGE') AS schema_usage,
 has_schema_privilege('inspector','vasileva_food','CREATE') AS schema_create,
 has_schema_privilege('inspector','exts','USAGE') AS exts_usage,
 has_schema_privilege('inspector','information_schema','USAGE') AS info_usage,
 has_schema_privilege('inspector','pg_catalog','USAGE') AS catalog_usage;

SELECT c.relname,
 has_table_privilege('inspector',c.oid,'SELECT') AS can_select,
 has_table_privilege('inspector',c.oid,'INSERT') AS can_insert,
 has_table_privilege('inspector',c.oid,'UPDATE') AS can_update,
 has_table_privilege('inspector',c.oid,'DELETE') AS can_delete
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='vasileva_food' AND c.relkind IN ('r','v')
ORDER BY c.relname;

SELECT p.proname, has_function_privilege('inspector',p.oid,'EXECUTE') AS can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='vasileva_food' ORDER BY p.proname;
```

Ожидается `true` для проверяемых прав. Фактические вызовы процедур выполнять в тестовой базе, в отдельных транзакциях с `ROLLBACK`.

```sql
BEGIN;
SET LOCAL ROLE inspector;
SELECT * FROM vasileva_food.get_statistic();
SELECT * FROM vasileva_food.how_much_money LIMIT 5;
ROLLBACK;
```

```sql
BEGIN;
SET LOCAL ROLE inspector;
CALL vasileva_food.insert_test_data(1);
ROLLBACK;
```

```sql
BEGIN;
SET LOCAL ROLE inspector;
CALL vasileva_food.courier_salary();
ROLLBACK;
```

```sql
BEGIN;
SET LOCAL ROLE inspector;
CALL vasileva_food.erase_test_data();
ROLLBACK;
```

Проверка `add_product()` (тестовая база):

```sql
BEGIN;
SET LOCAL ROLE inspector;
DO $$
DECLARE v_restaurant uuid; v_category uuid;
BEGIN
 SELECT restaurant_id INTO v_restaurant FROM vasileva_food.restaurant LIMIT 1;
 SELECT product_category_id INTO v_category FROM vasileva_food.product_category LIMIT 1;
 CALL vasileva_food.add_product(
  v_restaurant, v_category, 'Тестовое блюдо', 1200.00, 4.5,
  'доступно'::vasileva_food.product_status, 'Тест FOOD-109', NULL);
END $$;
ROLLBACK;
```

При ошибке внутри транзакции выполнить отдельный `ROLLBACK;`.

## FOOD-110. Резервная копия

Резервная копия: `db/foodexpress_vasileva.backup`. Восстановление в пустую БД с предварительно установленным `exts.uuid-ossp`; затем проверка количества объектов и строк. Если права при восстановлении исключены (`--no-acl`), `grants.sql` выполняется отдельно.
