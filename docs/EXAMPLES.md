# Backend env
```bash
./scripts/encrypt-secret.sh \
  --namespace scolx \
  --name scolx-backend-env \
  --data JWT_SECRET='<jwt>' \
  --data SCOLX_ADMIN_PASSWORD='<admin-pass>' \
  --data SCOLX_POSTGRES_PASSWORD='<db-pass>' \
  --out secrets/scolx/scolx-backend-env.secret.yaml
```

```bash
# Docker pull secret (create dockerconfigjson outside the repo, then import)
kubectl create secret docker-registry scolx-registry \
  --docker-server='registry.cherkaoui.ch' \
  --docker-username='<user>' \
  --docker-password='<pass>' \
  --dry-run=client -o yaml > /tmp/scolx-registry.plain.yaml

./scripts/encrypt-secret.sh \
  --from-file /tmp/scolx-registry.plain.yaml \
  --out secrets/scolx/scolx-registry.secret.yaml
```

> **Note:** You may want to ensure metadata.name and type are correct in the encrypted file:
> - `type: kubernetes.io/dockerconfigjson`
> - `metadata.name: scolx-registry`
> - `metadata.namespace: scolx`

```bash
# Protonmail username used for smtp.user_name + email.from + email.reply_to
./scripts/encrypt-secret.sh \
  --namespace gitlab \
  --name gitlab-protonmail \
  --data PROTONMAIL_USERNAME='user@domain.tld' \
  --out secrets/gitlab/gitlab-protonmail.secret.yaml
```

```bash
# SMTP password (used at global.smtp.password.secret:key=smtp-password)
./scripts/encrypt-secret.sh \
  --namespace gitlab \
  --name gitlab-smtp-password \
  --data smtp-password='<your-smtp-password>' \
  --out secrets/gitlab/gitlab-smtp-password.secret.yaml
```

```bash
# GitLab agent token
./scripts/encrypt-secret.sh \
  --namespace gitlab \
  --name gitlab-agent-token \
  --data GITLAB_AGENT_TOKEN='<agent-token>' \
  --out secrets/gitlab/gitlab-agent-token.secret.yaml
```

```bash
# Paperless admin credentials
./scripts/encrypt-secret.sh \
  --namespace paperless \
  --name paperless-admin \
  --data PAPERLESS_ADMIN_USER='hadi' \
  --data PAPERLESS_ADMIN_PASSWORD='<strong-password>' \
  --data PAPERLESS_ADMIN_MAIL='paperless@hide.cherkaoui.ch' \
  --out secrets/paperless/paperless-admin.secret.yaml
```

```bash
# Notifiarr API key
./scripts/encrypt-secret.sh \
  --namespace media \
  --name notifiarr-env \
  --data NOTIFIARR_APIKEY='<your-notifiarr-apikey>' \
  --out secrets/media/notifiarr-env.secret.yaml
```

```bash
# qBittorrent OpenVPN credentials (with inline config)
./scripts/encrypt-secret.sh \
  --namespace media \
  --name qbittorrent-openvpn \
  --data OPENVPN_USER='<your-openvpn-user>' \
  --data OPENVPN_PASSWORD='<your-openvpn-password>' \
  --data openvpn.conf="$(cat /path/to/openvpn.conf)" \
  --out secrets/media/qbittorrent-openvpn.secret.yaml
```

```bash
# qBittorrent OpenVPN credentials (with config from file)
./scripts/encrypt-secret.sh \
  --namespace media \
  --name qbittorrent-openvpn \
  --data OPENVPN_USER='<your-openvpn-user>' \
  --data OPENVPN_PASSWORD='<your-openvpn-password>' \
  --from-file /path/to/openvpn.conf \
  --out secrets/media/qbittorrent-openvpn.secret.yaml
```
