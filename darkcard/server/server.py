"""暗牌技能对战 · 联机服务器（纯标准库）

为什么是 Python 标准库：
  服务器是借来的机器，只开放了 ip+端口 映射。上传体积必须小、不能装依赖。
  整个 server/ 目录只有本文件 + cards.json，拷上去 python3 server.py 就能跑。

为什么服务器用 Python 引擎、客户端用 GDScript：
  双方各跑各自语言的内核，服务器做「权威裁定」，客户端本地重放事件流。
  - 服务器：判定出牌是否合法、结算出权威状态快照（不产生事件）
  - 客户端：用与单机完全相同的 GDScript 内核重放同一组牌，产出事件流驱动 UI
  两边内核已有 800 局 / 10336 步双引擎对拍 0 差异，所以「服务器裁定 == 客户端重放」成立。
  客户端每回合还会拿服务器的状态快照跟自己的本地结果对一次账，不一致就立刻报出来。

协议：JSON over HTTP（一条请求一个 JSON 响应）。
  选 HTTP 而不是自定义 TCP，是因为 HTTP 能穿过任何形态的端口映射 / 反代 / CDN，
  而原生 TCP 端口在很多映射服务里不保证透传。

命令（POST /api/<cmd>，或 GET /api/<cmd>?k=v 便于 curl 调试）：
  register    {name}                  -> {token, player_id, name}
  login       {token}                 -> {token, player_id, name, online_count}
  rename      {player_id, name}       -> {ok, name}
  online      {}                      -> {online_count, rooms: [...]}
  create_room {player_id}             -> {room_id}
  join_room   {player_id, room_id}    -> {ok, room_id}
  list_rooms  {}                      -> {rooms: [...]}
  matchmake   {player_id}             -> {ok, queued, room_id}   快速匹配
  cancel_match{player_id}             -> {ok}
  add_friend  {player_id, name}       -> {ok, friend}
  remove_friend {player_id, friend_id}-> {ok}
  friends     {player_id}             -> {friends: [...]}
  invite      {player_id, friend_id, room_id} -> {ok}
  play        {player_id, room_id, card} -> {ok}
  poll        {player_id, token, seq} -> {events: [...], seq, online_count}
  leave       {player_id}             -> {ok}

事件（poll 返回的 events，每项带 seq 递增序号，客户端拿 seq 续拉）：
  room_joined {room_id, seat, players:[{id,name}]}
  game_start  {room_id, seed, rules_version, deadline}
  turn_ready  {room_id, turn, deadline, must_play:[...]}   该谁出牌了
  turn_resolve{room_id, turn, cards:[a,b], state:{...}, deadline}
  game_over   {room_id, winner_seat, reason}
  player_join {room_id, player:{id,name}}
  player_left {room_id, player_id}
  invite      {from_name, room_id}
  friend_add  {friend}
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 部署时希望「三个文件放一起就能跑」，而不是让人摆对 server/ data/ train/ 的层级。
# 所以先找同目录，找不到再回退到仓库里的原始布局。
def _pick(*candidates: str) -> str:
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return candidates[0] if candidates else ""


CARDS_PATH = _pick(
    os.path.join(HERE, "cards.json"),
    os.path.join(ROOT, "data", "cards.json"),
)
ENGINE_PATH = _pick(
    os.path.join(HERE, "engine.py"),
    os.path.join(ROOT, "train", "engine.py"),
)
STORE_PATH = os.path.join(HERE, "store.json")

PASS_ID = "pass"

# 协议版本：客户端与服务器之间的消息格式。
# 改了协议（新增命令 / 改事件结构）就 +1，服务器会拒绝不匹配的客户端。
PROTOCOL_VERSION = 1

TURN_SECONDS = 20.0
POLL_HOLD_SECONDS = 15.0
ROOM_IDLE_SECONDS = 1800.0
ONLINE_TTL = 150.0


# ---------------------------------------------------------------- 规则引擎

def _load_engine():
    """加载 train/engine.py 里的 Python 规则镜像。

    走 importlib 而不是改 sys.path：server/ 与 train/ 平级，
    直接改 sys.path 会污染同进程的其它模块。
    """
    import importlib.util
    import sys

    path = ENGINE_PATH
    if not os.path.exists(path):
        raise RuntimeError(
            "找不到规则引擎：请把 engine.py 放在 server.py 同目录，"
            "或保留仓库里的 train/engine.py 布局（找不到 %s）" % path
        )
    spec = importlib.util.spec_from_file_location("dc_engine", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load engine at %s" % path)
    mod = importlib.util.module_from_spec(spec)
    # 必须先注册到 sys.modules：@dataclass 在处理字段类型时会回查
    # sys.modules[cls.__module__]，没注册会直接抛 AttributeError
    sys.modules["dc_engine"] = mod
    spec.loader.exec_module(mod)
    return mod


_engine = _load_engine()


# ---------------------------------------------------------------- 持久化

class Store:
    """玩家档案与好友关系。

    只存「谁认识谁」「玩家叫什么」这类跨会话要记住的东西；
    对局状态一律在内存，重启即失效（对局本来也不该跨重启续上）。
    """

    def __init__(self, path: str):
        self.path = path
        # 必须是 RLock：save() 会在持锁的临界区里被调用
        self.lock = threading.RLock()
        self.players: dict[str, dict[str, Any]] = {}
        self.friends: dict[str, set[str]] = {}
        self.load()

    def load(self) -> None:
        if not os.path.exists(self.path):
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            return
        for pid, p in (raw.get("players") or {}).items():
            self.players[pid] = {
                "id": pid,
                "name": str(p.get("name", "玩家")),
                "token": str(p.get("token", "")),
                "created": float(p.get("created", 0.0)),
            }
        for pid, names in (raw.get("friends") or {}).items():
            self.friends[pid] = set(str(n) for n in names)

    def save(self) -> None:
        with self.lock:
            data = {
                "players": self.players,
                "friends": {k: sorted(v) for k, v in self.friends.items()},
            }
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def create_player(self, name: str) -> dict[str, Any]:
        with self.lock:
            pid = uuid.uuid4().hex[:12]
            token = uuid.uuid4().hex
            p = {
                "id": pid,
                "name": name,
                "token": token,
                "created": time.time(),   # 重名时用来挑「最新注册」的那个
            }
            self.players[pid] = p
            self.friends.setdefault(pid, set())
            self.save()
        return p

    def find_by_token(self, token: str) -> Optional[dict[str, Any]]:
        with self.lock:
            for p in self.players.values():
                if p["token"] == token:
                    return p
        return None

    def find_by_name(self, name: str) -> Optional[dict[str, Any]]:
        """按名字找玩家。

        重名时取「最新注册」的那个：store.json 是持久化的，
        同一个名字可能堆积多个历史号（重连、改名、反复测试），
        无脑取第一个会导致「加好友加到一个早已不用的旧号上」。
        """
        with self.lock:
            hits = [p for p in self.players.values() if p["name"] == name]
        if not hits:
            return None
        if len(hits) == 1:
            return hits[0]
        return max(hits, key=lambda p: float(p.get("created", 0)))

    def get(self, pid: str) -> Optional[dict[str, Any]]:
        with self.lock:
            return self.players.get(pid)

    def rename(self, pid: str, name: str) -> None:
        with self.lock:
            if pid in self.players:
                self.players[pid]["name"] = name
                self.save()

    def add_friend(self, pid: str, friend_id: str) -> None:
        with self.lock:
            self.friends.setdefault(pid, set()).add(friend_id)
            self.friends.setdefault(friend_id, set()).add(pid)
            self.save()

    def remove_friend(self, pid: str, friend_id: str) -> None:
        with self.lock:
            self.friends.get(pid, set()).discard(friend_id)
            self.friends.get(friend_id, set()).discard(pid)
            self.save()

    def friend_ids(self, pid: str) -> list[str]:
        with self.lock:
            return sorted(self.friends.get(pid, set()))


# ---------------------------------------------------------------- 房间

class Room:
    """一个房间 = 一场对局。

    房间持有权威状态：两名玩家各提交一张牌后，服务器用 Python 内核
    跑一次结算，得到权威状态快照，再广播给双方。
    客户端拿到两张牌后用 GDScript 内核本地重放，事件流与单机完全一致。
    """

    def __init__(self, room_id: str, owner_id: str, mode: str = "room"):
        self.id = room_id
        self.owner_id = owner_id
        self.mode = mode          # "room"（自建）| "match"（快速匹配）
        self.players: list[str] = []   # player ids，seat 0 / seat 1
        self.names: dict[str, str] = {}
        self.picks: dict[int, str] = {}
        self.game: Any = None      # 权威状态，_start_game 时由 Hub.new_game() 填入
        self.turn = 0
        self.started = False
        self.over = False
        self.winner = -1
        self.reason = ""
        self.created = time.time()
        self.last_active = time.time()
        self.deadline = 0.0
        self.lock = threading.Lock()

    # ---- 席位 ----
    def seat_of(self, pid: str) -> int:
        return self.players.index(pid) if pid in self.players else -1

    def is_full(self) -> bool:
        return len(self.players) >= 2

    def both_picked(self) -> bool:
        return len(self.picks) >= 2

    def set_game(self, game: Any) -> None:
        self.game = game

    # ---- 回合推进 ----
    def start(self, game: Any) -> None:
        self.set_game(game)
        self.turn = 0
        self.picks.clear()
        self.started = True
        self.over = False
        self.winner = -1
        self.reason = ""
        self.deadline = time.time() + TURN_SECONDS

    def pick(self, seat: int, card: str) -> Optional[str]:
        """记录一张出牌。返回 None 成功，返回字符串表示拒绝原因。"""
        if self.over:
            return "对局已结束"
        if seat < 0 or seat > 1:
            return "你不在这个房间里"
        if seat in self.picks:
            return "本回合已经出过牌了"
        if self.game is None:
            return "对局还没开始"
        if not self.game.can_play(seat, card):
            return self.game.play_reason(seat, card)
        self.picks[seat] = card
        self.last_active = time.time()
        return None

    def autopick(self, seat: int) -> Optional[str]:
        """超时替玩家出牌：能出运就出运，否则出第一张合法牌。"""
        if self.game is None:
            return None
        legal = self.game.legal_cards(seat)
        if not legal:
            return None
        pick = "yun" if "yun" in legal else legal[0]
        self.picks[seat] = pick
        return pick

    def resolve(self) -> Optional[dict[str, Any]]:
        """结算本回合。返回给客户端的消息体，或 None（牌不齐）。"""
        if not self.both_picked():
            return None
        a = self.picks.get(0, PASS_ID)
        b = self.picks.get(1, PASS_ID)
        # 权威结算：Python 内核跑一遍，产出最终状态
        self.game.play_turn(a, b)
        self.picks.clear()
        self.turn += 1
        self.last_active = time.time()
        if self.game.over:
            self.over = True
            self.winner = self.game.winner
            self.reason = self.game.end_reason
        else:
            self.deadline = time.time() + TURN_SECONDS
        return {
            "type": "turn_resolve",
            "room_id": self.id,
            "turn": self.turn,
            "cards": [a, b],
            "state": self.snapshot(),
            "deadline": self.deadline,
        }

    def snapshot(self) -> dict[str, Any]:
        """权威状态快照。客户端用它跟自己的本地重放结果对账。"""
        g = self.game
        return {
            "turn": g.turn,
            "over": g.over,
            "winner": g.winner,
            "end_reason": g.end_reason,
            "hp": [g.p0.hp, g.p1.hp],
            "yun": [g.p0.yun, g.p1.yun],
            "shields": [g.p0.shields, g.p1.shields],
        }

    def is_idle(self) -> bool:
        return time.time() - self.last_active > ROOM_IDLE_SECONDS

class Hub:
    """全局状态中心。所有改动都在 self.lock 保护下进行。"""

    def __init__(self, store: Store):
        self.store = store
        self.lock = threading.RLock()
        self.rooms: dict[str, Room] = {}
        self.player_room: dict[str, str] = {}
        self.player_events: dict[str, list[dict[str, Any]]] = {}
        self.player_seq: dict[str, int] = {}
        self.online: dict[str, dict[str, Any]] = {}   # pid -> {name, seen}
        self.pending_invites: dict[str, list[dict[str, Any]]] = {}
        self.match_queue: list[str] = []
        self.db = _engine.DB(CARDS_PATH)
        # 规则版本：来自卡表。客户端拿它跟自己的卡表比对，
        # 不一致说明服务器上的卡表是旧版（改了规则但服务器没更新），
        # 这时两边会用不同规则结算同一手牌，必须挡住。
        self.rules_version = str(getattr(self.db, "version", ""))
        # 游戏版本：客户端拿它跟自己的版本比对，
        # 不一致说明服务器上跑的是新版本，客户端该更新了
        #（服务器端的更新是自动的，客户端这边的 APK/EXE 还得手动发）
        self.game_version = _local_game_version()

    # ---- 在线人数 ----
    def online_count(self) -> int:
        cutoff = time.time() - ONLINE_TTL
        with self.lock:
            return sum(1 for v in self.online.values() if v["seen"] >= cutoff)

    def touch(self, pid: str, name: str) -> None:
        with self.lock:
            self.online[pid] = {"name": name, "seen": time.time()}

    def is_online(self, pid: str) -> bool:
        cutoff = time.time() - ONLINE_TTL
        with self.lock:
            v = self.online.get(pid)
            return v is not None and v["seen"] >= cutoff

    # ---- 事件投递（每玩家一条带 seq 的队列）----
    def push(self, pid: str, event: dict[str, Any]) -> None:
        with self.lock:
            seq = self.player_seq.get(pid, 0) + 1
            self.player_seq[pid] = seq
            ev = dict(event)
            ev["seq"] = seq
            q = self.player_events.setdefault(pid, [])
            q.append(ev)
            # 队列封顶，防止长时间挂机把内存吃满
            if len(q) > 400:
                del q[:200]

    def drain(self, pid: str, since: int) -> list[dict[str, Any]]:
        with self.lock:
            q = self.player_events.get(pid, [])
            return [e for e in q if int(e.get("seq", 0)) > since]

    # ---- 房间 ----
    def new_game(self) -> Any:
        return _engine.Game(self.db)

    def create_room(self, owner_id: str, mode: str = "room") -> Room:
        with self.lock:
            rid = uuid.uuid4().hex[:6].upper()
            room = Room(rid, owner_id, mode)
            self.rooms[rid] = room
            self.player_room[owner_id] = rid
            return room

    def room_of(self, pid: str) -> Optional[Room]:
        with self.lock:
            rid = self.player_room.get(pid)
            return self.rooms.get(rid) if rid else None

    def join(self, room: Room, pid: str, name: str) -> bool:
        with self.lock:
            if room.is_full():
                return False
            room.players.append(pid)
            room.names[pid] = name
            self.player_room[pid] = room.id
            return True

    def leave_room(self, pid: str) -> None:
        with self.lock:
            rid = self.player_room.pop(pid, None)
            room = self.rooms.get(rid) if rid else None
            if room is None:
                return
            if pid in room.players:
                seat = room.players.index(pid)
                room.players.remove(pid)
                room.names.pop(pid, None)
                # 对局中有人跑了：这一局判负，对方直接赢
                if room.started and not room.over:
                    room.over = True
                    room.winner = 1 - seat
                    room.reason = "opponent_left"
                    for other in room.players:
                        self.push(other, {
                            "type": "game_over",
                            "room_id": room.id,
                            "winner_seat": room.players.index(other),
                            "reason": "opponent_left",
                        })
                elif room.players:
                    for other in room.players:
                        self.push(other, {
                            "type": "player_left",
                            "room_id": room.id,
                            "player_id": pid,
                        })
            if not room.players:
                self.rooms.pop(room.id, None)

    def list_rooms(self) -> list[dict[str, Any]]:
        with self.lock:
            out = []
            for room in self.rooms.values():
                if room.mode != "room" or room.is_full():
                    continue
                out.append({
                    "room_id": room.id,
                    "owner": room.names.get(room.owner_id, "?"),
                    "count": len(room.players),
                    "players": [room.names.get(p, "?") for p in room.players],
                })
            return out

    # ---- 快速匹配 ----
    def enqueue(self, pid: str) -> Optional[Room]:
        with self.lock:
            if pid in self.match_queue:
                return None
            self.match_queue.append(pid)
            if len(self.match_queue) < 2:
                return None
            a = self.match_queue.pop(0)
            b = self.match_queue.pop(0)
            room = Room(uuid.uuid4().hex[:6].upper(), a, "match")
            self.rooms[room.id] = room
            for pid2 in (a, b):
                p = self.store.get(pid2)
                if p:
                    room.players.append(pid2)
                    room.names[pid2] = p["name"]
                self.player_room[pid2] = room.id
            return room

    def dequeue(self, pid: str) -> None:
        with self.lock:
            if pid in self.match_queue:
                self.match_queue.remove(pid)

    # ---- 好友与邀请 ----
    def add_friend(self, pid: str, name: str) -> Optional[dict[str, Any]]:
        target = self.store.find_by_name(name)
        if target is None:
            return None
        self.store.add_friend(pid, target["id"])
        self.push(target["id"], {"type": "friend_add", "friend": self.name_of(pid)})
        return target

    def name_of(self, pid: str) -> str:
        p = self.store.get(pid)
        return p["name"] if p else "?"

    def friends_of(self, pid: str) -> list[dict[str, Any]]:
        out = []
        for fid in self.store.friend_ids(pid):
            p = self.store.get(fid)
            if not p:
                continue
            out.append({
                "id": fid,
                "name": p["name"],
                "online": self.is_online(fid),
            })
        return out

    def invite(self, pid: str, friend_id: str, room_id: str) -> bool:
        with self.lock:
            room = self.rooms.get(room_id)
            if room is None or pid not in room.players:
                return False
            ev = {"type": "invite", "from_name": self.name_of(pid), "room_id": room_id}
            if self.is_online(friend_id):
                self.push(friend_id, ev)
            else:
                self.pending_invites.setdefault(friend_id, []).append(ev)
            return True

    def take_pending_invites(self, pid: str) -> list[dict[str, Any]]:
        with self.lock:
            evs = self.pending_invites.pop(pid, [])
            for ev in evs:
                seq = self.player_seq.get(pid, 0) + 1
                self.player_seq[pid] = seq
                e = dict(ev)
                e["seq"] = seq
                self.player_events.setdefault(pid, []).append(e)
            return evs


# ---------------------------------------------------------------- 请求处理

    def has_active_match(self) -> bool:
        """有没有正在进行的对局（自动更新要等它结束再重启）。"""
        for room in self.rooms.values():
            if room.started and not room.over:
                return True
        return False

    # ---- 热重载：不重启就换掉规则 ----

    def hot_reload(self) -> tuple[bool, str]:
        """热重载规则引擎与卡表，不重启进程。

        安全的关键：**每局对局锁定引擎版本**。
        正在打的局持有的 Game 实例指向旧的 DB 与旧的类，热重载不会影响它，
        所以那一局会按旧规则正常打完；之后新开的局才用新规则。
        配合 rules_version 握手（老客户端会被挡），不会出现两边规则不一致。

        先在临时模块里验证新代码能加载，验证过了才切换：
        万一新 engine.py 有语法错误，服务器保持旧代码继续跑，不会挂掉。
        """
        import importlib.util
        import sys

        try:
            spec = importlib.util.spec_from_file_location("dc_engine_new", ENGINE_PATH)
            if spec is None or spec.loader is None:
                return False, "无法加载 %s" % ENGINE_PATH
            mod = importlib.util.module_from_spec(spec)
            sys.modules["dc_engine_new"] = mod
            spec.loader.exec_module(mod)          # 这里抛异常就是新代码有问题
            new_db = mod.DB(CARDS_PATH)
            if len(new_db.order) == 0:
                return False, "新卡表是空的"
        except Exception as exc:  # noqa: BLE001
            return False, "新代码加载失败：%s" % exc

        global _engine
        old_rules = self.rules_version
        _engine = mod
        self.db = new_db
        self.rules_version = str(getattr(new_db, "version", ""))
        # 正在进行的对局不动：它们的 game 实例还指着旧的 db
        for room in self.rooms.values():
            if not room.started:
                room.set_game(self.new_game())
        print("[darkcard] 热重载完成：规则 %s -> %s（进行中的对局仍按旧规则打完）" % (
            old_rules, self.rules_version), flush=True)
        return True, ""

    def notify_server_updated(self) -> None:
        """告诉在线客户端「服务器换规则了」，让它们重连拿新版本。"""
        for pid in list(self.player_events.keys()):
            self.push(pid, {
                "type": "server_updated",
                "rules_version": self.rules_version,
            })


class Api:
    """把 JSON 命令翻译成 Hub 上的操作。"""

    def __init__(self, hub: Hub):
        self.hub = hub

    def handle(self, cmd: str, body: dict[str, Any]) -> dict[str, Any]:
        fn = getattr(self, "cmd_" + cmd, None)
        if fn is None:
            return {"ok": False, "error": "未知命令: %s" % cmd}
        try:
            return fn(body)
        except Exception as exc:  # noqa: BLE001 - 异常必须变成 JSON 错误，不能让线程死掉
            return {"ok": False, "error": "服务器内部错误: %s" % exc}

    # ---- 身份 ----
    def cmd_register(self, body: dict[str, Any]) -> dict[str, Any]:
        name = str(body.get("name", "")).strip()[:16] or "无名氏"
        p = self.hub.store.create_player(name)
        self.hub.touch(p["id"], name)
        return {
            "ok": True, "token": p["token"], "player_id": p["id"], "name": name,
            "protocol_version": PROTOCOL_VERSION,
            "rules_version": self.hub.rules_version,
            "game_version": self.hub.game_version,
        }

    def cmd_login(self, body: dict[str, Any]) -> dict[str, Any]:
        token = str(body.get("token", ""))
        p = self.hub.store.find_by_token(token)
        if p is None:
            return {"ok": False, "error": "登录已失效，请重新注册"}
        self.hub.touch(p["id"], p["name"])
        return {
            "ok": True, "token": p["token"], "player_id": p["id"], "name": p["name"],
            "online_count": self.hub.online_count(),
            "protocol_version": PROTOCOL_VERSION,
            "rules_version": self.hub.rules_version,
            "game_version": self.hub.game_version,
        }

    def cmd_rename(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        name = str(body.get("name", "")).strip()[:16]
        if not name:
            return {"ok": False, "error": "名字不能为空"}
        self.hub.store.rename(pid, name)
        self.hub.touch(pid, name)
        return {"ok": True, "name": name}

    def cmd_online(self, body: dict[str, Any]) -> dict[str, Any]:
        return {
            "ok": True,
            "online_count": self.hub.online_count(),
            "rooms": self.hub.list_rooms(),
        }

    # ---- 房间 ----
    def cmd_create_room(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        p = self.hub.store.get(pid)
        if p is None:
            return {"ok": False, "error": "请先登录"}
        self.hub.leave_room(pid)
        room = self.hub.create_room(pid)
        room.players.append(pid)
        room.names[pid] = p["name"]
        # 房主自己也要收到入座通知，否则客户端不知道自己的座位号
        self.hub.push(pid, {
            "type": "room_joined", "room_id": room.id, "seat": 0,
            "players": [{"id": pid, "name": p["name"]}],
        })
        return {"ok": True, "room_id": room.id}

    def cmd_join_room(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        rid = str(body.get("room_id", "")).upper()
        room = self.hub.rooms.get(rid)
        if room is None:
            return {"ok": False, "error": "房间不存在"}
        if room.is_full():
            return {"ok": False, "error": "房间已满"}
        p = self.hub.store.get(pid)
        if p is None:
            return {"ok": False, "error": "请先登录"}
        if pid in room.players:
            return {"ok": True, "room_id": room.id}
        self.hub.leave_room(pid)
        self.hub.join(room, pid, p["name"])
        self._seat_player(room, pid, p["name"])
        return {"ok": True, "room_id": room.id}

    def _seat_player(self, room: Room, pid: str, name: str) -> None:
        """玩家入座：广播 room_joined / player_join；满员则开局。"""
        self.hub.push(pid, {
            "type": "room_joined", "room_id": room.id,
            "seat": room.seat_of(pid),
            "players": [{"id": x, "name": room.names.get(x, "?")} for x in room.players],
        })
        for other in room.players:
            if other != pid:
                self.hub.push(other, {
                    "type": "player_join", "room_id": room.id,
                    "player": {"id": pid, "name": name},
                })
        if room.is_full() and not room.started:
            self._start_game(room)

    def _start_game(self, room: Room) -> None:
        room.start(self.hub.new_game())
        for p in room.players:
            self.hub.push(p, {
                "type": "game_start", "room_id": room.id,
                "seed": 0,
                "rules_version": getattr(self.hub.db, "version", ""),
                "deadline": room.deadline,
            })

    def cmd_list_rooms(self, body: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "rooms": self.hub.list_rooms()}

    # ---- 匹配 ----
    def cmd_matchmake(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        p = self.hub.store.get(pid)
        if p is None:
            return {"ok": False, "error": "请先登录"}
        self.hub.leave_room(pid)
        room = self.hub.enqueue(pid)
        if room is None:
            return {"ok": True, "queued": True, "room_id": ""}
        for p2 in room.players:
            self.hub.push(p2, {
                "type": "room_joined", "room_id": room.id,
                "seat": room.seat_of(p2),
                "players": [{"id": x, "name": room.names.get(x, "?")} for x in room.players],
            })
        self._start_game(room)
        return {"ok": True, "queued": False, "room_id": room.id}

    def cmd_cancel_match(self, body: dict[str, Any]) -> dict[str, Any]:
        self.hub.dequeue(str(body.get("player_id", "")))
        return {"ok": True}

    # ---- 好友 ----
    def cmd_add_friend(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        name = str(body.get("name", "")).strip()[:16]
        target = self.hub.add_friend(pid, name)
        if target is None:
            return {"ok": False, "error": "找不到叫这个名字的玩家"}
        return {"ok": True, "friend": {"id": target["id"], "name": target["name"]}}

    def cmd_remove_friend(self, body: dict[str, Any]) -> dict[str, Any]:
        self.hub.store.remove_friend(
            str(body.get("player_id", "")),
            str(body.get("friend_id", "")),
        )
        return {"ok": True}

    def cmd_friends(self, body: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "friends": self.hub.friends_of(str(body.get("player_id", "")))}

    def cmd_invite(self, body: dict[str, Any]) -> dict[str, Any]:
        ok = self.hub.invite(
            str(body.get("player_id", "")),
            str(body.get("friend_id", "")),
            str(body.get("room_id", "")),
        )
        if not ok:
            return {"ok": False, "error": "邀请失败：房间不存在或你不在房间里"}
        return {"ok": True}

    # ---- 对局 ----
    def cmd_play(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        rid = str(body.get("room_id", ""))
        card = str(body.get("card", ""))
        room = self.hub.rooms.get(rid)
        if room is None:
            return {"ok": False, "error": "房间不存在"}
        # 规则版本不符就别让这局开始（两边算出来的结果必然对不上）
        client_rules = str(body.get("rules_version", ""))
        if client_rules and client_rules != self.hub.rules_version:
            return {
                "ok": False,
                "error": "游戏版本与服务器不一致（你的是 %s，服务器是 %s），"
                         "请让服务器更新后重试" % (client_rules, self.hub.rules_version),
            }
        seat = room.seat_of(pid)
        with room.lock:
            if not room.started:
                return {"ok": False, "error": "对局还没开始"}
            err = room.pick(seat, card)
            if err:
                return {"ok": False, "error": err}
            msg = room.resolve()
        if msg is not None:
            self._broadcast_resolve(room, msg)
        return {"ok": True}

    def _broadcast_resolve(self, room: Room, msg: dict[str, Any]) -> None:
        for p in room.players:
            self.hub.push(p, msg)
        if room.over:
            for p in room.players:
                self.hub.push(p, {
                    "type": "game_over", "room_id": room.id,
                    "winner_seat": room.players.index(p) if p in room.players else -1,
                    "reason": room.reason,
                })

    def cmd_poll(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        token = str(body.get("token", ""))
        p = self.hub.store.find_by_token(token)
        if p is None:
            return {"ok": False, "error": "登录已失效"}
        self.hub.touch(pid, p["name"])
        since = int(body.get("seq", 0) or 0)
        deadline = time.time() + POLL_HOLD_SECONDS
        events: list[dict[str, Any]] = []
        while time.time() < deadline:
            events = self.hub.drain(pid, since)
            if events:
                break
            time.sleep(0.12)
        if not events:
            # 没有新事件时，把「已排队的离线邀请」补上
            self.hub.take_pending_invites(pid)
            events = self.hub.drain(pid, since)
        return {
            "ok": True,
            "events": events,
            "seq": int(events[-1]["seq"]) if events else since,
            "online_count": self.hub.online_count(),
        }

    def cmd_reload(self, body: dict[str, Any]) -> dict[str, Any]:
        """手动触发热重载。

        只允许从本机调用（127.0.0.1）：这是运维口子，
        绝不能让公网随便一个请求就把服务器规则换掉。
        """
        if not str(body.get("_local", "")) == "1":
            return {"ok": False, "error": "reload 只能在本机执行"}
        ok, err = self.hub.hot_reload()
        if not ok:
            return {"ok": False, "error": err}
        self.hub.notify_server_updated()
        return {"ok": True, "rules_version": self.hub.rules_version}

    def cmd_leave(self, body: dict[str, Any]) -> dict[str, Any]:
        pid = str(body.get("player_id", ""))
        self.hub.dequeue(pid)
        self.hub.leave_room(pid)
        return {"ok": True}


# ---------------------------------------------------------------- 看门狗

class Watchdog(threading.Thread):
    """回合超时看门狗。

    客户端每回合有 20 秒出牌时间；有人不点，服务器替他出（能出运就出运），
    否则整局会卡死在这里等一个人。
    """

    def __init__(self, hub: Hub):
        super().__init__(daemon=True)
        self.hub = hub
        self.stop_flag = threading.Event()

    def run(self) -> None:
        while not self.stop_flag.wait(0.5):
            try:
                self.tick()
            except Exception:  # noqa: BLE001 - 看门狗绝不能死
                pass

    def tick(self) -> None:
        now = time.time()
        with self.hub.lock:
            rooms = list(self.hub.rooms.values())
        for room in rooms:
            with room.lock:
                if not room.started or room.over:
                    continue
                if now < room.deadline:
                    continue
                # 超时：给还没出牌的人自动出牌
                for seat in (0, 1):
                    if seat not in room.picks:
                        room.autopick(seat)
                msg = room.resolve()
                if msg is not None:
                    self.api_broadcast(room, msg)

    def api_broadcast(self, room: Room, msg: dict[str, Any]) -> None:
        for p in room.players:
            self.hub.push(p, msg)
        if room.over:
            for p in room.players:
                self.hub.push(p, {
                    "type": "game_over", "room_id": room.id,
                    "winner_seat": room.players.index(p) if p in room.players else -1,
                    "reason": room.reason,
                })


# ---------------------------------------------------------------- 版本检查

UPDATE_REPO = "littlegan-Max/DarkCardDuel"

# 自动更新的文件分类（决定是热重载还是要重启进程）
# 规则层：改这些只需热重载，不打断任何对局
RULE_FILES = ("engine.py", "cards.json")
# 元信息：改这些不影响运行，不用重启
META_FILES = ("版本.txt", "使用说明.txt", "update.sh")
# 永不覆盖：玩家数据
PRESERVE_FILES = ("store.json",)


def _update_url() -> str:
    """更新包下载地址。

    默认从 GitHub Releases 拿最新版；可以用环境变量 DARKCARD_UPDATE_URL 覆盖
    （自建镜像、服务器连不上 GitHub、或做自动化测试时用）。
    """
    return os.environ.get(
        "DARKCARD_UPDATE_URL",
        "https://github.com/%s/releases/latest/download/darkcard-server.zip" % UPDATE_REPO,
    )


def check_remote_version(timeout: float = 8.0) -> str:
    """查 GitHub 上有没有比本地新的服务器包。

    只查不动：自动更新意味着半夜重启服务器，得由人决定。
    返回空串表示已是最新或查不到。
    """
    import urllib.request

    forced = os.environ.get("DARKCARD_UPDATE_TAG", "").strip()
    if forced:
        return forced
    url = os.environ.get(
        "DARKCARD_UPDATE_API",
        "https://api.github.com/repos/%s/releases/latest" % UPDATE_REPO,
    )
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "darkcard-server"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception:
        return ""
    tag = str(data.get("tag_name", ""))
    if not tag:
        return ""
    local = _local_game_version()
    if local and tag == "v" + local:
        return ""
    return tag


# ---------------------------------------------------------------- 自动更新

def _local_game_version() -> str:
    """本地版本（读 版本.txt 里的游戏版本）。"""
    try:
        with open(os.path.join(HERE, "版本.txt"), "r", encoding="utf-8") as f:
            m = re.search(r"游戏版本 (\S+)", f.read())
            return m.group(1) if m else ""
    except OSError:
        return ""


def _remote_game_version() -> str:
    """远端版本（去掉 tag 的 v 前缀）。"""
    tag = check_remote_version()
    return tag[1:] if tag.startswith("v") else tag

class AutoUpdater(threading.Thread):
    """自动更新：定期查 GitHub Releases，有新版就下载解压，等空闲后重启自己。

    为什么重启用 os.execv 而不是 subprocess：
    execv 是「进程替换自己」——PID 不变，systemd 不会当成进程退出，
    父进程（systemd / nohup）完全无感，新代码立刻生效。

    为什么等空闲：正在打的对局会被重启打断。
    所以下载可以随时做，重启要等到没有进行中的对局。

    全程只用 Python 标准库（urllib + zipfile），不依赖 curl / unzip。
    """

    CHECK_INTERVAL = 600.0      # 10 分钟查一次
    IDLE_WAIT_MAX = 1800.0      # 最多等 30 分钟有人打完

    @staticmethod
    def _interval() -> float:
        """检查间隔，可用环境变量调短（自动化测试用）。"""
        try:
            v = float(os.environ.get("DARKCARD_UPDATE_INTERVAL", ""))
            if v > 0:
                return v
        except ValueError:
            pass
        return AutoUpdater.CHECK_INTERVAL

    def __init__(self, hub: "Hub"):
        super().__init__(daemon=True)
        self.hub = hub
        self._stop = threading.Event()
        # 待办：这次更新分别要做什么
        #   rule   = 规则层变了（engine.py / cards.json）→ 热重载即可
        #   runtime= 进程层变了（server.py / 新增模块）→ 必须重启进程
        #   deps   = 依赖变了（requirements.txt）→ 装依赖
        self._pending = {"rule": False, "runtime": False, "deps": False}

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        # 启动后先等一会儿，别和服务器抢启动。
        # 间隔被调短时（测试）也跟着缩短，不然要干等一分钟。
        if self._stop.wait(min(60.0, self._interval())):
            return
        while not self._stop.is_set():
            try:
                self._tick()
            except Exception as exc:  # noqa: BLE001 - 更新失败绝不能影响服务器
                print("[darkcard] 自动更新出错（不影响服务）：%s" % exc, flush=True)
            self._stop.wait(self._interval())

    def _tick(self) -> None:
        # 还没下载过：先查有没有新版
        if not any(self._pending.values()):
            tag = check_remote_version()
            if not tag:
                return
            print("[darkcard] 发现新版本 %s，开始下载…" % tag, flush=True)
            changed = self._download_and_stage()
            if changed is None:
                return
            self._pending["rule"] = changed["rule"]
            self._pending["runtime"] = changed["runtime"]
            self._pending["deps"] = changed["deps"]
            if not any(self._pending.values()):
                print("[darkcard] 已是最新，无需变更", flush=True)
                return

        # 1) 依赖：装不上就下轮再试（不阻塞其他步骤）
        if self._pending["deps"]:
            self._pending["deps"] = not self._install_deps()

        # 2) 规则层（engine.py / cards.json）：热重载，不重启、不打断对局
        if self._pending["rule"]:
            ok, err = self.hub.hot_reload()
            if ok:
                self.hub.notify_server_updated()
                self._pending["rule"] = False
                print("[darkcard] 新规则已生效（热重载，未重启）", flush=True)
            else:
                print("[darkcard] 热重载失败：%s" % err, flush=True)

        # 3) 进程层（server.py / 新增模块）：必须重启进程才会生效。
        #    Python 不能热替换自己的模块，所以这里等没人打牌时 execv 自己。
        if self._pending["runtime"]:
            print("[darkcard] 服务器程序有改动，等没人打牌时重启以生效", flush=True)
            waited = 0.0
            while waited < self.IDLE_WAIT_MAX and not self._stop.is_set():
                if not self.hub.has_active_match():
                    print("[darkcard] 正在重启以应用新版本…", flush=True)
                    self._exec_restart()
                    return
                self._stop.wait(10.0)
                waited += 10.0
            print("[darkcard] 等了太久还没空闲，本次不重启（下个周期再来）", flush=True)

    def _download_and_stage(self) -> dict[str, bool] | None:
        """下载新版本并解压到当前目录。

        返回 {"rule": bool, "runtime": bool, "deps": bool}，
        说明这次更新分别动了「规则层」「进程层」「依赖」，
        调用方据此决定是热重载还是要重启进程。

        解压用**黑名单**而不是白名单：除了明确要保留的东西
        （玩家数据 store.json、日志、临时文件），包里有什么就装什么。
        这样以后服务器新增了模块文件也能自动到位，
        不会出现「代码更新了但新文件没装上」的半拉子状态。
        """
        import hashlib
        import urllib.request
        import zipfile

        url = _update_url()
        tmp = os.path.join(HERE, ".update.tmp.zip")
        old_version = _local_game_version()   # 解压会覆盖 版本.txt，先记住旧的
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "darkcard-server"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            with open(tmp, "wb") as f:
                f.write(data)

            changed = {"rule": False, "runtime": False, "deps": False}
            with zipfile.ZipFile(tmp) as z:
                for info in z.infolist():
                    name = info.filename
                    if info.is_dir():
                        continue
                    base = os.path.basename(name)
                    if base in PRESERVE_FILES:
                        continue                      # 玩家数据，绝不能覆盖
                    if base.startswith(".update") or base.endswith((".log", ".pid")):
                        continue                      # 临时文件与日志
                    new_bytes = z.read(name)
                    new_hash = hashlib.sha256(new_bytes).hexdigest()
                    dest = os.path.join(HERE, base)
                    old_hash = ""
                    if os.path.isfile(dest):
                        with open(dest, "rb") as f:
                            old_hash = hashlib.sha256(f.read()).hexdigest()
                    if old_hash == new_hash:
                        continue                      # 没变，不动它
                    # 写文件（zipfile 的 extract 会做路径穿越防护，但这里我们自己控目标路径）
                    with open(dest, "wb") as f:
                        f.write(new_bytes)
                    if base in RULE_FILES:
                        changed["rule"] = True
                    elif base == "requirements.txt":
                        changed["deps"] = True
                    elif base in META_FILES:
                        pass                           # 说明文件 / 版本号 / 更新脚本
                    else:
                        changed["runtime"] = True      # server.py 或新增模块 → 要重启
        except Exception as exc:  # noqa: BLE001
            print("[darkcard] 下载失败：%s" % exc, flush=True)
            return None
        finally:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass

        # 写个标记：新代码已经在磁盘上，但当前进程还在跑旧代码。
        # 标记让下次启动能知道自己是从哪一版升上来的。
        try:
            with open(os.path.join(HERE, ".updated_from"), "w", encoding="utf-8") as f:
                f.write("%s -> %s\n" % (old_version, _remote_game_version()))
        except OSError:
            pass
        if any(changed.values()):
            print("[darkcard] 新文件已解压到 %s（规则层=%s 进程层=%s 依赖=%s）" % (
                HERE, changed["rule"], changed["runtime"], changed["deps"]), flush=True)
        return changed

    def _install_deps(self) -> bool:
        """装 requirements.txt 里的依赖。返回是否成功。

        服务器一直是纯标准库，所以这个文件通常是空的。
        以后真要引第三方库，把依赖写进 server/requirements.txt，
        自动更新会顺手装上——否则会出现「代码更新了但 import 失败」。

        装不上不致命：只警告，让服务器继续用旧代码跑。
        """
        import subprocess
        import sys

        req = os.path.join(HERE, "requirements.txt")
        if not os.path.exists(req):
            return True
        try:
            with open(req, "r", encoding="utf-8") as f:
                lines = [ln.strip() for ln in f
                         if ln.strip() and not ln.strip().startswith("#")]
        except OSError:
            return True
        if not lines:
            return True
        print("[darkcard] 安装依赖：%s" % ", ".join(lines), flush=True)
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "pip", "install", "-r", req],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        except Exception as exc:  # noqa: BLE001
            print("[darkcard] 依赖安装失败（不影响服务）：%s" % exc, flush=True)
            return False
        if proc.returncode != 0:
            print("[darkcard] 依赖安装失败（不影响服务）：%s" % (
                proc.stdout.decode("utf-8", "replace")[-400:]), flush=True)
            return False
        print("[darkcard] 依赖安装完成", flush=True)
        return True

    def _exec_restart(self) -> None:
        """进程替换自己：PID 不变，父进程无感。"""
        import sys

        args = [sys.executable] + sys.argv
        try:
            os.execv(sys.executable, args)
        except Exception as exc:  # noqa: BLE001
            print("[darkcard] 重启失败：%s" % exc, flush=True)


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    api: Api = None  # type: ignore[assignment]
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.environ.get("DC_VERBOSE"):
            super().log_message(fmt, *args)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def _send(self, obj: dict[str, Any]) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            # 报的是**正在跑的进程**的版本，不是磁盘上文件的版本。
            # 两者不一致 = 文件更新了但进程还没换新代码（过渡期就是这个状态），
            # update.sh 靠这个判断该不该重启。
            self._send({
                "ok": True,
                "service": "darkcard-duel",
                "game_version": self.api.hub.game_version,
                "rules_version": self.api.hub.rules_version,
                "protocol_version": PROTOCOL_VERSION,
            })
            return
        # GET 也允许带参数调用命令，方便 curl 调试
        qs = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        cmd = parsed.path.rsplit("/", 1)[-1]
        self._send(self.api.handle(cmd, qs))

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        cmd = parsed.path.rsplit("/", 1)[-1]
        body = self._read_json()
        # 运维命令（reload）只接受本机请求
        if cmd == "reload":
            peer = self.client_address[0] if self.client_address else ""
            if peer not in ("127.0.0.1", "::1"):
                self._send({"ok": False, "error": "reload 只能在本机执行"})
                return
            body["_local"] = "1"
        self._send(self.api.handle(cmd, body))


def _check_update_bg() -> None:
    tag = check_remote_version()
    if tag:
        print("[darkcard] 有新版本 %s 可用（在本目录跑 bash update.sh 即可更新）" % tag, flush=True)


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="暗牌技能对战 联机服务器")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8737)
    ap.add_argument("--cards", default=CARDS_PATH)
    ap.add_argument("--store", default=STORE_PATH)
    ap.add_argument("--no-auto-update", action="store_true",
                    help="关闭自动更新（默认开启：自动查新版，热重载生效，不重启）")
    args = ap.parse_args()

    store = Store(args.store)
    hub = Hub(store)
    # CARDS_PATH 是模块级常量，改卡表路径要在建 Hub 之前生效
    if os.path.abspath(args.cards) != os.path.abspath(CARDS_PATH):
        hub.db = _engine.DB(args.cards)
        for room in hub.rooms.values():
            room.set_game(hub.db)

    Handler.api = Api(hub)
    Watchdog(hub).start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print("[darkcard] 服务器启动 http://%s:%d  （卡表 %d 张）" % (
        args.host, args.port, len(hub.db.order)), flush=True)
    print("[darkcard] 规则版本 %s · 协议版本 %d" % (
        hub.rules_version, PROTOCOL_VERSION), flush=True)
    print("[darkcard] 内网穿透请把公网端口映射到 %d/tcp" % args.port, flush=True)
    # 写 PID 文件：update.sh 靠它精确地重启这个进程，
    # 不依赖 pgrep（不是所有系统都有）。
    try:
        with open(os.path.join(HERE, "server.pid"), "w", encoding="utf-8") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    # 上次是不是刚更新过？是的话说明磁盘上的代码比刚才跑的还新
    marker = os.path.join(HERE, ".updated_from")
    if os.path.exists(marker):
        try:
            with open(marker, "r", encoding="utf-8") as f:
                print("[darkcard] 本次由 %s 升级而来" % f.read().strip(), flush=True)
        except OSError:
            pass
    if args.no_auto_update:
        print("[darkcard] 自动更新已关闭（--no-auto-update）", flush=True)
    else:
        AutoUpdater(hub).start()
        print("[darkcard] 自动更新已开启：每 %.0f 秒查一次，有新版自动生效"
              % AutoUpdater._interval(), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[darkcard] 停止", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
