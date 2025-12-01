#!/usr/bin/env python3

# ============================================================================ #
"""
Frontmatter Update Script:
Handles YAML frontmatter updates for Hugo blog posts with improved error
handling, atomic operations, and integration with Git-based change detection.

Author: XtremeXSPC
Version: 2.1.0
"""
# ============================================================================ #

import sys
import os
import hashlib
import tempfile
import shutil
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any
from io import StringIO
import logging

# Configure logging.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


# Dependency validation.
def validate_dependencies() -> bool:
    """Validates that all required dependencies are available."""
    missing_deps = []

    try:
        from ruamel.yaml import YAML
        from ruamel.yaml.scalarstring import DoubleQuotedScalarString
    except ImportError as e:
        missing_deps.append("ruamel.yaml")

    if missing_deps:
        logger.error(f"Missing required dependencies: {', '.join(missing_deps)}")
        logger.error("Install with: pip3 install " + " ".join(missing_deps))
        return False

    return True


# Import dependencies after validation.
if not validate_dependencies():
    sys.exit(1)

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import DoubleQuotedScalarString


class FrontmatterProcessor:
    """Handles frontmatter processing with atomic operations and error recovery."""

    def __init__(self, backup_dir: Optional[str] = None):
        self.yaml = YAML()
        self.yaml.preserve_quotes = True
        self.yaml.width = 4096  # Prevent line wrapping.
        self.backup_dir = backup_dir
        self.processed_files = []
        self.failed_files = []

        if self.backup_dir:
            os.makedirs(self.backup_dir, exist_ok=True)

    def calculate_file_hash(self, file_path: str) -> Optional[str]:
        """Calculate SHA-256 hash of a file."""
        try:
            sha256 = hashlib.sha256()
            with open(file_path, "rb") as f:
                for block in iter(lambda: f.read(65536), b""):
                    sha256.update(block)
            return sha256.hexdigest()
        except Exception as e:
            logger.error(f"Failed to calculate hash for {file_path}: {e}")
            return None

    def load_existing_hashes(self, hash_file: str) -> Dict[str, str]:
        """Load existing file hashes from hash file."""
        hashes = {}
        if not os.path.exists(hash_file):
            logger.warning(f"Hash file not found: {hash_file}")
            return hashes

        try:
            with open(hash_file, "r", encoding="utf-8") as f:
                for line_num, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue

                    parts = line.split("\t")
                    if len(parts) != 2:
                        logger.warning(
                            f"Malformed line {line_num} in hash file: {line}"
                        )
                        continue

                    file_path, file_hash = parts
                    abs_path = os.path.abspath(file_path)
                    hashes[abs_path] = file_hash

            logger.info(f"Loaded {len(hashes)} hashes from {hash_file}")
        except Exception as e:
            logger.error(f"Failed to load hash file {hash_file}: {e}")

        return hashes

    def create_backup(self, file_path: str) -> Optional[str]:
        """Create a backup of the file before modification."""
        if not self.backup_dir:
            return None

        try:
            backup_name = f"{os.path.basename(file_path)}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.backup"
            backup_path = os.path.join(self.backup_dir, backup_name)
            shutil.copy2(file_path, backup_path)
            logger.debug(f"Created backup: {backup_path}")
            return backup_path
        except Exception as e:
            logger.error(f"Failed to create backup for {file_path}: {e}")
            return None

    def read_markdown_file(self, file_path: str) -> Optional[str]:
        """Read markdown file content safely."""
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception as e:
            logger.error(f"Failed to read file {file_path}: {e}")
            return None

    def split_frontmatter(
        self, content: str, file_path: str
    ) -> Tuple[Optional[str], str]:
        """Split frontmatter from content."""
        if not content.startswith("---"):
            return None, content

        parts = content.split("---", 2)
        if len(parts) >= 3:
            return parts[1], parts[2]
        else:
            logger.warning(f"Malformed frontmatter in {file_path}")
            return None, content

    def parse_yaml_frontmatter(
        self, frontmatter_text: str, file_path: str
    ) -> Optional[Dict[str, Any]]:
        """Parse YAML frontmatter safely."""
        try:
            data = self.yaml.load(frontmatter_text) or {}
            return data
        except Exception as e:
            logger.error(f"Failed to parse YAML frontmatter in {file_path}: {e}")
            return None

    def update_title_and_date(self, data: Dict[str, Any], file_path: str) -> bool:
        """Update title and date fields if missing."""
        modified = False

        # Update title if missing
        if "title" not in data or not data["title"]:
            default_title = (
                os.path.basename(file_path)
                .replace(".md", "")
                .replace("_", " ")
                .replace("-", " ")
                .title()
            )
            data["title"] = DoubleQuotedScalarString(default_title)
            modified = True
            logger.info(f"Added title to {file_path}: {default_title}")

        # Update date if missing (RFC3339 format).
        if "date" not in data or not data["date"]:
            current_date = datetime.utcnow().isoformat() + "Z"
            data["date"] = DoubleQuotedScalarString(current_date)
            modified = True
            logger.info(f"Added date to {file_path}: {current_date}")

        return modified

    def update_categories(self, data: Dict[str, Any], file_path: str) -> bool:
        """Update categories field."""
        modified = False

        if "categories" in data:
            original_categories = data["categories"]
            if isinstance(original_categories, list):
                new_categories = [
                    DoubleQuotedScalarString(cat.strip())
                    for cat in original_categories
                    if isinstance(cat, str) and cat.strip()
                ]
                if not new_categories:
                    del data["categories"]
                    modified = True
                    logger.info(f"Removed empty categories from {file_path}")
                elif new_categories != original_categories:
                    data["categories"] = new_categories
                    modified = True
                    logger.info(f"Updated categories for {file_path}")
            else:
                del data["categories"]
                modified = True
                logger.info(f"Removed invalid categories field from {file_path}")

        # Add default category if none exists.
        if "categories" not in data:
            data["categories"] = [DoubleQuotedScalarString("Uncategorized")]
            modified = True
            logger.info(f"Added default category to {file_path}: Uncategorized")

        return modified

    def write_file_atomic(self, file_path: str, content: str) -> bool:
        """Write file content atomically using temporary file."""
        temp_path = None
        try:
            # Create temporary file in same directory as target.
            temp_dir = os.path.dirname(file_path)
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=temp_dir, delete=False, suffix=".tmp"
            ) as temp_file:
                temp_file.write(content)
                temp_file.flush()
                os.fsync(temp_file.fileno())
                temp_path = temp_file.name

            # Atomic move.
            shutil.move(temp_path, file_path)
            logger.debug(f"Atomically wrote {file_path}")
            return True

        except Exception as e:
            logger.error(f"Failed to write {file_path}: {e}")
            # Clean up temporary file if it exists.
            try:
                if temp_path and os.path.exists(temp_path):
                    os.unlink(temp_path)
            except:
                pass
            return False

    def save_frontmatter(self, data: Dict[str, Any], body: str, file_path: str) -> bool:
        """Save frontmatter and body to file."""
        try:
            stream = StringIO()
            self.yaml.dump(data, stream)
            updated_frontmatter = stream.getvalue().rstrip()

            # Ensure body starts with newline.
            if not body.startswith("\n"):
                body = "\n" + body

            updated_content = f"---\n{updated_frontmatter}\n---{body}"

            return self.write_file_atomic(file_path, updated_content)

        except Exception as e:
            logger.error(f"Failed to save frontmatter for {file_path}: {e}")
            return False

    def add_frontmatter_if_missing(
        self, data: Dict[str, Any], body: str, file_path: str
    ) -> bool:
        """Add frontmatter to file if missing."""
        try:
            stream = StringIO()
            self.yaml.dump(data, stream)
            frontmatter = stream.getvalue().rstrip()

            # Ensure body starts with newline.
            if not body.startswith("\n"):
                body = "\n" + body

            updated_content = f"---\n{frontmatter}\n---{body}"

            if self.write_file_atomic(file_path, updated_content):
                logger.info(f"Added frontmatter to {file_path}")
                return True
            return False

        except Exception as e:
            logger.error(f"Failed to add frontmatter to {file_path}: {e}")
            return False

    def process_file(self, file_path: str, previous_hash: Optional[str] = None) -> bool:
        """Process a single markdown file."""
        try:
            # Calculate current hash.
            current_hash = self.calculate_file_hash(file_path)
            if not current_hash:
                return False

            # Skip if file hasn't changed (when using hash-based detection).
            if previous_hash and previous_hash == current_hash:
                logger.debug(f"File unchanged, skipping: {file_path}")
                return True

            logger.info(f"Processing: {file_path}")

            # Create backup.
            backup_path = self.create_backup(file_path)

            # Read file content.
            content = self.read_markdown_file(file_path)
            if content is None:
                return False

            # Split frontmatter and body.
            frontmatter_text, body = self.split_frontmatter(content, file_path)

            if frontmatter_text is not None:
                # File has frontmatter, update it.
                data = self.parse_yaml_frontmatter(frontmatter_text, file_path)
                if data is None:
                    return False

                modified = self.update_title_and_date(data, file_path)
                modified = self.update_categories(data, file_path) or modified

                if modified:
                    if self.save_frontmatter(data, body, file_path):
                        logger.info(f"Updated frontmatter for: {file_path}")
                        self.processed_files.append(file_path)
                        return True
                    else:
                        return False
                else:
                    logger.debug(f"No changes needed for: {file_path}")
                    return True
            else:
                # File missing frontmatter, add it.
                data = {}

                # Add title.
                default_title = (
                    os.path.basename(file_path)
                    .replace(".md", "")
                    .replace("_", " ")
                    .replace("-", " ")
                    .title()
                )
                data["title"] = DoubleQuotedScalarString(default_title)
                logger.info(f"Adding title to {file_path}: {default_title}")

                # Add date in RFC3339 format.
                current_date = datetime.utcnow().isoformat() + "Z"
                data["date"] = DoubleQuotedScalarString(current_date)
                logger.info(f"Adding date to {file_path}: {current_date}")

                # Add default category.
                data["categories"] = [DoubleQuotedScalarString("Uncategorized")]
                logger.info(f"Adding default category to {file_path}: Uncategorized")

                if self.add_frontmatter_if_missing(data, body, file_path):
                    self.processed_files.append(file_path)
                    return True
                else:
                    return False

        except Exception as e:
            logger.error(f"Unexpected error processing {file_path}: {e}")
            self.failed_files.append(file_path)
            return False

    def get_markdown_files(self, directory: str) -> List[str]:
        """Get all markdown files in directory recursively."""
        markdown_files = []
        try:
            for root, _, files in os.walk(directory):
                for file in files:
                    if file.endswith(".md"):
                        markdown_files.append(os.path.abspath(os.path.join(root, file)))
        except Exception as e:
            logger.error(f"Failed to scan directory {directory}: {e}")

        return markdown_files

    def print_summary(self):
        """Print processing summary."""
        logger.info(f"\n=== Processing Summary ===")
        logger.info(f"Successfully processed: {len(self.processed_files)} files")

        if self.failed_files:
            logger.error(f"Failed to process: {len(self.failed_files)} files")
            for failed_file in self.failed_files:
                logger.error(f"  - {failed_file}")

        if self.processed_files:
            logger.info("Modified files:")
            for processed_file in self.processed_files:
                logger.info(f"  - {processed_file}")


def main():
    """Main function with improved argument handling."""
    if len(sys.argv) < 2:
        logger.error("Usage: update_frontmatter.py <directory> [hash_file]")
        logger.error("  directory: Directory containing markdown files")
        logger.error("  hash_file: Optional hash file for change detection")
        sys.exit(1)

    target_directory = sys.argv[1]
    hash_file = sys.argv[2] if len(sys.argv) > 2 else None

    # Validate target directory.
    if not os.path.isdir(target_directory):
        logger.error(f"Target directory does not exist: {target_directory}")
        sys.exit(1)

    target_directory = os.path.abspath(target_directory)
    logger.info(f"Processing directory: {target_directory}")

    # Create processor with backup directory.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    backup_dir = os.path.join(script_dir, "backups", "frontmatter")
    processor = FrontmatterProcessor(backup_dir=backup_dir)

    # Load existing hashes if hash file provided.
    existing_hashes = {}
    if hash_file and os.path.exists(hash_file):
        existing_hashes = processor.load_existing_hashes(hash_file)
        logger.info(
            f"Using hash-based change detection with {len(existing_hashes)} existing hashes"
        )
    else:
        logger.info("Processing all files (no hash-based filtering)")

    # Get all markdown files.
    markdown_files = processor.get_markdown_files(target_directory)
    if not markdown_files:
        logger.warning(f"No markdown files found in {target_directory}")
        return

    logger.info(f"Found {len(markdown_files)} markdown files to process")

    # Process files.
    success_count = 0
    for file_path in markdown_files:
        previous_hash = existing_hashes.get(file_path)
        if processor.process_file(file_path, previous_hash):
            success_count += 1

    # Print summary.
    processor.print_summary()

    if success_count == len(markdown_files):
        logger.info("All files processed successfully")
    else:
        logger.error(
            f"Processing completed with errors: {success_count}/{len(markdown_files)} successful"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()

# ============================================================================ #
# End of update_frontmatter.py
