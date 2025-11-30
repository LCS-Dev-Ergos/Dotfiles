# Nushell Config

$env.config = {
    show_banner: false,
    ls: { use_ls_colors: true, clickable_links: true },
    rm: { always_trash: true },
    table: { mode: "rounded" }
}

# Aliases
alias ll = ls -l
alias la = ls -a
alias g = git

# Starship Integration
# Check if starship is installed and generate the init script if needed
if (which starship | is-empty) == false {
    mkdir ($nu.data-dir | path join "vendor/autoload")
    starship init nu | save -f ($nu.data-dir | path join "vendor/autoload/starship.nu")
}
