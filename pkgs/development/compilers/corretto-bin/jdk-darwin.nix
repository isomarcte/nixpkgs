{
  lib,
  callPackage,
}:

let
  sources = (lib.importJSON ./sources.json).mac;
  common = opts: callPackage (import ./jdk-darwin-base.nix opts) { };
in
{
  jdk-11 = common { sourcePerArch = sources.jdk.corretto11; };
  jdk-17 = common { sourcePerArch = sources.jdk.corretto17; };
  jdk-21 = common { sourcePerArch = sources.jdk.corretto21; };
  jdk-25 = common { sourcePerArch = sources.jdk.corretto25; };
}
