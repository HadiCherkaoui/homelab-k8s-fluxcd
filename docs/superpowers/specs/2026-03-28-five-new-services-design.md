# Design: Add 5 New Services to FluxCD Homelab

**Date:** 2026-03-28
**Status:** Approved

## Overview

Add ntfy, Uptime Kuma, Headscale, Changedetection.io, and Wallos to the homelab Kubernetes cluster using Helm charts managed by Flux CD. All services follow existing repo conventions for namespaces, HelmReleases, IngressRoutes, and storage.

## New HelmRepositories

Added to `infrastructure/helmrepositories/repositories.yaml`:

| Name | Type | URL | Used By |
|------|------|-----|---------|
| `uptime-kuma` | HTTPS | `https://dirsigler.github.io/uptime-kuma-helm` | Uptime Kuma |
| `wrenix` | OCI | `oci://codeberg.org/wrenix/helm-charts` | Headscale |
| `alekc` | HTTPS | `https://charts.alekc.dev` | Changedetection.io |

ntfy and Wallos use the existing `truecharts` OCI repository.

## Service Designs

### 1. ntfy — Push Notifications

- **Chart:** `ntfy` from `truecharts` (OCI)
- **Namespace:** `ntfy`
- **Storage:** 1Gi, storageClass `fast`
- **Ingress:** `ntfy.cherkaoui.ch` via Traefik IngressRoute
- **Service port:** `main` (TrueCharts convention)
- **Database:** None (file-based)
- **Files:** `apps/ntfy/{namespace,helmrelease,ingressroute,kustomization}.yaml`

### 2. Uptime Kuma — Uptime Monitoring

- **Chart:** `uptime-kuma` v4.0.0 from `uptime-kuma` repo (HTTPS)
- **Namespace:** `uptime-kuma`
- **Storage:** 2Gi, storageClass `fast`
- **Ingress:** `status.cherkaoui.ch` via Traefik IngressRoute, port 3001
- **Database:** Embedded SQLite
- **SSO note:** No native OIDC. Protect via Traefik ForwardAuth middleware with Authentik outpost (proxy provider) when ready.
- **Files:** `apps/uptime-kuma/{namespace,helmrelease,ingressroute,kustomization}.yaml`

### 3. Headscale — Tailscale Control Server

- **Chart:** `headscale` v1.0.14 from `wrenix` repo (OCI)
- **Namespace:** `headscale`
- **Storage:** 1Gi, storageClass `fast`
- **Service type:** LoadBalancer (chart-managed, Approach A)
  - Port 8080 TCP — control plane / API
  - Port 3478 UDP — DERP/STUN relay
- **Ingress:** `headscale.cherkaoui.ch` via Traefik IngressRoute, port 8080 (web/API browser access)
- **Config:** `server_url: https://headscale.cherkaoui.ch`, DERP enabled
- **Database:** Embedded SQLite
- **SSO note:** Native OIDC support (`oidc.issuer`, `oidc.client_id`, etc.). Configure with Authentik later.
- **Files:** `apps/headscale/{namespace,helmrelease,ingressroute,kustomization}.yaml`

### 4. Changedetection.io — Website Change Monitoring

- **Chart:** `changedetection` v0.11.6 from `alekc` repo (HTTPS)
- **Namespace:** `changedetection`
- **Storage:** 2Gi, storageClass `fast`
- **Ingress:** `changes.cherkaoui.ch` via Traefik IngressRoute, port 5000
- **Playwright browser fetcher:** Disabled by default (can enable later for JS-heavy sites)
- **Files:** `apps/changedetection/{namespace,helmrelease,ingressroute,kustomization}.yaml`

### 5. Wallos — Subscription Tracker

- **Chart:** `wallos` from `truecharts` (OCI)
- **Namespace:** `wallos`
- **Storage:** 1Gi, storageClass `fast`
- **Ingress:** `wallos.cherkaoui.ch` via Traefik IngressRoute
- **Service port:** `main` (TrueCharts convention)
- **Database:** Embedded SQLite
- **Files:** `apps/wallos/{namespace,helmrelease,ingressroute,kustomization}.yaml`

## Conventions Applied

- `createNamespace: false` on all HelmReleases (namespace managed by explicit `namespace.yaml`)
- `interval: 10m` for all HelmReleases
- All HelmRepository `sourceRef` points to `namespace: flux-system`
- All IngressRoutes use `websecure` entryPoint, `letsencrypt` certResolver, `security-headers` middleware from `traefik` namespace
- Ingress disabled in all chart values (Traefik IngressRoute handles routing)
- Storage class `fast` for all persistent volumes
- All 5 apps registered in `apps/kustomization.yaml`

## Files Modified

- `infrastructure/helmrepositories/repositories.yaml` — add 3 new HelmRepository entries
- `apps/kustomization.yaml` — add 5 new app directories

## Files Created

Per app (5 apps × 4 files = 20 new files):
- `apps/<name>/namespace.yaml`
- `apps/<name>/helmrelease.yaml`
- `apps/<name>/ingressroute.yaml`
- `apps/<name>/kustomization.yaml`

## Future Work (not in scope)

- Authentik OIDC integration for Headscale (native) and Uptime Kuma (ForwardAuth)
- Headscale-UI deployment if CLI management becomes tedious
- Playwright browser fetcher for Changedetection.io
