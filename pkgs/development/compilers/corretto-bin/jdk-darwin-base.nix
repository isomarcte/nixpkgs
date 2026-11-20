args:
import ../temurin-bin/jdk-darwin-base.nix (
  {
    name-prefix = "corretto";
    brand-name = "Amazon Corretto";
  }
  // args
)
