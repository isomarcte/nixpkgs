args:
import ../temurin-bin/jdk-linux-base.nix (
  {
    name-prefix = "corretto";
    brand-name = "Amazon Corretto";
  }
  // args
)
