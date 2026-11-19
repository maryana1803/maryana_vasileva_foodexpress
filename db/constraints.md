# Описание ограничений — vasileva_food

## Типы данных и структура
- Идентификаторы сущностей имеют тип `uuid` и DEFAULT `exts.uuid_generate_v4()` (BR-11.1). Связующие таблицы используют составные PK; `courier_pay` использует составной PK `(year, month, courier_id)`.
- Используемые ENUM-типы: `restaurant_status`, `product_status`, `courier_status`, `order_status`, `order_pay_status`, `payment_status`, `payment_type`, `review_entity_type` (BR-11.5).
- Таблица `"order"` записывается с двойными кавычками (BR-13.1).
- Поля `payment_type`, `amount`, `transaction_id`, `transaction_timestamp`, `status` добавлены в `payment`, поскольку они обязательны по BR-8.2 и отсутствовали в сокращённой ERD.

## Ключевые бизнес-ограничения
| Таблица | Ограничение | Правило | Обоснование |
|---|---|---|---|
| client | UNIQUE(login), UNIQUE(phone_number) | BR-2.2 | Логин и телефон уникальны |
| client | CHECK password ~ `^[0-9a-f]{32}$` | BR-2.3 | Хранится MD5-хэш |
| address | apartment_office nullable | BR-3.2, BR-11.3 | Квартира/офис необязательны |
| restaurant | UNIQUE(address_id) | BR-3.3 | Один ресторан на физический адрес |
| restaurant | CHECK(work_end > work_start) | BR-4.4 | Время закрытия позже открытия |
| restaurant | rating BETWEEN 0 AND 5 | BR-4.2 | Допустимый диапазон рейтинга |
| courier | UNIQUE(phone_number) | BR-6.1 | Телефон идентифицирует курьера |
| courier | coefficient BETWEEN 0.1 AND 0.5 | BR-6.4 | Допустимый коэффициент |
| courier | dismissal_date >= hire_date | BR-6.3 | Даты увольнения и найма согласованы |
| courier | уволен => dismissal_date NOT NULL | BR-6.3 | Уволенный обязан иметь дату увольнения |
| product | price >= 0 | BR-5.3 | Цена неотрицательна |
| product | rating BETWEEN 0 AND 5 | BR-5.4 | Рейтинг блюда в диапазоне |
| "order" | FK(client_id,address_id) -> client_address | BR-7.4 | Адрес доставки принадлежит клиенту |
| "order" | commission = round(order_amount*0.10,2) | BR-1.4, BR-7.10 | Комиссия сервиса 10% |
| "order" | total_amount = order_amount + commission | BR-7.10 | Общая сумма вычисляется из частей |
| "order" | total_amount >= 1000 | BR-1.8, BR-7.11 | Минимальная сумма заказа |
| "order" | delivery_timestamp >= order_timestamp | BR-7.13 | Доставка не раньше создания |
| "order" | доставлен => delivery_timestamp NOT NULL | BR-7.12 | Для доставленного заказа есть время окончания |
| order_structure | quantity > 0 | BR-7.15 | Положительное количество |
| order_structure | PK(order_id,product_id) | BR-7.16 | Блюдо не дублируется в заказе |
| payment | UNIQUE(transaction_id) | BR-8.3 | Внешний идентификатор уникален |
| payment | partial UNIQUE(order_id) WHERE status='успех' + отложенный constraint trigger | BR-8.1 | Ровно одна успешная попытка к COMMIT транзакции |
| payment | amount >= 0 | BR-8.2 | Сумма попытки неотрицательна |
| review | rating BETWEEN 1 AND 5 | BR-9.4 | Оценка от 1 до 5 |
| review | UNIQUE(order_id,entity_type,entity_id) | BR-9.5 | Не более одного отзыва на объект в рамках заказа |
| review | валидатор-триггер | BR-9.2, BR-9.5 | Отзыв только на объект из заказа и от его клиента |
| courier_pay | PK(year,month,courier_id) | BR-10.3 | Одна выплата курьеру за месяц |
| courier_pay | amount >= 0 | BR-10.4 | Выплата неотрицательна |

## Внешние ключи
- `client_address.client_id -> client.client_id`, `client_address.address_id -> address.address_id` (BR-2.4).
- `restaurant.address_id -> address.address_id` (BR-3.3).
- `product.restaurant_id -> restaurant.restaurant_id`, `product.product_category_id -> product_category.product_category_id` (BR-5.1).
- `"order".courier_id -> courier.courier_id`, `"order".restaurant_id -> restaurant.restaurant_id` (BR-7.2, BR-7.5).
- Составной FK `"order"(client_id,address_id) -> client_address(client_id,address_id)` (BR-7.4).
- `order_structure.order_id -> "order".order_id`, `order_structure.product_id -> product.product_id` (BR-7.14).
- `payment.order_id -> "order".order_id` (BR-8.1).
- `review.client_id -> client.client_id`, `review.order_id -> "order".order_id` (BR-9.2).
- `courier_pay.courier_id -> courier.courier_id` (BR-10.3).

## Правила, обеспечиваемые триггерами
- `order_structure` проверяет, что блюдо относится к ресторану заказа (BR-7.3).
- `review` проверяет принадлежность отзыва клиенту и объекту из заказа (BR-9.2, BR-9.5).
- `rating_change()` пересчитывает средний рейтинг блюда/ресторана после INSERT/UPDATE/DELETE (BR-9.6, BR-9.7).
- Платёжный триггер синхронизирует `order.pay_status` с попытками оплаты (BR-7.8, BR-8.7).

## Нормализация
Сущности клиента, адреса, ресторана, курьера, категории, блюда, заказа, оплаты, позиции, отзыва и выплаты разделены по самостоятельным объектам. Неключевые атрибуты зависят от полного ключа; транзитивные зависимости вынесены в связанные таблицы. `client_address` и `order_structure` реализуют связи M:N составными ключами.

`commission` и `total_amount` хранятся как обычные поля с CHECK, а не GENERATED: формулы явно контролируются бизнес-ограничениями. `product.rating` и `restaurant.rating` — агрегаты, намеренно сохранённые для быстрого чтения и поддерживаемые триггером (денормализация по BR-9.6). `review.entity_id` — полиморфная ссылка на блюдо/ресторан/заказ; FK не может ссылаться на несколько таблиц, поэтому целостность проверяет триггер.

## Генератор
`insert_test_data(value)` добавляет новый набор данных при каждом вызове, не очищая прежние данные (FOOD-102). Уникальность логинов, телефонов и transaction_id обеспечивается случайными суффиксами. Процедура не вызывает бизнес-процедуры и не использует `add_product`, `rating_change` или `courier_salary`.
