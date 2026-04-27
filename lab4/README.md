# Lab 4 — Indexing & Query Optimization in PostgreSQL

## Запуск

### 1. Поднять базу данных

```bash
docker-compose up -d
```

Дождаться завершения инициализации:

```bash
docker logs -f lab4_postgres
```

### 2. Запустить эксперименты

Подключиться к базе:

```bash
PGPASSWORD='postgres' psql -h localhost -p 5435 -U postgres -d rental_db
```

Затем внутри psql:

```sql
\timing on
\i scripts/03_experiments.sql
```

Или запустить сразу целиком (без пошагового анализа):

```bash
PGPASSWORD='postgres' psql -h localhost -p 5435 -U postgres -d rental_db -f scripts/03_experiments.sql
```

Запустить с сохранением всего вывода в файл:

```bash
PGPASSWORD='postgres' psql -h localhost -p 5435 -U postgres -d rental_db \
  -c "\timing on" \
  -f scripts/03_experiments.sql \
  2>&1 | tee explain.md
```

### 3. Остановить

```bash
docker-compose down
```
