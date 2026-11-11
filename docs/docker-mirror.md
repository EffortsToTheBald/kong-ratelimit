# 国内网络下的镜像拉取（WSL / Ubuntu）

> 症状：`docker compose up -d` 卡住，报
> `dial tcp [2a03:2880:...]:443: i/o timeout` 或 `failed to resolve reference`。
>
> 关键点：那个 IPv6 地址不是 Docker 的。这是 **DNS 解析被污染** + **WSL2 没有 IPv6 出口**，
> 所以别急着怀疑"墙"，先把解析修对，再配加速器。

---

## 0. 先判断你的 Docker 是哪一种

这决定了配置文件放哪，**改错地方等于白改**。

```bash
docker info --format '{{.ServerVersion}} | {{.OperatingSystem}} | {{.DockerRootDir}}'
docker context ls
systemctl status docker --no-pager 2>/dev/null | head -5
```

| 判断依据 | 结论 | 配置文件 |
|---|---|---|
| `systemctl` 能看到 `docker.service` | WSL 内**原生** Docker Engine | `/etc/docker/daemon.json` |
| `docker context ls` 有 `desktop-linux` 且为当前 | **Docker Desktop** | Windows 侧 Docker Desktop → Settings → Docker Engine |
| `docker context ls` 是 `default` 且 socket 在 `/var/run/docker.sock` | 原生 | `/etc/docker/daemon.json` |

> WSL 里跑原生 Docker，需要 `/etc/wsl.conf` 开启 systemd：
> ```ini
> [boot]
> systemd=true
> ```
> 改完在 Windows 执行 `wsl --shutdown` 再进。

---

## 1. 修 DNS（先做这一步，否则配了加速器也可能解析失败）

WSL2 默认把 DNS 请求转发给 Windows，Windows 那侧的解析结果可能已经被污染。

```bash
# 1) 关掉 WSL 自动生成 resolv.conf
sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[network]
generateResolvConf = false
EOF

# 2) 写死国内 DNS
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 180.76.76.76
EOF

# 3) 让 wsl.conf 生效（Windows 侧执行）
#    wsl --shutdown
```

重新进入后验证：

```bash
cat /etc/resolv.conf
getent hosts registry-1.docker.io      # 不该再出现 2a03:2880 这类地址
```

> 如果 `getent` 仍然返回奇怪的地址，说明 Windows 侧还在劫持；可以临时用
> `curl -4 -I https://registry-1.docker.io/v2/` 看 IPv4 是否通，以区分"解析问题"和"出口问题"。

---

## 2. 配镜像加速器

### 2.1 首选：阿里云个人加速器（稳定、免费，需登录获取专属地址）

1. 登录 <https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors>
2. 复制形如 `https://<你的ID>.mirror.aliyuncs.com` 的地址
3. 填进下面的 `registry-mirrors`

### 2.2 写 daemon.json

> JSON **不支持注释**，下面这份可以直接用，把 `<你的ID>` 换成自己的（没有就删掉那一行）。

```bash
sudo mkdir -p /etc/docker
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://<你的ID>.mirror.aliyuncs.com",
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live",
    "https://docker.1ms.run"
  ],
  "dns": ["223.5.5.5", "119.29.29.29"],
  "max-concurrent-downloads": 5
}
EOF

sudo systemctl restart docker     # 没有 systemd 时：sudo service docker restart
```

**注意两点，很多教程写错：**

- `registry-mirrors` **只对 Docker Hub（docker.io）生效**，其他 registry 不受影响。本项目三个镜像全部来自 Hub，正好适用。
- `"dns"` 配的是**容器内部**的 DNS，不是 dockerd 自己去解析 registry 用的。dockerd 的解析走宿主机 `/etc/resolv.conf`，所以第 1 步不能省。

### 2.3 验证

```bash
docker info | sed -n '/Registry Mirrors/,+5p'
docker pull redis:7-alpine
```

拉取时输出里会出现加速器域名，说明生效了。

---

## 3. 备选：镜像前缀 + 本地 retag（完全不动 daemon.json）

适合两种情况：你的 Docker 是 Docker Desktop（改配置要重启整个桌面端），
或者加速器都被限流了。

思路是**从可用的镜像站拉，然后 tag 成原来的名字**，这样 `docker-compose.yml` 一个字都不用改。

```bash
./scripts/pull-images.sh
```

脚本内容见 `scripts/pull-images.sh`，它会依次尝试多个镜像站，成功后自动 retag 成
`redis:7-alpine` / `hashicorp/http-echo:1.0` / `kong:3.6`。

也可以手动：

```bash
docker pull docker.m.daocloud.io/library/redis:7-alpine
docker tag  docker.m.daocloud.io/library/redis:7-alpine redis:7-alpine
```

> 非官方镜像要带命名空间：`hashicorp/http-echo` → `docker.m.daocloud.io/hashicorp/http-echo:1.0`；
> 官方镜像要补 `library/`：`redis` → `docker.m.daocloud.io/library/redis:7-alpine`。

如果更希望 compose 里直接写死镜像站（团队共享时更省事），用 override 文件：

```bash
docker compose -f docker-compose.yml -f docker-compose.mirror.yml up -d
```

---

## 4. 仍然失败：按现象对表

| 现象 | 判断 | 处理 |
|---|---|---|
| 仍解析到 `2a03:2880:*` | DNS 没生效 | 确认 `/etc/resolv.conf`、`wsl --shutdown` 后重进 |
| `connection refused` / `no such host` | 加速器域名本身挂了 | 换下一个加速器；公共加速器寿命很短 |
| `toomanyrequests: rate limit exceeded` | 匿名拉取被限流 | 用阿里云个人加速器，或 `docker login` |
| 只有某个镜像拉不下来 | 该 namespace 未被缓存 | 换镜像站重试；或改用 `nginx:alpine` 当上游（见下） |
| 拉取成功但启动失败 | 架构不匹配 | `docker pull --platform linux/amd64 <img>` |

**上游镜像的替代方案**：`hashicorp/http-echo` 只是需要一个"秒回 200"的服务。
如果它实在拉不到，可以把 `docker-compose.yml` 里的 `echo` 服务换成：

```yaml
  echo:
    image: nginx:alpine
    # 默认页就是 200，Kong 只关心状态码，不关心 body
```

`nginx:alpine` 是 `library/` 下的官方镜像，任何镜像站都缓存过，命中率最高。

---

## 5. 顺带说下 k6

README 里给的 `dl.k6.io` 源在国内可能很慢。三个备选，按可靠性排序：

```bash
# A. snap（Ubuntu 自带）
sudo snap install k6

# B. 官方 deb 包直连下载后再装
curl -L -o k6.deb https://dl.k6.io/deb/dists/stable/main/binary-amd64/k6_0.49.0_amd64.deb
sudo dpkg -i k6.deb

# C. GitHub release（用你信任的加速前缀替换 <proxy>/）
curl -L -o k6.tgz "<proxy>/https://github.com/grafana/k6/releases/download/v0.49.0/k6-v0.49.0-linux-amd64.tar.gz"
tar -xzf k6.tgz && sudo mv k6-v0.49.0-linux-amd64/k6 /usr/local/bin/
```

装完 `k6 version` 确认。

---

## 6. 全部就绪后的自检

```bash
docker images | grep -E 'kong|redis|http-echo'     # 三个镜像都在
docker compose up -d
docker compose ps                                   # 3 个 kong 都是 running
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8030/echo
```
