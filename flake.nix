{
  description = "vtab development environment and isolated Codex MicroVM";

  nixConfig = {
    extra-substituters = [
      "https://microvm.cachix.org"
    ];
    extra-trusted-public-keys = [
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPkgs = system:
        import nixpkgs {
          inherit system;
          overlays = [
            microvm.overlay
          ];
        };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.emacsPackages.trivialBuild {
            pname = "vtab";
            version = "1.1.0";
            src = self;
            packageRequires = [ ];
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in
        {
          byte-compile = pkgs.runCommand "vtab-byte-compile"
            {
              nativeBuildInputs = [ pkgs.emacs ];
            }
            ''
              cp ${self}/vtab.el ./vtab.el
              emacs -Q --batch -L . -f batch-byte-compile vtab.el
              touch "$out"
            '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              emacs
              git
              ripgrep
              fd
              nil
              nixfmt
              nixpkgs-fmt
              statix
              deadnix
              codex
              bubblewrap
              direnv
              nix-direnv
            ];

            shellHook = ''
              echo "vtab dev shell"
              echo "check:    emacs -Q --batch -L . -f batch-byte-compile vtab.el"
              echo "codex VM: nix run .#codex-vm"
            '';
          };
        });

      apps = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          codexVm = defaultHypervisor:
            let
              runnerConfig = ./nix/codex-microvm.nix;
            in
            {
              type = "app";
              program = toString (pkgs.writeShellScript "run-vtab-codex-vm" ''
                set -euo pipefail

                project_root="''${VTAB_PROJECT_ROOT:-$(pwd)}"
                state_dir="''${VTAB_MICROVM_STATE_DIR:-$project_root/.microvm/codex}"
                hypervisor="''${VTAB_MICROVM_HYPERVISOR:-${defaultHypervisor}}"
                tap_interface="''${VTAB_MICROVM_TAP:-}"
                codex_app_server_port="''${VTAB_CODEX_APP_SERVER_PORT:-4500}"
                codex_app_server_host_address="''${VTAB_CODEX_APP_SERVER_HOST:-127.0.0.1}"

                if [ "$hypervisor" = "cloud-hypervisor" ] && [ -z "''${WAYLAND_DISPLAY:-}" ]; then
                  echo "cloud-hypervisor graphics needs a host Wayland session (WAYLAND_DISPLAY is unset)." >&2
                  exit 1
                fi

                case "$codex_app_server_port" in
                  ""|*[!0-9]*)
                    echo "VTAB_CODEX_APP_SERVER_PORT must be a decimal TCP port." >&2
                    exit 1
                    ;;
                esac

                if [ "$hypervisor" = "cloud-hypervisor" ] && [ -z "$tap_interface" ]; then
                  echo "warning: cloud-hypervisor has graphics forwarding but no default user networking; set VTAB_MICROVM_TAP for guest internet." >&2
                fi

                mkdir -p "$state_dir/home" "$state_dir/nix-cache"

                export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$state_dir/nix-cache}"

                runner="$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
                  -f ${runnerConfig} config.microvm.declaredRunner \
                  --arg nixpkgs 'builtins.getFlake "${nixpkgs}"' \
                  --arg microvm 'builtins.getFlake "${microvm}"' \
                  --argstr system '${system}' \
                  --argstr projectRoot "$project_root" \
                  --argstr stateDir "$state_dir" \
                  --argstr hypervisor "$hypervisor" \
                  --argstr tapInterface "$tap_interface" \
                  --arg codexAppServerPort "$codex_app_server_port" \
                  --argstr codexAppServerHostAddress "$codex_app_server_host_address")"

                cd "$state_dir"

                echo "Codex App Server:"
                echo "  VM:   starts codex-app-server automatically"
                echo "  Host: codex --dangerously-bypass-approvals-and-sandbox --remote ws://$codex_app_server_host_address:$codex_app_server_port"
                if [ "$hypervisor" != "qemu" ]; then
                  echo "  Note: microvm.forwardPorts is only configured for qemu user networking."
                fi

                cleanup() {
                  if [ -n "''${virtiofsd_pid:-}" ]; then
                    kill "$virtiofsd_pid" 2>/dev/null || true
                    wait "$virtiofsd_pid" 2>/dev/null || true
                  fi
                }
                trap cleanup EXIT INT TERM

                if [ -x "$runner/bin/virtiofsd-run" ]; then
                  if [ "$(id -u)" != 0 ]; then
                    echo "This MicroVM configuration needs virtiofsd, which microvm.nix starts through supervisord as root." >&2
                    echo "Use the default qemu app without virtiofsd: nix run .#codex-vm" >&2
                    echo "Or run the cloud-hypervisor variant with appropriate root/systemd setup for virtiofsd." >&2
                    exit 1
                  fi

                  "$runner/bin/virtiofsd-run" &
                  virtiofsd_pid="$!"

                  for socket_file in "$runner"/share/microvm/virtiofs/*/socket; do
                    socket="$(cat "$socket_file")"
                    while [ ! -S "$socket" ]; do
                      sleep 0.1
                    done
                  done
                fi

                "$runner/bin/microvm-run" &
                microvm_pid="$!"
                wait "$microvm_pid"
              '');
            };
        in
        {
          codex-vm = codexVm "qemu";
          codex-vm-cloud = codexVm "cloud-hypervisor";
        });

      nixosConfigurations.codex-microvm = import ./nix/codex-microvm.nix {
        inherit nixpkgs microvm;
        system = "x86_64-linux";
        projectRoot = toString self;
        stateDir = "/var/lib/vtab-codex-microvm";
        hypervisor = "qemu";
      };
    };
}
