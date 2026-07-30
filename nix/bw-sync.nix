{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  coreutils,
  curl,
  jq,
  oath-toolkit,
  rbw,
}:

stdenvNoCC.mkDerivation {
  pname = "bw-sync";
  version = "unstable-2024-09-11";
  src = ../.;

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src/bw-sync.sh" "$out/bin/bw-sync"
    install -Dm644 "$src/lib.sh" "$out/bin/lib.sh"

    runHook postInstall
  '';

  postInstall = ''
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/bw-sync" \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          curl
          jq
          oath-toolkit
          rbw
        ]
      }
  '';

  meta = {
    description = "Mirror Bitwarden/Vaultwarden vaults (personal or org collections), built on rbw";
    homepage = "https://github.com/pschmitt/bw-backup";
    license = lib.licenses.gpl3Only;
    mainProgram = "bw-sync";
    platforms = lib.platforms.unix;
  };
}
