# IDURAR ERP CRM — Azure App Service 容器部署

## 项目架构

```
Azure App Service (Linux B1)
├── mongodb 容器   mongo:7                    (数据存容器本地 /data/db)
└── app 容器       idurar-app:latest          (一体化: nginx + Node.js)
    ├── nginx      静态前端 + 反向代理
    └── Node.js    后端 API (port 8888)
```

## 前置条件

- Azure CLI 已安装并登录
  ```bash
  az login
  az account show
  ```
- Docker Desktop 已安装
  ```bash
  docker --version
  ```
- 项目代码已克隆到本地

---

## 一、创建 Azure 资源

### 1.1 注册资源提供程序

> 首次使用需要注册，已注册的可跳过。

```bash
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.Web
```

等待注册完成（约 2-5 分钟）：

```bash
az provider show --namespace Microsoft.ContainerRegistry --query "registrationState" -o tsv
az provider show --namespace Microsoft.Web --query "registrationState" -o tsv
```

### 1.2 创建资源组

```bash
az group create \
  --name idurar-erp-crm-rg \
  --location eastasia
```

### 1.3 创建容器镜像仓库 (ACR)

```bash
az acr create \
  --resource-group idurar-erp-crm-rg \
  --name iduraracr \
  --sku Basic \
  --admin-enabled true
```

> ACR 名称需全局唯一，如 `iduraracr` 被占用请更换。

### 1.4 创建 App Service Plan

```bash
az appservice plan create \
  --resource-group idurar-erp-crm-rg \
  --name idurar-asp \
  --sku B1 \
  --is-linux
```

| SKU | CPU | 内存 | 价格（约） |
|-----|-----|------|-----------|
| B1  | 1核 | 1.75 GB | $13/月 |
| B2  | 2核 | 3.5 GB  | $27/月 |
| B3  | 4核 | 7 GB    | $54/月 |

---

## 二、构建并推送 Docker 镜像

### 2.1 登录 ACR

```bash
az acr login --name iduraracr
```

### 2.2 构建一体化镜像

> 镜像包含：nginx（静态前端） + Node.js 后端 + 自动数据库初始化。

```bash
docker build \
  -t iduraracr.azurecr.io/idurar-app:latest \
  -f Dockerfile \
  .
```

### 2.3 推送到 ACR

```bash
docker push iduraracr.azurecr.io/idurar-app:latest
```

---

## 三、编写 docker-compose 配置

创建 `azure-docker-compose.yml`：

```yaml
services:
  mongodb:
    image: mongo:7
    restart: unless-stopped
    environment:
      MONGO_INITDB_DATABASE: idurar

  app:
    image: iduraracr.azurecr.io/idurar-app:latest
    restart: unless-stopped
    ports:
      - "80:80"
    depends_on:
      - mongodb
    environment:
      NODE_ENV: production
      PORT: "8888"
      DATABASE: mongodb://mongodb:27017/idurar
      JWT_SECRET: ${JWT_SECRET}
      OPENSSL_CONF: /dev/null
      PUBLIC_SERVER_FILE: http://localhost:8888/
```

> **说明**：
> - `mongodb` 服务使用官方 `mongo:7` 镜像，数据存储在容器本地文件系统 `/data/db`。
> - `app` 服务是自制的一体化镜像，启动后自动连接 MongoDB、初始化数据库、启动 nginx 和 Node.js 后端。
> - `${JWT_SECRET}` 通过 App Settings 注入，避免明文硬编码。

---

## 四、部署到 App Service

### 4.1 创建 Web App

```bash
az webapp create \
  --resource-group idurar-erp-crm-rg \
  --plan idurar-asp \
  --name idurar-erp-crm \
  --multicontainer-config-type compose \
  --multicontainer-config-file azure-docker-compose.yml
```

> App Service 名称需全局唯一，如 `idurar-erp-crm` 被占用请更换。

### 4.2 获取 ACR 密码

```bash
az acr credential show \
  --name iduraracr \
  --query "passwords[0].value" \
  -o tsv
```

### 4.3 配置环境变量

```bash
az webapp config appsettings set \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --settings \
    DOCKER_REGISTRY_SERVER_URL="https://iduraracr.azurecr.io" \
    DOCKER_REGISTRY_SERVER_USERNAME="iduraracr" \
    DOCKER_REGISTRY_SERVER_PASSWORD="<替换为4.2获取的密码>" \
    WEBSITES_PORT="80" \
    JWT_SECRET="<替换为随机安全字符串>"
```

> 生成安全 JWT_SECRET：
> ```bash
> powershell -Command "[guid]::NewGuid().ToString() + [guid]::NewGuid().ToString()"
> ```

### 4.4 重启生效

```bash
az webapp restart \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm
```

---

## 五、验证部署

### 5.1 检查服务状态

```bash
az webapp show \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --query "state" -o tsv
```

输出 `Running` 即正常运行。

### 5.2 测试前端

```bash
curl -I https://idurar-erp-crm.azurewebsites.net/
```

预期返回 `HTTP/1.1 200 OK`。

### 5.3 测试后端 API

```bash
curl -I https://idurar-erp-crm.azurewebsites.net/api
```

预期返回 `HTTP/1.1 401 Unauthorized`（JWT 认证中间件正常拦截未授权请求）。

### 5.4 浏览器访问

打开 `https://idurar-erp-crm.azurewebsites.net/`，使用默认管理员账号登录：

| 字段 | 值 |
|------|-----|
| Email | `admin@demo.com` |
| 密码 | `admin123` |

---

## 六、后续更新部署

代码变更后重新部署：

```bash
# 1. 重新构建镜像
docker build -t iduraracr.azurecr.io/idurar-app:latest -f Dockerfile .

# 2. 推送到 ACR
docker push iduraracr.azurecr.io/idurar-app:latest

# 3. 重启应用（自动拉取最新镜像）
az webapp restart \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm
```

---

## 七、查看日志

### 7.1 启用容器日志

```bash
az webapp log config \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --docker-container-logging filesystem
```

### 7.2 实时查看日志

```bash
az webapp log tail \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm
```

---

## 八、数据持久化（可选）

当前 MongoDB 数据存储在容器本地，**重新部署镜像会丢失数据**。如需持久化，使用 Azure Storage 挂载：

```bash
# 1. 创建存储账号
az storage account create \
  --resource-group idurar-erp-crm-rg \
  --name idurarstorage \
  --sku Standard_LRS \
  --location eastasia

# 2. 创建文件共享
az storage share create \
  --account-name idurarstorage \
  --name mongo-data

# 3. 挂载到 App Service
az webapp config storage-account add \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --custom-id mongo-data \
  --storage-type AzureFiles \
  --account-name idurarstorage \
  --share-name mongo-data \
  --mount-path /data/db
```

---

## 九、清理资源

```bash
az group delete --name idurar-erp-crm-rg --yes --no-wait
```

---

## 涉及文件

| 文件 | 说明 |
|------|------|
| `Dockerfile` | 一体化镜像构建文件（前端构建 + 后端 + nginx） |
| `docker-entrypoint.sh` | 容器入口脚本（等待 MongoDB → 初始化数据库 → 启动 nginx + Node.js） |
| `nginx.conf` | nginx 配置（静态文件 + 反向代理 /api → 127.0.0.1:8888） |
| `azure-docker-compose.yml` | Azure App Service 多容器编排配置 |
