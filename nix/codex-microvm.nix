{
  nixpkgs,
  microvm,
  system ? builtins.currentSystem,
  projectRoot ? builtins.getEnv "PWD",
  stateDir ? "${projectRoot}/.microvm/codex",
  hypervisor ? "qemu",
  tapInterface ? "",
  codexAppServerPort ? 4500,
  codexAppServerHostAddress ? "127.0.0.1",
}:

let
  lib = nixpkgs.lib;

  isQemu = hypervisor == "qemu";
  isCloudHypervisor = hypervisor == "cloud-hypervisor";
  shareProto = if isQemu then "9p" else "virtiofs";

  projectMount = "/workspace/vtab";
  codexHome = "/home/codex";
  codexAppServerListen = "ws://0.0.0.0:${toString codexAppServerPort}";
  codexAppServerRemote = "ws://${codexAppServerHostAddress}:${toString codexAppServerPort}";

  module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      vmScreenshot = pkgs.writeShellScriptBin "vm-screenshot" ''
        set -euo pipefail

        query=""
        if [ "$#" -eq 0 ]; then
          out="${codexHome}/screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png"
        elif [ "$#" -eq 1 ] && { [[ "$1" == */* ]] || [[ "$1" == *.png ]]; }; then
          out="$1"
        elif [ "$#" -eq 1 ]; then
          query="$1"
          safe_query="$(printf '%s' "$query" | ${pkgs.coreutils}/bin/tr -cs 'A-Za-z0-9_.-' '-')"
          out="${codexHome}/screenshots/screenshot-$safe_query-$(date +%Y%m%d-%H%M%S).png"
        else
          query="$1"
          out="$2"
        fi

        mkdir -p "$(dirname "$out")"

        if [ -z "$query" ]; then
          exec ${pkgs.grim}/bin/grim "$out"
        fi

        geometry="$(${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -er --arg q "$query" '
          def text:
            [
              .app_id,
              .name,
              .window_properties.class,
              .window_properties.title
            ]
            | map(. // "")
            | join(" ")
            | ascii_downcase;
          def real_window:
            (.pid? != null or .app_id? != null or .window_properties? != null)
            and ((.rect.width? // 0) > 0)
            and ((.rect.height? // 0) > 0);
          [
            .. | objects
            | select(.type? == "con")
            | select(real_window)
            | select(text | contains($q | ascii_downcase))
          ]
          | sort_by(if .focused then 0 else 1 end, .rect.x, .rect.y)
          | .[0].rect
          | "\(.x),\(.y) \(.width)x\(.height)"
        ')" || {
          echo "No visible Sway window matched '$query'." >&2
          echo "Visible windows:" >&2
          ${vmWindows}/bin/vm-windows >&2 || true
          exit 1
        }

        if ! [[ "$geometry" =~ ^[0-9]+,[0-9]+\ [1-9][0-9]*x[1-9][0-9]*$ ]]; then
          echo "Invalid geometry for '$query': $geometry" >&2
          exit 1
        fi

        exec ${pkgs.grim}/bin/grim -g "$geometry" "$out"
      '';

      vmWindows = pkgs.writeShellScriptBin "vm-windows" ''
        set -euo pipefail
        ${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -r '
          [
            .. | objects
            | select(.type? == "con")
            | select(.pid? != null or .app_id? != null or .window_properties? != null)
            | select(((.rect.width? // 0) > 0) and ((.rect.height? // 0) > 0))
            | {
                id,
                app_id: (.app_id // ""),
                class: (.window_properties.class // ""),
                title: (.name // .window_properties.title // ""),
                focused: (.focused // false),
                rect
              }
          ]
          | (["id", "app_id", "class", "focused", "geometry", "title"] | @tsv),
            (.[] | [
              (.id | tostring),
              .app_id,
              .class,
              (.focused | tostring),
              "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)",
              .title
            ] | @tsv)
        '
      '';

      vmFocus = pkgs.writeShellScriptBin "vm-focus" ''
        set -euo pipefail
        if [ "$#" -lt 1 ]; then
          echo "Usage: vm-focus <app-id-or-title-fragment>" >&2
          exit 2
        fi

        query="$*"
        id="$(${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -er --arg q "$query" '
          def text:
            [
              .app_id,
              .name,
              .window_properties.class,
              .window_properties.title
            ]
            | map(. // "")
            | join(" ")
            | ascii_downcase;
          def real_window:
            (.pid? != null or .app_id? != null or .window_properties? != null)
            and ((.rect.width? // 0) > 0)
            and ((.rect.height? // 0) > 0);
          [
            .. | objects
            | select(.type? == "con")
            | select(real_window)
            | select(text | contains($q | ascii_downcase))
          ]
          | sort_by(if .focused then 0 else 1 end, .rect.x, .rect.y)
          | .[0].id
        ')" || {
          echo "No visible Sway window matched '$query'." >&2
          echo "Visible windows:" >&2
          ${vmWindows}/bin/vm-windows >&2 || true
          exit 1
        }

        exec ${pkgs.sway}/bin/swaymsg "[con_id=$id]" focus
      '';

      vmEmacs = pkgs.writeShellScriptBin "vm-emacs" ''
        set -euo pipefail

        if [ -z "''${SWAYSOCK:-}" ]; then
          echo "vm-emacs must run inside the Sway session." >&2
          exit 1
        fi

        args=(
          ${pkgs.emacs}/bin/emacs
          -Q
          -L
          ${projectMount}
        )

        if [ "$#" -eq 0 ]; then
          args+=(--load ${projectMount}/init.el)
        else
          args+=("$@")
        fi

        command="$(${pkgs.bash}/bin/printf ' %q' "''${args[@]}")"
        command="''${command:1}"
        exec ${pkgs.sway}/bin/swaymsg exec "$command"
      '';

      vmType = pkgs.writeShellScriptBin "vm-type" ''
        set -euo pipefail
        exec ${pkgs.wtype}/bin/wtype "$*"
      '';

      vmKey = pkgs.writeShellScriptBin "vm-key" ''
        set -euo pipefail

        if [ "$#" -lt 1 ]; then
          echo "Usage: vm-key <key-or-chord>..." >&2
          echo "Examples: vm-key Return, vm-key Ctrl+x, vm-key C-x, vm-key Alt+Return" >&2
          exit 2
        fi

        normalize_modifier() {
          case "''${1,,}" in
            c|ctrl|control)
              printf '%s\n' ctrl
              ;;
            a|alt|m|meta)
              printf '%s\n' alt
              ;;
            s|shift)
              printf '%s\n' shift
              ;;
            super|logo|win|windows|mod4)
              printf '%s\n' logo
              ;;
            *)
              echo "Unknown modifier '$1'" >&2
              exit 2
              ;;
          esac
        }

        send_key() {
          local spec="$1"
          local -a parts modifiers mods args
          local key

          if [[ "$spec" == *+* ]]; then
            IFS=+ read -r -a parts <<< "$spec"
          elif [[ "$spec" =~ ^(C|c|M|m|S|s|A|a|Ctrl|ctrl|Control|control|Alt|alt|Meta|meta|Shift|shift)-.+$ ]]; then
            IFS=- read -r -a parts <<< "$spec"
          else
            ${pkgs.wtype}/bin/wtype -k "$spec"
            return
          fi

          if [ "''${#parts[@]}" -lt 2 ]; then
            echo "Invalid key chord '$spec'" >&2
            exit 2
          fi

          key="''${parts[''$((''${#parts[@]} - 1))]}"
          modifiers=("''${parts[@]:0:''$((''${#parts[@]} - 1))}")
          mods=()
          for modifier in "''${modifiers[@]}"; do
            mods+=("''$(normalize_modifier "$modifier")")
          done

          args=()
          for modifier in "''${mods[@]}"; do
            args+=(-M "$modifier")
          done
          args+=(-k "$key")
          for ((i = ''${#mods[@]} - 1; i >= 0; i--)); do
            args+=(-m "''${mods[$i]}")
          done

          ${pkgs.wtype}/bin/wtype "''${args[@]}"
        }

        for key in "$@"; do
          send_key "$key"
        done
      '';

      vmClick = pkgs.writeShellScriptBin "vm-click" ''
        set -euo pipefail
        button="''${1:-0xC0}"
        export YDOTOOL_SOCKET=/tmp/.ydotool_socket
        exec ${pkgs.ydotool}/bin/ydotool click "$button"
      '';

      vmMoveMouse = pkgs.writeShellScriptBin "vm-move-mouse" ''
        set -euo pipefail
        if [ "$#" -ne 2 ]; then
          echo "Usage: vm-move-mouse <x> <y>" >&2
          exit 2
        fi

        export YDOTOOL_SOCKET=/tmp/.ydotool_socket
        exec ${pkgs.ydotool}/bin/ydotool mousemove --absolute "$1" "$2"
      '';

      codexEditor = pkgs.writeShellScriptBin "codex-editor" ''
        set -euo pipefail
        # Non-interactive editor for agent workflows. Tools that spawn $EDITOR
        # can continue immediately instead of blocking on Emacs or another TUI.
        exit 0
      '';

      codexAppServer = pkgs.writeShellScriptBin "codex-app-server" ''
        set -euo pipefail
        cd ${projectMount}
        exec ${pkgs.codex}/bin/codex app-server \
          --listen ${codexAppServerListen} \
          -c sandbox_mode='"danger-full-access"' \
          -c approval_policy='"never"' \
          -c default_permissions='":danger-no-sandbox"' \
          -c model_reasoning_effort='"high"' \
          -c shell_environment_policy.inherit='"all"' \
          "$@"
      '';
    in
    {
      networking.hostName = "vtab-codex";
      system.stateVersion = lib.trivial.release;

      nixpkgs.overlays = [
        microvm.overlay
      ];

      microvm = {
        inherit hypervisor;

        vcpu = 4;
        mem = 4096;
        socket = "vtab-codex.sock";
        graphics.enable = true;

        shares = [
          {
            tag = "project";
            proto = shareProto;
            source = projectRoot;
            mountPoint = projectMount;
            cache = "metadata";
          }
          {
            tag = "home";
            proto = shareProto;
            source = "${stateDir}/home";
            mountPoint = codexHome;
            cache = "metadata";
          }
          {
            tag = "ro-store";
            proto = shareProto;
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            readOnly = true;
            cache = "always";
          }
        ];

        writableStoreOverlay = "/nix/.rw-store";
        volumes = [
          {
            image = "${stateDir}/nix-store-overlay.img";
            mountPoint = config.microvm.writableStoreOverlay;
            size = 8192;
          }
        ];

        interfaces =
          lib.optional isQemu {
            type = "user";
            id = "usernet";
            mac = "02:00:00:00:00:01";
          }
          ++ lib.optional (isCloudHypervisor && tapInterface != "") {
            type = "tap";
            id = tapInterface;
            mac = "02:00:00:00:00:02";
          };

        forwardPorts = lib.optionals isQemu [
          {
            from = "host";
            host.port = 2222;
            guest.port = 22;
          }
          {
            from = "host";
            host.address = codexAppServerHostAddress;
            host.port = codexAppServerPort;
            guest.port = codexAppServerPort;
          }
        ];

        qemu.serialConsole = false;
        virtiofsd.group = null;
      };

      assertions = [
        {
          assertion = isQemu || isCloudHypervisor;
          message = "vtab Codex MicroVM supports hypervisor = \"qemu\" or \"cloud-hypervisor\".";
        }
      ];

      boot.kernelModules = [
        "drm"
        "uinput"
        "virtio_gpu"
      ];

      hardware.graphics.enable = true;
      services.dbus.enable = true;
      services.openssh.enable = true;
      networking.firewall.allowedTCPPorts = lib.unique ([ codexAppServerPort ] ++ lib.optional isQemu 22);
      networking.useDHCP = lib.mkDefault true;

      nix = {
        enable = true;
        settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          sandbox = true;
        };
      };

      users.groups.codex.gid = 1000;
      users.users.codex = {
        isNormalUser = true;
        uid = 1000;
        group = "codex";
        home = codexHome;
        createHome = false;
        extraGroups = [
          "input"
          "video"
          "wheel"
        ];
        password = "";
      };

      security.sudo = {
        enable = true;
        wheelNeedsPassword = false;
      };

      services.udev.extraRules = ''
        KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
      '';

      systemd.services.ydotoold = {
        description = "ydotool virtual input daemon";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.ydotool}/bin/ydotoold --socket-path=/tmp/.ydotool_socket --socket-perm=0666";
          Restart = "on-failure";
        };
      };

      programs.sway = {
        enable = true;
        wrapperFeatures.gtk = true;
      };

      services.greetd = {
        enable = true;
        settings.default_session = {
          user = "codex";
          command = "${pkgs.sway}/bin/sway --config /etc/sway/config";
        };
      };

      xdg.portal = {
        enable = true;
        wlr.enable = true;
        extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      };

      fonts.packages = with pkgs; [
        dejavu_fonts
        nerd-fonts.jetbrains-mono
      ];

      environment.sessionVariables = {
        CODEX_HOME = "${codexHome}/.codex";
        EDITOR = "codex-editor";
        GIT_EDITOR = "codex-editor";
        HUMAN_EDITOR = "emacs";
        VISUAL = "codex-editor";
        VTAB_CODEX_APP_SERVER_LISTEN = codexAppServerListen;
        VTAB_CODEX_REMOTE_URL = codexAppServerRemote;
        XDG_CURRENT_DESKTOP = "sway";
        XDG_SESSION_TYPE = "wayland";
        WLR_RENDERER_ALLOW_SOFTWARE = "1";
      };

      environment.systemPackages = with pkgs; [
        bashInteractive
        bubblewrap
        codex
        codexAppServer
        codexEditor
        curl
        emacs
        fd
        firefox
        foot
        git
        grim
        jq
        nil
        nixfmt
        nixpkgs-fmt
        openssh
        pciutils
        ripgrep
        slurp
        statix
        sway
        vmClick
        vmEmacs
        vmFocus
        vmKey
        vmMoveMouse
        vmScreenshot
        vmType
        vmWindows
        wayland-utils
        wl-clipboard
        wtype
        xdg-utils
        ydotool
      ];

      environment.etc."codex/config.toml".text = ''
        cli_auth_credentials_store = "file"
        sandbox_mode = "danger-full-access"
        approval_policy = "never"
        default_permissions = ":danger-no-sandbox"
        model_reasoning_effort = "high"

        [shell_environment_policy]
        inherit = "all"

        [projects."${projectMount}"]
        trust_level = "trusted"
      '';

      systemd.tmpfiles.rules = [
        "d ${codexHome}/.codex 0700 codex codex -"
        "d ${codexHome}/.emacs.d 0755 codex codex -"
        "d ${codexHome}/screenshots 0755 codex codex -"
        "C ${codexHome}/.codex/config.toml 0600 codex codex - /etc/codex/config.toml"
        "L+ ${codexHome}/.emacs.d/init.el - - - - /etc/emacs/init.el"
      ];

      environment.etc."emacs/init.el".text = ''
        (load-file "${projectMount}/init.el")
      '';

      environment.etc."sway/config".text = ''
        set $mod Mod1
        set $term ${pkgs.foot}/bin/foot

        output * bg #1d2021 solid_color
        input * xkb_layout us
        workspace_layout tabbed

        exec_always ${pkgs.coreutils}/bin/mkdir -p ${codexHome}/screenshots ${codexHome}/.codex
        exec ${pkgs.foot}/bin/foot --title codex-app-server --working-directory ${projectMount} ${codexAppServer}/bin/codex-app-server

        bindsym Print exec ${vmScreenshot}/bin/vm-screenshot
        bindsym $mod+Return exec ${pkgs.foot}/bin/foot --working-directory ${projectMount}
        bindsym $mod+b exec ${pkgs.firefox}/bin/firefox
        bindsym $mod+Shift+e exec ${pkgs.systemd}/bin/systemctl poweroff
      '';
    };
in
lib.nixosSystem {
  inherit system;
  modules = [
    microvm.nixosModules.microvm
    module
  ];
}
// {
  _module = module;
}
