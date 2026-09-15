{ lib, clangStdenv, swift, swiftpm, swiftpm2nix, swiftPackages, autoPatchelfHook, jq }:

let
  # SwiftPM passes Clang-specific flags when compiling C dependencies.
  stdenv = clangStdenv;
  dependencies = swiftpm2nix.helpers ./dependencies;
  linuxLibraries = lib.optionals stdenv.hostPlatform.isLinux [
    swiftPackages.Dispatch
    swiftPackages.Foundation
    swiftPackages.XCTest
  ];
in
stdenv.mkDerivation {
  pname = "autolith-bridge";
  version = "0-unstable";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Package.resolved
      ../Sources
      ../Shared
      ../Tests
      ../LICENSE
    ];
  };

  nativeBuildInputs = [ swift swiftpm ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook jq ];
  buildInputs = linuxLibraries;
  swiftpmFlags = [ "--disable-sandbox" "--skip-update" ];

  configurePhase = ''
    runHook preConfigure
    ${dependencies.configure}
    runHook postConfigure
  '';

  # SwiftPM executes compiled manifests before linking the bridge. Their loader
  # needs Dispatch explicitly; the installed executable uses patched RUNPATHs.
  LD_LIBRARY_PATH = lib.optionalString stdenv.hostPlatform.isLinux
    (lib.makeLibraryPath linuxLibraries);
  preFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    addAutoPatchelfSearchPath ${swift.swift.lib}/lib/swift/linux
    addAutoPatchelfSearchPath ${swiftPackages.Foundation}/lib/swift/linux
  '';

  preBuild = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # Foundation's user-directory lookup on Darwin needs more than HOME.
    export CFFIXED_USER_HOME="$HOME"
    # The Swift wrapper's process-substitution response file can be closed
    # before swift-driver reads /dev/fd/63. Pass arguments directly instead.
    export NIX_CC_USE_RESPONSE_FILE=0
  '';

  # Nix's Darwin SwiftPM does not provide Apple's XCTest runner.
  # Run the full suite on Linux, and use Xcode for Darwin's suite.
  doCheck = stdenv.hostPlatform.isLinux;
  preCheck = lib.optionalString stdenv.hostPlatform.isLinux ''
    # Nixpkgs omits libIndexStore. Generate the portable XCTest entry point
    # from compiler symbol graphs instead of maintaining a test list.
    mapfile -t testModules < <(swift package describe --type json | jq -r '.targets[] | select(.type == "test") | .c99name')
    test "''${#testModules[@]}" -gt 0
    printf 'import XCTest\nXCTMain([])\n' > Tests/LinuxMain.swift
    mkdir -p "$TMPDIR/test-symbols"
    discoveryFlags=()
    concatTo discoveryFlags swiftpmFlags swiftpmFlagsArray
    swift build -c release -j "$NIX_BUILD_CORES" --build-tests "''${discoveryFlags[@]}" \
      -Xswiftc -enable-testing \
      -Xswiftc -emit-symbol-graph \
      -Xswiftc -emit-symbol-graph-dir -Xswiftc "$TMPDIR/test-symbols" \
      -Xswiftc -symbol-graph-minimum-access-level -Xswiftc internal
    swiftc ${./discover-tests.swift} -o "$TMPDIR/discover-tests"
    "$TMPDIR/discover-tests" "$TMPDIR/test-symbols" Tests/LinuxMain.swift "''${testModules[@]}"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    state=$(mktemp -d)
    # Stop at management configuration, after automatic bearer-token provisioning.
    for attempt in 1 2; do
      status=0
      env -u LD_LIBRARY_PATH -u AUTOLITH_BRIDGE_TOKEN_FILE -u AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE \
        XDG_STATE_HOME="$state" AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET=/unused \
        "$out/bin/autolith-bridge" >startup.log 2>&1 || status=$?
      test "$status" -eq 69
      test "$(wc -c < "$state/autolith-bridge/token")" -eq 64
      test "$(stat -c %a "$state/autolith-bridge/token")" = 600
      test "$(stat -c %a "$state/autolith-bridge")" = 700
      ! grep -Fq -f "$state/autolith-bridge/token" startup.log
      grep -Fq "Bridge token file: $state/autolith-bridge/token" startup.log
      cat startup.log
      if test "$attempt" -eq 1; then
        cp "$state/autolith-bridge/token" "$state/first-token"
      else
        cmp "$state/first-token" "$state/autolith-bridge/token"
      fi
    done
    rm -rf "$state"
    runHook postInstallCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$(swiftpmBinPath)/autolith-bridge" "$out/bin/autolith-bridge"
    cp -R "$(swiftpmBinPath)/AutolithCompanion_AutolithBridge.${if stdenv.hostPlatform.isDarwin then "bundle" else "resources"}" "$out/bin/"
    install -Dm644 LICENSE "$out/share/licenses/autolith-bridge/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Local bridge between the Autolith mobile client and backend";
    homepage = "https://github.com/chakanysystems/autolith-remote";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
    mainProgram = "autolith-bridge";
  };
}
