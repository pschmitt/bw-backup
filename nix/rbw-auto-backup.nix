{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  coreutils,
  curl,
  findutils,
  gnupg,
  oath-toolkit,
  rbw,
}:

stdenvNoCC.mkDerivation {
  pname = "rbw-auto-backup";
  version = "unstable-2024-09-11";
  src = ../.;

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src/bw-backup.sh" "$out/bin/rbw-auto-backup"
    install -Dm644 "$src/lib.sh" "$out/bin/lib.sh"

    runHook postInstall
  '';

  postInstall = ''
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/rbw-auto-backup" \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          curl
          findutils
          gnupg
          oath-toolkit
          rbw
        ]
      }
  '';

  meta = {
    description = "Bitwarden/Vaultwarden backup helper, built on rbw";
    homepage = "https://github.com/pschmitt/rbw-auto";
    license = lib.licenses.gpl3Only;
    mainProgram = "rbw-auto-backup";
    platforms = lib.platforms.unix;
  };
}
