#!/usr/bin/env zsh
# shellcheck shell=zsh
# zsh-load: deferred
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
#   - remove_pdf_watermarks      Remove repeated watermark overlays via Python CLI.
#   - remove_pdf_metadata        Remove PDF metadata.
#   - remove_pdf_metadata_batch  Batch metadata removal.
#   - remove_pdf_metadata_simple Simplified metadata removal.
#
# Dependencies:
#   - qpdf      PDF manipulation (required for most functions).
#   - exiftool  Metadata removal (recommended).
#   - ddjvu     DjVu conversion (djvulibre package).
#   - python3   Bookmark copying and watermark removal (with pypdf/PyPDF2).
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# _pdf_install_hint
# @internal
# @description Prints platform-specific install commands for a required tool.
# @arg $1 string Tool name.
# @arg $2 path Homebrew package name.
# @arg $3 path Arch package name.
# @arg $4 path Debian package name.
# @arg $5 path Optional Fedora package name.
# -----------------------------------------------------------------------------
_pdf_install_hint() {
    local tool="$1" brew_pkg="$2" arch_pkg="$3" apt_pkg="$4" dnf_pkg="${5:-$4}"
    print -u2 "Install $tool with:"
    case "$PLATFORM" in
        macOS) print -u2 "  brew install $brew_pkg" ;;
        Linux)
            if [[ "$ARCH_LINUX" == true ]]; then
                print -u2 "  sudo pacman -S $arch_pkg"
            else
                print -u2 "  sudo apt install $apt_pkg (Debian/Ubuntu)"
                print -u2 "  sudo dnf install $dnf_pkg (Fedora)"
            fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# pdfextract
# @description Extracts an inclusive page range from a PDF with qpdf.
# The end page is clamped to the document length when necessary.
# @arg $1 path Input PDF.
# @arg $2 integer First page, starting at 1.
# @arg $3 integer Last page, starting at 1.
# @arg $4 path Optional output PDF; generated when omitted.
# @exitcode 1 If dependencies, arguments, input, or extraction are invalid.
# -----------------------------------------------------------------------------
function pdfextract() {
    setopt localoptions pipefail no_aliases

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        _pdf_install_hint qpdf qpdf qpdf qpdf qpdf
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
# pdfrotate
# @description Rotates selected PDF pages in place with qpdf.
# Accepts left/l, right/r, or 180; pages default to all.
# @arg $1 path PDF to modify.
# @arg $2 string Rotation: left, right, or 180.
# @arg $3 string Optional page selection; defaults to all.
# @exitcode 1 If qpdf, input, permissions, rotation, or operation is invalid.
# -----------------------------------------------------------------------------
function pdfrotate() {
  # Validate required tools.
  if ! command -v qpdf >/dev/null 2>&1; then
    echo "${C_RED}Error: qpdf is required.${C_RESET}" >&2
    _pdf_install_hint qpdf qpdf qpdf qpdf qpdf
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
# @description Converts a DjVu document to PDF with ddjvu.
# The output filename defaults to the input basename with a .pdf extension.
# @arg $1 path Input DjVu document.
# @arg $2 path Optional output PDF.
# @exitcode 1 If ddjvu, input, arguments, or conversion is invalid.
# -----------------------------------------------------------------------------
function djvu_to_pdf() {
    setopt localoptions pipefail no_aliases

    # Check if ddjvu is installed (part of djvulibre).
    if ! command -v ddjvu >/dev/null 2>&1; then
        echo "${C_RED}Error: ddjvu is not installed.${C_RESET}" >&2
        _pdf_install_hint djvulibre djvulibre djvulibre djvulibre-bin djvulibre
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
# @description Copies bookmarks between PDFs using the repository's Python tool.
# The output filename defaults to the target basename with bookmarks appended.
# @arg $1 path Source PDF containing bookmarks.
# @arg $2 path Target PDF to receive bookmarks.
# @arg $3 path Optional output PDF.
# @exitcode 1 If dependencies, scripts, inputs, or copying are invalid.
# -----------------------------------------------------------------------------
function copy_pdf_bookmarks() {
    setopt localoptions pipefail no_aliases

    # Check if Python 3 is installed.
    if ! command -v python3 >/dev/null 2>&1; then
        echo "${C_RED}Error: Python 3 is not installed.${C_RESET}" >&2
        _pdf_install_hint "Python 3" python3 python python3 python3
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
# remove_pdf_watermarks
# @description Delegates watermark removal to the trusted Python CLI.
# Supports dry-run, diagnostics, text matching, reports, and fallback redaction.
# @arg $1 path Input PDF; additional output and CLI arguments may follow.
# @exitcode 1 If dependencies, scripts, backends, or processing are unavailable.
# -----------------------------------------------------------------------------
function remove_pdf_watermarks() {
    emulate -L zsh
    setopt localoptions pipefail no_aliases
    _zsh_ui_load || return 1

    # Check if Python 3 is installed.
    if ! command -v python3 >/dev/null 2>&1; then
        _zsh_ui_log error "Python 3 is not installed."
        _pdf_install_hint "Python 3" python3 python python3 python3
        return 1
    fi

    # Check if remove_watermarks.py script exists in trusted paths only.
    local script_path=""
    local -a script_candidates=(
        "${PDF_REMOVE_WATERMARKS_SCRIPT:-}"
        "${HOME}/.config/zsh/scripts/python/remove_watermarks.py"
        "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/python/remove_watermarks.py"
    )
    local candidate
    for candidate in "${script_candidates[@]}"; do
        [[ -n "$candidate" && -f "$candidate" && -r "$candidate" ]] || continue
        script_path="$candidate"
        break
    done

    if [[ -z "$script_path" ]]; then
        _zsh_ui_log error \
            "remove_watermarks.py was not found in trusted paths."
        echo "Checked:" >&2
        echo "  1. \$PDF_REMOVE_WATERMARKS_SCRIPT (if set)" >&2
        echo "  2. ${HOME}/.config/zsh/scripts/python/remove_watermarks.py" >&2
        echo "  3. ${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/python/remove_watermarks.py" >&2
        return 1
    fi

    # Show wrapper help if no arguments were provided.
    if [[ $# -eq 0 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_watermarks <input.pdf> [output.pdf] [options...]${C_RESET}" >&2
        echo "Examples:" >&2
        echo "  remove_pdf_watermarks file.pdf" >&2
        echo "  remove_pdf_watermarks file.pdf --dry-run --verbose" >&2
        echo "  remove_pdf_watermarks file.pdf cleaned.pdf --match-text \"Acquistato da\"" >&2
        echo "" >&2
        echo "Run 'remove_pdf_watermarks --help' for the full Python CLI help." >&2
        return 1
    fi

    # The Python script can show --help without a PDF backend installed.
    local help_mode=false
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            help_mode=true
            break
        fi
    done

    # Check if at least one supported PDF backend library is installed.
    if [[ "$help_mode" == false ]]; then
        if ! python3 -c 'import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("pypdf") or importlib.util.find_spec("PyPDF2") else 1)' 2>/dev/null; then
            _zsh_ui_log error "Neither pypdf nor PyPDF2 is installed."
            echo "Please install a supported backend first:" >&2
            echo "  python3 -m pip install pypdf" >&2
            echo "  or: python3 -m pip install PyPDF2" >&2
            return 1
        fi
    fi

    if [[ "$help_mode" == false ]]; then
        _zsh_ui_heading \
            "PDF watermark removal" \
            "Analyzing repeated text and overlay geometry"
    fi
    command python3 "$script_path" "$@"
}

# -----------------------------------------------------------------------------
# remove_pdf_metadata
# @description Removes PDF metadata with qpdf and optional exiftool cleanup.
# Omitting the output prompts before overwriting the input PDF.
# @arg $1 path Input PDF.
# @arg $2 path Optional output PDF; omission overwrites input after approval.
# @exitcode 1 If dependencies, input, validation, or cleanup fails.
# -----------------------------------------------------------------------------
function remove_pdf_metadata() {
    emulate -L zsh
    setopt localoptions pipefail no_aliases
    _zsh_ui_load || return 1

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        _zsh_ui_log error "qpdf is not installed."
        _pdf_install_hint qpdf qpdf qpdf qpdf qpdf
        return 1
    fi

    # Check if exiftool is installed (highly recommended for metadata removal).
    if ! command -v exiftool >/dev/null 2>&1; then
        _zsh_ui_log warn \
            "exiftool is unavailable; qpdf alone cannot remove all metadata."
        _pdf_install_hint exiftool exiftool perl-image-exiftool libimage-exiftool-perl perl-Image-ExifTool
        if ! _zsh_ui_confirm "Continue with basic qpdf cleanup?"; then
            _zsh_ui_log info "Operation cancelled."
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
        _zsh_ui_log error "Input file '$input_file' not found."
        return 1
    fi

    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        _zsh_ui_log error "Input file must be a PDF document."
        return 1
    fi

    # If no output file specified, overwrite the original.
    if [[ -z "$output_file" ]]; then
        overwrite_mode=true

        if ! _zsh_ui_confirm \
            "No output was specified. Overwrite '$input_file'?"; then
            _zsh_ui_log info "Operation cancelled."
            return 0
        fi

        # Use mktemp beside input so final mv is atomic across filesystems.
        # qpdf refuses an existing output, so remove the placeholder while
        # retaining the unique name. Register a trap for interruption cleanup.
        output_file="$(command mktemp "${input_file}.tmp.XXXXXX" 2>/dev/null)" || {
            _zsh_ui_log error "Unable to create a temporary output file."
            return 1
        }
        command rm -f -- "$output_file" 2>/dev/null
        trap 'command rm -f -- "$output_file" 2>/dev/null' EXIT INT TERM HUP
    else
        # Ensure output file has .pdf extension when user supplied a name.
        if [[ ! "$output_file" =~ \.(pdf|PDF)$ ]]; then
            output_file="${output_file}.pdf"
        fi
    fi

    # Check if output file already exists (and we're not in overwrite mode).
    if [[ "$overwrite_mode" == false && -f "$output_file" ]]; then
        if ! _zsh_ui_confirm \
            "Output '$output_file' already exists. Overwrite it?"; then
            _zsh_ui_log info "Operation cancelled."
            return 0
        fi
    fi

    # Display current metadata before removal (if exiftool is available).
    if command -v exiftool >/dev/null 2>&1; then
        _zsh_ui_section "Current metadata"
        local current_meta=$(exiftool -G -s "$input_file" 2>/dev/null | grep -E "(Author|Creator|Producer|Title|Subject|Keywords|CreateDate|ModifyDate)")
        if [[ -n "$current_meta" ]]; then
            echo "$current_meta"
        else
            echo "  (No standard metadata found)"
        fi
        echo
    fi

    # Perform metadata removal.
    _zsh_ui_heading \
        "PDF metadata removal" \
        "Cleaning '${input_file:t}'"

    # First, check if the PDF is valid.
    if ! qpdf --check "$input_file" >/dev/null 2>&1; then
        _zsh_ui_log warn \
            "PDF validation reported issues; attempting cleanup anyway."
    fi

    # Use qpdf to remove metadata - using basic compatible options.
    # Basic qpdf command works with all versions.
    local qpdf_error
    qpdf_error=$(qpdf "$input_file" "$output_file" 2>&1)

    if [[ $? -eq 0 ]]; then

        # qpdf alone doesn't remove metadata, we need exiftool for that.
        if command -v exiftool >/dev/null 2>&1; then
            _zsh_ui_log info "Removing extended metadata with exiftool."
            # Remove all metadata.
            if exiftool -all:all= -overwrite_original "$output_file" 2>/dev/null; then
                _zsh_ui_log ok "Extended metadata removed."
            else
                _zsh_ui_log warn "exiftool could not remove all metadata."
            fi
        else
            _zsh_ui_log warn "Only basic qpdf cleanup was performed."
            _pdf_install_hint exiftool exiftool perl-image-exiftool libimage-exiftool-perl perl-Image-ExifTool
        fi

        # If in overwrite mode, atomically replace the original file.
        if [[ "$overwrite_mode" == true ]]; then
            if ! command mv -f -- "$output_file" "$input_file"; then
                _zsh_ui_log error "Failed to replace the original file."
                trap - EXIT INT TERM HUP
                return 1
            fi
            output_file="$input_file"
            trap - EXIT INT TERM HUP
        fi

        local -a result_lines=("Output    $output_file")
        if command -v du >/dev/null 2>&1; then
            local input_size=$(du -h "$input_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            result_lines+=("Size      $input_size → $output_size")
        fi
        _zsh_ui_card "PDF metadata removed" "${result_lines[@]}"

        # Show remaining metadata (if exiftool is available).
        if command -v exiftool >/dev/null 2>&1; then
            echo
            _zsh_ui_section "Remaining metadata"
            local remaining_meta=$(exiftool -G -s "$output_file" 2>/dev/null | grep -E "(Author|Creator|Producer|Title|Subject|Keywords|CreateDate|ModifyDate)")
            if [[ -n "$remaining_meta" ]]; then
                echo "$remaining_meta"
            else
                echo "  ${C_GREEN}(All standard metadata removed)${C_RESET}"
            fi
        fi

    else
        # In overwrite mode, EXIT cleans up the temporary file on return.
        # In explicit-output mode, leave a partial file at the user-named path.

        _zsh_ui_log error "Failed to remove PDF metadata."
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
# @description Cleans multiple PDFs and creates copies with a _cleaned suffix.
# Uses qpdf and applies exiftool cleanup when available.
# @arg $1 path First PDF; additional PDFs may follow.
# @exitcode 1 If qpdf is unavailable or any input cannot be processed.
# -----------------------------------------------------------------------------
function remove_pdf_metadata_batch() {
    emulate -L zsh
    setopt localoptions pipefail no_aliases
    _zsh_ui_load || return 1

    # Check if at least one argument is provided.
    if [[ $# -lt 1 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_metadata_batch <file1.pdf> [file2.pdf] ...${C_RESET}" >&2
        echo "Example: remove_pdf_metadata_batch *.pdf" >&2
        return 1
    fi

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        _zsh_ui_log error "qpdf is not installed."
        return 1
    fi

    # Check if exiftool is installed.
    local exiftool_available=true
    if ! command -v exiftool >/dev/null 2>&1; then
        exiftool_available=false
        _zsh_ui_log warn \
            "exiftool is unavailable; only qpdf cleanup will be applied."
    fi

    local total_files=$#
    local success_count=0
    local fail_count=0

    _zsh_ui_section "PDF metadata batch · $total_files files"

    # Process each PDF file.
    for pdf_file in "$@"; do
        if [[ -f "$pdf_file" && "$pdf_file" =~ \.(pdf|PDF)$ ]]; then
            _zsh_ui_log info "Processing: $pdf_file"

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

                _zsh_ui_log ok "Created: $output_file"
                ((success_count++))
            else
                _zsh_ui_log error "Failed to process: $pdf_file"
                ((fail_count++))
            fi
        else
            _zsh_ui_log warn "Skipping non-PDF input: $pdf_file"
            ((fail_count++))
        fi
    done

    _zsh_ui_card \
        "PDF metadata batch complete" \
        "Successful  $success_count" \
        "Failed      $fail_count"
    (( fail_count == 0 ))
}

# -----------------------------------------------------------------------------
# remove_pdf_metadata_simple
# @description Performs simplified qpdf metadata cleanup for problematic PDFs.
# Creates a _cleaned PDF when no output path is supplied.
# @arg $1 path Input PDF.
# @arg $2 path Optional output PDF.
# @exitcode 1 If qpdf, input, or processing is invalid.
# -----------------------------------------------------------------------------
function remove_pdf_metadata_simple() {
    emulate -L zsh
    setopt localoptions pipefail no_aliases
    _zsh_ui_load || return 1

    # Check if correct number of arguments is provided.
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "${C_YELLOW}Usage: remove_pdf_metadata_simple <input.pdf> [output.pdf]${C_RESET}" >&2
        echo "This is a simplified version that works with problematic PDFs." >&2
        return 1
    fi

    # Check if qpdf is installed.
    if ! command -v qpdf >/dev/null 2>&1; then
        _zsh_ui_log error "qpdf is not installed."
        return 1
    fi

    local input_file="$1"
    local output_file="${2:-}"

    # Check if input file exists and is a PDF.
    if [[ ! -f "$input_file" ]]; then
        _zsh_ui_log error "Input file '$input_file' not found."
        return 1
    fi

    # Check if input file is a PDF.
    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        _zsh_ui_log error "Input file must be a PDF document."
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
        if ! _zsh_ui_confirm \
            "Output '$output_file' already exists. Overwrite it?"; then
            _zsh_ui_log info "Operation cancelled."
            return 0
        fi
    fi

    _zsh_ui_heading \
        "Simple PDF metadata cleanup" \
        "Processing '${input_file:t}'"

    # Try the simplest possible qpdf command.
    if qpdf "$input_file" "$output_file" 2>&1; then
        _zsh_ui_log ok "Created: $output_file"

        # Try to remove additional metadata with exiftool if available.
        if command -v exiftool >/dev/null 2>&1; then
            _zsh_ui_log info "Removing extended metadata with exiftool."
            exiftool -all:all= -overwrite_original "$output_file" >/dev/null 2>&1
            _zsh_ui_log ok "Extended metadata removed."
        fi

        return 0
    else
        _zsh_ui_log error "Simple PDF processing failed."
        return 1
    fi
}

# ============================================================================ #
# End of pdf.zsh
