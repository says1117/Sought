#!/usr/bin/env python3
"""Message board and task list for human + agent coordination.

Data lives as plain files on the git branch `board`, checked out at `.board/`.
Standard library only. Run from anywhere inside the repo. See coord/PROTOCOL.md.
"""
import argparse
import datetime as dt
import fcntl
import json
import re
import secrets
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def shared_root():
    """Main checkout root, so every git worktree of this repo shares one .board/."""
    out = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--git-common-dir"],
                         capture_output=True, text=True).stdout.strip()
    return (REPO / out).resolve().parent if out else REPO


BOARD = shared_root() / ".board"
TASKS, MSGS, ACKS = BOARD / "tasks", BOARD / "messages", BOARD / "acks"
STATUSES = ("open", "claimed", "blocked", "review", "done")
NOTIFY_ON = ("blocked", "review", "done")
# A dependency in review already has code on a branch, so dependents may start "stacked" on it.
UNBLOCKS = ("review", "done")


# ---------- git plumbing ----------

def git(*args, cwd=BOARD):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)


def warn(msg):
    print(f"warning: {msg}", file=sys.stderr)


# ---------- GitHub issue mirror (optional): pings show up where people already look ----------

MARKER = "<!-- recall-board -->"
CONFIG = BOARD / "config.json"


def config():
    return json.loads(CONFIG.read_text()) if CONFIG.exists() else {}


def gh(*args, stdin=None):
    try:
        return subprocess.run(["gh", *args], capture_output=True, text=True, input=stdin,
                              cwd=REPO, timeout=25)
    except (OSError, subprocess.TimeoutExpired):
        return None


def mirror_comment(meta, body):
    issue = config().get("issue")
    if not issue:
        return
    text = f"{MARKER}\n**{meta['from']}** to **{meta['to']}** {meta['task'] or ''}\n### {meta['subject']}\n\n{body}"
    gh("issue", "comment", str(issue), "--body-file", "-", stdin=text)


def mirror_body():
    issue = config().get("issue")
    board_md = BOARD / "BOARD.md"
    if issue and board_md.exists():
        head = ("Shared message board for Recall. Comment here to ping the team; start a comment with "
                "`@<role>` (for example `@firmware`) to address an agent role, otherwise it goes to everyone. "
                "Agents read this through `coord/tools/board.py`. **This repo is public: no secrets or personal data.**\n\n")
        gh("issue", "edit", str(issue), "--body-file", "-", stdin=MARKER + "\n" + head + board_md.read_text())


def import_comments():
    """Turn new human comments on the board issue into board messages."""
    cfg = config()
    issue = cfg.get("issue")
    if not issue:
        return
    r = gh("api", f"repos/:owner/:repo/issues/{issue}/comments", "--paginate")
    if not r or r.returncode:
        return
    last, new = cfg.get("last_comment", 0), 0
    for c in json.loads(r.stdout or "[]"):
        if c["id"] <= last:
            continue
        last = max(last, c["id"])
        text = c["body"].strip()
        if MARKER in text or not text:
            continue
        m = re.match(r"@([\w-]+)\s*(.*)", text, re.S)
        to, text = (m.group(1), m.group(2).strip() or text) if m else ("ALL", text)
        subject, _, rest = text.partition("\n")
        post_message(f"gh-{c['user']['login']}", to, subject[:80], rest.strip() or subject, mirror=False)
        new += 1
    cfg["last_comment"] = last
    CONFIG.write_text(json.dumps(cfg))
    if new:
        publish(f"imported {new} issue comment(s)")
def checked_git(*args, cwd=BOARD):
    result = git(*args, cwd=cwd)
    if result.returncode:
        sys.exit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


@contextmanager
def board_lock():
    with (BOARD.parent / ".board.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit("Board is busy in another session; retry when that command finishes.")
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def require_board():
    if not BOARD.exists():
        sys.exit("Board not set up. Run: python3 coord/tools/board.py init")


def sync():
    r = git("pull", "--rebase", "--autostash")
    if r.returncode:
        warn(f"sync failed (offline or no remote?): {r.stderr.strip()[:200]}")
    import_comments()
    return r.returncode == 0


def render():
    """Regenerate BOARD.md, the human-readable kanban view, from tasks and messages."""
    tasks = all_tasks()
    bodies = {m["id"]: b for _, m, b in tasks}
    done = {m["id"] for _, m, _ in tasks if m["status"] in UNBLOCKS}
    columns = {"todo": [], "waiting": [], "claimed": [], "review": [], "blocked": [], "done": []}
    for _, m, _ in tasks:
        if m["status"] == "open":
            columns["todo" if deps_done(m, done) else "waiting"].append(m)
        else:
            columns["claimed" if m["status"] == "claimed" else m["status"]].append(m)

    def table(rows, header, cells):
        if not rows:
            return "_none_\n"
        lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
        lines += ["| " + " | ".join(cells(m)) + " |" for m in rows]
        return "\n".join(lines) + "\n"

    plain = lambda m: [m["id"], m["size"], m["role"], m["title"]]
    out = [f"# Recall work board\n\n_Updated {now()}. Generated by board.py; do not edit by hand._\n",
           "## To do (ready to claim)\n", table(columns["todo"], ["Task", "Size", "Role", "Title"], plain),
           "## Claimed (agents at work)\n",
           table(columns["claimed"], ["Task", "Agent", "Working on", "Updated", "Title"],
                 lambda m: [m["id"], m["owner"], m.get("doing") or "_no update yet_",
                            m.get("doing_at", "") or m["created"], m["title"]]),
           "## In review\n", table(columns["review"], ["Task", "Agent", "Title", "Report"],
                                   lambda m: [m["id"], m["owner"], m["title"], last_note(bodies[m["id"]])]),
           "## Blocked\n", table(columns["blocked"], ["Task", "Agent", "Why", "Title"],
                                 lambda m: [m["id"], m["owner"], m.get("doing") or "", m["title"]]),
           "## Waiting on dependencies\n", table(columns["waiting"], ["Task", "Size", "Role", "Title"], plain),
           "## Done\n", table(columns["done"], ["Task", "Agent", "Title"],
                              lambda m: [m["id"], m["owner"], m["title"]]),
           "## Latest messages\n"]
    msgs = [parse(p)[0] for p in sorted(MSGS.glob("*.md"))][-8:]
    out.append("\n".join(f"- `{m['time']}` **{m['from']}** to **{m['to']}**: {m['subject']}" for m in reversed(msgs))
               or "_none_")
    (BOARD / "BOARD.md").write_text("\n".join(out) + "\n")


def last_note(body, width=220):
    """Last appended status note, one line, for the board table."""
    note = body.split("\n\n")[-1].strip().replace("|", "/").replace("\n", " ")
    return note if note.startswith("[") and len(note) <= width else (note[:width] + "...") if note.startswith("[") else ""


def chat_lines(name=None, limit=40):
    lines = []
    for p in sorted(MSGS.glob("*.md"))[-limit * 4:]:
        meta, body = parse(p)
        if name and name not in (meta["from"], meta["to"], "ALL"):
            continue
        head = f"[{meta['time'][5:16].replace('T', ' ')}] {meta['from']} -> {meta['to']}  {meta['subject']}"
        lines.append(head + "".join(f"\n    {ln}" for ln in body.splitlines()) + "\n")
    return lines[-limit:]


def publish(message, push=True):
    if TASKS.exists():
        render()
        (BOARD / "CHAT.md").write_text("# Recall chat log\n\n```\n" + "\n".join(chat_lines(limit=100)) + "\n```\n")
    checked_git("add", "-A")
    diff = git("diff", "--cached", "--quiet")
    if diff.returncode == 0:
        return
    if diff.returncode != 1:
        sys.exit(f"Unable to inspect staged board changes: {diff.stderr.strip()}")
    checked_git("commit", "-m", f"board: {message}")
    if not push:
        return
    mirror_body()
    for _ in range(2):
        if git("push", "-u", "origin", "board").returncode == 0:
            return
        if git("pull", "--rebase", "--autostash").returncode:
            break
    sys.exit("Push failed; your change is saved locally. Resolve any rebase conflicts, then run `board.py sync`.")


# ---------- file format: "key: value" header, a --- line, then the body ----------

def parse(path):
    head, _, body = path.read_text().partition("\n---\n")
    meta = {}
    for line in head.splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return meta, body.strip()


def write(path, meta, body):
    head = "\n".join(f"{k}: {v}" for k, v in meta.items())
    path.write_text(f"{head}\n---\n{body}\n")


def all_tasks():
    return [(p, *parse(p)) for p in sorted(TASKS.glob("T-*.md"))]


def find_task(tid):
    for path, meta, body in all_tasks():
        if meta["id"] == tid:
            return path, meta, body
    sys.exit(f"No such task: {tid}")


def deps_done(meta, done_ids):
    deps = [d for d in re.split(r"[,\s]+", meta.get("depends", "")) if d]
    return all(d in done_ids for d in deps)


def ready_tasks(role=None):
    done = {m["id"] for _, m, _ in all_tasks() if m["status"] in UNBLOCKS}
    out = []
    for path, meta, body in all_tasks():
        if meta["status"] != "open" or not deps_done(meta, done):
            continue
        if role and meta["role"] != role:
            continue
        out.append((path, meta, body))
    return out


# ---------- commands ----------

def cmd_init(args):
    if BOARD.exists():
        print("Board already set up.")
        return
    git("fetch", "origin", cwd=REPO)
    local = git("rev-parse", "--verify", "refs/heads/board", cwd=REPO).returncode == 0
    remote = git("rev-parse", "--verify", "origin/board", cwd=REPO).returncode == 0
    if local:
        r = git("worktree", "add", str(BOARD), "board", cwd=REPO)
    elif remote:
        r = git("worktree", "add", "-b", "board", str(BOARD), "origin/board", cwd=REPO)
    else:
        r = git("worktree", "add", "--detach", str(BOARD), "HEAD", cwd=REPO)
        if r.returncode == 0:
            checked_git("checkout", "--orphan", "board")
            checked_git("rm", "-rf", "-q", ".")
    if r.returncode:
        sys.exit(f"init failed: {r.stderr.strip()}")
    for d in (TASKS, MSGS, ACKS):
        d.mkdir(exist_ok=True)
        (d / ".gitkeep").touch()
    publish("init board")
    print("Board ready at .board/")


def cmd_sync(args):
    require_board()
    if not sync():
        sys.exit("Board sync failed; no successful synchronization was reported.")
    if args.push:
        checked_git("push", "-u", "origin", "board")
    print("synced")


def cmd_task(args):
    require_board()
    sync()
    nums = [int(m["id"][2:]) for _, m, _ in all_tasks()]
    tid = f"T-{max(nums, default=0) + 1:03d}"
    slug = re.sub(r"[^a-z0-9]+", "-", args.title.lower()).strip("-")[:40]
    meta = {"id": tid, "title": args.title, "role": args.role, "size": args.size,
            "status": "open", "owner": "", "depends": args.depends,
            "read": args.read, "created": now()}
    write(TASKS / f"{tid}-{slug}.md", meta, args.body or args.title)
    publish(f"new task {tid}", args.push)
    print(tid)


def cmd_tasks(args):
    require_board()
    sync()
    ready = {m["id"] for _, m, _ in ready_tasks()}
    for _, m, _ in all_tasks():
        if args.role and m["role"] != args.role:
            continue
        if args.status and m["status"] != args.status:
            continue
        if m["status"] == "done" and not args.status and not args.all:
            continue
        flag = "ready" if m["id"] in ready else m["status"]
        print(f"{m['id']}  {flag:<8} {m['size']}  {m['role']:<13} {m['owner'] or '-':<13} {m['title']}")


def cmd_next(args):
    require_board()
    sync()
    ready = ready_tasks(args.role)
    if not ready:
        print(f"No ready tasks for {args.role}.")
        return
    _, meta, body = ready[0]
    print(f"{meta['id']} [{meta['size']}] {meta['title']}\nRead: {meta['read'] or '-'}\n\n{body}")


def cmd_claim(args):
    require_board()
    sync()
    path, meta, body = find_task(args.task)
    if meta["status"] != "open":
        sys.exit(f"{args.task} is {meta['status']}; only open tasks can be claimed")
    done = {task["id"] for _, task, _ in all_tasks() if task["status"] == "done"}
    if not deps_done(meta, done):
        sys.exit(f"{args.task} is waiting on dependencies")
    if meta["owner"] and meta["owner"] != args.who:
        sys.exit(f"{args.task} is already claimed by {meta['owner']}")
    meta.update(owner=args.who, status="claimed", doing=args.doing, doing_at=now())
    write(path, meta, body)
    publish(f"{args.who} claimed {args.task}", args.push)
    print(f"claimed {args.task}")


def cmd_working(args):
    """Agents call this to say what they are doing right now (one short line)."""
    require_board()
    sync()
    path, meta, body = find_task(args.task)
    if meta["status"] not in ("claimed", "blocked"):
        sys.exit(f"{args.task} is {meta['status']}; claim it first")
    meta.update(doing=args.text, doing_at=now())
    write(path, meta, body)
    publish(f"{meta['owner']} working on {args.task}", args.push)
    print(f"{args.task}: {args.text}")


def cmd_prs(args):
    """Report what changed on open PRs since the last check (commits, comments, reviews, state)."""
    require_board()
    r = gh("pr", "list", "--state", "all", "--limit", "60", "--json",
           "number,title,state,headRefOid,baseRefName,mergeable,comments,reviews")
    if not r or r.returncode:
        sys.exit("gh pr list failed (is gh signed in?)")
    state_file = BOARD / "prwatch.json"
    old = json.loads(state_file.read_text()) if state_file.exists() else {}
    new, changes = {}, []
    for pr in json.loads(r.stdout):
        n = str(pr["number"])
        cur = {"sha": pr["headRefOid"][:7], "state": pr["state"], "base": pr["baseRefName"],
               "mergeable": pr["mergeable"], "comments": len(pr["comments"]), "reviews": len(pr["reviews"])}
        new[n] = cur
        prev = old.get(n)
        if prev is None:
            changes.append(f"#{n} NEW {cur['state']} {pr['title']}") if old else None
            continue
        diffs = [f"{k} {prev[k]} -> {cur[k]}" for k in cur if prev.get(k) != cur[k]]
        if diffs:
            changes.append(f"#{n} {pr['title']}: " + ", ".join(diffs))
    state_file.write_text(json.dumps(new, indent=1))
    print("\n".join(changes) if changes else ("Baseline saved." if not old else "No PR changes."))
    if changes and args.post:
        post_message("orchestrator", "ALL", "[FYI] PR changes", "\n".join(changes))
        publish("pr watch digest", args.push)


def cmd_chat(args):
    require_board()
    sync()
    print("\n".join(chat_lines(args.name, args.limit)) or "No messages.")


def cmd_view(args):
    require_board()
    sync()
    render()
    print((BOARD / "BOARD.md").read_text())


def cmd_status(args):
    require_board()
    sync()
    path, meta, body = find_task(args.task)
    meta["status"] = args.status
    if args.status == "open":
        meta["owner"] = ""
    if args.status in ("open", "review", "done"):
        meta["doing"] = ""
    elif args.status == "blocked":
        meta["doing"] = args.note
    note = f"\n\n[{now()}] {meta['owner'] or 'someone'} -> {args.status}: {args.note}" if args.note else ""
    write(path, meta, body + note)
    if args.status in NOTIFY_ON:
        post_message(meta["owner"] or "unknown", "orchestrator",
                     f"[{'DONE' if args.status == 'done' else args.status.upper()}] {args.task} {meta['title']}",
                     args.note, args.task)
    publish(f"{args.task} -> {args.status}", args.push)
    print(f"{args.task} is now {args.status}")


def post_message(sender, to, subject, body, task="", mirror=True):
    mid = f"{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}-{sender}-to-{to}-{secrets.token_hex(2)}"
    write(MSGS / f"{mid}.md",
          {"id": mid, "from": sender, "to": to, "task": task, "subject": subject, "time": now()},
          body or "")
    if mirror:
        mirror_comment({"from": sender, "to": to, "task": task, "subject": subject}, body or "")
    return mid


def cmd_post(args):
    require_board()
    sync()
    body = args.body if args.body is not None else (sys.stdin.read() if not sys.stdin.isatty() else "")
    mid = post_message(args.sender, args.to, args.subject, body, args.task)
    publish(f"{args.sender} -> {args.to}", args.push)
    print(f"sent {mid}")


def cmd_inbox(args):
    require_board()
    sync()
    ack_file = ACKS / f"{args.name}.txt"
    acked = set(ack_file.read_text().split()) if ack_file.exists() else set()
    new = []
    for p in sorted(MSGS.glob("*.md")):
        meta, body = parse(p)
        if meta["to"] in (args.name, "ALL") and meta["from"] != args.name and meta["id"] not in acked:
            new.append((meta, body))
    if not new:
        print("Inbox empty.")
        return
    for meta, body in new:
        print(f"--- {meta['from']} | {meta['subject']} | {meta['task'] or '-'} | {meta['time']}\n{body}\n")
    if args.ack:
        with ack_file.open("a") as f:
            f.writelines(m["id"] + "\n" for m, _ in new)
        publish(f"{args.name} acked", args.push)


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, **kw):
        sp = sub.add_parser(name, **kw)
        sp.set_defaults(fn=fn)
        sp.add_argument("--no-push", dest="push", action="store_false", help="commit locally only")
        return sp

    add("init", cmd_init, help="set up .board/ (first time)")
    add("sync", cmd_sync, help="pull the latest board")
    t = add("task", cmd_task, help="create a task (orchestrator)")
    t.add_argument("--role", required=True)
    t.add_argument("--title", required=True)
    t.add_argument("--size", choices=("S", "M"), default="S")
    t.add_argument("--depends", default="", help="comma separated task ids")
    t.add_argument("--read", default="", help="files/sections the agent should read")
    t.add_argument("--body", default="")
    ls = add("tasks", cmd_tasks, help="list tasks")
    ls.add_argument("--role")
    ls.add_argument("--status", choices=STATUSES)
    ls.add_argument("--all", action="store_true", help="include done")
    n = add("next", cmd_next, help="show the first ready task for a role")
    n.add_argument("role")
    c = add("claim", cmd_claim, help="claim a task")
    c.add_argument("task")
    c.add_argument("who")
    c.add_argument("--doing", default="starting", help="one line: what you are about to do")
    w = add("working", cmd_working, help="update your one-line 'working on' status")
    w.add_argument("task")
    w.add_argument("text", help="short, present tense, e.g. 'writing sonar median filter'")
    pr = add("prs", cmd_prs, help="show what changed on PRs since the last check")
    pr.add_argument("--post", action="store_true", help="also post the changes as a board ping")
    ch = add("chat", cmd_chat, help="chat-style log of pings, newest last")
    ch.add_argument("--with", dest="name", help="only messages to/from this role (plus ALL)")
    ch.add_argument("--limit", type=int, default=20)
    add("view", cmd_view, help="print the kanban board (also saved as BOARD.md)")
    s = add("status", cmd_status, help="set task status; pings the orchestrator")
    s.add_argument("task")
    s.add_argument("status", choices=STATUSES)
    s.add_argument("--note", default="")
    po = add("post", cmd_post, help="send a message (a ping)")
    po.add_argument("--from", dest="sender", required=True)
    po.add_argument("--to", required=True, help="role, person, or ALL")
    po.add_argument("--subject", required=True)
    po.add_argument("--task", default="")
    po.add_argument("--body", default=None, help="or pipe the body on stdin")
    ib = add("inbox", cmd_inbox, help="show unread messages for a role")
    ib.add_argument("name")
    ib.add_argument("--ack", action="store_true", help="mark shown messages as read")

    args = p.parse_args()
    with board_lock():
        args.fn(args)


if __name__ == "__main__":
    main()
