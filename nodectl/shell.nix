let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "nodectl";

  buildInputs = [
    pkgs.ruby
    pkgs.ncurses
    pkgs.git
    pkgs.zlib
    pkgs.openssl
    pkgs.mariadb
    pkgs.mariadb-connector-c
  ];

  shellHook = ''
    mkdir -p /tmp/dev-ruby-gems
    export GEM_HOME="/tmp/dev-ruby-gems"
    export GEM_PATH="$GEM_HOME:$PWD/lib"
    export PATH="$GEM_HOME/bin:$PATH"

    BUNDLE="$GEM_HOME/bin/bundle"

    [ ! -x "$BUNDLE" ] && ${pkgs.ruby}/bin/gem install bundler

    export BUNDLE_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE="$PWD/Gemfile"

    $BUNDLE install

    export RUBYOPT=-rbundler/setup
  '';
}
