#!/usr/bin/env python3

# ============================================================================ #
"""
Claude Code Chat Title Fixer:
Automatically repairs corrupted conversation titles in Claude Code history file.
Scans history.jsonl for error messages used as titles (OAuth errors, credit
balance warnings, "Empty conversation") and replaces them with meaningful titles
generated from the first user message in the conversation.

Author: XtremeXSPC
Version: 2.0.0

Features:
    - Detects corrupted titles in ~/.claude/history.jsonl.
    - Finds corresponding conversation files using sessionId.
    - Extracts first meaningful user message from conversation history.
    - Generates concise, descriptive titles (max 60 chars).
    - Batch processes all corrupted conversations.
    - Dry-run mode for safe preview before applying changes.
    - Preserves all conversation data, only modifies display field.

Usage:
    fix_all_titles.py [--dry-run]

Examples:
    # Preview changes without modifying files
    fix_all_titles.py --dry-run

    # Apply title fixes
    fix_all_titles.py
"""
# ============================================================================ #

import json
import sys
import tempfile
import shutil
from pathlib import Path

# ++++++++++++++++++++++++++++++++ Constants +++++++++++++++++++++++++++++++++ #

# Error messages and placeholders used as corrupted titles.
CORRUPTED_TITLES = [
    "OAuth token revoked",
    "Credit balance is too low",
    "Please run/login",
    "Login and exit commands",
    "Empty conversation",
]

# Claude Code paths.
CLAUDE_DIR = Path.home() / ".claude"
HISTORY_FILE = CLAUDE_DIR / "history.jsonl"
PROJECTS_DIR = CLAUDE_DIR / "projects"

# ++++++++++++++++++++++++++++++ Helper Functions ++++++++++++++++++++++++++++ #

def is_corrupted_title(title):
    """Check if title is a corrupted error message."""
    return any(corrupt in title for corrupt in CORRUPTED_TITLES)

def find_conversation_file(session_id, project_path):
    """Find the conversation file for a given sessionId."""
    if not project_path:
        return None

    # Convert project path to directory name format
    # e.g., "/Users/foo/bar" -> "-Users-foo-bar"
    dir_name = project_path.replace('/', '-')
    if dir_name.startswith('-'):
        dir_name = dir_name[1:]

    project_dir = PROJECTS_DIR / dir_name

    if not project_dir.exists():
        # Try without leading dash.
        project_dir = PROJECTS_DIR / ('-' + dir_name)

    if not project_dir.exists():
        return None

    # Look for the session file.
    session_file = project_dir / f"{session_id}.jsonl"
    if session_file.exists():
        return session_file

    return None

def extract_first_message(jsonl_file):
    """Extract the first real user message from a conversation file."""
    try:
        with open(jsonl_file, 'r') as f:
            for line in f:
                try:
                    data = json.loads(line)

                    # Check if this is a user message.
                    if data.get('type') == 'user':
                        message = data.get('message', {})
                        content = message.get('content', [])

                        if isinstance(content, list):
                            for item in content:
                                if isinstance(item, dict) and item.get('type') == 'text':
                                    text = item.get('text', '')

                                    # Skip IDE messages and system messages.
                                    if (text and
                                        not text.startswith('<ide_') and
                                        not text.startswith('<system') and
                                        not text.startswith('Caveat:') and
                                        len(text.strip()) > 10):
                                        return text.strip()[:300]
                        elif isinstance(content, str):
                            if (content and
                                not content.startswith('<') and
                                len(content.strip()) > 10):
                                return content.strip()[:300]

                except json.JSONDecodeError:
                    continue
    except Exception as e:
        print(f"  Warning: Could not read {jsonl_file.name}: {e}", file=sys.stderr)
    return None

def generate_title(message_text):
    """Generate a concise title from the message text."""
    # Remove common prefixes.
    text = message_text.strip()
    for prefix in ['Claude! ', 'Claude, ', 'Ehi Claude! ', 'Ciao Claude! ', 'Hey Claude! ']:
        if text.startswith(prefix):
            text = text[len(prefix):]

    # Take first sentence or first 60 chars.
    sentences = text.split('.')
    if sentences:
        title = sentences[0].strip()
        if len(title) > 60:
            title = title[:60].strip() + '...'
        return title

    return text[:60].strip() + ('...' if len(text) > 60 else '')

def update_history_file(updates, dry_run=False):
    """Update the history.jsonl file with new titles."""
    if dry_run:
        return 0

    temp_file = Path(tempfile.mktemp(suffix='.jsonl'))
    updated_count = 0

    try:
        with open(HISTORY_FILE, 'r') as infile, open(temp_file, 'w') as outfile:
            for line in infile:
                try:
                    data = json.loads(line)
                    session_id = data.get('sessionId')

                    if session_id in updates:
                        data['display'] = updates[session_id]
                        updated_count += 1

                    outfile.write(json.dumps(data) + '\n')
                except json.JSONDecodeError:
                    outfile.write(line)

        # Replace original file.
        shutil.move(str(temp_file), HISTORY_FILE)
        return updated_count
    except Exception as e:
        if temp_file.exists():
            temp_file.unlink()
        raise e

# +++++++++++++++++++++++++++++++ Main Processing +++++++++++++++++++++++++++ #

def process_conversations(dry_run=False):
    """Process all conversations with corrupted titles."""
    if not HISTORY_FILE.exists():
        print(f"Error: History file not found at {HISTORY_FILE}")
        return 0

    updates = {}
    processed = 0
    skipped = 0

    print(f"Reading history from: {HISTORY_FILE}")

    # Read all history entries.
    with open(HISTORY_FILE, 'r') as f:
        for line in f:
            try:
                data = json.loads(line)
                session_id = data.get('sessionId')
                display = data.get('display', '')
                project = data.get('project', '')

                if not session_id or not is_corrupted_title(display):
                    continue

                # Find conversation file.
                conv_file = find_conversation_file(session_id, project)

                if not conv_file:
                    skipped += 1
                    if dry_run:
                        print(f"\n[SKIP] {session_id[:8]}... - file not found")
                        print(f"  Old: {display}")
                    continue

                # Extract first message.
                first_msg = extract_first_message(conv_file)

                if not first_msg:
                    skipped += 1
                    if dry_run:
                        print(f"\n[SKIP] {session_id[:8]}... - no valid message")
                        print(f"  Old: {display}")
                    continue

                # Generate new title.
                new_title = generate_title(first_msg)
                updates[session_id] = new_title
                processed += 1

                if dry_run:
                    print(f"\n[UPDATE] {session_id[:8]}...")
                    print(f"  Old: {display}")
                    print(f"  New: {new_title}")
                    print(f"  Preview: {first_msg[:100]}")
                else:
                    print(f"✓ {session_id[:8]}...: '{new_title}'")

            except json.JSONDecodeError:
                continue

    # Apply updates if not dry run.
    if not dry_run and updates:
        updated = update_history_file(updates, dry_run=False)
        print(f"\nUpdated {updated} conversation titles in history file")

    return processed, skipped

# +++++++++++++++++++++++++++++++++++ Main ++++++++++++++++++++++++++++++++++ #

if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='Fix corrupted chat titles in Claude Code history')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be changed without modifying files')

    args = parser.parse_args()

    if args.dry_run:
        print("DRY RUN MODE - No files will be modified\n")

    processed, skipped = process_conversations(dry_run=args.dry_run)

    print(f"\n{'Would process' if args.dry_run else 'Processed'}: {processed} conversations")
    if skipped > 0:
        print(f"Skipped: {skipped} conversations (file not found or no valid message)")

# ============================================================================ #
# End of fix_all_titles.py
