# FoodExpress — практическая работа №2

Схема БД: `vasileva_food`. СУБД: PostgreSQL 15+.

## Файлы

| Файл | Содержание |
|---|---|
| `db/schema/01_schema.sql` | ENUM, таблицы, ограничения, индексы (FOOD-101) |
| `db/schema/02_routines.sql` | Процедуры, функции, триггеры, представление (FOOD-102–108) |
| `db/schema/grants.sql` | Роль `inspector` и права доступа (FOOD-109) |
| `db/constraints.md` | Ограничения и ссылки на бизнес-правила |
| `db/tests.md` | SQL-запросы для проверки |
| `db/foodexpress_vasileva.backup` | Резервная копия схемы с данными (FOOD-110) |
| `docs/` | Исходные материалы задания |

## Развёртывание SQL-скриптами

Перед запуском в базе должна существовать схема `exts` с расширением `uuid-ossp` (BR-13.3). Скрипты не создают расширение повторно.

В пустой базе последовательно выполнить:

1. `db/schema/01_schema.sql`
2. `db/schema/02_routines.sql`
3. `db/schema/grants.sql` — под ролью с правами администратора

Для заполнения тестовыми данными:

```sql
CALL vasileva_food.insert_test_data(10);
```

Запросы для проверки приведены в `db/tests.md`.

## Восстановление резервной копии (FOOD-110)

Архив `db/foodexpress_vasileva.backup` создан в формате PostgreSQL Custom и содержит схему `vasileva_food` с данными. Для восстановления нужна пустая база с предварительно настроенным `exts.uuid-ossp`.

```powershell
pg_restore -U postgres -d foodexpress_restore --no-owner --no-acl db/foodexpress_vasileva.backup
```

После восстановления с `--no-acl` выполнить `db/schema/grants.sql` в восстановленной базе. Проверки выполняются по `db/tests.md`.

## Особенность очистки (FOOD-103)

`erase_test_data()` использует `TRUNCATE`. Из-за отложенных платёжных триггеров очистку следует вызывать отдельной транзакцией после завершения вставки заказов и платежей. Процедура удаляет данные; для проверки использовать отдельную тестовую базу.
