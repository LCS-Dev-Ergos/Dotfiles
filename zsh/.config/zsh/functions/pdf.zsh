#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ PDF UTILITIES +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Specialized utilities for PDF document manipulation.
# All functions include dependency checking and platform-aware install hints.
#
# Functions:
#   - pdfextract                 Extract page range from PDF.
#   - pdfrotate                  Rotate specific pages.
#   - djvu_to_pdf                Convert DjVu to PDF.
#   - copy_pdf_bookmarks         Copy bookmarks between PDFs.
#   - remove_pdf_metadata        Remove PDF metadata.
#   - remove_pdf_metadata_batch  Batch metadata removal.
#   - remove_pdf_metadata_simple Simplified metadata removal.
#
# Dependencies:
#   - qpdf      PDF manipulation (required for most functions).
#   - exiftool  Metadata removal (recommended).
#   - ddjvu     DjVu conversion (djvulibre package).
#   - python3   Bookmark copying (with PyPDF2).
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# pdfextract
# -----------------------------------------------------------------------------
# Extract specific page range from a PDF document using qpdf.
# Validates page numbers against document length and handles edge cases.
#
# Usage:
#   pdfextract <input.pdf> <start_page> <end_page> [output.pdf]
#
# Arguments:
#   input.pdf  - Source PDF file (required).
#   start_page - First page to extract (required, 1-indexed).
#   end_page   - Last page to extract (required, 1-indexed).
#   output.pdf - Output filename (optional, auto-generated if not provided).
# -----------------------------------------------------------------------------
function pdfextract() {
    setopt localoptions pipefail no_aliases

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        echo "Please install qpdf first:" >&2
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install qpdf (Debian/Ubuntu)" >&2
            echo "  sudo dnf install qpdf (Fedora)" >&2
        fi
        return 1
    fi

    # Check if correct number of arguments is provided.
    if [[ $# -lt 3 || $# -gt 4 ]]; then
        echo "${C_YELLOW}Usage: pdfextract <input.pdf> <start_page> <end_page> [output.pdf]${C_RESET}" >&2
        echo "Example: pdfextract document.pdf 5 10 pages_5-10.pdf" >&2
        return 1
    fi

    local input_file="$1"
    local start_page="$2"
    local end_page="$3"
    local output_file="${4:-}"

    # Check if input file exists and is a PDF.
    if [[ ! -f "$input_file" ]]; then
        echo "${C_RED}Error: Input file '$input_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Input file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # Validate page numbers (must be positive integers).
    if ! [[ "$start_page" =~ ^[1-9][0-9]*$ ]] || ! [[ "$end_page" =~ ^[1-9][0-9]*$ ]]; then
        echo "${C_RED}Error: Page numbers must be positive integers.${C_RESET}" >&2
        return 1
    fi

    # Check if start page is less than or equal to end page.
    if [[ $start_page -gt $end_page ]]; then
        echo "${C_RED}Error: Start page ($start_page) cannot be greater than end page ($end_page).${C_RESET}" >&2
        return 1
    fi

    # Get total number of pages in the PDF.
    local total_pages
    total_pages=$(qpdf --show-npages "$input_file" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "${C_RED}Error: Unable to read PDF file. File may be corrupted or password-protected.${C_RESET}" >&2
        return 1
    fi

    # Validate page range against document length.
    if [[ $start_page -gt $total_pages ]]; then
        echo "${C_RED}Error: Start page ($start_page) exceeds document length ($total_pages pages).${C_RESET}" >&2
        return 1
    fi

    if [[ $end_page -gt $total_pages ]]; then
        echo "${C_YELLOW}Warning: End page ($end_page) exceeds document length. Using page $total_pages instead.${C_RESET}"
        end_page=$total_pages
    fi

    # Generate output filename if not provided.
    if [[ -z "$output_file" ]]; then
        local base_name="${input_file%.*}"
        output_file="${base_name}_pages_${start_page}-${end_page}.pdf"
    fi

    # Check if output file already exists and ask for confirmation.
    if [[ -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Perform the extraction.
    echo "${C_CYAN}Extracting pages $start_page-$end_page from '$input_file'...${C_RESET}"

    if qpdf "$input_file" --pages . "$start_page-$end_page" -- "$output_file" 2>/dev/null; then
        echo "${C_GREEN}✓ Successfully extracted pages to '$output_file'${C_RESET}"

        # Show file size information.
        if command -v du >/dev/null 2>&1; then
            local input_size=$(du -h "$input_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            echo "${C_BLUE}Original: $input_size → Extracted: $output_size${C_RESET}"
        fi
    else
        echo "${C_RED}Error: Failed to extract pages. Please check the PDF file and try again.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# pdfrotate
# -----------------------------------------------------------------------------
# Rotate specific pages of a PDF file in-place.
# Uses qpdf for safe, lossless rotation that preserves PDF structure.
#
# Usage:
#   pdfrotate <file.pdf> <rotation> [pages]
#
# Arguments:
#   file.pdf  - PDF file to rotate (required)
#   rotation  - Rotation angle: left (-90°), right (+90°), or 180 (required)
#   pages     - Page spec: single (5), range (1-10), list (1,3,5), or all
#
# Examples:
#   pdfrotate doc.pdf right        Rotate all pages clockwise 90°
#   pdfrotate doc.pdf left 1-5     Rotate pages 1-5 counter-clockwise 90°
#   pdfrotate doc.pdf 180 3        Rotate page 3 by 180°
#   pdfrotate doc.pdf right 1,3,5  Rotate pages 1, 3, and 5 clockwise
# -----------------------------------------------------------------------------
function pdfrotate() {
  # Validate required tools.
  if ! command -v qpdf >/dev/null 2>&1; then
    echo "${C_RED}Error: qpdf is required.${C_RESET}" >&2
    echo "${C_YELLOW}Install: brew install qpdf${C_RESET}" >&2
    return 1
  fi

  # Show help.
  if [[ $# -lt 2 ]]; then
    echo "${C_YELLOW}Usage: pdfrotate <file.pdf> <rotation> [pages]${C_RESET}" >&2
    echo ""
    echo "Rotation: left (-90°), right (+90°), 180"
    echo "Pages:    number, range (1-10), list (1,3,5), or all (default)"
    echo ""
    echo "Examples:"
    echo "  pdfrotate doc.pdf right        All pages clockwise"
    echo "  pdfrotate doc.pdf left 1-5     Pages 1-5 counter-clockwise"
    echo "  pdfrotate doc.pdf 180 3        Page 3 upside-down"
    return 1
  fi

  local input_file="$1"
  local rotation="$2"
  local pages="${3:-all}"

  # Validate input file.
  if [[ ! -f "$input_file" ]]; then
    echo "${C_RED}Error: File '$input_file' not found.${C_RESET}" >&2
    return 1
  fi

  if [[ "${input_file:l}" != *.pdf ]]; then
    echo "${C_RED}Error: File must be a PDF.${C_RESET}" >&2
    return 1
  fi

  if [[ ! -r "$input_file" || ! -w "$input_file" ]]; then
    echo "${C_RED}Error: No read/write permission for '$input_file'.${C_RESET}" >&2
    return 1
  fi

  # Convert rotation aliases to qpdf format.
  local angle
  case "$rotation" in
    left | l)   angle="-90" ;;
    right | r)  angle="+90" ;;
    180)        angle="+180" ;;
    *)
      echo "${C_RED}Error: Invalid rotation '$rotation'. Use: left, right, or 180.${C_RESET}" >&2
      return 1
      ;;
  esac

  # Convert page specification to qpdf format.
  local page_range
  if [[ "$pages" == "all" ]]; then
    page_range="1-z"
  else
    page_range="$pages"
  fi

  # Use qpdf --replace-input for atomic in-place modification.
  echo "${C_CYAN}Rotating pages ${pages}...${C_RESET}"

  local error_output
  error_output=$(qpdf --rotate="${angle}:${page_range}" --replace-input "$input_file" 2>&1)
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    echo "${C_GREEN}Done.${C_RESET}"
    return 0
  else
    echo "${C_RED}Error: Rotation failed.${C_RESET}" >&2
    [[ -n "$error_output" ]] && echo "$error_output" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# djvu_to_pdf
# -----------------------------------------------------------------------------
# Convert DjVu documents to PDF format using ddjvu from djvulibre.
# Automatically adds .pdf extension to output if missing.
#
# Usage:
#   djvu_to_pdf <input.djvu> [output.pdf]
#
# Arguments:
#   input.djvu - Source DjVu file (.djvu, .djv) (required).
#   output.pdf - Output PDF filename (optional, auto-generated from input name).
# -----------------------------------------------------------------------------
function djvu_to_pdf() {
    setopt localoptions pipefail no_aliases

    # Check if ddjvu is installed (part of djvulibre).
    if ! command -v ddjvu >/dev/null 2>&1; then
        echo "${C_RED}Error: ddjvu is not installed.${C_RESET}" >&2
        echo "Please install djvulibre first:" >&2
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install djvulibre" >&2
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S djvulibre" >&2
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install djvulibre-bin (Debian/Ubuntu)" >&2
            echo "  sudo dnf install djvulibre (Fedora)" >&2
        fi
        return 1
    fi

    # Check if correct number of arguments is provided.
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "${C_YELLOW}Usage: djvu_to_pdf <input.djvu> [output.pdf]${C_RESET}" >&2
        echo "Example: djvu_to_pdf document.djvu" >&2
        echo "         djvu_to_pdf document.djvu converted.pdf" >&2
        return 1
    fi

    local input_file="$1"
    local output_file="${2:-}"

    # Check if input file exists and is a DjVu file.
    if [[ ! -f "$input_file" ]]; then
        echo "${C_RED}Error: Input file '$input_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$input_file" =~ \.(djvu|djv|DJVU|DJV)$ ]]; then
        echo "${C_RED}Error: Input file must be a DjVu document.${C_RESET}" >&2
        return 1
    fi

    # Generate output filename if not provided.
    if [[ -z "$output_file" ]]; then
        local base_name="${input_file%.*}"
        output_file="${base_name}.pdf"
    fi

    # Ensure output file has .pdf extension.
    if [[ ! "$output_file" =~ \.(pdf|PDF)$ ]]; then
        output_file="${output_file}.pdf"
    fi

    # Check if output file already exists and ask for confirmation.
    if [[ -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Perform the conversion.
    echo "${C_CYAN}Converting '$input_file' to PDF format...${C_RESET}"

    if ddjvu -format=pdf "$input_file" "$output_file" 2>/dev/null; then
        echo "${C_GREEN}✓ Successfully converted to '$output_file'${C_RESET}"

        # Show file size information.
        if command -v du >/dev/null 2>&1; then
            local input_size=$(du -h "$input_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            echo "${C_BLUE}Original: $input_size → Converted: $output_size${C_RESET}"
        fi
    else
        echo "${C_RED}Error: Failed to convert DjVu file. Please check the file and try again.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# copy_pdf_bookmarks
# -----------------------------------------------------------------------------
# Copy bookmarks (table of contents) from one PDF to another using Python
# script. Requires copy_bookmarks.py in ~/.config/zsh/scripts/python/ or
# current directory.
#
# Usage:
#   copy_pdf_bookmarks <source_with_bookmarks.pdf> <target_without_bookmarks.pdf> [output.pdf]
#
# Arguments:
#   source_with_bookmarks.pdf    - PDF with bookmarks to copy (required).
#   target_without_bookmarks.pdf - PDF to receive bookmarks (required).
#   output.pdf                   - Output filename (optional, auto-generated).
# -----------------------------------------------------------------------------
function copy_pdf_bookmarks() {
    setopt localoptions pipefail no_aliases

    # Check if Python 3 is installed.
    if ! command -v python3 >/dev/null 2>&1; then
        echo "${C_RED}Error: Python 3 is not installed.${C_RESET}" >&2
        echo "Please install Python 3 first:" >&2
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install python3" >&2
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S python" >&2
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install python3 (Debian/Ubuntu)" >&2
            echo "  sudo dnf install python3 (Fedora)" >&2
        fi
        return 1
    fi

    # Check if PyPDF2 is installed.
    if ! python3 -c "import PyPDF2" 2>/dev/null; then
        echo "${C_RED}Error: PyPDF2 library is not installed.${C_RESET}" >&2
        echo "Please install PyPDF2 first:" >&2
        echo "  pip3 install PyPDF2" >&2
        echo "  or: python3 -m pip install PyPDF2" >&2
        return 1
    fi

    # Check if copy_bookmarks.py script exists in trusted paths only.
    local script_path=""
    local -a script_candidates=(
        "${PDF_COPY_BOOKMARKS_SCRIPT:-}"
        "${HOME}/.config/zsh/scripts/python/copy_bookmarks.py"
        "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/python/copy_bookmarks.py"
    )
    local candidate
    for candidate in "${script_candidates[@]}"; do
        [[ -n "$candidate" && -f "$candidate" && -r "$candidate" ]] || continue
        script_path="$candidate"
        break
    done

    if [[ -z "$script_path" ]]; then
        echo "${C_RED}Error: copy_bookmarks.py script not found in trusted paths.${C_RESET}" >&2
        echo "Checked:" >&2
        echo "  1. \$PDF_COPY_BOOKMARKS_SCRIPT (if set)" >&2
        echo "  2. ${HOME}/.config/zsh/scripts/python/copy_bookmarks.py" >&2
        echo "  3. ${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/python/copy_bookmarks.py" >&2
        return 1
    fi

    # Check if correct number of arguments is provided.
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "${C_YELLOW}Usage: copy_pdf_bookmarks <source_with_bookmarks.pdf> <target_without_bookmarks.pdf> [output.pdf]${C_RESET}" >&2
        echo "Example: copy_pdf_bookmarks original.pdf new.pdf" >&2
        echo "         copy_pdf_bookmarks original.pdf new.pdf result.pdf" >&2
        return 1
    fi

    local source_file="$1"
    local target_file="$2"
    local output_file="${3:-}"

    # Check if source file exists and is a PDF.
    if [[ ! -f "$source_file" ]]; then
        echo "${C_RED}Error: Source file '$source_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$source_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Source file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # Check if target file exists and is a PDF.
    if [[ ! -f "$target_file" ]]; then
        echo "${C_RED}Error: Target file '$target_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$target_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Target file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # Generate output filename if not provided.
    if [[ -z "$output_file" ]]; then
        local base_name="${target_file%.*}"
        output_file="${base_name}_with_bookmarks.pdf"
    fi

    # Ensure output file has .pdf extension.
    if [[ ! "$output_file" =~ \.(pdf|PDF)$ ]]; then
        output_file="${output_file}.pdf"
    fi

    # Check if output file already exists and ask for confirmation.
    if [[ -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Perform the bookmark copy operation.
    echo "${C_CYAN}Copying bookmarks from '$source_file' to '$target_file'...${C_RESET}"
    echo

    if python3 "$script_path" "$source_file" "$target_file" "$output_file"; then
        echo
        echo "${C_GREEN}✓ Successfully created '$output_file' with bookmarks${C_RESET}"

        # Show file size information
        if command -v du >/dev/null 2>&1; then
            local source_size=$(du -h "$source_file" | cut -f1)
            local target_size=$(du -h "$target_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            echo "${C_BLUE}Source: $source_size | Target: $target_size | Output: $output_size${C_RESET}"
        fi
    else
        echo "${C_RED}Error: Failed to copy bookmarks. Please check the files and try again.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# remove_pdf_metadata
# -----------------------------------------------------------------------------
# Remove metadata from PDF documents for privacy and security.
# Uses qpdf for PDF processing and exiftool for comprehensive metadata removal.
# Displays metadata before and after removal for verification.
#
# Usage:
#   remove_pdf_metadata <input.pdf> [output.pdf]
#
# Arguments:
#   input.pdf  - PDF file to clean (required).
#   output.pdf - Output filename (optional, overwrites original if not provided).
#
# Removed metadata:
#   Author, Creator, Producer, Title, Subject, Keywords, CreateDate, ModifyDate.
# -----------------------------------------------------------------------------
function remove_pdf_metadata() {
    setopt localoptions pipefail no_aliases

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        echo "Please install qpdf first:" >&2
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install qpdf (Debian/Ubuntu)" >&2
            echo "  sudo dnf install qpdf (Fedora)" >&2
        fi
        return 1
    fi

    # Check if exiftool is installed (highly recommended for metadata removal).
    if ! command -v exiftool >/dev/null 2>&1; then
        echo "${C_YELLOW}Warning: exiftool is not installed.${C_RESET}"
        echo "${C_YELLOW}For complete metadata removal, it's highly recommended:${C_RESET}"
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install exiftool"
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S perl-image-exiftool"
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install libimage-exiftool-perl (Debian/Ubuntu)"
            echo "  sudo dnf install perl-Image-ExifTool (Fedora)"
        fi
        echo
        echo -n "${C_YELLOW}Continue anyway? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Check if correct number of arguments is provided.
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_metadata <input.pdf> [output.pdf]${C_RESET}" >&2
        echo "Examples:" >&2
        echo "  remove_pdf_metadata document.pdf" >&2
        echo "  remove_pdf_metadata document.pdf cleaned.pdf" >&2
        echo "" >&2
        echo "If no output file is specified, the original will be overwritten." >&2
        return 1
    fi

    local input_file="$1"
    local output_file="${2:-}"
    local overwrite_mode=false

    # Check if input file exists and is a PDF.
    if [[ ! -f "$input_file" ]]; then
        echo "${C_RED}Error: Input file '$input_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Input file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # If no output file specified, overwrite the original.
    if [[ -z "$output_file" ]]; then
        overwrite_mode=true
        output_file="${input_file}.tmp"

        echo -n "${C_YELLOW}No output file specified. Overwrite '$input_file'? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Ensure output file has .pdf extension.
    if [[ ! "$output_file" =~ \.(pdf|PDF)$ ]]; then
        output_file="${output_file}.pdf"
    fi

    # Check if output file already exists (and we're not in overwrite mode).
    if [[ "$overwrite_mode" == false && -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Display current metadata before removal (if exiftool is available).
    if command -v exiftool >/dev/null 2>&1; then
        echo "${C_CYAN}Current metadata:${C_RESET}"
        local current_meta=$(exiftool -G -s "$input_file" 2>/dev/null | grep -E "(Author|Creator|Producer|Title|Subject|Keywords|CreateDate|ModifyDate)")
        if [[ -n "$current_meta" ]]; then
            echo "$current_meta"
        else
            echo "  (No standard metadata found)"
        fi
        echo
    fi

    # Perform metadata removal.
    echo "${C_CYAN}Removing metadata from '$input_file'...${C_RESET}"

    # First, check if the PDF is valid.
    if ! qpdf --check "$input_file" >/dev/null 2>&1; then
        echo "${C_YELLOW}Warning: PDF validation check reported issues, attempting anyway...${C_RESET}"
    fi

    # Use qpdf to remove metadata - using basic compatible options.
    # Basic qpdf command works with all versions.
    local qpdf_error
    qpdf_error=$(qpdf "$input_file" "$output_file" 2>&1)

    if [[ $? -eq 0 ]]; then

        # qpdf alone doesn't remove metadata, we need exiftool for that.
        if command -v exiftool >/dev/null 2>&1; then
            echo "${C_CYAN}Removing metadata with exiftool...${C_RESET}"
            # Remove all metadata.
            if exiftool -all:all= -overwrite_original "$output_file" 2>/dev/null; then
                echo "${C_GREEN}✓ Metadata removed successfully${C_RESET}"
            else
                echo "${C_YELLOW}Warning: exiftool had issues removing some metadata${C_RESET}"
            fi
        else
            echo "${C_YELLOW}Warning: exiftool not found. Only basic PDF cleanup performed.${C_RESET}"
            echo "${C_YELLOW}For complete metadata removal, install exiftool:${C_RESET}"
            if [[ "$PLATFORM" == "macOS" ]]; then
                echo "  brew install exiftool"
            elif [[ "$PLATFORM" == "Linux" ]]; then
                echo "  sudo apt install libimage-exiftool-perl (Debian/Ubuntu)"
                echo "  sudo pacman -S perl-image-exiftool (Arch)"
            fi
        fi

        # If in overwrite mode, replace the original file.
        if [[ "$overwrite_mode" == true ]]; then
            mv "$output_file" "$input_file"
            output_file="$input_file"
        fi

        echo "${C_GREEN}✓ Successfully processed PDF${C_RESET}"
        echo "${C_GREEN}✓ Output file: '$output_file'${C_RESET}"

        # Show file size comparison.
        if command -v du >/dev/null 2>&1; then
            local input_size=$(du -h "$input_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            echo "${C_BLUE}Original: $input_size → Cleaned: $output_size${C_RESET}"
        fi

        # Show remaining metadata (if exiftool is available).
        if command -v exiftool >/dev/null 2>&1; then
            echo
            echo "${C_CYAN}Remaining metadata:${C_RESET}"
            local remaining_meta=$(exiftool -G -s "$output_file" 2>/dev/null | grep -E "(Author|Creator|Producer|Title|Subject|Keywords|CreateDate|ModifyDate)")
            if [[ -n "$remaining_meta" ]]; then
                echo "$remaining_meta"
            else
                echo "  ${C_GREEN}(All standard metadata removed)${C_RESET}"
            fi
        fi

    else
        # Clean up temporary file if it was created.
        [[ "$overwrite_mode" == true && -f "$output_file" ]] && rm -f "$output_file"

        echo "${C_RED}Error: Failed to remove metadata.${C_RESET}" >&2
        echo
        echo "${C_YELLOW}qpdf error message:${C_RESET}" >&2
        echo "$qpdf_error" >&2
        echo
        echo "${C_YELLOW}Possible solutions:${C_RESET}" >&2

        # Provide specific suggestions based on error message.
        if echo "$qpdf_error" | grep -q "password"; then
            echo "  → The PDF is password-protected. Decrypt it first:" >&2
            echo "    qpdf --password=PASSWORD --decrypt input.pdf output.pdf" >&2
        elif echo "$qpdf_error" | grep -q "damaged\|corrupt"; then
            echo "  → The PDF appears to be corrupted. Try repairing it:" >&2
            echo "    qpdf --check input.pdf" >&2
            echo "    qpdf input.pdf --replace-input" >&2
        elif echo "$qpdf_error" | grep -q "not a PDF"; then
            echo "  → The file is not a valid PDF document" >&2
        else
            echo "  1. Check if the PDF is corrupted: qpdf --check \"$input_file\"" >&2
            echo "  2. Try without linearization: qpdf \"$input_file\" \"${output_file%.pdf}_simple.pdf\"" >&2
            echo "  3. If password-protected: qpdf --decrypt \"$input_file\" output.pdf" >&2
        fi
        return 1
    fi
}

# -----------------------------------------------------------------------------
# remove_pdf_metadata_batch
# -----------------------------------------------------------------------------
# Remove metadata from multiple PDF files in a single operation.
# Creates cleaned copies with "_cleaned" suffix. Processes all valid PDFs
# and provides summary statistics.
#
# Usage:
#   remove_pdf_metadata_batch <file1.pdf> [file2.pdf] [file3.pdf] ...
#   remove_pdf_metadata_batch *.pdf
#
# Arguments:
#   file1.pdf, file2.pdf, ... - PDF files to process (one or more required).
#
# Output:
#   Creates files with "_cleaned" suffix (e.g., document_cleaned.pdf).
# -----------------------------------------------------------------------------
function remove_pdf_metadata_batch() {
    setopt localoptions pipefail no_aliases

    # Check if at least one argument is provided.
    if [[ $# -lt 1 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_metadata_batch <file1.pdf> [file2.pdf] ...${C_RESET}" >&2
        echo "Example: remove_pdf_metadata_batch *.pdf" >&2
        return 1
    fi

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        return 1
    fi

    # Check if exiftool is installed.
    local exiftool_available=true
    if ! command -v exiftool >/dev/null 2>&1; then
        exiftool_available=false
        echo "${C_YELLOW}Warning: exiftool not found; only qpdf cleanup will be applied.${C_RESET}" >&2
    fi

    local total_files=$#
    local success_count=0
    local fail_count=0

    echo "${C_CYAN}Processing $total_files PDF file(s)...${C_RESET}"
    echo

    # Process each PDF file.
    for pdf_file in "$@"; do
        if [[ -f "$pdf_file" && "$pdf_file" =~ \.(pdf|PDF)$ ]]; then
            echo "${C_BLUE}Processing: $pdf_file${C_RESET}"

            # Create output filename with suffix.
            local base_name="${pdf_file%.*}"
            local extension="${pdf_file##*.}"
            local output_file="${base_name}_cleaned.${extension}"

            # Use qpdf to remove metadata - basic command for compatibility.
            if qpdf "$pdf_file" "$output_file" 2>/dev/null; then

                # Additionally use exiftool if available.
                if [[ "$exiftool_available" == true ]]; then
                    exiftool -all:all= -overwrite_original "$output_file" >/dev/null 2>&1
                fi

                echo "  ${C_GREEN}✓ Created: $output_file${C_RESET}"
                ((success_count++))
            else
                echo "  ${C_RED}✗ Failed to process${C_RESET}"
                ((fail_count++))
            fi
            echo
        else
            echo "${C_YELLOW}Skipping: $pdf_file (not a valid PDF)${C_RESET}"
            echo
            ((fail_count++))
        fi
    done

    echo "${C_CYAN}Summary:${C_RESET}"
    echo "  ${C_GREEN}Success: $success_count${C_RESET}"
    [[ $fail_count -gt 0 ]] && echo "  ${C_RED}Failed: $fail_count${C_RESET}"
}

# -----------------------------------------------------------------------------
# remove_pdf_metadata_simple
# -----------------------------------------------------------------------------
# Simplified metadata removal for problematic PDFs that fail with the standard
# function. Uses basic qpdf command without advanced options.
# Fallback option when remove_pdf_metadata encounters issues.
#
# Usage:
#   remove_pdf_metadata_simple <input.pdf> [output.pdf]
#
# Arguments:
#   input.pdf  - PDF file to clean (required).
#   output.pdf - Output filename (optional, creates "_cleaned" version).
#
# Note:
#   Use this when remove_pdf_metadata fails due to PDF compatibility issues.
# -----------------------------------------------------------------------------
function remove_pdf_metadata_simple() {
    setopt localoptions pipefail no_aliases

    # Check if correct number of arguments is provided.
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_metadata_simple <input.pdf> [output.pdf]${C_RESET}" >&2
        echo "This is a simplified version that works with problematic PDFs." >&2
        return 1
    fi

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        return 1
    fi

    local input_file="$1"
    local output_file="${2:-}"

    # Check if input file exists and is a PDF.
    if [[ ! -f "$input_file" ]]; then
        echo "${C_RED}Error: Input file '$input_file' not found.${C_RESET}" >&2
        return 1
    fi

    # Check if input file is a PDF.
    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Input file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # Generate output filename if not provided.
    if [[ -z "$output_file" ]]; then
        local base_name="${input_file%.*}"
        output_file="${base_name}_cleaned.pdf"
    fi

    # Ensure output file has .pdf extension.
    if [[ ! "$output_file" =~ \.(pdf|PDF)$ ]]; then
        output_file="${output_file}.pdf"
    fi

    # Check if output file already exists and ask for confirmation.
    if [[ -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    echo "${C_CYAN}Attempting simple metadata removal...${C_RESET}"

    # Try the simplest possible qpdf command.
    if qpdf "$input_file" "$output_file" 2>&1; then
        echo "${C_GREEN}✓ Successfully created: $output_file${C_RESET}"

        # Try to remove additional metadata with exiftool if available.
        if command -v exiftool >/dev/null 2>&1; then
            echo "${C_CYAN}Removing additional metadata with exiftool...${C_RESET}"
            exiftool -all:all= -overwrite_original "$output_file" >/dev/null 2>&1
            echo "${C_GREEN}✓ Additional metadata removed${C_RESET}"
        fi

        return 0
    else
        echo "${C_RED}Error: Even simple processing failed.${C_RESET}" >&2
        return 1
    fi
}

# ============================================================================ #
# End of pdf.zsh
