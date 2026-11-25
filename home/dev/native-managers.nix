# Native installation inventory. Inspect with:
# nix eval --json --file home/dev/native-managers.nix
# Package names declare intent; native repositories are not version locks.
let
  managers = {
    node = "fnm";
    python = "pyenv";
    ocaml = "opam";
    ruby = "rbenv";
  };
  managerPackages = [
    managers.node
    managers.ocaml
    managers.python
    managers.ruby
    "ruby-build"
  ];
  # What the installer scripts call (SDKMAN needs zip and unzip). macOS ships
  # all three in /usr/bin, where Homebrew's copies are keg-only and unused, so
  # only Arch declares them.
  archInstallerPackages = [
    "curl"
    "unzip"
    "zip"
  ];
  archPythonPackages = [
    "base-devel"
    "bzip2"
    "libffi"
    "openssl"
    "pkgconf"
    "readline"
    "sqlite"
    "tk"
    "xz"
    "zlib"
    "zstd"
  ];
  # Audited official installer bytes, fetched only by explicit apply. Mutable
  # endpoints fail closed on drift; scripts/updates/update-runtime-baseline.py
  # reports it and records a reviewed replacement. Manager updates remain
  # native.
  installers = {
    rust = {
      url = "https://sh.rustup.rs";
      sha256 = "d890e2fef6fa991b19cde2e608199bc1dca4e37f41f884edf8849ff693048de6";
      shell = "/bin/sh";
      arguments = [
        "-y"
        "--no-modify-path"
        "--default-toolchain"
        "none"
      ];
    };
    haskell = {
      url = "https://get-ghcup.haskell.org";
      sha256 = "c85add4cdca779ea34bcbeeb3a311bbfed23fc96583311df41fe4e73554eba6d";
      shell = "/bin/sh";
      arguments = [ ];
      environment = {
        BOOTSTRAP_HASKELL_NONINTERACTIVE = "1";
        BOOTSTRAP_HASKELL_MINIMAL = "1";
        BOOTSTRAP_HASKELL_NO_UPGRADE = "1";
        BOOTSTRAP_HASKELL_ADJUST_BASHRC = "";
      };
    };
    lean = {
      url = "https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh";
      sha256 = "a620ff1641616222c8d37c54845492004bb84d6877cdbc944dd65c1aa685bf53";
      shell = "/bin/sh";
      arguments = [
        "-y"
        "--no-modify-path"
        "--default-toolchain"
        "none"
      ];
    };
    # SDKMAN 5.23 requires Bash 4, and macOS ships 3.2: the package runs this
    # installer, and every `sdk` call, with its own Bash (sdkmanShell).
    jvm = {
      url = "https://get.sdkman.io?rcupdate=false";
      sha256 = "434360efbde4d2ee31940ff28130fc6ec66121f1e1afc84aa37504752c4babb0";
      arguments = [ ];
    };
    # .NET has no version manager: the script installs one exact SDK per run,
    # beside any other in DOTNET_ROOT, and keeps an existing muxer.
    dotnet = {
      url = "https://dot.net/v1/dotnet-install.sh";
      sha256 = "082f7685e156738a1b2e2ed8381a621870d4ce8e8c59278034556f05c186eb2e";
      shell = "/bin/bash";
      arguments = [
        "--version"
        "{version}"
        "--install-dir"
        "{DOTNET_ROOT}"
        "--no-path"
        "--skip-non-versioned-files"
      ];
      environment.DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    };
    julia = {
      url = "https://install.julialang.org";
      sha256 = "1d511625586b747272a9ce7008d38a622ed38ca58431cee8d42452e457ae5168";
      shell = "/bin/sh";
      arguments = [
        "--yes"
        "--path"
        "{JULIAUP_HOME}"
        "--default-channel"
        "{version}"
        "--add-to-path=no"
        "--background-selfupdate=0"
        "--startup-selfupdate=0"
      ];
    };
  };
  # Miniforge3 installs conda and its base environment in batch mode, which
  # never runs `conda init`.
  miniforge = asset: {
    url = "https://github.com/conda-forge/miniforge/releases/download/26.9.4-2/${asset.name}";
    inherit (asset) sha256 size;
    shell = "/bin/bash";
    arguments = [
      "-b"
      "-p"
      "{CONDA_ROOT_PREFIX}"
    ];
  };
  # Terms an apply records as accepted once its --accept names them, as the
  # hash sdkmanager itself writes under licenses/: SHA-1 of the reviewed text
  # in Google's repository index, normalized the way sdkmanager reads it.
  # With it on file sdkmanager asks nothing, and bootstrap declines every
  # question it still asks, so no package needing other terms is installed.
  # scripts/updates/update-runtime-baseline.py reports a changed text, and
  # --accept-license records the hash of the reviewed one.
  licenses.android-sdk-license = "24333f8a63b6825ea9c5514f83c2829b004d1fee";
  # Release assets above the 1 MiB script bound, pinned per platform with their
  # exact size. Coursier's native launcher, the alr binary in Alire's archive
  # and Google's command-line tools (sdkmanager, at the release
  # runtime-baseline.nix names in android.tools) need no setup run.
  releaseInstallers = {
    aarch64-darwin = {
      ada = {
        url = "https://github.com/alire-project/alire/releases/download/v2.1.1/alr-2.1.1-bin-aarch64-macos.zip";
        sha256 = "2c4867bfff3b95ecd9d846df460a52983d2b0072808b341f8fa5d82494fb309e";
        size = 8816840;
      };
      android = {
        url = "https://dl.google.com/android/repository/commandlinetools-mac_arm64-16111833_latest.zip";
        sha256 = "58da8f215781cc0208743e88b65ae259780c55e7eb40e50373d377cf369232d6";
        size = 155384151;
      };
      android-cli = {
        url = "https://dl.google.com/android/cli/1.1.16919734/darwin_arm64/android-cli";
        sha256 = "b559c8b87373b43bd3b4bba4564c8808981c1b74bc7e18aa41f55bf6af3c3f5b";
        size = 75861744;
      };
      scala = {
        url = "https://github.com/coursier/coursier/releases/download/v2.1.27/cs-aarch64-apple-darwin.gz";
        sha256 = "468a4c08483d77f8896b33bcf474e303f716ad43a3f7fb9639cc1112fca9dc1f";
        size = 29095465;
        format = "gzip";
      };
      conda = miniforge {
        name = "Miniforge3-26.9.4-2-MacOSX-arm64.sh";
        sha256 = "fb567612b76f4ef46de326f04425dbe381b6afc6a66c545f5043255a5ef34258";
        size = 86880973;
      };
    };
    x86_64-linux = {
      ada = {
        url = "https://github.com/alire-project/alire/releases/download/v2.1.1/alr-2.1.1-bin-x86_64-linux.zip";
        sha256 = "09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7";
        size = 12800698;
      };
      android = {
        url = "https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip";
        sha256 = "0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8";
        size = 181052239;
      };
      android-cli = {
        url = "https://dl.google.com/android/cli/1.1.16919734/linux_x86_64/android-cli";
        sha256 = "9803784ddf24d4699929eece519ffa8b066afa9a2b93bd58749b3c6d2caaeeec";
        size = 79497240;
      };
      scala = {
        url = "https://github.com/coursier/coursier/releases/download/v2.1.27/cs-x86_64-pc-linux.gz";
        sha256 = "9bf62b300a043260f39bc738ddb90dd02a1d2cc998931251614e1749d3231e07";
        size = 30036399;
        format = "gzip";
      };
      conda = miniforge {
        name = "Miniforge3-26.9.4-2-Linux-x86_64.sh";
        sha256 = "bbaf16b3897da24c4be50315934ba74848f617b4495982841d6a0a60e0edbbdf";
        size = 128272241;
      };
    };
  };
in
{
  inherit licenses;
  homebrew = managerPackages;
  arch = {
    packages = managerPackages;
    fnm = {
      method = "pacman";
      documentation = "https://archlinux.org/packages/extra/x86_64/fnm/";
      destination = "/usr/bin/fnm";
    };
  };
  # Explicit post-Nix bootstrap routes; no OS foundation or system upgrade.
  bootstrap = {
    aarch64-darwin = {
      inherit licenses managers;
      installerPackages = [ ];
      installers = installers // releaseInstallers.aarch64-darwin;
      packageManager = "/opt/homebrew/bin/brew";
      managerDirectory = "/opt/homebrew/bin";
      query = [
        "list"
        "--formula"
      ];
      install = [
        "install"
        "--formula"
      ];
      privilege = [ ];
      environment = {
        HOMEBREW_NO_AUTO_UPDATE = "1";
        HOMEBREW_NO_INSTALL_UPGRADE = "1";
        HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK = "1";
        HOMEBREW_NO_INSTALL_CLEANUP = "1";
        HOMEBREW_NO_ANALYTICS = "1";
      };
      buildPackages = {
        python = [
          "libb2"
          "libffi"
          "ncurses"
          "openssl@3"
          "readline"
          "sqlite"
          "tcl-tk@8"
          "xz"
          "zlib"
          "zstd"
          "pkgconf"
        ];
        ocaml = [ ];
        ruby = [
          "ruby-build"
          "openssl@3"
          "libyaml"
          "readline"
          "gmp"
          "pkgconf"
        ];
        haskell = [
          "gmp"
          "ncurses"
          "libffi"
          "pkgconf"
        ];
      };
      sdkProbe = [
        "/usr/bin/xcrun"
        "--show-sdk-path"
      ];
      # Source builds compile with the Nix host drivers of
      # home/dev/toolchains/llvm, named by the profile path the shell's CC
      # names too: what a runtime records (CPython's sysconfig, rbconfig,
      # OCaml's and GHC's settings) then survives every generation, and a
      # rebuild from the shell uses the same compiler. The first profile
      # that provides them serves; package.nix adds the deployment target.
      compilerProfiles = [
        "/etc/profiles/per-user/{USER}"
        "{HOME}/.nix-profile"
      ];
      # Commands a build calls by name instead of CC (OCaml's and rustc's
      # links call cc): the profile's drivers come first on the build's
      # search path, as in the shell, without the profile's other tools.
      compilerCommands = [
        "cc"
        "c++"
        "cpp"
        "clang"
        "clang++"
        "gcc"
        "g++"
        "ld"
      ];
      buildEnvironment = {
        CC = "{compiler}/bin/clang";
        CXX = "{compiler}/bin/clang++";
        PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
    x86_64-linux = {
      inherit licenses managers;
      installerPackages = archInstallerPackages;
      installers = installers // releaseInstallers.x86_64-linux;
      packageManager = "/usr/bin/pacman";
      managerDirectory = "/usr/bin";
      query = [ "-Qq" ];
      missingQuery = [ "-T" ];
      install = [
        "-S"
        "--needed"
        "--noconfirm"
      ];
      # The install never prompts; an attended apply authenticates once
      # beforehand. Never run the executor as root.
      privilege = [
        "/usr/bin/sudo"
        "-n"
      ];
      authenticate = [
        "/usr/bin/sudo"
        "-v"
      ];
      # Signs in a failed install that the sync database is older than the
      # mirrors. Apply then names the full upgrade, never a partial -Sy.
      staleDatabase = {
        signs = [
          "target not found"
          "failed retrieving file"
        ];
        upgrade = [ "-Syu" ];
      };
      environment = { };
      buildPackages = {
        python = archPythonPackages;
        ocaml = [ "base-devel" ];
        rust = [ "base-devel" ];
        ruby = [
          "ruby-build"
          "base-devel"
          "openssl"
          "libyaml"
          "readline"
          "gmp"
        ];
        haskell = [
          "base-devel"
          "gmp"
          "libffi"
          "ncurses"
          "numactl"
          "xz"
        ];
        # The runtime's globalization support.
        dotnet = [ "icu" ];
        # alr clones its index with git.
        ada = [ "git" ];
      };
      sdkProbe = [ ];
      buildEnvironment = {
        CC = "/usr/bin/cc";
        CXX = "/usr/bin/c++";
        PATH = "/usr/bin:/bin";
      };
    };
  };
}
