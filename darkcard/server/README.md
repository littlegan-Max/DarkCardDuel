# 联机服务器部署

## 这是什么

一个**纯 Python 标准库**的联机服务器。整个 `server/` 目录只有两个文件要传：

```
server/server.py        # 服务器本体（~30 KB）
data/cards.json         # 卡表（~60 KB）
```

不需要 pip install，不需要编译，不需要装 Godot。对方机器上有 Python 3.8+ 就能跑。

## 为什么是 HTTP 而不是自定义 TCP

服务器是借来的、端口是别人帮忙映射的，映射服务的形态不可控：

| 映射类型 | HTTP | 原生 TCP |
|---|---|---|
| TCP 端口映射（frp tcp / |natfrp） | 通 | 通 |
| HTTP 反代 / 隧道（cloudflared / ngrok） | 通 | **不通** |
| 云厂商安全组 + 直接暴露 | 通 | 通 |

HTTP 是唯一在所有形态下都能跑的。而且**不需要改一行客户端代码**。

## 上传

**最省事的做法：直接发那个 zip。**

```bash
python3 tools/pack_server.py     # 生成 build/darkcard-server.zip（23 KB）
```

zip 里只有 3 个文件 + 一份说明，对方解压就能跑，**不需要摆目录结构**：

```
darkcard-server.zip
  server.py        服务器本体
  engine.py        规则引擎（权威结算用）
  cards.json       50 张卡表
  使用说明.txt      给对方看的操作步骤
```

把 zip 传到服务器上（scp / 宝塔面板上传 / 什么方便用什么），解压：

```bash
mkdir -p /opt/darkcard && cd /opt/darkcard
unzip darkcard-server.zip
python3 server.py --port 8737
```

> 不解压也行：`python3 server.py` 需要三个文件在一起；
> 想省事就一起解压。

## 跑起来

```bash
cd /opt/darkcard
python3 server.py --port 8737
```

看到这两行就是好了：

```
[darkcard] 服务器启动 http://0.0.0.0:8737  （卡表 50 张）
[darkcard] 内网穿透请把公网端口映射到 8737/tcp
```

**后台常驻**（推荐 systemd，或者简单的 nohup）：

```bash
cat > /etc/systemd/system/darkcard.service << 'EOF'
[Unit]
Description=DarkCard Duel Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/darkcard
ExecStart=/usr/bin/python3 /opt/darkcard/server.py --port 8737
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now darkcard
systemctl status darkcard
```

嫌麻烦就用 nohup：

```bash
nohup python3 server.py --port 8737 > server.log 2>&1 &
```

## 防火墙

服务器默认绑 `0.0.0.0`（监听所有网卡），这是公网能连上的前提。
Linux 上如果装了 ufw / firewalld，需要放行这个端口：

```bash
# ufw
ufw allow 8737/tcp

# firewalld
firewall-cmd --permanent --add-port=8737/tcp && firewall-cmd --reload

# 云服务器还要在控制台的安全组里放行 8737
```

只想在本机跑（比如调试），可以绑回环地址，不占端口也不对外暴露：

```bash
python3 server.py --host 127.0.0.1 --port 8737
```

> 在 Windows 上用 0.0.0.0 跑会弹「Python 需要允许通过防火墙」的提示。
> 那是 Windows 防火墙的入站规则询问，选「取消」也能跑（只是外部连不进来）。
> 本地测试时用 `--host 127.0.0.1` 就不会弹。

## 端口映射

对方的服务器上跑 8737，让映射把公网端口指到 **8737/tcp**。

映射类型选 **TCP**（HTTP 也能跑，但 TCP 更直接，少一层反代改写规则的风险）。

验证映射通不通，在自己电脑上：

```bash
curl -s http://你的公网地址:公网端口/api/health
# 期望：{"ok": true, "service": "darkcard-duel"}
```

## 客户端连

游戏里：主菜单 → 联机对战 → 填地址和端口 → 昵称 → 连接服务器。

地址填公网地址，端口填映射出来的公网端口。

## 玩法

| 功能 | 怎么用 |
|---|---|
| 快速匹配 | 点「快速匹配」，等另一个人也点，自动配对开局 |
| 开房间 | 点「创建房间」拿到 6 位房号，告诉朋友 |
| 房间列表 | 大厅里能看到所有公开房间，点「加入」 |
| 加好友 | 填对方昵称 → 加好友（双向） |
| 邀请好友 | 先创建房间 → 在好友列表点「邀请」→ 再点「邀请好友进本房间」 |

**昵称即身份**。服务器按昵称找人，所以两个人要起不同的昵称。

## 以后更新了，要不要重新发给对方

**看改了什么，三种情况：**

| 改了什么 | 要不要重发服务器 | 为什么 |
|---|---|---|
| 只改客户端（UI、文案、加个单机模式） | **不用** | 服务器只管规则和房间，不碰界面 |
| 改了**规则**（卡牌数值、结算逻辑、增删卡牌） | **要** | 服务器是权威方，规则不一样两边算出的结果就对不上 |
| 改了**联机协议**（新增命令、改事件结构） | **要** | 消息格式变了，老服务器看不懂新客户端的话 |

关键在 `cards.json` 里的 `rules_version`：改规则时把它 +1（比如 `2.1` → `2.2`），
客户端连上时会跟服务器比对，**不一致直接拒绝并提示「请让服务器更新」**。
所以最坏的情况是「客户端提示版本不符」，而不是「打了一局结果乱七八糟的」。

协议版本同理：`server.py` 里的 `PROTOCOL_VERSION` 和
`scripts/net/net_client.gd` 里的 `PROTOCOL_VERSION` 必须一样，改消息格式时两边一起 +1。

### 不用再发文件了：服务器能自己更新

**服务器默认开着自动更新**——每 10 分钟查一次 GitHub Releases，
有新版就自动下载、解压、**热重载生效**（不重启、不打断任何对局）。

所以以后的流程是：

1. 我们发一个新 Release（带 `darkcard-server.zip` 资产）
2. 服务器自己发现并更新，**对方完全不用参与**
3. 最多 10 分钟后生效

对方想手动触发也行：

```bash
bash update.sh          # 更新到最新版
bash update.sh --check  # 只看有没有新版
```

`update.sh` 走的也是同一条路：下载 → 覆盖解压（保留 `store.json`）→ 热重载 → 健康检查。

### 各类更新的覆盖范围

服务器端的更新**按改动的内容分三层**，处理方式不同：

| 改动落在哪 | 例子 | 服务器怎么处理 | 会不会打断对局 |
|---|---|---|---|
| **规则层** | `engine.py`、`cards.json`（改卡牌数值、改结算逻辑） | **热重载**：换掉引擎与卡表，进程不动 | 不会。正在打的局按旧规则打完 |
| **进程层** | `server.py`、新增的服务器模块（改匹配逻辑、加新命令） | 等没人打牌时**重启进程**（`execv`，PID 不变，systemd 无感） | 只在没人在打牌时重启 |
| **依赖层** | `requirements.txt`（新增第三方库） | 自动 `pip install` | 不会 |

> 为什么要分层：Python 不能热替换自己正在跑的模块。
> `server.py` 改了必须重启进程才生效——所以更新器会**先判断改动落在哪一层**，
> 只对规则层用热重载，避免出现「代码更新了但新功能没上」这种静默失败。

判定是按文件内容算哈希得出的（`sha256`），只覆盖真正变了的文件。
解压用的是**黑名单**：除 `store.json`（玩家数据）、日志、临时文件外，
包里有什么装什么——所以以后新增服务器模块文件也能自动到位。

### 客户端（APK / EXE）不在自动更新范围内

服务器能自己更新，**客户端不行**——APK/EXE 得你手动重新发一次。

不过客户端连上服务器时会比对游戏版本，如果服务器比你这份新，
大厅会提示「服务器已更新到 vX，建议更新后再来」，不会让你稀里糊涂地打一场。

### 热重载：为什么不重启也能安全更新

服务器**每局对局锁定引擎版本**：

- 正在打的局持有的 `Game` 实例指向旧卡表和旧类，热重载碰不到它
  → 那一局**按旧规则正常打完**
- 之后**新开的局**才用新规则
- 老客户端会被 `rules_version` 握手挡住（提示「请让服务器更新」）

所以不会出现「一半人用新规则、一半人用旧规则」的对局。

热重载前会**先验证新代码能加载**：万一新 `engine.py` 有语法错误，
服务器保持旧代码继续跑，不会挂掉。验证过了才切换。

如果热重载失败（极少见），自动更新会退回到「等没人打牌时重启」。

### 什么时候还是得找他

| 情况 | 要不要找他 |
|---|---|
| 常规发版 | **不用**，服务器自己更新 |
| 改了规则 / 协议 | 不用，但**客户端也要一起更新**（版本握手会挡住老客户端） |
| 服务器连不上 GitHub | 要，用 `bash update.sh --url <直链>` 手动指定 |
| 改端口 / 改存储路径 | 要，得改启动参数 |

### 可调的环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `DARKCARD_UPDATE_URL` | GitHub Releases | 更新包下载地址（自建镜像、服务器连不上 GitHub 时用） |
| `DARKCARD_UPDATE_TAG` | 空 | 强制认为某个版本可用（测试用） |
| `DARKCARD_UPDATE_INTERVAL` | `600`（秒） | 检查间隔 |
| `--no-auto-update` | 关 | 启动参数：完全关掉自动更新 |

### 验证

```bash
curl -s http://公网地址:公网端口/api/health
```

服务器启动时会打印自己的版本：

```
[darkcard] 服务器启动 http://0.0.0.0:8737  （卡表 50 张）
[darkcard] 规则版本 2.1 · 协议版本 1
[darkcard] 自动更新已开启：每 10 分钟查一次，有新版自动热重载（不重启）
```

### 不用重发的情况

只改客户端的话，游戏包重新出（APK / EXE）就行，服务器原封不动。
那种情况下服务器上的 `rules_version` 没变，客户端版本也没变，不会有任何影响。

## 服务器上都有什么

| 能力 | 实现位置 |
|---|---|
| 匹配 / 开房间 / 房间列表 | `Hub.enqueue` / `cmd_create_room` / `list_rooms` |
| 在线人数 | `Hub.online_count`，150 秒无请求视为离线 |
| 好友（双向） | `Store.add_friend`，落盘到 `store.json` |
| 邀请 | `Hub.invite`，对方离线时暂存，上线补发 |
| 断线判负 | 对局中有人离开 → 另一方直接赢 |
| 超时兜底 | 看门狗线程，20 秒没人出牌就自动替他出（优先出运） |
| 权威结算 | `train/engine.py`（与客户端 GDScript 内核逐条对齐） |

## 安全边界

服务器是**权威方**：出牌合法性、最终状态、胜负都由服务器裁定，客户端改不了。

但服务器**没有做**这些（内网娱乐够用，不适合公网运营）：

- 密码 / 验证码：谁都能注册
- 昵称唯一性：重名会加好友到旧号上（已按「最新注册优先」缓解，但没根治）
- 限流 / 防刷
- TLS：走明文 HTTP。映射是公网的话，流量是可读的

要长期公网跑，至少加一条：**用 nginx / caddy 在前面做 TLS 终结**，客户端地址填 `https://` 域名。

## 排查

| 现象 | 原因 |
|---|---|
| 客户端显示「连接失败」 | 映射没通 / 端口填错 / 服务器没起 |
| `curl /api/health` 通但游戏连不上 | 客户端地址填了内网 IP，要填公网地址 |
| 一直「排队中」 | 另一个人没点匹配，或者两人昵称相同被当成同一人 |
| 对局卡住不结算 | 一方掉线了，等 20 秒服务器会自动替他出牌 |
| 双方血量/运对不上 | 客户端会弹「状态不一致」警告并打印详情，这是两个内核漂移了，要立刻报 |

服务器日志：

```bash
tail -f /opt/darkcard/server.log
# 或者
journalctl -u darkcard -f
```

开 verbose：

```bash
DC_VERBOSE=1 python3 server.py --port 8737
```

## 数据

`store.json` 存玩家档案和好友关系（不含对局）。删了就是重置所有玩家和好友关系。

对局状态只在内存，服务器重启即失效——正在打的对局会判负。

## 自测

服务器改完先跑一遍：

```bash
python3 server/test_server.py    # 39 项：注册/房间/匹配/好友/邀请/断线
```

端到端（需要 Godot）：

```bash
python3 tools/run_online_test.py  # 起服务器 + 两个真客户端打 12 回合，逐回合对账
```
