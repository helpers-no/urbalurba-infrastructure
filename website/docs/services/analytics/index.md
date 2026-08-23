---
title: Analytics
sidebar_label: Analytics
description: Data science and orchestration with Dagster, Spark, JupyterHub, Unity Catalog, and OpenMetadata
---

# Analytics

The analytics package provides data science and analytics platforms for interactive analysis, distributed processing, and data governance.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
| [Dagster](./dagster.md) | Data-asset orchestration: scheduling, lineage, freshness | `./uis deploy dagster` |
| [JupyterHub](./jupyterhub.md) | Multi-user Jupyter notebooks with PySpark | `./uis deploy jupyterhub` |
| [OpenMetadata](./openmetadata.md) | Data discovery, governance, and metadata platform | `./uis deploy openmetadata` |
| [Apache Spark](./spark.md) | Kubernetes-native distributed processing | `./uis deploy spark` |
| [Unity Catalog](./unitycatalog.md) | Data catalog and governance | `./uis deploy unity-catalog` |

## Quick Start

```bash
./uis stack install analytics
```

This installs Spark, JupyterHub, and Unity Catalog. OpenMetadata is deployed separately:

```bash
./uis deploy postgresql      # Required by OpenMetadata
./uis deploy elasticsearch   # Required by OpenMetadata
./uis deploy openmetadata
```

## How It Works

- **JupyterHub** gives users interactive notebooks with PySpark pre-configured
- **Spark Operator** runs batch jobs as Kubernetes-native SparkApplication resources
- **Unity Catalog** provides a three-level namespace (catalog.schema.table) for governed data access
- **OpenMetadata** provides data discovery, lineage tracking, and governance across all data assets
