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


def add_outline_recursively(writer, outline, source_reader, parent=None):
    """
    Recursive function that adds the original outline to the new PDF
    while maintaining the hierarchical structure.
    """
    # If outline is None or empty, terminate.
    if not outline:
        return None

    # If outline is a list, process each element at the same level.
    if isinstance(outline, list):
        for item in outline:
            add_outline_recursively(writer, item, source_reader, parent)
        return None

    # Now we have a single outline element (dictionary).
    if not isinstance(outline, dict):
        return None

    # Check if this is a valid bookmark with a title.
    if "/Title" not in outline:
        return None

    title = outline["/Title"]
    page_num = get_outline_page_number(source_reader, outline)

    # Create the bookmark in the new PDF with the correct parent.
    # Use positional argument for parent to ensure compatibility.
    try:
        # PyPDF2's add_outline_item signature: add_outline_item(title, page_number, parent=None).
        # We need to make sure parent is properly passed.
        if parent is not None:
            current_bookmark = writer.add_outline_item(title, page_num, parent)
        else:
            current_bookmark = writer.add_outline_item(title, page_num)
    except Exception as e:
        print(f"Warning: Could not add bookmark '{title}': {e}")
        return None

    # Now recursively process children if they exist.
    # Children are stored in a linked list structure using /First and /Next.
    if "/First" in outline and outline["/First"]:
        first_child = outline["/First"]

        # Process the first child with current_bookmark as parent.
        add_outline_recursively(
            writer, first_child, source_reader, parent=current_bookmark
        )

        # Process all siblings of the first child (they share the same parent).
        current_sibling = first_child
        while "/Next" in current_sibling and current_sibling["/Next"]:
            current_sibling = current_sibling["/Next"]
            add_outline_recursively(
                writer, current_sibling, source_reader, parent=current_bookmark
            )

    return current_bookmark


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
    Debug function to print the structure of bookmarks.
    """
    if indent > max_depth:
        return

    if not outline:
        return

    if isinstance(outline, list):
        print(f"{'  ' * indent}[List with {len(outline)} items]")
        for i, item in enumerate(outline):
            print(f"{'  ' * indent}Item {i}:")
            print_outline_structure(item, indent + 1, max_depth)
    elif isinstance(outline, dict):
        if "/Title" in outline:
            title = outline.get("/Title", "No title")
            print(f"{'  ' * indent}- {title}")
            if "/First" in outline:
                print(f"{'  ' * (indent + 1)}[Children:]")
                child = outline["/First"]
                print_outline_structure(child, indent + 2, max_depth)

                # Print siblings.
                current = child
                while "/Next" in current and current["/Next"]:
                    current = current["/Next"]
                    print_outline_structure(current, indent + 2, max_depth)


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
            except PyPDF2.PdfReadError as e:  # type: ignore
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
                # PyPDF2 can return outline as a list or as a nested dict structure.
                print("Copying bookmarks with hierarchy...")

                if isinstance(source_pdf.outline, list):
                    # Process each top-level item
                    for item in source_pdf.outline:
                        add_outline_recursively(
                            pdf_writer, item, source_pdf, parent=None
                        )
                else:
                    # Handle non-list outline structure.
                    add_outline_recursively(
                        pdf_writer, source_pdf.outline, source_pdf, parent=None
                    )

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
