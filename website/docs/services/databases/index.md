---
title: Databases
sidebar_label: Databases
description: PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch, and Qdrant
---

# Databases

UIS provides multiple database options for different data models and use cases. PostgreSQL is the primary database used by other UIS services. The others are available for user workloads.

## Services

| Service | Type | Used by UIS | Deploy |
|---------|------|-------------|--------|
| [PostgreSQL](./postgresql.md) | Relational (SQL) | authentik, openwebui, litellm, unity-catalog, pgadmin | `./uis deploy postgresql` |
| [Redis](./redis.md) | In-memory key-value | authentik, redisinsight | `./uis deploy redis` |
| [MySQL](./mysql.md) | Relational (SQL) | — | `./uis deploy mysql` |
| [MongoDB](./mongodb.md) | Document (NoSQL) | — | `./uis deploy mongodb` |
| [Qdrant](./qdrant.md) | Vector search | — | `./uis deploy qdrant` |
| [Elasticsearch](./elasticsearch.md) | Search & analytics | — | `./uis deploy elasticsearch` |

For S3-compatible object storage, see [MinIO](../storage/minio.md) under [Storage](../storage/index.md).

## Quick Start

PostgreSQL and Redis are the most commonly needed databases:

```bash
./uis deploy postgresql
./uis deploy redis
```

Other databases are deployed on demand when specific applications need them.

## PostgreSQL Extensions

UIS deploys the official Bitnami PostgreSQL image (PostgreSQL 18.3) which includes 8 pre-built extensions: pgvector (AI embeddings), PostGIS (geospatial), hstore, ltree, uuid-ossp, pg_trgm, btree_gin, and pgcrypto. See [PostgreSQL details](./postgresql.md).
