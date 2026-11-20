#!/usr/bin/env python3
"""Emit a task state for any agent. Does not change the agent's configuration."""
import argparse
import datetime
import json
import os
from pathlib import Path
import tempfile
import hashlib

parser = argparse.ArgumentParser(description="向 AgentBoard 写入任务状态")
parser.add_argument("--agent", choices=["codex", "workbuddy", "dsh", "qwen", "claude", "custom"], required=True)
parser.add_argument("--task-id", required=True)
parser.add_argument("--state", choices=["running", "waiting", "completed", "failed", "interrupted", "idle", "unknown"], required=True)
parser.add_argument("--title", default="Agent 任务")
parser.add_argument("--project", default=os.getcwd())
parser.add_argument("--directory", type=Path, default=Path.home()/"Library/Application Support/AgentBoard/events")
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)
record = {"schema": "agentboard.v1", "agent": args.agent, "taskId": args.task_id, "state": args.state, "title": args.title, "project": args.project, "updatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
target = args.directory/(hashlib.sha256((args.agent+":"+args.task_id).encode()).hexdigest()[:32]+".json")
with tempfile.NamedTemporaryFile(mode="w", dir=args.directory, suffix=".tmp", delete=False) as stream:
    json.dump(record, stream, ensure_ascii=False)
    temporary = Path(stream.name)
temporary.chmod(0o600)
temporary.replace(target)
print(f"{args.agent}: {args.task_id} → {args.state}")
