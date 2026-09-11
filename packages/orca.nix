# Orca for NixOS, from the release AppImage.
#
# Two commands come out, mirroring what the .deb installs on Debian (resources/linux/bin/orca-ide in
# the Orca repo) and what the AppImage's own CLI registration writes:
#
#   orca-ide       the CLI — Electron in Node mode (ELECTRON_RUN_AS_NODE=1) running the packaged
#                  out/cli/index.js. Never initialises Chromium; safe anywhere, no display needed.
#   orca-ide-app   the Electron runtime (the AppImage's AppRun). `orca-ide-app --no-sandbox serve …`
#                  is the server; Orca spawns Xvfb from PATH for it (see modules/orca-server.nix).
#
# Named `orca-ide`, as on every Linux install, because bare `orca` is the GNOME screen reader — the
# skills that drive the CLI already resolve that name on Linux.
#
# Pinned to a release tag, never `releases/latest`: the hash below is the hash of one artifact.
# Bumping: change `version`, run `nix store prefetch-file <url>` for each system, paste the hashes.
{ lib, stdenv, appimageTools, fetchurl, writeShellScriptBin, symlinkJoin, xorg, dbus }:
let
  version = "1.4.199";
  artifacts = {
    x86_64-linux = {
      name = "orca-linux.AppImage";
      hash = "sha256-rrH9Qg3IFbeanBVO26GXj4jljzmO9IUluVcF1mHrr0U=";
    };
    aarch64-linux = {
      name = "orca-linux-arm64.AppImage";
      hash = "sha256-4r5F82P5rdHjqb/wmWyXQFyNSeWqZQxnP26om5q5nTM=";
    };
  };
  system = stdenv.hostPlatform.system;
  artifact = artifacts.${system} or (throw "orca: no AppImage for ${system}");
  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/${artifact.name}";
    inherit (artifact) hash;
  };

  # The runtime. appimageTools unpacks the image at build time and runs its AppRun inside an FHS
  # environment carrying the Electron/Chromium library set; `-w` exports APPDIR to the unpacked tree,
  # which is what the CLI script below relies on. Xvfb, xauth and dbus join that environment so Orca's
  # ensure-virtual-display finds `Xvfb` on PATH when it runs headless.
  app = appimageTools.wrapType2 {
    pname = "orca-ide-app";
    inherit version src;
    extraPkgs = pkgs: [ pkgs.xorg-server pkgs.xauth pkgs.dbus ];
    # The FHS environment is a bubblewrap sandbox with a CURATED /etc (passwd, hosts, ssl, nix, …) —
    # and every terminal and hook Orca spawns is inside it. What the host declares in /etc and the
    # workspace needs at run time is bound in explicitly (measured 2026-09-10: without these, direnv's
    # whitelist is invisible to Orca's terminals, so every worktree's .envrc is blocked; git has no
    # identity; the sandbox recipe cannot find its rootfs). `-try`: a missing source is not an error.
    extraBwrapArgs = [
      "--ro-bind-try /etc/direnv /etc/direnv"
      "--ro-bind-try /etc/gitconfig /etc/gitconfig"
      "--ro-bind-try /etc/orca-sandbox /etc/orca-sandbox"
    ];
  };

  # The CLI. This is Orca's own AppImage CLI wrapper (src/main/cli/legacy-appimage-cli-wrapper.ts),
  # verbatim in what matters: Node mode, NODE_OPTIONS parked in ORCA_NODE_OPTIONS, and the packaged CLI
  # located through $APPDIR at run time — because the unpacked path is the wrapper's business, not ours.
  cliScript = ''(async()=>{try{const path=require("path");const appDir=process.env.APPDIR;if(!appDir){console.error("Orca AppImage runtime did not set APPDIR.");process.exit(1);}const cli=path.join(appDir,"resources","app.asar.unpacked","out","cli","index.js");await Promise.resolve(require(cli).main(process.argv.slice(1)));}catch(error){console.error(error&&error.stack?error.stack:String(error));process.exit(1);}})();'';
  cli = writeShellScriptBin "orca-ide" ''
    export ORCA_NODE_OPTIONS="''${NODE_OPTIONS-}"
    export ORCA_NODE_REPL_EXTERNAL_MODULE="''${NODE_REPL_EXTERNAL_MODULE-}"
    unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE
    ELECTRON_RUN_AS_NODE=1 exec ${app}/bin/orca-ide-app -e ${lib.escapeShellArg cliScript} -- "$@"
  '';
in
symlinkJoin {
  name = "orca-ide-${version}";
  paths = [ cli app ];
  passthru = { inherit version app cli; };
  meta = with lib; {
    description = "Orca — the multi-agent coding workspace, packaged from the release AppImage";
    homepage = "https://www.onorca.dev";
    license = licenses.mit; # github.com/stablyai/orca/LICENSE — MIT, Lovecast Inc.
    platforms = builtins.attrNames artifacts;
    mainProgram = "orca-ide";
  };
}
