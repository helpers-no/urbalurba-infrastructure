---
title: Integration
sidebar_label: Integration
description: CMS, message queues, API gateways, and workflow orchestration with Enonic XP, RabbitMQ, Gravitee, and Temporal
---

# Integration

Content management, messaging, API gateways, workflow orchestration, and event-driven communication services.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
| [Enonic XP](./enonic.md) | Headless CMS platform | `./uis deploy enonic` |
| [RabbitMQ](./rabbitmq.md) | Message broker for async communication | `./uis deploy rabbitmq` |
| [Gravitee](./gravitee.md) | API management and gateway platform | `./uis deploy gravitee` |
| [Temporal](./temporal.md) | Durable workflow orchestration engine | `./uis deploy temporal` |

## Overview

- **Enonic XP** provides a headless CMS with Content Studio, headless APIs, and embedded storage
- **RabbitMQ** provides message queuing and pub/sub for decoupling services
- **Gravitee** offers API management with rate limiting, authentication, and developer portal
- **Temporal** runs long-lived workflows as ordinary code, surviving crashes, deploys, and multi-day waits
