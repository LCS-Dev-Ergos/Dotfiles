;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; ========================== PERSONAL INFORMATION ========================== ;;
;;
;; Some functionality uses this to identify you (GPG, email clients, templates)
;; (setq user-full-name "Your Name"
;;       user-mail-address "your.email@example.com")

;; =========================== THEME & APPEARANCE =========================== ;;
;;
(setq doom-theme 'doom-tokyo-night)
(setq display-line-numbers-type t)  ; Show line numbers (use 'relative for relative numbers)

;; ================================= FONTS ================================== ;;
;;
;; Using Iosevka Nerd Font - clean, mathematical aesthetic with full glyph support
;; Install with: brew install font-iosevka-nerd-font
;;
;; Alternatives:
;;   - "JetBrainsMono Nerd Font" - clear ligatures, excellent readability
;;   - "FiraCode Nerd Font" - classic choice with great ligatures
;;   - "CaskaydiaCove Nerd Font" - (Cascadia Code) Microsoft's font

(setq doom-font (font-spec :family "FiraCode Nerd Font" :size 15 :weight 'regular)
      doom-variable-pitch-font (font-spec :family "FiraCode Nerd Font" :size 15)
      doom-serif-font (font-spec :family "CMU Serif" :size 15))

;; Hybrid approach: use Computer Modern for prose
;; (setq doom-font (font-spec :family "Iosevka Nerd Font" :size 15 :weight 'regular)
;;       doom-variable-pitch-font (font-spec :family "Latin Modern Roman" :size 15)
;;       doom-serif-font (font-spec :family "Latin Modern Roman" :size 15))

;; ============================= FONT LIGATURES ============================= ;;
;;
;; Enables programming ligatures like -> => != >= etc.
;; Requires Emacs 27+ and a font with ligature support
;; Make sure ligatures module is enabled in init.el: (ligatures +extra)

(after! ligature
  ;; Disable ligatures in comments and strings
  (setq-default ligature-ignored-contexts '())

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

;; ================================ MARKDOWN ================================ ;;
;;
;; Use Pandoc for rich Markdown preview with MathJax support
(setq markdown-command "pandoc --standalone --mathjax --highlight-style=pygments --from=markdown_mmd --to=html5")

;; ================================ ORG MODE ================================ ;;
;;
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

;; ================================= LATEX ================================== ;;
;;
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

;; ============================ TERMINAL (VTERM) ============================ ;;
;;
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

;; ============================= OCAML (TUAREG) ============================= ;;
;;
;; Tuareg provides OCaml editing support
;; Make sure you have enabled (ocaml +lsp) in init.el for full IDE features
;; LSP provides: auto-completion, go-to-definition, documentation, refactoring

(after! tuareg
  (setq tuareg-indent-align-with-first-arg t
        tuareg-match-patterns-aligned t
        tuareg-prettify-symbols-full t))

;; OCaml format on save (requires ocamlformat installed)
;; Install: opam install ocamlformat
(after! format-all
  (add-hook 'tuareg-mode-hook #'format-all-mode))

;; ========================== ROCQ & PROOF GENERAL ========================== ;;
;;
;; Rocq (Coq) is a formal proof management system
;; Proof General provides an interactive interface for theorem provers in Emacs
;; Make sure you have enabled the 'coq' module in init.el

(after! proof-general
  ;; Coqtop path (auto-detected if in PATH; override if using opam switch)
  (setq coq-prog-name "coqtop")
  (setq coq-compile-before-require t)
  (setq coq-use-editing-holes t))

(after! company-coq
  (add-hook 'coq-mode-hook #'company-coq-mode)
  (setq company-coq-live-on-the-edge t))

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

;; ================================= LEAN ================================== ;;
;;
;; Requires: elan (Lean version manager) + Lean 4
;; Install: curl https://elan.lean-lang.org/elan-init.sh | sh
;; The lean module auto-starts lean4-mode for .lean files.
(after! lean4-mode
  (setq lean4-keybinding-lean4-toggle-info (kbd "C-c C-i"))
  (map! :map lean4-mode-map
        :localleader
        "i" #'lean4-toggle-info
        "r" #'lean4-refresh-file-dependencies
        "R" #'lean4-restart-server))

;; ================================= GLEAM ================================== ;;
;;
;; Gleam is a type-safe functional language that compiles to Erlang and JS
;; The LSP is built into the compiler: gleam lsp
;; Uses tree-sitter mode (requires Emacs 29+)
;; After install, run: M-x gleam-ts-install-grammar

(use-package! gleam-ts-mode
  :mode "\\.gleam\\'"
  :hook (gleam-ts-mode . lsp!)
  :config
  (after! lsp-mode
    (add-to-list 'lsp-language-id-configuration '(gleam-ts-mode . "gleam"))
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection '("gleam" "lsp"))
      :major-modes '(gleam-ts-mode)
      :server-id 'gleam-lsp))))

;; ================================ HASKELL ================================= ;;
;;
;; Requires: ghcup, cabal/stack, haskell-language-server (via ghcup)
;; Install HLS: ghcup install hls
(after! haskell-mode
  (setq haskell-process-type 'cabal-repl
        haskell-process-suggest-remove-import-lines t
        haskell-process-auto-import-loaded-modules t
        haskell-tags-on-save nil))   ; use LSP xref instead of tags

(after! lsp-haskell
  (setq lsp-haskell-server-path "haskell-language-server-wrapper"
        lsp-haskell-formatting-provider "fourmolu"))  ; alternatives: ormolu, stylish-haskell

;; ================================= RUST ================================== ;;
;;
;; Requires: rustup, rust-analyzer
;; Install: rustup component add rust-analyzer
(after! rustic
  (setq rustic-format-on-save t
        rustic-lsp-server 'rust-analyzer
        rustic-analyzer-command '("rust-analyzer")))

;; ================================== C# =================================== ;;
;;
;; Requires one of:
;;   - OmniSharp: dotnet tool install --global OmniSharp  (full .NET support)
;;   - csharp-ls: dotnet tool install --global csharp-ls  (lightweight)
;; Doom auto-detects via lsp-mode; run M-x lsp-install-server if needed.
(after! csharp-mode
  (setq lsp-csharp-server-install-dir
        (expand-file-name "~/.dotnet/tools/"))
  (add-hook 'csharp-mode-hook #'rainbow-delimiters-mode))

;; ================================= PYTHON ================================= ;;
;;
;; Requires: pyright (npm install -g pyright) or via venv
;; Virtual env auto-detection via direnv or python-dotenv.
(after! python
  (setq python-shell-interpreter "python3"))

(after! lsp-pyright
  (setq lsp-pyright-venv-path ".venv"
        lsp-pyright-auto-import-completions t
        lsp-pyright-use-library-code-for-types t
        lsp-pyright-stub-path (expand-file-name "~/.local/share/python-type-stubs")))

;; ================================ KOTLIN ================================= ;;
;;
;; Requires: kotlin-language-server in PATH
;; Install: https://github.com/fwcd/kotlin-language-server/releases
;; Or via SDKMAN: sdk install kotlin
(after! kotlin-mode
  (setq kotlin-tab-width 4))

;; ============================== DEBUGGER (DAP) ============================ ;;
;;
;; Requires: (debugger +lsp) in init.el
;; Install debug adapters:
;;   C/C++/Rust: brew install llvm  (provides lldb-vscode / lldb-dap)
;;   Python:     pip install debugpy
;;   Java:       jdtls bundles java-debug automatically
(after! dap-mode
  (require 'dap-lldb)
  (require 'dap-python)

  (setq dap-python-debugger 'debugpy)

  (dap-register-debug-template "LLDB: Launch"
                               (list :type "lldb-vscode"
                                     :request "launch"
                                     :name "LLDB: Launch"
                                     :program "${workspaceFolder}/build/app"
                                     :cwd "${workspaceFolder}"
                                     :stopOnEntry nil))

  (dap-register-debug-template "Python: Current File"
                               (list :type "python"
                                     :request "launch"
                                     :name "Python: Current File"
                                     :program "${file}"
                                     :console "integratedTerminal"))

  (map! :leader
        :desc "DAP debug"          "d d" #'dap-debug
        :desc "DAP breakpoint"     "d b" #'dap-breakpoint-toggle
        :desc "DAP step over"      "d n" #'dap-next
        :desc "DAP step into"      "d i" #'dap-step-in
        :desc "DAP step out"       "d o" #'dap-step-out
        :desc "DAP continue"       "d c" #'dap-continue
        :desc "DAP disconnect"     "d q" #'dap-disconnect
        :desc "DAP ui"             "d u" #'dap-ui-show-many-windows))

;; ================================= LSP UI ================================= ;;
;;
;; lsp-ui adds hover docs, sideline diagnostics, and peek windows.
;; Requires: (lsp +peek) in init.el
(after! lsp-ui
  (setq lsp-ui-doc-enable t
        lsp-ui-doc-show-with-cursor t
        lsp-ui-doc-show-with-mouse nil
        lsp-ui-doc-delay 0.4
        lsp-ui-doc-position 'at-point
        lsp-ui-sideline-enable t
        lsp-ui-sideline-show-diagnostics t
        lsp-ui-sideline-show-hover nil
        lsp-ui-sideline-show-code-actions t
        lsp-ui-peek-enable t
        lsp-ui-peek-always-show t))

;; ========================= CONSULT-LSP (VERTICO) ========================== ;;
;;
;; Workspace-wide symbol/diagnostic search via consult.
;; Requires: (package! consult-lsp) in packages.el
(after! consult-lsp
  (map! :leader
        :desc "LSP workspace symbols"  "c S" #'consult-lsp-symbols
        :desc "LSP diagnostics"        "c X" #'consult-lsp-diagnostics
        :desc "LSP file symbols"       "c ." #'consult-lsp-file-symbols))

;; ===================== ADDITIONAL USEFUL INTEGRATIONS ===================== ;;
;;
;; Company mode (auto-completion) - adjust delay for faster/slower completion
(after! vertico
  (setq vertico-resize nil))   ; skip resize computation on each keystroke

(after! company
  (setq company-idle-delay 0.3
        company-minimum-prefix-length 2
        company-show-quick-access t))

;; LSP Mode - Language Server Protocol for IDE features
(after! lsp-mode
  (setq lsp-idle-delay 0.5
        lsp-log-io nil
        lsp-headerline-breadcrumb-enable t
        lsp-lens-enable t
        lsp-signature-auto-activate t
        lsp-signature-render-documentation t
        lsp-file-watch-threshold 10000
        lsp-enable-file-watchers t))

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

;; =========================== CUSTOM KEYBINDINGS =========================== ;;
;;
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

;; ======================= PERFORMANCE OPTIMIZATIONS ======================== ;;
;;
;; gc-cons-threshold intentionally omitted: Doom's gcmh-mode manages GC timing
;; automatically (pauses during input, triggers on idle). Hardcoding a value
;; here overrides gcmh and causes the continuous GC overhead visible in profiling.
(setq read-process-output-max (* 4 1024 1024)  ; 4 MB — match LSP chunked reads
      bidi-display-reordering nil              ; faster rendering for LTR-only code
      bidi-inhibit-bpa t)

;; ============================= SPELL CHECKING ============================= ;;
;;
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

;; ========================= NOTES ON INTEGRATIONS ========================== ;;
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
;; ========================================================================== ;;
