# Pulling Images on China Networks (WSL / Ubuntu)

> Symptom: `docker compose up -d` hangs, reporting
> `dial tcp [2a03:2880:...]:443: i/o timeout` or `failed to resolve reference`.
>
> Key point: that IPv6 address is not Docker's. This is **DNS resolution being polluted**
> plus **WSL2 having no IPv6 egress**, so don't rush to blame "the wall"; fix resolution
> first, then configure the accelerator.

---

## 0. First Determine Which Docker You Have

This determines where the config file goes; **editing the wrong place is wasted effort**.

```bash
docker info --format '{{.ServerVersion}} | {{.OperatingSystem}} | {{.DockerRootDir}}'
docker context ls
systemctl status docker --no-pager 2>/dev/null | head -5
```

| Basis | Conclusion | Config file |
|---|---|---|
| `systemctl` shows `docker.service` | **Native** Docker Engine inside WSL | `/etc/docker/daemon.json` |
| `docker context ls` has `desktop-linux` and it is current | **Docker Desktop** | Windows-side Docker Desktop → Settings → Docker Engine |
| `docker context ls` shows `default` and the socket is at `/var/run/docker.sock` | Native | `/etc/docker/daemon.json` |

> Running native Docker inside WSL requires enabling systemd in `/etc/wsl.conf`:
> ```ini
> [boot]
> systemd=true
> ```
> After the change, run `wsl --shutdown` on the Windows side, then re-enter.

---

## 1. Fix DNS (do this first, otherwise the accelerator may still fail to resolve)

WSL2 forwards DNS requests to Windows by default, and the Windows-side resolution may
already be polluted.

```bash
# 1) Disable WSL auto-generating resolv.conf
sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[network]
generateResolvConf = false
EOF

# 2) Pin domestic DNS servers
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 180.76.76.76
EOF

# 3) Make wsl.conf effective (execute on the Windows side)
#    wsl --shutdown
```

After re-entering, verify:

```bash
cat /etc/resolv.conf
getent hosts registry-1.docker.io      # addresses like 2a03:2880 should no longer appear
```

> If `getent` still returns odd addresses, the Windows side is still hijacking; you can
> temporarily use `curl -4 -I https://registry-1.docker.io/v2/` to check whether IPv4
> works, to distinguish a "resolution problem" from an "egress problem".

---

## 2. Configure the Registry Accelerator

### 2.1 First Choice: Aliyun personal accelerator (stable, free, requires login to get your dedicated address)

1. Log in at <https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors>
2. Copy an address like `https://<your-ID>.mirror.aliyuncs.com`
3. Put it into the `registry-mirrors` below

### 2.2 Write daemon.json

> JSON **does not support comments**; the following can be used directly, replacing
> `<your-ID>` with your own (or delete that line if you have none).

```bash
sudo mkdir -p /etc/docker
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://<your-ID>.mirror.aliyuncs.com",
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live",
    "https://docker.1ms.run"
  ],
  "dns": ["223.5.5.5", "119.29.29.29"],
  "max-concurrent-downloads": 5
}
EOF

sudo systemctl restart docker     # Without systemd: sudo service docker restart
```

**Two points many tutorials get wrong:**

- `registry-mirrors` **only applies to Docker Hub (docker.io)**; other registries are
  unaffected. All three images of this project come from Hub, so it fits exactly.
- The `"dns"` entry configures the DNS **inside containers**, not the one dockerd itself
  uses to resolve registries. dockerd's resolution uses the host's `/etc/resolv.conf`,
  so step 1 cannot be skipped.

### 2.3 Verification

```bash
docker info | sed -n '/Registry Mirrors/,+5p'
docker pull redis:7-alpine
```

During the pull, the accelerator domain appearing in the output means it is in effect.

---

## 3. Alternative: mirror prefix + local retag (no daemon.json changes at all)

Suitable for two cases: your Docker is Docker Desktop (changing config requires
restarting the whole desktop app), or all accelerators are rate-limited.

The idea is to **pull from an available mirror registry, then retag to the original
name**, so `docker-compose.yml` needs no changes at all.

```bash
./scripts/pull-images.sh
```

The script content is in `scripts/pull-images.sh`; it tries several mirror registries in
turn and automatically retags on success to
`redis:7-alpine` / `hashicorp/http-echo:1.0` / `kong:3.6`.

You can also do it manually:

```bash
docker pull docker.m.daocloud.io/library/redis:7-alpine
docker tag  docker.m.daocloud.io/library/redis:7-alpine redis:7-alpine
```

> Non-official images need the namespace: `hashicorp/http-echo` →
> `docker.m.daocloud.io/hashicorp/http-echo:1.0`;
> official images need `library/` added: `redis` →
> `docker.m.daocloud.io/library/redis:7-alpine`.

If you prefer to hard-code the mirror registry directly in compose (more convenient for
team sharing), use the override file:

```bash
docker compose -f docker-compose.yml -f docker-compose.mirror.yml up -d
```

---

## 4. Still Failing: Match the Symptom to the Table

| Symptom | Diagnosis | Fix |
|---|---|---|
| Still resolves to `2a03:2880:*` | DNS change did not take effect | Verify `/etc/resolv.conf`, `wsl --shutdown`, then re-enter |
| `connection refused` / `no such host` | The accelerator domain itself is down | Switch to the next accelerator; public accelerators are short-lived |
| `toomanyrequests: rate limit exceeded` | Anonymous pull rate-limited | Use the Aliyun personal accelerator, or `docker login` |
| Only one image fails to pull | That namespace is not cached | Retry with another mirror registry; or switch to `nginx:alpine` as the upstream (see below) |
| Pull succeeds but startup fails | Architecture mismatch | `docker pull --platform linux/amd64 <img>` |

**Alternative for the upstream image**: `hashicorp/http-echo` is only needed to provide a
"return 200 instantly" service. If it truly cannot be pulled, replace the `echo` service
in `docker-compose.yml` with:

```yaml
  echo:
    image: nginx:alpine
    # The default page is 200; Kong only cares about the status code, not the body
```

`nginx:alpine` is an official image under `library/`, cached by every mirror registry,
with the highest hit rate.

---

## 5. A Word on k6

The `dl.k6.io` source given in the README may be very slow on China networks. Three
alternatives, ordered by reliability:

```bash
# A. snap (bundled with Ubuntu)
sudo snap install k6

# B. Download the official deb package directly and install
curl -L -o k6.deb https://dl.k6.io/deb/dists/stable/main/binary-amd64/k6_0.49.0_amd64.deb
sudo dpkg -i k6.deb

# C. GitHub release (replace <proxy>/ with an acceleration prefix you trust)
curl -L -o k6.tgz "<proxy>/https://github.com/grafana/k6/releases/download/v0.49.0/k6-v0.49.0-linux-amd64.tar.gz"
tar -xzf k6.tgz && sudo mv k6-v0.49.0-linux-amd64/k6 /usr/local/bin/
```

After installing, verify with `k6 version`.

---

## 6. Final Self-Check Once Everything Is Ready

```bash
docker images | grep -E 'kong|redis|http-echo'     # all three images present
docker compose up -d
docker compose ps                                   # all 3 kong running
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8030/echo
```
