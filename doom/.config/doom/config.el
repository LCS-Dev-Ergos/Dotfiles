;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; ============================================================================
;; PERSONAL INFORMATION
;; ============================================================================
;; Some functionality uses this to identify you (GPG, email clients, templates)
;; (setq user-full-name "Your Name"
;;       user-mail-address "your.email@example.com")

;; ============================================================================
;; THEME & APPEARANCE
;; ============================================================================
(setq doom-theme 'doom-tokyo-night)
(setq display-line-numbers-type t)  ; Show line numbers (use 'relative for relative numbers)

;; ============================================================================
;; FONTS
;; ============================================================================
;; Using Iosevka Nerd Font - clean, mathematical aesthetic with full glyph support
;; Install with: brew install font-iosevka-nerd-font
;; 
;; Alternatives:
;;   - "JetBrainsMono Nerd Font" - clear ligatures, excellent readability
;;   - "FiraCode Nerd Font" - classic choice with great ligatures
;;   - "CaskaydiaCove Nerd Font" - (Cascadia Code) Microsoft's font

(setq doom-font (font-spec :family "Iosevka Nerd Font" :size 16 :weight 'regular)
      doom-variable-pitch-font (font-spec :family "Iosevka Nerd Font" :size 16)
      doom-serif-font (font-spec :family "CMU Serif" :size 16))

;; Hybrid approach: use Computer Modern for prose
;; (setq doom-font (font-spec :family "Iosevka Nerd Font" :size 14)
;;       doom-variable-pitch-font (font-spec :family "Latin Modern Roman" :size 15)
;;       doom-serif-font (font-spec :family "Latin Modern Roman" :size 15))

;; ============================================================================
;; LIGATURES (Font Ligatures)
;; ============================================================================
;; Enables programming ligatures like -> => != >= etc.
;; Requires Emacs 27+ and a font with ligature support
;; Make sure ligatures module is enabled in init.el: (ligatures +extra)

(after! ligature
  ;; Disable ligatures in comments and strings
  (setq-default ligature-ignored-contexts
                '(comment string))
  
  ;; Enable comprehensive set of ligatures in programming modes
  (ligature-set-ligatures 'prog-mode
                          '("www" "**" "***" "**/" "*>" "*/" "\\\\" "\\\\\\"
                            "{-" "[]" "::" ":::" ":=" "!!" "!=" "!==" "-}"
                            "--" "---" "-->" "->" "->>" "-<" "-<<" "-~"
                            "#{" "#[" "##" "###" "####" "#(" "#?" "#_" "#_("
                            ".-" ".=" ".." "..<" "..." "?=" "??" ";;" "/*"
                            "/**" "/=" "/==" "/>" "//" "///" "&&" "||" "||="
                            "|=" "|>" "^=" "$>" "++" "+++" "+>" "=:=" "=="
                            "===" "==>" "=>" "=>>" "<=" "=<<" "=/=" ">-" ">="
                            ">=>" ">>" ">>-" ">>=" ">>>" "<*" "<*>" "<|" "<|>"
                            "<$" "<$>" "<!--" "<-" "<--" "<->" "<+" "<+>" "<="
                            "<==" "<=>" "<=<" "<>" "<<" "<<-" "<<=" "<<<" "<~"
                            "<~~" "</" "</>" "~@" "~-" "~=" "~>" "~~" "~~>" "%%"))
  
  ;; OCaml-specific ligatures
  (ligature-set-ligatures 'tuareg-mode
                          '("->" "=>" "<-" "::" ":::" "|>" "<|" 
                            ">=" "<=" ">>" "<<" ">>=" "<<=" 
                            ":=" "!=" "<>" "@@"))
  
  ;; Coq-specific ligatures  
  (ligature-set-ligatures 'coq-mode
                          '("->" "=>" "<-" "::" "|-" "<>" ">=" "<="
                            "==>" "<=>" "<->" "/\\" "\\/" 
                            ":=" "forall" "exists"))
  
  ;; LaTeX ligatures (for mathematical symbols)
  (ligature-set-ligatures 'latex-mode
                          '("--" "---" "``" "''" "<<" ">>" 
                            "->" "<-" "=>" "<="))
  
  ;; Activate ligatures globally
  (global-ligature-mode t))

;; ============================================================================
;; ORG MODE
;; ============================================================================
(setq org-directory "~/org/")

(after! org
  ;; Keep leading stars visible (better for outline structure visualization)
  (setq org-hide-leading-stars nil)
  
  ;; Hugo integration for static site generation from Org files
  ;; Requires ox-hugo package (usually included in Doom's org module)
  (require 'ox-hugo)
  
  ;; LaTeX preview improvements (useful for mathematical content)
  (setq org-preview-latex-default-process 'dvipng)  ; or 'imagemagick
  (setq org-format-latex-options
        (plist-put org-format-latex-options :scale 1.5))  ; Larger LaTeX previews
  
  ;; Better LaTeX export defaults
  (setq org-latex-compiler "xelatex")  ; Better Unicode support than pdflatex
  
  ;; Enable syntax highlighting in exported PDFs
  (setq org-latex-src-block-backend 'minted
        org-latex-packages-alist '(("" "minted")))
  (setq org-latex-pdf-process
        '("xelatex -shell-escape -interaction nonstopmode -output-directory %o %f"
          "xelatex -shell-escape -interaction nonstopmode -output-directory %o %f"))
  
  ;; Prettier org mode with modern bullets
  (setq org-superstar-headline-bullets-list '("◉" "○" "●" "○" "●" "○" "●")))

;; ============================================================================
;; MARKDOWN
;; ============================================================================
;; Use Pandoc for rich Markdown preview with MathJax support
(setq markdown-command "pandoc --standalone --mathjax --highlight-style=pygments --from=markdown_mmd --to=html5")

;; ============================================================================
;; TERMINAL (VTERM)
;; ============================================================================
;; Customized color scheme for vterm (Gruvbox-inspired)
(after! vterm
  (set-face-attribute 'vterm-color-black nil :background "#282828" :foreground "#282828")
  (set-face-attribute 'vterm-color-underline nil :foreground "#8ec07c" :underline t)
  (set-face-attribute 'vterm-color-inverse-video nil :background "#282828" :inverse-video t)

  (setq vterm-color-black   "#282828"
        vterm-color-red     "#cc241d"
        vterm-color-green   "#98971a"
        vterm-color-yellow  "#d79921"
        vterm-color-blue    "#458588"
        vterm-color-magenta "#b16286"
        vterm-color-cyan    "#689d6a"
        vterm-color-white   "#a89984"))

;; ============================================================================
;; COQ & PROOF GENERAL (Theorem Proving)
;; ============================================================================
;; Coq is a formal proof management system
;; Proof General provides an interactive interface for theorem provers in Emacs
;; Make sure you have enabled the 'coq' module in init.el

(after! coq
  ;; Set the path to coqtop executable (auto-detected if in PATH)
  (setq coq-prog-name "coqtop")
  
  ;; Compile Coq files on save (useful for catching errors early)
  (setq coq-compile-before-require t)
  
  ;; Use unicode symbols for better readability
  (setq coq-use-editing-holes t)
  
  ;; Auto-completion support (if using company-coq)
  ;; company-coq provides IDE-like features: auto-completion, documentation, etc.
  ;; Requires: (coq +company) in init.el
  )

(after! proof-general
  ;; Disable splash screen for faster startup
  (setq proof-splash-enable nil)
  
  ;; Hybrid window layout: combines goals and response buffers intelligently
  (setq proof-three-window-mode-policy 'hybrid)
  
  ;; Auto-raise Emacs when Coq finishes processing (optional)
  ;; (setq proof-auto-raise-buffers t)
  
  ;; Delete empty windows when proof is completed (cleaner workspace)
  (setq proof-delete-empty-windows t)
  
  ;; Unicode math symbols support (makes Coq code more readable)
  (setq proof-use-unicode-symbols t)
  
  ;; Show proof state in mode line
  (setq proof-shell-show-proof-state-in-mode-line t))

;; ============================================================================
;; OCAML (via Tuareg)
;; ============================================================================
;; Tuareg provides OCaml editing support
;; Make sure you have enabled (ocaml +lsp) in init.el for full IDE features
;; LSP provides: auto-completion, go-to-definition, documentation, refactoring

(after! tuareg
  ;; Indentation settings (OCaml community standard is 2 spaces)
  (setq tuareg-indent-align-with-first-arg t)
  (setq tuareg-match-patterns-aligned t)
  
  ;; Show type information on hover (requires LSP)
  (setq lsp-ocaml-show-type-info t)
  
  ;; Prettier symbols (optional)
  (setq tuareg-prettify-symbols-full t))

;; OCaml format on save (requires ocamlformat installed)
;; Install: opam install ocamlformat
(after! format-all
  (add-hook 'tuareg-mode-hook #'format-all-mode))

;; ============================================================================
;; LATEX (LaTeX alongside Coq/OCaml)
;; ============================================================================
;; AUCTeX provides comprehensive LaTeX editing support
;; Enable with: (latex +lsp) in init.el

(after! latex
  ;; Use XeLaTeX by default (better Unicode and font support)
  (setq-default TeX-engine 'xetex)
  
  ;; Enable synctex for PDF<->source synchronization
  (setq TeX-source-correlate-mode t)
  (setq TeX-source-correlate-start-server t)
  
  ;; Auto-save before compiling
  (setq TeX-save-query nil)
  
  ;; Use PDF mode by default (not DVI)
  (setq TeX-PDF-mode t)
  
  ;; Automatically insert braces
  (setq LaTeX-electric-left-right-brace t)
  
  ;; Fold macros for cleaner view
  (setq TeX-fold-mode t)
  
  ;; Use the Computer Modern font in LaTeX documents (LaTeX default)
  (setq LaTeX-font-family "cmr"))

;; ============================================================================
;; SPELL CHECKING (Optional - uncomment to enable)
;; ============================================================================
;; Requires: aspell or hunspell installed on your system
;; Install: brew install aspell (on macOS)

;; (setq ispell-program-name "aspell")
;; (setq ispell-extra-args '("--sug-mode=ultra" "--lang=en"))

;; Enable spell checking in text modes
;; (add-hook 'text-mode-hook 'flyspell-mode)
;; (add-hook 'org-mode-hook 'flyspell-mode)
;; (add-hook 'latex-mode-hook 'flyspell-mode)

;; Spell check comments in programming modes
;; (add-hook 'prog-mode-hook 'flyspell-prog-mode)

;; ============================================================================
;; ADDITIONAL USEFUL INTEGRATIONS
;; ============================================================================

;; Company mode (auto-completion) - adjust delay for faster/slower completion
(after! company
  (setq company-idle-delay 0.2)  ; Show completions after 0.2s
  (setq company-minimum-prefix-length 2)  ; Start completing after 2 characters
  (setq company-show-quick-access t))  ; Show numbers for quick selection

;; LSP Mode - Language Server Protocol for IDE features
(after! lsp-mode
  ;; Performance tuning
  (setq lsp-idle-delay 0.5)  ; Adjust responsiveness
  (setq lsp-log-io nil)  ; Disable logging for better performance
  
  ;; UI improvements
  (setq lsp-headerline-breadcrumb-enable t)  ; Show file breadcrumbs
  (setq lsp-lens-enable t)  ; Show code lenses (references, implementations)
  (setq lsp-signature-auto-activate t)  ; Show function signatures
  (setq lsp-signature-render-documentation t))

;; Treemacs - File explorer sidebar
(after! treemacs
  (setq treemacs-width 30)
  (setq treemacs-follow-mode t))  ; Auto-follow current file

;; Which-key - Show available keybindings
(after! which-key
  (setq which-key-idle-delay 0.5))  ; Show popup faster

;; Rainbow delimiters - Color-coded parentheses
(after! rainbow-delimiters
  (add-hook 'prog-mode-hook #'rainbow-delimiters-mode))

;; Smartparens - Better parentheses handling
(after! smartparens
  (setq sp-highlight-pair-overlay t)
  (setq sp-highlight-wrap-overlay t)
  (setq sp-highlight-wrap-tag-overlay t))

;; ============================================================================
;; CUSTOM KEYBINDINGS (Optional - examples)
;; ============================================================================
;; Doom uses SPC as the leader key in normal mode
;; 
;; Examples for Coq workflow:
;; (map! :map coq-mode-map
;;       :localleader
;;       "c" #'proof-goto-point           ; Process up to cursor
;;       "n" #'proof-assert-next-command  ; Step forward
;;       "u" #'proof-undo-last-command    ; Step backward
;;       "." #'proof-goto-end-of-locked   ; Process to end
;;       "r" #'proof-retract-buffer)      ; Reset buffer

;; Quick access to commonly used functions
;; (map! :leader
;;       :desc "Toggle ligatures" "t L" #'global-ligature-mode)

;; ============================================================================
;; PERFORMANCE OPTIMIZATIONS
;; ============================================================================

;; Increase garbage collection threshold for better performance
(setq gc-cons-threshold 100000000)  ; 100 MB
(setq read-process-output-max (* 1024 1024))  ; 1 MB

;; Reduce rendering overhead
(setq-default bidi-display-reordering nil)

;; ============================================================================
;; NOTES ON INTEGRATIONS
;; ============================================================================
;; 
;; This configuration supports a formal methods workflow:
;;
;; 1. COQ (Proof General + company-coq):
;;    - Interactive theorem proving with IDE features
;;    - Auto-completion, documentation lookup, prettified symbols
;;    - Best for: Formal verification, logic, type theory
;;
;; 2. OCAML (Tuareg + LSP):
;;    - Functional programming with modern IDE features
;;    - Used for Coq plugin development and general ML programming
;;    - Auto-formatting with ocamlformat
;;
;; 3. LATEX (AUCTeX):
;;    - Document preparation for papers
;;    - Excellent for mathematical notation
;;    - Synctex enables PDF<->source sync
;;
;; 4. ORG MODE (ox-hugo):
;;    - Note-taking, TODO lists, literate programming
;;    - Export to Hugo for static websites
;;    - LaTeX integration for mathematical notes
;;
;; 5. LIGATURES:
;;    - Makes code more readable with combined glyphs
;;    - Arrows (->), comparison (>=), logical operators (&&)
;;    - Works with Iosevka, JetBrains Mono, Fira Code
;;
;; ============================================================================
