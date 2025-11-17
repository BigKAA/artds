# artds - 389 Directory Server Kubernetes Deployment

## 📖 О проекте

Этот проект показывает **три этапа** развертывания LDAP кластера 389ds с постепенным усложнением и автоматизацией:

1. **Docker deployment** - Базовое развертывание и понимание архитектуры.
2. **Kubernetes Manifests** - Переход в Kubernetes без автоматизации.
3. **Мониторинг**.
4. **Helm Chart** - Production-ready автоматизация и шаблонизация.

---

## 🎓 Этапы проекта

### Docker Deployment

Базовое развертывание 389ds в Docker для понимания архитектуры и компонентов.

- [Создание кластера с использованием docker](docker.md) - Multi-master репликация в Docker
- [Создание кластера с использованием docker-swarm](docker-swarm.md) - Развертывание в Docker Swarm

---

### Kubernetes Manifests

Переход к Kubernetes с использованием нативных манифестов (без Helm).

- [Развертывание 389ds в Kubernetes](kubernetes/README.md) - Полное руководство по развертыванию кластера 389ds в kubernetes с использованием манифестов.

---

### Мониторинг

Сборка и установка экспортера.

*Under construction.*

---

### Helm Chart

Production-ready автоматизация через Helm с решением проблем Stage 2.

*Under construction.*

- [Artds Helm Chart](artds/README.md) - Comprehensive Helm tutorial

## 🔧 Технический стек

- **389 Directory Server** 3.1 - Open source LDAP server
- **Docker** / **Kubernetes** - Containerization и orchestration
- **Helm** 3.x - Kubernetes package manager
- **cert-manager** - TLS certificate management
- **MetalLB** - LoadBalancer implementation для on-premise
- **NFS Storage** - Persistent storage backend
