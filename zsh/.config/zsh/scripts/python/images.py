#!/usr/bin/env python3

# ============================================================================ #
"""
Images Processing Script:
Processes Obsidian-style image links in markdown files and converts them to
Hugo-compatible format with improved error handling, atomic operations,
and comprehensive validation.

Author: XtremeXSPC
Version: 2.1.0
"""
# ============================================================================ #

import os
import re
import shutil
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Dict, List, Set, Optional, Tuple
import logging
import time

# Configure logging.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()],
)
logger = logging.getLogger(__name__)


class ImagesProcessor:
    """Handles image processing with atomic operations and comprehensive validation."""

    def __init__(self, config: Optional[Dict[str, str]] = None):
        """
        Initialize the images processor with configuration.

        Args:
            config: Optional configuration dictionary, will use environment variables if None.
        """
        self.config = self._load_configuration(config)
        self.processed_files = []
        self.failed_files = []
        self.copied_images = []
        self.missing_images = []

        # Validate configuration.
        self._validate_configuration()

        # Create backup directory.
        script_dir = os.path.dirname(os.path.abspath(__file__))
        self.backup_dir = os.path.join(script_dir, "backups", "images")
        os.makedirs(self.backup_dir, exist_ok=True)

        # Regex pattern for Obsidian image links.
        self.image_pattern = re.compile(
            r"\[\[([\w\s.-]+\.(?:png|jpg|jpeg|gif|bmp|webp|svg))\]\]", re.IGNORECASE
        )

    def _load_configuration(self, config: Optional[Dict[str, str]]) -> Dict[str, str]:
        """Load configuration from provided dict or environment variables."""
        if config:
            return config

        # Default configuration using environment variables.
        default_config = {
            "posts_dir": os.environ.get(
                "BLOG_POSTS_DIR", "/Volumes/LCS.Data/Blog/CS-Topics/content/posts/"
            ),
            "attachments_dir": os.environ.get(
                "OBSIDIAN_ATTACHMENTS_DIR",
                "/Users/lcs-dev/Documents/Obsidian-Vault/XSPC-Vault/Blog/images/",
            ),
            "static_images_dir": os.environ.get(
                "BLOG_STATIC_IMAGES_DIR",
                "/Volumes/LCS.Data/Blog/CS-Topics/static/images/",
            ),
        }

        return default_config

    def _validate_configuration(self):
        """Validate that all configured directories exist or can be created."""
        for key, directory in self.config.items():
            if not directory:
                raise ValueError(f"Configuration {key} is empty or not set")

            # Validate directory path security.
            if ".." in directory or not os.path.isabs(directory):
                raise ValueError(f"Invalid directory path for {key}: {directory}")

            # Check if directory exists.
            if key == "static_images_dir":
                # Create static images directory if it doesn't exist.
                try:
                    os.makedirs(directory, exist_ok=True)
                    logger.info(f"Ensured {key} directory exists: {directory}")
                except Exception as e:
                    raise RuntimeError(
                        f"Cannot create {key} directory {directory}: {e}"
                    )
            else:
                # Other directories must already exist.
                if not os.path.isdir(directory):
                    raise RuntimeError(f"{key} directory does not exist: {directory}")

            # Check permissions.
            if not os.access(directory, os.R_OK):
                raise RuntimeError(f"No read access to {key} directory: {directory}")

            if key in ["posts_dir", "static_images_dir"] and not os.access(
                directory, os.W_OK
            ):
                raise RuntimeError(f"No write access to {key} directory: {directory}")

        logger.info("Configuration validation completed successfully")

    def create_backup(self, file_path: str) -> Optional[str]:
        """Create a backup of the file before modification."""
        try:
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            backup_name = f"{os.path.basename(file_path)}_{timestamp}.backup"
            backup_path = os.path.join(self.backup_dir, backup_name)
            shutil.copy2(file_path, backup_path)
            logger.debug(f"Created backup: {backup_path}")
            return backup_path
        except Exception as e:
            logger.error(f"Failed to create backup for {file_path}: {e}")
            return None

    def validate_image_name(self, image_name: str) -> bool:
        """
        Validate image name for security and compatibility.

        Args:
            image_name: Name of the image file.

        Returns:
            True if valid, False otherwise.
        """
        # Check for path traversal attempts.
        if "/" in image_name or "\\" in image_name or ".." in image_name:
            logger.warning(f"Suspicious image name detected: {image_name}")
            return False

        # Check for valid file extension.
        valid_extensions = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg"}
        file_ext = os.path.splitext(image_name.lower())[1]
        if file_ext not in valid_extensions:
            logger.warning(f"Invalid image extension: {image_name}")
            return False

        # Check for reasonable filename length.
        if len(image_name) > 255:
            logger.warning(f"Image name too long: {image_name}")
            return False

        return True

    def process_image_reference(self, image_name: str) -> Tuple[str, bool]:
        """
        Process a single image reference.

        Args:
            image_name: Original image name from Obsidian.

        Returns:
            Tuple of (markdown_replacement, success_flag).
        """
        # Validate image name.
        if not self.validate_image_name(image_name):
            return f"![Image Description - Invalid: {image_name}]", False

        # URL-encode spaces and special characters for web compatibility.
        encoded_name = urllib.parse.quote(image_name, safe=".-_")
        markdown_replacement = f"![Image Description](/images/{encoded_name})"

        # Copy image to static directory.
        source_path = os.path.join(self.config["attachments_dir"], image_name)
        dest_path = os.path.join(self.config["static_images_dir"], image_name)

        if not os.path.exists(source_path):
            logger.warning(f"Image not found: {source_path}")
            self.missing_images.append(image_name)
            return f"![Image Description - Missing: {image_name}]", False

        if not os.access(source_path, os.R_OK):
            logger.warning(f"Cannot read image: {source_path}")
            return f"![Image Description - Unreadable: {image_name}]", False

        try:
            # Copy with metadata preservation.
            shutil.copy2(source_path, dest_path)
            logger.debug(f"Copied image: {image_name}")
            self.copied_images.append(image_name)
            return markdown_replacement, True
        except Exception as e:
            logger.error(f"Failed to copy {source_path} to {dest_path}: {e}")
            return f"![Image Description - Copy Failed: {image_name}]", False

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

    def process_file(self, file_path: str) -> bool:
        """
        Process a single markdown file for image references.

        Args:
            file_path: Path to the markdown file.

        Returns:
            True if successful, False otherwise.
        """
        filename = os.path.basename(file_path)

        # Check file accessibility.
        if not os.access(file_path, os.R_OK):
            logger.warning(f"Cannot read file {file_path}. Skipping.")
            return False

        # Read file content.
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()
        except Exception as e:
            logger.error(f"Failed to read {file_path}: {e}")
            return False

        # Find all image references.
        images = self.image_pattern.findall(content)

        if not images:
            logger.debug(f"No images found in {filename}")
            return True

        logger.info(f"Processing {len(images)} images in {filename}")

        # Create backup.
        backup_path = self.create_backup(file_path)

        # Process each image and update content.
        updated_content = content
        processed_images = set()  # Track processed images to avoid duplicates.
        success_count = 0

        for image in images:
            if image in processed_images:
                continue
            processed_images.add(image)

            # Process the image reference.
            markdown_replacement, success = self.process_image_reference(image)

            if success:
                success_count += 1

            # Replace all occurrences of this image reference.
            obsidian_pattern = f"[[{image}]]"
            updated_content = updated_content.replace(
                obsidian_pattern, markdown_replacement
            )

        # Write updated content if there were changes.
        if updated_content != content:
            if not os.access(file_path, os.W_OK):
                logger.warning(f"No write access to {file_path}. File not updated.")
                return False

            if self.write_file_atomic(file_path, updated_content):
                logger.info(
                    f"Updated {filename}: {success_count}/{len(processed_images)} images processed successfully"
                )
                return True
            else:
                logger.error(f"Failed to update {filename}")
                return False
        else:
            logger.debug(f"No changes needed for {filename}")
            return True

    def get_markdown_files(self) -> List[str]:
        """Get all markdown files in the posts directory."""
        markdown_files = []
        posts_dir = self.config["posts_dir"]

        try:
            for file in os.listdir(posts_dir):
                if file.endswith(".md"):
                    file_path = os.path.join(posts_dir, file)
                    markdown_files.append(file_path)
        except Exception as e:
            logger.error(f"Error reading posts directory: {e}")
            return []

        return sorted(markdown_files)

    def process_all_files(self) -> bool:
        """
        Process all markdown files in the posts directory.

        Returns:
            True if all files processed successfully, False otherwise.
        """
        start_time = time.time()

        # Get all markdown files.
        markdown_files = self.get_markdown_files()

        if not markdown_files:
            logger.warning("No markdown files found in the posts directory")
            return True

        logger.info(f"Processing {len(markdown_files)} markdown files")

        # Process each file.
        for file_path in markdown_files:
            try:
                if self.process_file(file_path):
                    self.processed_files.append(file_path)
                else:
                    self.failed_files.append(file_path)
            except Exception as e:
                logger.error(f"Unexpected error processing {file_path}: {e}")
                self.failed_files.append(file_path)

        # Print summary.
        elapsed_time = time.time() - start_time
        self.print_summary(elapsed_time)

        return len(self.failed_files) == 0

    def print_summary(self, elapsed_time: float):
        """Print processing summary."""
        logger.info(f"\n=== Image Processing Summary ===")
        logger.info(f"Files processed successfully: {len(self.processed_files)}")
        logger.info(f"Images copied: {len(self.copied_images)}")
        logger.info(f"Processing time: {elapsed_time:.2f} seconds")

        if self.failed_files:
            logger.error(f"Failed files: {len(self.failed_files)}")
            for failed_file in self.failed_files:
                logger.error(f"  - {failed_file}")

        if self.missing_images:
            logger.warning(f"Missing images: {len(self.missing_images)}")
            for missing_image in self.missing_images:
                logger.warning(f"  - {missing_image}")

        if self.copied_images:
            logger.info("Successfully processed images:")
            for copied_image in sorted(set(self.copied_images)):
                logger.info(f"  - {copied_image}")

    def cleanup_orphaned_images(self) -> int:
        """
        Remove orphaned images from static directory that are no longer referenced.

        Returns:
            Number of orphaned images removed.
        """
        logger.info("Checking for orphaned images...")

        # Get all images currently in static directory.
        static_images = set()
        static_dir = self.config["static_images_dir"]

        try:
            for file in os.listdir(static_dir):
                if any(
                    file.lower().endswith(ext)
                    for ext in [
                        ".png",
                        ".jpg",
                        ".jpeg",
                        ".gif",
                        ".bmp",
                        ".webp",
                        ".svg",
                    ]
                ):
                    static_images.add(file)
        except Exception as e:
            logger.error(f"Failed to read static images directory: {e}")
            return 0

        # Find all image references in markdown files.
        referenced_images = set()
        markdown_files = self.get_markdown_files()

        for file_path in markdown_files:
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    content = f.read()

                # Find markdown image references.
                markdown_pattern = re.compile(
                    r"!\[.*?\]\(/images/([^)]+)\)", re.IGNORECASE
                )
                matches = markdown_pattern.findall(content)

                for match in matches:
                    # URL decode the filename.
                    decoded_name = urllib.parse.unquote(match)
                    referenced_images.add(decoded_name)

            except Exception as e:
                logger.error(f"Failed to scan {file_path} for image references: {e}")

        # Find orphaned images.
        orphaned_images = static_images - referenced_images
        removed_count = 0

        for orphaned_image in orphaned_images:
            try:
                orphaned_path = os.path.join(static_dir, orphaned_image)
                os.remove(orphaned_path)
                logger.info(f"Removed orphaned image: {orphaned_image}")
                removed_count += 1
            except Exception as e:
                logger.error(f"Failed to remove orphaned image {orphaned_image}: {e}")

        if removed_count > 0:
            logger.info(f"Removed {removed_count} orphaned images")
        else:
            logger.info("No orphaned images found")

        return removed_count


def main():
    """Main function with configuration validation."""
    logger.info("Enhanced Image Processing Script v2.1.0")
    logger.info("Processing Obsidian image links for Hugo compatibility")

    try:
        # Create processor with default configuration.
        processor = ImagesProcessor()

        # Process all files
        success = processor.process_all_files()

        # Optional: Clean up orphaned images.
        # processor.cleanup_orphaned_images()

        if success:
            logger.info("Image processing completed successfully")
        else:
            logger.error("Image processing completed with errors")
            sys.exit(1)

    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

# ============================================================================ #
# End of images.py
