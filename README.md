# 暗牌技能对战（Dark Card Duel）

单机 1v1 同时翻牌的读心卡牌游戏。50 张技能牌、10 阶段结算管线、可被列反制、连招、dot、盾。
Godot 4.7.2 + GDScript；同一套规则另有一份 Python 镜像实现，用于自博弈训练。

> 规则与数值由作者拍板，代码只负责实现。任何规则改动都走「作者裁定 → 双内核同步 → 对拍」的流程。

## 下载

到 [Releases](../../releases) 取最新包：

- `暗牌技能对战.apk` — Android，调试签名。安装时需允许"未知来源"。
- `暗牌技能对战.exe` — Windows 单文件，双击即玩，无需安装。

## 玩法

每回合双方同时扣下并翻开一张牌，然后按固定十阶段结算：
翻转 → 龟派 → 护身符 → 扭转时空 → 反制 → 资源与状态 → 伤害互拼 → 盾保命 → 死亡判定 → 结算。

- 血 10 点（内部 1 血 = 100 定点）、初始 1 运，每回合 +1 运。
- 卡表里每张牌都有**可被列**（哪些牌能挡它），读对对手的出牌方向才能吃到反制收益。
- 伤害互拼不是各打各的：比的是**单回合对对方的伤害总量**，相同则互抵，不同则只有高的生效。
- 首回合只能出「运」。血量归零或代码杀即负。

## 本地运行与构建

需要 Godot 4.7.2（标准版，非 .NET）与对应导出模板。

```bash
# 编辑器里直接跑
godot --path darkcard

# 导出
godot --headless --path darkcard --export-debug  "Android"        "$PWD/darkcard/build/DarkCardDuel.apk"
godot --headless --path darkcard --export-release "Windows Desktop" "$PWD/darkcard/build/DarkCardDuel.exe"
```

## 验证

```bash
bash darkcard/train/verify.sh          # 卡表校验 → GDScript 单测 → Python 对齐 → 特征比对 → 对拍 → 不变量
```

改动规则必须**两个引擎一起改**（`scripts/core/turn_resolver.gd` 与 `train/engine.py` 是同一套规则的镜像），
不一致时不会报错，只会表现为 AI 打得莫名其妙，所以对拍是硬门槛。

`export_parity.py` 里有一份定向牌对清单，专门保证随机跑不到的规则交叉点也被覆盖。

## 目录

```
darkcard/
  data/cards.json              50 张卡表（唯一数据源，含可被列与机制字段）
  scripts/core/                规则内核：结算管线、卡牌结构、状态、合法性判定
  scripts/ui/ scripts/ai/      界面与 AI
  train/                       规则镜像引擎、自博弈训练、对齐/对拍/不变量工具
  tests/ tools/                规则单测与校验工具
暗牌技能对战_立项包/            策划案、技术方案、规则风险清单与变更补丁
```

## 训练

`train/trainer.py` 是自博弈强化学习训练器，策略网络结构见 `train/policy_net.json`，
`train/watch_games.py` 可把对局逐回合打出来看。检查点不进仓库。

## 许可证

代码以 MIT 发布，见 [LICENSE](LICENSE)。卡表数值、规则文本、美术资源版权归作者。
