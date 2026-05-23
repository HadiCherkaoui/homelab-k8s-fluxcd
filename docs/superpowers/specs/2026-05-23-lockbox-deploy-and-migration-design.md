# Lockbox deployment and SOPS-secret migration

Date: 2026-05-23
Status: approved (Hadi)
Author: brainstorming session with Claude

## Goal

Deploy `lockbox` (Rust password manager, https://gitlab.cherkaoui.ch/HadiCherkaoui/lockbox) and `lockbox-k8s-controller` (Go controller that mirrors lockbox secrets into native `core/v1.Secret` objects) into the homelab cluster via Flux, and migrate all 17 existing SOPS-encrypted secrets out of the `secrets/` directory into lockbox-managed storage.

Once migrated, the controller is the source of truth for everything in `secrets/*` except its own bootstrap material (`secrets/lockbox/*`, which is necessarily SOPS-managed because lockbox cannot bootstrap itself from itself).

## Constraint discovered during brainstorming

`crates/lockbox-crypto/src/cipher.rs:13` uses the raw 32-byte Ed25519 seed verbatim as the AES-256-GCM symmetric key. Two consequences:

1. Every client (CLI, controller) has its own AES key derived from its own keypair.
2. Clients **cannot decrypt each other's ciphertext**.

The controller's behaviour confirms this: `internal/lockbox/auth.go:50` `Seed()` returns the same 32-byte private-key seed and the syncer uses it directly as the AES key (`internal/sync/reconcile.go:74`).

Migration via the `lbx` CLI therefore requires the CLI and the controller to share one keypair. The README presents this as "single-tenant" — for the homelab case that's fine.

## Architecture

### Component layout

| Path | Purpose |
|------|---------|
| `infrastructure/helmrepositories/repositories.yaml` | Adds two `HelmRepository` (kind: oci) entries: `lockbox` and `lockbox-k8s-controller`, both pointing at `registry.cherkaoui.ch/hadicherkaoui/<chart>`. Mirrors the existing `anvil` entry. |
| `infrastructure/lockbox/namespace.yaml` | Namespace `lockbox-system`. Shared with the controller. |
| `infrastructure/lockbox/helmrelease-lockbox.yaml` | Server `HelmRelease`, chart version `0.1.0-0df3cdfc` (current OCI tag). `auth.existingSecret: lockbox-auth`. `persistence.storageClassName: fast`, `size: 1Gi`. `ingress.enabled: true`, host `lockbox.cherkaoui.ch`, certResolver letsencrypt, `security-headers` middleware. Image pinned to SHA tag `0df3cdfcd3479cbc5c578bd3b01bbd93dc1e8fd2`. |
| `infrastructure/lockbox/helmrelease-controller.yaml` | Controller `HelmRelease`, chart `0.1.0`. `lockbox.existingSecret: lockbox-config`, `lockbox.skipBootstrapCheck: true`. Image `latest` (only tag CI publishes). `metrics.enabled: false` initially; can flip on later. Added in a second commit after `lockbox-credentials` exists. |
| `infrastructure/lockbox/kustomization.yaml` | Lists namespace + both HelmReleases. Pattern mirrors `infrastructure/cnpg-operator/`. |
| `infrastructure/kustomization.yaml` | Appends `lockbox/`. |
| `secrets/lockbox/lockbox-auth.secret.yaml` | SOPS — `API_KEY`, `JWT_SECRET` for the server. |
| `secrets/lockbox/lockbox-config.secret.yaml` | SOPS — `endpoint=https://lockbox.cherkaoui.ch` for the controller. (No `api-key` after first start.) |
| `secrets/lockbox/lockbox-credentials.secret.yaml` | SOPS — `seed` (32 bytes, base64 in the `data` field) shared with the local `lbx` CLI. Lives in `lockbox-system`. Auto-discovered by Flux because `secrets/` has no root `kustomization.yaml` — every YAML under the tree is applied. |

### Why both in `infrastructure/`

The `apps` Flux Kustomization `dependsOn: infrastructure`. Putting lockbox in `infrastructure/` means all apps wait for it to be ready before they reconcile — appropriate, since the controller is the source of their Secret data after migration. The current `cnpg-operator` follows the same pattern (operator-style plumbing in `infrastructure/`).

### Why one namespace

The controller chart's README example uses `lockbox-system`. The controller and server are operationally one unit on this single-tenant deployment, and the controller needs `lockbox-credentials` in its own namespace. Co-locating avoids cross-namespace Secret reads.

## Bootstrap sequence (one-time)

1. **Generate auth material.** Two `openssl rand -base64 32` values for `API_KEY` and `JWT_SECRET`.
2. **Write SOPS-encrypted seed files.**
   - `secrets/lockbox/lockbox-auth.secret.yaml` (carries `API_KEY`, `JWT_SECRET`)
   - `secrets/lockbox/lockbox-config.secret.yaml` (carries `endpoint=https://lockbox.cherkaoui.ch`)
   No `kustomization.yaml` needed at `secrets/lockbox/`; Flux walks the tree.
3. **Add `HelmRepository` entries.** Two OCI repos for the two charts.
4. **Add `infrastructure/lockbox/`.** Namespace, `helmrelease-lockbox.yaml`, kustomization listing both. Do NOT add `helmrelease-controller.yaml` yet — it depends on `lockbox-credentials` which is not in git until after step 8.
5. **Commit + `flux reconcile ks infrastructure --with-source`.** Server pod boots, `/health` + `/ready` green. Confirm `curl https://lockbox.cherkaoui.ch/health` from local returns 200.
6. **Build CLI.** `cd ~/gitlab/lockbox && cargo build --release -p lbx`, copy/symlink `target/release/lbx` to `~/.local/bin/lbx`.
7. **`lbx init`.** Server URL = `https://lockbox.cherkaoui.ch`; API key = the generated `API_KEY` from step 1; label = `homelab-bootstrap`. Writes `~/.local/share/lockbox/keypair.bin` (32-byte raw Ed25519 seed) and `serverbase.txt`; registers the public key with lockbox.
8. **Extract seed → SOPS.** Read 32 bytes from `keypair.bin`, base64-encode, write `secrets/lockbox/lockbox-credentials.secret.yaml` with `data.seed: <base64>`. SOPS-encrypt.
9. **Add `helmrelease-controller.yaml`** to `infrastructure/lockbox/kustomization.yaml`. Commit + `flux reconcile ks infrastructure`. Controller starts, finds `lockbox-credentials`, loads seed, polls `/secrets/sync`.

## Migration sequence

1. **Decrypt + push each secret.** With `SOPS_AGE_KEY=<key>` exported, decrypt each of the 17 SOPS files locally and push to lockbox with `lbx set -n <namespace> <secret-name> KEY=VALUE ...`. A loop script written in the implementation plan iterates the 17 files. The `name` matches the existing k8s Secret name; the `namespace` field on the lockbox secret IS the target k8s namespace.
2. **Verify on lockbox.** `lbx list` returns 17 entries. Spot-check one with `lbx get`.
3. **Force controller sync + verify adoption.** `kubectl -n lockbox-system rollout restart deploy/<controller>`. Wait for ready. Confirm `kubectl get secret -A -l app.kubernetes.io/managed-by=lockbox-k8s-controller | wc -l` ≈ 17.
4. **Suspend the `secrets` Flux Kustomization.** `flux suspend ks secrets`.
5. **Delete migrated SOPS files.** `git rm` all `secrets/<app>/*.secret.yaml` EXCEPT the three under `secrets/lockbox/`. Commit and push.
6. **Resume + force reconcile.** `flux resume ks secrets` then `flux reconcile ks secrets --with-source`. Flux's pruner deletes 17 Secret resources (out of inventory). ~60 s window where they're gone.
7. **Controller recreates within next poll cycle.** `kubectl get secret -A -l app.kubernetes.io/managed-by=lockbox-k8s-controller` should return 17 again.
8. **Spot-check pods.** Most apps loaded the secret into env vars at startup and don't notice. Anything that re-reads at runtime might log auth errors during the window — verify it self-recovered.

## Error handling and rollback

| Phase | Failure mode | Recovery |
|------|------|----------|
| Server pod won't start | `/health` not reachable; PVC unbound; wrong auth secret keys | inspect pod events; fix Secret; `flux reconcile hr lockbox` |
| `lbx init` registration fails | wrong API_KEY or endpoint unreachable from local | `curl https://lockbox.cherkaoui.ch/health` first; verify Traefik IngressRoute |
| Mid-loop push failure (n of 17 done) | network blip, lockbox restart | script is idempotent — `lbx set` overwrites, safe to re-run for missing entries |
| Controller `CrashLoopBackOff` | seed length ≠ 32 bytes in `lockbox-credentials` (`auth.go:62`) | re-extract seed from `keypair.bin`, re-encrypt SOPS file, push |
| Controller "decrypt failed" logs | CLI seed ≠ controller seed (someone pushed before extracting) | re-extract seed from `keypair.bin`, update SOPS file, redeploy |
| After prune, controller does not recreate | leader election stuck, sync cursor wedged | `kubectl logs -n lockbox-system deploy/<controller>`; `rollout restart` |

**Rollback before step 5 of migration:** all changes are additive. Delete the HelmReleases, revert the commits, original SOPS files still in git history.

**Rollback after step 5:** revert the deletion commit, `flux reconcile ks secrets --with-source`. Flux re-applies the 17 SOPS-managed Secrets. They collide with the now-controller-managed live Secrets (data identical) — SSA merge should be clean. Worst case `kubectl delete secret -n <ns> <name>` and let Flux recreate from restored SOPS.

## Testing

**After bootstrap, before migration:**
- `curl -fsSL https://lockbox.cherkaoui.ch/health` → 200
- `lbx set -n default smoke FOO=bar && lbx get smoke` round-trips `FOO=bar`
- `lbx remove smoke`
- `kubectl get hr -A` shows both `lockbox` and `lockbox-k8s-controller` as Ready=True

**After migration:**
- `kubectl get secret -A -l app.kubernetes.io/managed-by=lockbox-k8s-controller` returns 17
- For each namespace, one of: pod is Running and was not restarted (still has env from boot), or pod restarted and Running (got new Secret cleanly)
- Spot-check at least one pod per namespace, focused on the riskier ones (paperless admin, monitoring alertmanager-discord, traefik cloudflare-dns)

## Out of scope (deliberate)

- **Multi-client AES keys / true per-user E2EE.** The homelab uses one shared keypair. Multi-user is a future lockbox feature.
- **Metrics scraping for the controller.** `metrics.enabled: false` initially. Flip on after the migration settles.
- **Automated chart-version bumps.** The existing `scripts/update_helm_charts.sh` handles helm chart freshness; lockbox versions are pinned manually until the script learns the new repos.
- **Image-update automation.** Both image tags are pinned in the HelmRelease values; no Flux ImagePolicy is being set up here.

## Post-execution notes (added 2026-05-23)

The actual count of SOPS files at execution time was **18**, not 17 — `secrets/anvil/` had three files (`anvil-cf`, `anvil-oidc`, `cf-api-key`) and the original count missed one. The plan was corrected; this section is preserved as-is for the historical design.

Three issues surfaced during execution that the design didn't anticipate:

1. **Multi-line `stringData` values were corrupted in transit.** The initial `push-sops-to-lockbox.sh` used `yq -r '... | @tsv'` to extract key/value pairs, and `@tsv` escapes embedded newlines (0x0a) to the literal two-byte sequence `\n` (0x5c 0x6e). Three secrets (`alertmanager-discord`, `gitlab-authentik`, `matrix-synapse-email`) lost their newlines. Alertmanager was running with a null route for ~30 minutes before remediation. Fix: per-key `yq` extraction so values round-trip through bash variables cleanly; documented in the script header.
2. **Secret `type:` is not preserved.** The controller writes every managed Secret as `type: Opaque` regardless of the source. `scolx-registry` was originally `kubernetes.io/dockerconfigjson`; kubelet silently ignored the Opaque substitute as an imagePullSecret. Workloads kept running on cached images; the next pull would have failed. Remediation: restored `scolx-registry` to a SOPS file and removed the entry from lockbox. **Lockbox is for `Opaque` Secrets only.** Special-typed Secrets stay SOPS-managed.
3. **Controller does not self-heal manually-deleted Secrets.** The controller uses a `since` cursor; once an event has been processed, it isn't re-applied unless the cursor resets (controller restart) or a new event arrives for that key. During the Phase E cutover, Flux pruned the 18 live Secrets but the controller sat at `count: 0` until restarted. Operationally: `kubectl -n lockbox-system rollout restart deploy/lockbox-k8s-controller` is the fix when a lockbox-managed Secret goes missing. Noted in `CLAUDE.md`'s Flux debugging section.

The final cluster state has **17** controller-managed Secrets (the `Opaque` migratable ones) plus one SOPS-managed `kubernetes.io/dockerconfigjson` (`scolx-registry`) plus the three lockbox bootstrap SOPS files.
