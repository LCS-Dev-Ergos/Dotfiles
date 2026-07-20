#!/usr/bin/env python3

# ============================================================================ #
"""
PDF Bookmark Copy Utility:
Copies the complete bookmark/outline structure from a source PDF to a target
PDF while preserving the hierarchical organization. Useful for restoring
bookmarks to PDFs that have been processed or regenerated without them.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

import PyPDF2
import sys
import os

# Check PyPDF2 version and warn if it's too old.
try:
    pypdf2_version = PyPDF2.__version__
    print(f"Using PyPDF2 version: {pypdf2_version}")

    # Suggest pypdf (the modern fork) if using old PyPDF2.
    major_version = int(pypdf2_version.split(".")[0])
    if major_version < 3:
        print("Note: You're using an old version of PyPDF2.")
        print("Consider upgrading: pip install --upgrade PyPDF2")
        print("Or switching to pypdf: pip install pypdf")
        print()
except AttributeError:
    print("Warning: Could not determine PyPDF2 version")
    print()


def get_outline_page_number(reader, outline_item):
    """
    Get the page number corresponding to an outline item.
    """
    try:
        return reader.get_destination_page_number(outline_item)
    except (AttributeError, KeyError, IndexError) as e:
        # Return 0 if the destination cannot be determined
        print(f"Warning: Could not determine page number for bookmark: {e}")
        return 0


def add_single_outline_item(writer, outline_item, source_reader, parent=None):
    """
    Add one outline entry to the writer and return the created bookmark
    handle, or None when the entry cannot be added.
    """
    if not isinstance(outline_item, dict) or "/Title" not in outline_item:
        return None

    title = outline_item["/Title"]
    page_num = get_outline_page_number(source_reader, outline_item)

    try:
        return writer.add_outline_item(title, page_num, parent)
    except Exception as e:
        print(f"Warning: Could not add bookmark '{title}': {e}")
        return None


def add_outline_list(writer, outline, source_reader, parent=None):
    """
    Copy a reader outline while maintaining the hierarchical structure.

    Modern PyPDF2/pypdf readers represent children as a nested list that
    immediately follows their parent Destination, so a nested list attaches
    to the most recently created bookmark at this level.
    """
    last_bookmark = parent
    for item in outline:
        if isinstance(item, list):
            add_outline_list(writer, item, source_reader, parent=last_bookmark)
            continue
        created = add_single_outline_item(writer, item, source_reader, parent)
        if created is not None:
            last_bookmark = created


def validate_pdf_file(file_path, file_description):
    """
    Validate that a file exists, is readable, and is a PDF.
    """
    # Check if file exists.
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"{file_description} not found: {file_path}")

    # Check if it's a file (not a directory).
    if not os.path.isfile(file_path):
        raise ValueError(f"{file_description} is not a file: {file_path}")

    # Check if file is readable.
    if not os.access(file_path, os.R_OK):
        raise PermissionError(f"{file_description} is not readable: {file_path}")

    # Basic check for PDF extension.
    if not file_path.lower().endswith(".pdf"):
        print(f"Warning: {file_description} does not have .pdf extension")


def print_outline_structure(outline, indent=0, max_depth=10):
    """
    Debug function to print the outline tree as parsed by the reader.
    """
    if indent > max_depth or not outline:
        return

    if isinstance(outline, list):
        for item in outline:
            if isinstance(item, list):
                print_outline_structure(item, indent + 1, max_depth)
            elif isinstance(item, dict):
                print(f"{'  ' * indent}- {item.get('/Title', 'No title')}")
    elif isinstance(outline, dict):
        print(f"{'  ' * indent}- {outline.get('/Title', 'No title')}")


def copy_bookmarks(source_pdf_path, target_pdf_path, output_pdf_path):
    """
    Copy the exact bookmark structure from a source PDF to a target PDF.
    """
    try:
        # Validate input files.
        print("Validating input files...")
        validate_pdf_file(source_pdf_path, "Source PDF")
        validate_pdf_file(target_pdf_path, "Target PDF")

        # Check if output directory is writable.
        output_dir = os.path.dirname(output_pdf_path) or "."
        if not os.access(output_dir, os.W_OK):
            raise PermissionError(f"Output directory is not writable: {output_dir}")

        print(f"Copying bookmarks from {source_pdf_path} to {target_pdf_path}...")

        # Open the source PDF (the one with bookmarks).
        with open(source_pdf_path, "rb") as source_file:
            try:
                source_pdf = PyPDF2.PdfReader(source_file)
            except PyPDF2.errors.PdfReadError as e:
                raise ValueError(f"Cannot read source PDF: {e}")

            # Check that the source PDF contains bookmarks.
            if not source_pdf.outline:
                print("The source PDF does not contain bookmarks.")
                return

            # Open the target PDF (the one without bookmarks).
            with open(target_pdf_path, "rb") as target_file:
                try:
                    target_pdf = PyPDF2.PdfReader(target_file)
                except PyPDF2.errors.PdfReadError as e:  # type: ignore
                    raise ValueError(f"Cannot read target PDF: {e}")

                # Create a new PDF writer.
                pdf_writer = PyPDF2.PdfWriter()

                # Add all pages from the target PDF.
                for page in target_pdf.pages:
                    pdf_writer.add_page(page)

                # Copy metadata if present.
                if hasattr(target_pdf, "metadata") and target_pdf.metadata:
                    for key, value in target_pdf.metadata.items():
                        pdf_writer.add_metadata({key: value})

                # Print debug information about the source outline.
                print("\nSource outline structure:")
                print_outline_structure(source_pdf.outline)
                print()

                # Copy the outline structure maintaining hierarchy.
                print("Copying bookmarks with hierarchy...")

                outline = source_pdf.outline
                if not isinstance(outline, list):
                    outline = [outline]
                add_outline_list(pdf_writer, outline, source_pdf)

                # Save the new PDF with bookmarks.
                with open(output_pdf_path, "wb") as output_file:
                    pdf_writer.write(output_file)

        print(f"PDF with copied bookmarks saved as: {output_pdf_path}")

    except FileNotFoundError as e:
        print(f"File error: {str(e)}")
        sys.exit(1)
    except PermissionError as e:
        print(f"Permission error: {str(e)}")
        sys.exit(1)
    except ValueError as e:
        print(f"Validation error: {str(e)}")
        sys.exit(1)
    except Exception as e:
        print(f"Error copying bookmarks: {str(e)}")
        import traceback

        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(
            "Usage: python copy-bookmarks.py <source_pdf_with_bookmarks> <target_pdf_without_bookmarks> <output_pdf>"
        )
        sys.exit(1)

    source_pdf = sys.argv[1]
    target_pdf = sys.argv[2]
    output_pdf = sys.argv[3]

    copy_bookmarks(source_pdf, target_pdf, output_pdf)

# ============================================================================ #
# End of copy_bookmarks.py
