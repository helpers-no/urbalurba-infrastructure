---
title: Storage
sidebar_label: Storage
---

# Storage

Platform storage infrastructure. Deploy the services your application needs.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
| [Garage](./garage.md) | S3-compatible object storage (replaces MinIO, 2026-10-01) | `./uis deploy garage` |
| [MinIO](./minio.md) | S3-compatible object storage - ⚠️ images withdrawn, see its page | `./uis deploy minio` |

## Quick Start

Deploy the services you need:

```bash
./uis deploy garage
```
