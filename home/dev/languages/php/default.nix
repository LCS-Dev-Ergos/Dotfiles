{ pkgs, ... }:
let
  # Extensions are part of the package, not something pecl adds afterwards.
  # nixpkgs' default set plus the ones Homebrew's build also enabled, so the
  # move from Homebrew loses no module except odbc (not packaged in nixpkgs;
  # PDO_ODBC is in the default set) and pdo_dblib (broken on Darwin).
  php = pkgs.php85.withExtensions (
    { enabled, all }:
    enabled
    ++ [
      all.bz2
      all.dba
      all.ffi
      all.shmop
      all.snmp
      all.sysvmsg
      all.sysvshm
      all.tidy
      all.xsl
    ]
  );
in
{
  # PHP and Composer, on both hosts. Composer runs on this same interpreter,
  # so `composer` and `php` see the same extensions.
  home.packages = [
    php
    php.packages.composer
  ];
}
