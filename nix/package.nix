{ lib, stdenv, swift, swiftpm }:

stdenv.mkDerivation {
  pname = "autolith-bridge";
  version = "0-unstable";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Sources
      ../Shared
      ../Tests
      ../LICENSE
    ];
  };

  nativeBuildInputs = [ swift swiftpm ];
  swiftpmFlags = [ "--disable-sandbox" ];

  preBuild = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
  '';

  # Nix's Darwin SwiftPM does not provide Apple's XCTest runner.
  # Check the installed executable; run the full suite with Xcode's swift test.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    status=0
    env -u AUTOLITH_BRIDGE_TOKEN_FILE "$out/bin/autolith-bridge" >startup.log 2>&1 || status=$?
    cat startup.log
    test "$status" -eq 64
    runHook postInstallCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$(swiftpmBinPath)/autolith-bridge" "$out/bin/autolith-bridge"
    install -Dm644 LICENSE "$out/share/licenses/autolith-bridge/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Local bridge between the Autolith mobile client and backend";
    homepage = "https://github.com/chakanysystems/autolith-remote";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
    mainProgram = "autolith-bridge";
  };
}
