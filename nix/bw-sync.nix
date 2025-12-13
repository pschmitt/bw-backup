{ lib
, stdenvNoCC
, makeWrapper
, bash
, bitwarden-cli
, coreutils
, curl
, findutils
, gawk
, gnugrep
, gnused
, jq
, python3
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
    install -Dm755 "$src/bw.py" "$out/bin/bw.py"
    install -Dm644 "$src/lib.sh" "$out/bin/lib.sh"

    runHook postInstall
  '';

  postInstall = ''
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/bw-sync" \
      --prefix PATH : ${lib.makeBinPath [
        bash
        bitwarden-cli
        coreutils
        curl
        findutils
        gawk
        gnugrep
        gnused
        jq
        python3
      ]}
  '';

  meta = {
    description = "Sync Bitwarden/Vaultwarden vaults including attachments";
    homepage = "https://github.com/pschmitt/bw-backup";
    license = lib.licenses.gpl3Only;
    mainProgram = "bw-sync";
    platforms = lib.platforms.unix;
  };
}
