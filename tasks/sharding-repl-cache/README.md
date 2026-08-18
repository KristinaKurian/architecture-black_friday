# MongoDB Sharding + Replication + Redis Cache

Решение задания 4. Проект является копией `mongo-sharding-repl` и сохраняет шардирование и репликацию MongoDB. Дополнительно добавлен Redis для кеширования запросов приложения.

## Архитектура

```text
                           +---------+
                           |  Redis  |
                           +----^----+
                                |
                                |
                         +------+------+
                         | pymongo-api |
                         +------+------+
                                |
                                v
                         +------+------+
                         | mongos_router|
                         +------+------+
                            /       \
                           /         \
                          v           v

                  ReplicaSet       ReplicaSet
                    shard1           shard2
                  -----------      -----------
                  shard1-1         shard2-1
                  shard1-2         shard2-2
                  shard1-3         shard2-3
```

База данных: `somedb`.

Коллекция: `helloDoc`.

Shard key:

```javascript
{name: "hashed"}
```

Каждый shard имеет три реплики: одну `PRIMARY` и две `SECONDARY`.

## Redis

В `compose.yaml` добавлен сервис Redis:

```yaml
redis:
  image: redis:7-alpine
  restart: unless-stopped
```

В приложение передаётся переменная окружения из задания:

```yaml
REDIS_URL: "redis://redis:6379"
```

`redis` — имя сервиса Docker Compose, поэтому приложение может обращаться к Redis по адресу `redis:6379` внутри общей сети.

Кеширование приложения проверяется на эндпоинте:

```text
/helloDoc/users
```

## Структура директории

Папка должна оставаться копией предыдущего проекта, поэтому `api_app` необходимо сохранить:

```text
sharding-repl-cache/
├── api_app/
│   ├── Dockerfile
│   └── ...
├── compose.yaml
├── init.sh
├── check.sh
└── README.md
```

## Запуск

Перед запуском остановите предыдущий стенд `mongo-sharding-repl`, если он ещё работает: оба проекта используют host-порты `8080` и `27020`.

Из `tasks/sharding-repl-cache`:

```bash
docker compose down -v --remove-orphans
bash init.sh
bash check.sh
```

`init.sh` автоматически:

1. запускает Redis;
2. запускает Config Server;
3. запускает по три MongoDB-инстанса для каждого shard;
4. инициализирует ReplicaSet `config_server`;
5. инициализирует ReplicaSet `shard1` и `shard2`;
6. ждёт состояния `1 PRIMARY + 2 SECONDARY`;
7. запускает `mongos_router`;
8. регистрирует два shard-а;
9. включает sharding для `somedb`;
10. шардирует `somedb.helloDoc` по `{name: "hashed"}`;
11. создаёт не менее 1000 документов;
12. запускает `pymongo-api` с `REDIS_URL=redis://redis:6379`.

## Проверка Redis

```bash
docker compose exec -T redis redis-cli ping
```

Ожидаемый результат:

```text
PONG
```

## Проверка кеширования

Первый запрос прогревает кеш:

```bash
curl -o /dev/null -s -w "first: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

Второй запрос:

```bash
curl -o /dev/null -s -w "second: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

Третий запрос:

```bash
curl -o /dev/null -s -w "third: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

По условию задания второй и последующие запросы должны выполняться быстрее `0.100` секунды.

`check.sh` автоматизирует эту проверку: первый вызов прогревает кеш, затем измеряются второй и третий вызовы.

Посмотреть количество ключей в Redis после запросов:

```bash
docker compose exec -T redis redis-cli DBSIZE
```

## Что проверяет check.sh

- Redis отвечает `PONG`;
- зарегистрировано два shard-а;
- общее число документов `>= 1000`;
- документы присутствуют на обоих shard-ах;
- в каждом shard по три реплики;
- состояния реплик — `1 PRIMARY + 2 SECONDARY`;
- второй и третий запросы `/helloDoc/users` выполняются `<100 ms`.

Успешный результат заканчивается примерно так:

```text
OK: Redis is available
OK: 2 shards registered
OK: total documents >= 1000
OK: documents exist on both shards
OK: shard1 has 3 replicas (1 PRIMARY + 2 SECONDARY)
OK: shard2 has 3 replicas (1 PRIMARY + 2 SECONDARY)
OK: cached requests are < 100 ms
SUCCESS
```

## Приложение

```text
http://localhost:8080
```

Swagger:

```text
http://localhost:8080/docs
```

Кешируемый endpoint:

```text
http://localhost:8080/helloDoc/users
```

## Полный сброс

```bash
docker compose down -v --remove-orphans
bash init.sh
bash check.sh
```

Опция `-v` удаляет MongoDB volumes. Для Redis отдельный persistent volume не создаётся, потому что здесь Redis используется как кеш.
