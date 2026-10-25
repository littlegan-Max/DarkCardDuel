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
