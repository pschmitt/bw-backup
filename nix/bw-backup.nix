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
, gnupg
, gnused
, gnutar
, gzip
, jq
}:

stdenvNoCC.mkDerivation {
  pname = "bw-backup";
  version = "unstable-2024-09-11";
  src = ../.;

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src/bw-backup.sh" "$out/bin/bw-backup"
    install -Dm644 "$src/lib.sh" "$out/bin/lib.sh"

    runHook postInstall
  '';

  postInstall = ''
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/bw-backup" \
      --prefix PATH : ${lib.makeBinPath [
        bash
        bitwarden-cli
        coreutils
        curl
        findutils
        gawk
        gnugrep
        gnupg
        gnused
        gnutar
        gzip
        jq
      ]}
  '';

  meta = {
    description = "Bitwarden/Vaultwarden backup helper";
    homepage = "https://github.com/pschmitt/bw-backup";
    license = lib.licenses.gpl3Only;
    mainProgram = "bw-backup";
    platforms = lib.platforms.unix;
  };
}
