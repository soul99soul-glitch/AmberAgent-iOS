#!/usr/bin/env python3
"""Check only a task-owned real-device acceptance conversation and copied Room rows.

Usage: python3 iosApp/scripts/check-intelligent-ui-acceptance.py CONVERSATIONS_DIR DATABASE --marker TASK_UI_ACCEPTED_<32 hex>
Study: add --task-kind study and use STUDY_UI_ACCEPTED_<32 hex>.
Copy agent_runtime.db together with its existing -wal/-shm sidecars. This script
never opens device files: it checks an offline private copy with SQLite mode=ro.
It does not print titles, prompts, credentials, model IDs, or unrelated data.
"""
import argparse
import json
import pathlib
import re
import shutil
import sqlite3
import sys
import tempfile
import uuid


class VerificationError(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise VerificationError(reason)


def uuid_id(value, reason):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise VerificationError(reason) from None


def text_parts(message):
    return [(i, p) for i, p in enumerate(message.get("parts", []))
            if isinstance(p, dict) and p.get("type") == "text"]


def text(message):
    return "".join(p.get("text", "") for _, p in text_parts(message))


def selected_messages(conversation):
    nodes = conversation.get("messageNodes")
    require(isinstance(nodes, list), "Target conversation has no messageNodes array.")
    result = []
    for node in nodes:
        variants, index = node.get("messages", []), node.get("selectIndex", 0)
        require(isinstance(index, int) and 0 <= index < len(variants),
                "Target conversation has an invalid selected branch.")
        result.append(variants[index])
    return result


def locate(conversations, marker):
    matches = []
    # Restrict discovery to UUID conversation filenames, never preferences/index.
    for path in conversations.glob("*.json"):
        try:
            uuid.UUID(path.stem)
        except ValueError:
            continue
        try:
            raw = path.read_text(encoding="utf-8")
            if marker not in raw:
                continue
            conversation = json.loads(raw)
            messages = selected_messages(conversation)
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise VerificationError("A marker-bearing conversation could not be read safely.") from None
        if any(m.get("role") == "assistant" and text(m).startswith(marker + "：") for m in messages):
            matches.append((path, conversation, messages))
    require(len(matches) == 1,
            "Expected exactly one conversation with a selected assistant marker prefix.")
    return matches[0]


def verify_study(card, receipt, draft, prompt):
    items = card.get("study", {}).get("items", [])
    require(len(items) == 16, "Study acceptance must retain all sixteen learning items.")
    item_ids = [item.get("id") for item in items]
    require(all(isinstance(item_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", item_id)
                for item_id in item_ids) and len(set(item_ids)) == 16,
            "Study items must have unique stable IDs.")
    quiz_items = []
    for item in items:
        require(all(isinstance(item.get(key), str) and item[key].strip() for key in ("prompt", "answer")),
                "All study items must contain their learning prompt and answer.")
        if item.get("options") is None:
            require(item.get("correct_option_id") is None, "A non-quiz study item declares a correct choice.")
            continue
        choices = item["options"]
        require(isinstance(choices, list) and 2 <= len(choices) <= 8,
                "Study quiz items must contain two to eight choices.")
        choice_ids = [choice.get("id") for choice in choices]
        require(all(isinstance(choice_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", choice_id)
                    for choice_id in choice_ids) and len(set(choice_ids)) == len(choice_ids)
                and item.get("correct_option_id") in choice_ids,
                "Study quiz choices or their correct choice ID are invalid.")
        require(all(isinstance(choice.get("label"), str) and choice["label"].strip() for choice in choices),
                "Study quiz choices must have labels.")
        quiz_items.append(item)
    require(quiz_items, "Study acceptance must include a locally answerable quiz.")
    require(not card.get("options") and not card.get("fields"),
            "This study acceptance requests neither a decision option nor extra input fields.")
    require(receipt.get("taskKind") == "study" and receipt.get("option") is None
            and receipt.get("inputs") == [] and draft.get("selectedOptionID") is None,
            "Study submission must carry study semantics without a decision choice or extra inputs.")
    values = draft.get("values", {})
    require(set(values) == {"__study_session"} and isinstance(values["__study_session"], str),
            "This local study draft must contain only its private JSON-string session.")
    try:
        session = json.loads(values["__study_session"])
    except json.JSONDecodeError:
        raise VerificationError("Local study session is not valid JSON.") from None
    require(isinstance(session, dict) and set(session) == {"mode", "index", "revealed", "answers"},
            "Local study session does not match its actual Codable schema.")
    mode, index, revealed, answers = (session[key] for key in ("mode", "index", "revealed", "answers"))
    require(mode in ("review", "quiz") and type(index) is int and type(revealed) is bool
            and isinstance(answers, dict), "Local study session contains invalid field types.")
    current_items = items if mode == "review" else quiz_items
    require(0 <= index < len(current_items), "Local study session index is out of range.")
    quizzes = {item["id"]: item for item in quiz_items}
    require(len(answers) == 1, "Actual study session must contain exactly one answered quiz item.")
    for item_id, choice_id in answers.items():
        require(item_id in quizzes and choice_id in [choice["id"] for choice in quizzes[item_id]["options"]],
                "Local study session references an invalid item or answer choice.")
    current_id = current_items[index]["id"]
    if mode == "quiz":
        require(revealed == (current_id in answers), "Quiz answer visibility differs from actual local answers.")
    incorrect = [item["id"] for item in quiz_items
                 if item["id"] in answers and answers[item["id"]] != item["correct_option_id"]]
    expected_summary = {"answeredCount": len(answers), "correctCount": len(answers) - len(incorrect),
                        "totalQuizCount": len(quiz_items), "incorrectItemIDs": incorrect,
                        "mode": mode, "currentItemID": current_id, "answerRevealed": revealed}
    summary = receipt.get("studySummary")
    require(isinstance(summary, dict) and summary == expected_summary
            and all(type(summary.get(key)) is int for key in ("answeredCount", "correctCount", "totalQuizCount"))
            and type(summary.get("answerRevealed")) is bool,
            "Submitted study summary differs from the score, position or visibility computed from the local session.")
    require(prompt.startswith("【任务卡交互结果】") and "交互类型：study" in prompt
            and re.search(r"已答\s*1/" + str(len(quiz_items)) + r"\s*题", prompt)
            and re.search(r"答对\s*" + str(expected_summary["correctCount"]) + r"\s*题", prompt),
            "Persisted study continuation prompt does not match its summary.")
    require("__study_session" not in prompt and "__study_session" not in receipt,
            "Private study storage must not be submitted as a task input.")
    return {"task_kind": "study", "study_item_count": len(items),
            "study_summary_matches_local_session": True, "study_summary": expected_summary}


def verify(conversations, database, marker, task_kind="decision"):
    require(task_kind in ("decision", "study"), "Unsupported acceptance task kind.")
    path, conversation, messages = locate(conversations, marker)
    conversation_id = uuid_id(conversation.get("id"), "Target conversation ID is invalid.")
    require(conversation_id == str(uuid.UUID(path.stem)), "Conversation filename and ID differ.")
    require(len(messages) == 4, "Acceptance conversation must contain exactly four selected messages.")
    require([m.get("role") for m in messages] == ["user", "assistant", "user", "assistant"],
            "Selected messages must be user → card assistant → submission user → answer assistant.")
    message_ids = [uuid_id(m.get("id"), "Target message ID is invalid.") for m in messages]
    require(len(set(message_ids)) == 4, "Acceptance message IDs must be unique.")
    require(marker in text(messages[0]), "Initial task-owned user request does not contain the marker.")
    answer = text(messages[3])
    if task_kind == "decision":
        require(answer.startswith(marker + "：") and "本地存储" in answer and "离线" in answer,
                "Second assistant must begin with the marker and confirm local storage plus offline constraint.")
    else:
        require(answer.startswith(marker + "：") and re.search(r"已答\s*1\s*题", answer),
                "Second study assistant must begin with the marker and confirm exactly one answered question.")
    require(messages[1].get("finishedAt") and messages[3].get("finishedAt"),
            "Both selected assistant messages must have persisted finishedAt values.")
    require(not text(messages[1]).startswith(marker + "："), "First assistant must not satisfy the answer marker.")

    card_parts = [(i, p) for i, p in text_parts(messages[1]) if re.search(r"```task-ui\s*\n", p.get("text", ""))]
    require(len(card_parts) == 1, "First assistant must contain exactly one task-ui Text part.")
    part_index, card_part = card_parts[0]
    blocks = re.findall(r"```task-ui\s*\n(.*?)\n```", card_part["text"], re.S)
    require(len(blocks) == 1, "First assistant must contain exactly one complete task-ui block.")
    try:
        card = json.loads(blocks[0])
    except json.JSONDecodeError:
        raise VerificationError("Persisted task-ui block is not valid JSON.") from None
    card_id = card.get("card_id")
    require(card.get("version") == 1 and card.get("kind") == task_kind
            and isinstance(card_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", card_id)
            and (task_kind != "decision" or card_id == "notes-storage"),
            "Persisted card identity/version/kind differ from the acceptance contract.")
    if task_kind == "decision":
        require([o.get("id") for o in card.get("options", [])] == ["local", "cloud"],
                "Persisted options must be exactly local and cloud.")
        require(len(card.get("fields", [])) == 1 and card["fields"][0].get("id") == "constraints"
                and card["fields"][0].get("required") is True,
                "Persisted card must declare the required constraints field.")
    terminal = card_part.get("metadata", {})
    require(terminal.get("amber_task_ui_source_terminal") == "completed",
            "Card source lacks the trusted persisted completed terminal marker.")
    source_run = terminal.get("amber_task_ui_source_run_id")
    uuid_id(source_run, "Card source run ID is invalid.")
    require(terminal.get("amber_local_kind") is None, "Card source has a local generation error marker.")

    receipts = [p.get("metadata", {}).get("amber_task_ui_submission")
                for _, p in text_parts(messages[2])
                if "amber_task_ui_submission" in p.get("metadata", {})]
    require(len(receipts) == 1 and isinstance(receipts[0], str),
            "Submission user must carry exactly one JSON-string task-ui snapshot.")
    try:
        receipt = json.loads(receipts[0])
    except json.JSONDecodeError:
        raise VerificationError("Task-ui submission snapshot could not be decoded.") from None
    uuid_id(receipt.get("id"), "Submission snapshot ID is invalid.")
    expected_source = {"conversationID": conversation_id, "messageID": message_ids[1],
                       "textPartIndex": part_index, "cardID": card_id}
    require(receipt.get("source") == expected_source, "Submission source does not match the actual card source.")
    require(receipt.get("goal") == card.get("goal")
            and receipt.get("question") == card.get("question", "" if task_kind == "study" else None),
            "Submission task goal/question do not match the card.")
    if task_kind == "decision":
        require(receipt.get("option") == card["options"][0] and receipt["option"].get("title") == "本地存储",
                "Submission option snapshot does not match the actual local option.")
        require(receipt.get("inputs") == [{"id": "constraints", "label": card["fields"][0].get("label"),
                                          "value": "必须离线可用"}],
                "Submission snapshot does not contain exactly the entered offline constraint.")
    require(re.fullmatch(r"[0-9a-f]{64}", receipt.get("definitionFingerprint", "")) is not None,
            "Submission snapshot lacks a SHA-256 definition fingerprint.")
    require(isinstance(receipt.get("draftRevision"), int) and receipt["draftRevision"] >= 2,
            "Submission snapshot lacks the interaction draft revision.")
    if task_kind == "decision":
        require(text(messages[2]).startswith("【任务卡选择】") and "本地存储" in text(messages[2])
                and "必须离线可用" in text(messages[2]),
                "Persisted submission prompt does not match its metadata snapshot.")

    draft_path = conversations / "task-ui-drafts.json"
    require(draft_path.is_file(), "Persisted local task-ui draft file is missing.")
    try:
        drafts = json.loads(draft_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise VerificationError("Persisted local task-ui drafts could not be decoded.") from None
    matching = [r.get("draft", {}) for r in drafts.get("records", []) if r.get("source") == expected_source]
    require(len(matching) == 1, "Expected exactly one persisted local draft for this card source.")
    draft = matching[0]
    require(draft.get("definitionFingerprint") == receipt["definitionFingerprint"]
            and draft.get("revision") == receipt["draftRevision"],
            "Persisted local draft does not match the immutable submitted snapshot.")
    if task_kind == "decision":
        require(draft.get("selectedOptionID") == "local" and draft.get("values") == {"constraints": "必须离线可用"},
                "Persisted local draft does not match the immutable submitted snapshot.")
        task_evidence = {"selected_option_id": "local", "offline_constraint_matches": True}
    else:
        task_evidence = verify_study(card, receipt, draft, text(messages[2]))

    require(database.is_file(), "Copied Room database is missing.")
    # Retain WAL contents. immutable=1 would silently ignore WAL, so do not use it.
    # Isolate even shared-memory access to a private disposable offline copy.
    with tempfile.TemporaryDirectory(prefix="amber-task-ui-room-check-") as working:
        local_db = pathlib.Path(working) / "agent_runtime.db"
        copied = []
        for suffix in ("", "-wal", "-shm"):
            original = pathlib.Path(str(database) + suffix)
            if original.is_file():
                shutil.copyfile(original, pathlib.Path(str(local_db) + suffix))
                copied.append(suffix or "db")
        connection = sqlite3.connect(local_db.as_uri() + "?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        try:
            rows = connection.execute(
                "SELECT run_id, agent_descriptor_id, status, started_at, finished_at "
                "FROM agent_run WHERE conversation_id = ? AND agent_descriptor_id IN ('chat', 'chat_turn') "
                "ORDER BY started_at, run_id", (conversation_id,)).fetchall()
        finally:
            connection.close()
    require(len(rows) == 2, "Acceptance conversation must have exactly two persisted chat run rows.")
    require(all(r["agent_descriptor_id"] == "chat" for r in rows),
            "Current iOS chat runs must use the actual source descriptor chat.")
    require(rows[0]["run_id"] == source_run, "First Room run does not match the completed card provenance.")
    require(rows[0]["run_id"] != rows[1]["run_id"], "Two chat turns share a run ID.")
    for row in rows:
        uuid_id(row["run_id"], "Room run ID is invalid.")
        require(row["status"] == "completed" and isinstance(row["finished_at"], int)
                and row["finished_at"] >= row["started_at"],
                "A corresponding chat turn is not durably completed with a valid finished_at.")
    require(rows[0]["finished_at"] <= rows[1]["started_at"],
            "Second chat turn began before the card-producing run finished.")
    return {"result": "PASS", "marker": marker, "conversation_id": conversation_id,
            "selected_roles": ["user", "assistant", "user", "assistant"],
            "card_id": card_id, "source_message_id": message_ids[1],
            "source_text_part_index": part_index, "source_run_id": source_run,
            "submission_message_id": message_ids[2], **task_evidence, "local_draft_matches_submission": True,
            "definition_fingerprint": receipt["definitionFingerprint"], "draft_revision": receipt["draftRevision"],
            "second_assistant_prefix_matches": True, "copied_sqlite_sidecars": copied,
            "runs": [dict(r) for r in rows]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("conversations", type=pathlib.Path)
    parser.add_argument("database", type=pathlib.Path)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--task-kind", choices=("decision", "study"), default="decision")
    args = parser.parse_args()
    marker_prefix = "STUDY_UI_ACCEPTED_" if args.task_kind == "study" else "TASK_UI_ACCEPTED_"
    if not re.fullmatch(marker_prefix + r"[0-9A-Fa-f]{32}", args.marker):
        parser.error("--marker must be the exact " + marker_prefix + "<32 hex> acceptance marker")
    try:
        print(json.dumps(verify(args.conversations.resolve(), args.database.resolve(), args.marker, args.task_kind),
                         ensure_ascii=False, indent=2))
    except (VerificationError, OSError, sqlite3.Error, KeyError, TypeError, ValueError) as error:
        # Do not echo exception payloads from SQLite/filesystem/JSON: they may expose
        # other paths or content. Only hand-authored contract failures are public.
        reason = str(error) if isinstance(error, VerificationError) else "Offline acceptance data could not satisfy the expected schema."
        print(json.dumps({"result": "FAIL", "reason": reason}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
