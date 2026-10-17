"""Regression tests for the optional GitHub issue mirror."""
import json
import subprocess

from coord.tools import board


def test_import_comments_flattens_paginated_json(tmp_path, monkeypatch):
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps({"issue": 6, "last_comment": 0}))
    pages = [
        [
            {"id": 1, "body": "[FYI] first page", "user": {"login": "alice"}},
            {"id": 2, "body": "<!-- recall-board --> mirrored", "user": {"login": "recall-bot"}},
        ],
        [
            {"id": 3, "body": "@reviewer [ASK] second page\nPlease inspect this.", "user": {"login": "bob"}},
        ],
    ]
    result = subprocess.CompletedProcess([], 0, stdout=json.dumps(pages), stderr="")
    gh_calls = []

    def gh(*args, **kwargs):
        gh_calls.append(args)
        return result
    posted = []
    monkeypatch.setattr(board, "CONFIG", config_path)
    monkeypatch.setattr(board, "gh", gh)
    monkeypatch.setattr(board, "post_message", lambda *args, **kwargs: posted.append((args, kwargs)))
    monkeypatch.setattr(board, "publish", lambda *args, **kwargs: None)

    board.import_comments()

    assert gh_calls[0][-1] == "--slurp"
    assert len(posted) == 2
    assert posted[0][0][0:4] == ("gh-alice", "ALL", "[FYI] first page", "[FYI] first page")
    assert posted[1][0][0:4] == ("gh-bob", "reviewer", "[ASK] second page", "Please inspect this.")
    assert posted[1][1] == {"mirror": False}
    assert json.loads(config_path.read_text())["last_comment"] == 3
