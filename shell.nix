{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    emacs
    git
    ripgrep
    fd
    nil
    nixpkgs-fmt
    nixfmt
    statix
    deadnix
    codex
    bubblewrap
  ];

  shellHook = ''
    echo "vtab nix-shell"
    echo "check: emacs -Q --batch -L . -f batch-byte-compile vtab.el"
  '';
}
