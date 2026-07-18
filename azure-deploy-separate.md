# IDURAR ERP CRM — Azure 分离部署

## 架构

```
Azure App Service (Linux B1)
└── idurar-app 容器     nginx + Node.js (一体化镜像, 端口 80)

Azure Cosmos DB for MongoDB vCore (M10)
└── idurar-mongo-zwt    MongoDB 7.0, 32GB, eastasia, 公网访问
```

不使用 docker-compose，MongoDB 以 Cosmos DB 托管服务方式部署，应用以单容器方式部署到 App Service，两者独立分开。

---

## 资源清单

| 资源 | 名称 | SKU | 位置 |
|------|------|-----|------|
| 资源组 | `idurar-erp-crm-rg` | — | eastasia |
| App Service Plan | `ASP-idurarerpcrmrg-962e` | B1 (1核/1.75GB) | eastasia |
| Web App | `idurar-erp-crm` | — | eastasia |
| Cosmos DB | `idurar-mongo-zwt` | M10 | eastasia |
| ACR | `myimageszwt` | Basic | eastasia |

---

## 部署步骤

### 1. 创建 Cosmos DB for MongoDB vCore

```bash
# 安装预览扩展
az config set extension.dynamic_install_allow_preview=true
az extension add --name cosmosdb-preview

# 生成管理员密码
$mongoPass = "Idr" + [guid]::NewGuid().ToString("N").Substring(0,20) + "!Az"
$mongoUser = "iduraradmin"

# 创建集群 (M10, 单节点, 无HA, 7.0)
az cosmosdb mongocluster create \
  --cluster-name idurar-mongo-zwt \
  --resource-group idurar-erp-crm-rg \
  --location eastasia \
  --administrator-login $mongoUser \
  --administrator-login-password $mongoPass \
  --server-version 7.0 \
  --shard-node-tier "M10" \
  --shard-node-ha false \
  --shard-node-disk-size-gb 32 \
  --shard-node-count 1

# 开放 Azure 服务访问 (0.0.0.0 表示允许所有 Azure 内部流量)
az cosmosdb mongocluster firewall rule create \
  --cluster-name idurar-mongo-zwt \
  --resource-group idurar-erp-crm-rg \
  --rule-name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

> 创建约需 **10 分钟**，登录 Azure Portal 可查看进度。

### 2. 构建并推送镜像

```bash
# 登录 ACR
az acr login --name myimageszwt

# 构建一体化镜像 (前后端 + nginx)
docker build -t myimageszwt.azurecr.io/idurar-app:latest -f Dockerfile .

# 推送
docker push myimageszwt.azurecr.io/idurar-app:latest
```

### 3. 创建 App Service Plan

```bash
az appservice plan create \
  --resource-group idurar-erp-crm-rg \
  --name idurar-asp \
  --sku B1 \
  --is-linux
```

| SKU | CPU | 内存 | 月价（约） |
|-----|-----|------|-----------|
| F1  | 共用 | 1 GB | 免费 |
| B1  | 1核 | 1.75 GB | $13 |
| B2  | 2核 | 3.5 GB | $27 |
| B3  | 4核 | 7 GB | $54 |

> F1 免费层有每日 60 分钟计算配额，不适合生产。

### 4. 创建 Web App 并配置

```bash
# 创建资源组 (如未创建)
az group create --name idurar-erp-crm-rg --location eastasia

# 启用 ACR admin (如未启用)
az acr update -n myimageszwt --admin-enabled true

# 创建 Web App
az webapp create \
  --resource-group idurar-erp-crm-rg \
  --plan idurar-asp \
  --name idurar-erp-crm \
  --deployment-container-image-name myimageszwt.azurecr.io/idurar-app:latest

# 获取 ACR 密码
$acrPass = az acr credential show --name myimageszwt --query "passwords[0].value" -o tsv

# 获取 Cosmos 连接地址
$connStr = az cosmosdb mongocluster show --cluster-name idurar-mongo-zwt \
  --resource-group idurar-erp-crm-rg --query "properties.connectionString" -o tsv
# 输出类似: mongodb+srv://<user>:<password>@idurar-mongo-zwt.mongocluster.cosmos.azure.com/...

# 组装完整连接字符串 (密码需 URL 编码)
$encPass = [uri]::EscapeDataString($mongoPass)
$DATABASE = "mongodb+srv://iduraradmin:$encPass@idurar-mongo-zwt.mongocluster.cosmos.azure.com/idurar?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000"

# 生成 JWT_SECRET
$JWT_SECRET = [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")

# 获取 ACR 密码
$acrPass = az acr credential show --name myimageszwt --query "passwords[0].value" -o tsv

# 获取 Cosmos 连接地址
$connStr = az cosmosdb mongocluster show --cluster-name idurar-mongo-zwt \
  --resource-group idurar-erp-crm-rg --query "properties.connectionString" -o tsv
# 输出类似: mongodb+srv://<user>:<password>@idurar-mongo-zwt.mongocluster.cosmos.azure.com/...

# 组装完整连接字符串 (密码需 URL 编码)
$encPass = [uri]::EscapeDataString($mongoPass)
$DATABASE = "mongodb+srv://iduraradmin:$encPass@idurar-mongo-zwt.mongocluster.cosmos.azure.com/idurar?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000"

# 生成 JWT_SECRET
$JWT_SECRET = [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
```

### 5. 配置环境变量

> 因连接字符串含 `&` 字符，通过 JSON 文件注入避免 shell 截断：

```bash
# 创建应用设置 JSON 文件
$settings = @(
  @{name="DOCKER_REGISTRY_SERVER_URL";      value="https://myimageszwt.azurecr.io"}
  @{name="DOCKER_REGISTRY_SERVER_USERNAME"; value="myimageszwt"}
  @{name="DOCKER_REGISTRY_SERVER_PASSWORD"; value=$acrPass}
  @{name="WEBSITES_PORT";                   value="80"}
  @{name="NODE_ENV";                        value="production"}
  @{name="PORT";                            value="8888"}
  @{name="DATABASE";                        value=$DATABASE}
  @{name="JWT_SECRET";                      value=$JWT_SECRET}
  @{name="OPENSSL_CONF";                    value="/dev/null"}
  @{name="PUBLIC_SERVER_FILE";              value="https://idurar-erp-crm.azurewebsites.net/"}
)
ConvertTo-Json $settings | Set-Content -Path idurar-appsettings.json

# 应用设置
az webapp config appsettings set \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --settings "@idurar-appsettings.json"

# 重启生效
az webapp restart --resource-group idurar-erp-crm-rg --name idurar-erp-crm
```

### 6. 验证部署

```bash
# 前端: 200
curl -I https://idurar-erp-crm.azurewebsites.net/

# API 拦截: 401 (JWT 认证正常)
curl -I https://idurar-erp-crm.azurewebsites.net/api

# 登录: 200
curl -X POST https://idurar-erp-crm.azurewebsites.net/api/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@admin.com","password":"admin123"}'
```

---

## VSCode Azure 插件部署

### 安装插件

在 VSCode 扩展面板 (`Ctrl+Shift+X`) 搜索安装：

| 插件 | 用途 |
|------|------|
| Azure App Service | 管理 Web App、查看日志、部署容器 |
| Azure Resources | 浏览所有 Azure 资源（可选） |
| Docker | 管理 ACR 镜像（通常已安装） |

### 1. 登录 Azure

- `Ctrl+Shift+P` → `Azure: Sign In`
- 或左侧 Azure 面板（⚡图标）点击 **Sign in to Azure**

### 2. 创建 App Service Plan

1. 左侧 Azure 面板 → **App Services** → 右键你的订阅 → **Create App Service Plan (Linux)**
2. 填写：
   - **Name**: `idurar-asp`
   - **Location**: `East Asia`
   - **Pricing Tier**: `B1 (Basic)` — 1 核 / 1.75 GB
3. 等待创建完成

### 3. 创建 Web App

1. 左侧 Azure 面板 → **App Services** → 右键 `idurar-asp` → **Create Web App (Advanced)**
2. 填写：
   - **Name**: `idurar-erp-crm`（全局唯一，被占用则换名）
   - **Runtime Stack**: 任意（容器模式会覆盖）
   - **OS**: Linux
   - **Publish Model**: Container Image
   - **Container Image Source**: Container Registry
3. 选择 ACR → `myimageszwt` → `idurar-app:latest`
4. 等待创建完成

或通过**命令面板**：

1. `Ctrl+Shift+P` → `Azure App Service: Create Web App (Advanced)`
2. 名称填 `idurar-erp-crm`
3. Runtime Stack 任选（容器模式会覆盖）
4. 选择 Linux + B1 计划

### 4. 配置 Application Settings

左侧 Azure 面板 → **App Services** → 展开 `idurar-erp-crm` → 右键 → **Application Settings**

添加以下设置：

| Name | Value |
|------|-------|
| `DOCKER_REGISTRY_SERVER_URL` | `https://myimageszwt.azurecr.io` |
| `DOCKER_REGISTRY_SERVER_USERNAME` | `myimageszwt` |
| `DOCKER_REGISTRY_SERVER_PASSWORD` | *ACR Access Key 密码* |
| `WEBSITES_PORT` | `80` |
| `NODE_ENV` | `production` |
| `PORT` | `8888` |
| `DATABASE` | *Cosmos DB 连接字符串* |
| `JWT_SECRET` | *随机安全字符串* |
| `OPENSSL_CONF` | `/dev/null` |
| `PUBLIC_SERVER_FILE` | `https://idurar-erp-crm.azurewebsites.net/` |

> **获取 ACR 密码**：Azure 面板 → **Container Registries** → 右键 `myimageszwt` → **View Properties** 或 Portal 中 Access Keys。
>
> **获取连接字符串**：Azure 面板 → Cosmos DB 中右键 `idurar-mongo-zwt` → 属性查看，或 Azure Portal 中复制后填入。

### 5. 部署镜像

**图形化操作**：

1. 左侧 Azure 面板，展开 **App Services**
2. 右键 `idurar-erp-crm` → **Deploy to Web App**
3. 选择 **Container Registry** → `myimageszwt` → `idurar-app:latest`
4. 提示确认覆盖，点 **Deploy**

**命令面板操作**：

1. `Ctrl+Shift+P` → `Azure App Service: Deploy to Web App`
2. 选择 `idurar-erp-crm`
3. 选择 `myimageszwt` → `idurar-app:latest`

### 6. 查看日志

- 右键 `idurar-erp-crm` → **Start Streaming Logs**
- 或右键 → **View Files** 查看日志文件

### 7. 访问验证

- 右键 `idurar-erp-crm` → **Browse Website** 打开前端
- 登录：`admin@admin.com` / `admin123`

---

## 登录信息

| 字段 | 值 |
|------|-----|
| 地址 | `https://idurar-erp-crm.azurewebsites.net/` |
| Email | `admin@admin.com` |
| 密码 | `admin123` |

---

## 容器启动流程

镜像入口脚本 `docker-entrypoint.sh` 启动顺序：

1. 等待 MongoDB 就绪（最多 30 次 × 3 秒）
2. 执行 `node src/setup/setup.js` 初始化数据库（创建管理员、默认设置、税率等）
3. 启动 nginx（端口 80，静态文件 + `/api` 反向代理到 `127.0.0.1:8888`）
4. 启动 Node.js 后端（端口 8888）

---

## 更新重新部署

**CLI 方式**：

```bash
docker build -t myimageszwt.azurecr.io/idurar-app:latest -f Dockerfile .
docker push myimageszwt.azurecr.io/idurar-app:latest
az webapp restart --resource-group idurar-erp-crm-rg --name idurar-erp-crm
```

**VSCode 方式**：

1. 终端执行 `docker build -t myimageszwt.azurecr.io/idurar-app:latest -f Dockerfile .`
2. 左侧 Docker 面板 → Registries → `myimageszwt` → 右键 → **Push** 推送 `idurar-app:latest`
3. 左侧 Azure 面板 → App Services → 右键 `idurar-erp-crm` → **Restart**

**登录信息**：`admin@admin.com` / `admin123`

---

## 查看日志

```bash
# 启用容器日志
az webapp log config \
  --resource-group idurar-erp-crm-rg \
  --name idurar-erp-crm \
  --docker-container-logging filesystem

# 实时查看
az webapp log tail --resource-group idurar-erp-crm-rg --name idurar-erp-crm
```

---

## 清理资源

```bash
az group delete --name idurar-erp-crm-rg --yes --no-wait
```

---

## 注意事项

- Cosmos DB M10 为最低付费规格，按量计费。如需降低成本可换用 **RU-based serverless**（但 mongoose 兼容性较差）或 ACI 自建 MongoDB。
- 数据库初始化是幂等的（setup.js 已有 admin 时报错跳过），重启不会重复创建。
- 当前无数据持久化挂载，重新部署镜像**不会丢失数据库**（数据在 Cosmos DB 托管存储中）。
