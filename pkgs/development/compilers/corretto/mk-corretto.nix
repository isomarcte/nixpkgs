{
  majorVersion, # jdk wording is "featureVersion"
  jdk11,
  jdk17,
  jdk21,
  jdk25,
  lib,
  fetchurl,
  stdenv,
  gradle,
  cacert,
  jre-generate-cacerts,
  nixpkgs-openjdk-updater,
  extraConfig ? [ ],
  libarchive,
  rsync,
  runCommand,
  testers,
  # Darwin-only build inputs (corretto builds itself via its own
  # ./configure + gradle, not via jdk.overrideAttrs, see below).
  autoconf,
  cups,
  libiconv,
  makeWrapper,
  which,
  zip,
  # Build with Xcode's real `metal`/`metallib` shader compiler instead of
  # skipping the Metal-accelerated Java2D pipeline (see postPatch below).
  # Requires manually downloading Xcode and adding it to the store yourself
  # via `pkgs.xcode`'s `requireFile` instructions - see
  # ../../../os-specific/darwin/xcode/default.nix.
  withAppleMetal ? false,
  xcode,
}:

# Each Corretto version is based on a corresponding OpenJDK version. On
# Linux, building Corretto is more or less the same as building OpenJDK, so
# the Corretto derivation overrides the corresponding OpenJDK derivation to
# reuse its version-specific fixes. Corretto uses `gradle` as build tool
# (which in turn invokes `make`); the configure/build phases are adapted as
# needed.
#
# On Darwin, `jdk11`/`jdk17`/etc. resolve to prebuilt Zulu (see
# ../../../top-level/java-packages.nix), not a from-source OpenJDK build —
# there is no from-source OpenJDK-on-Darwin derivation in nixpkgs to override.
# `jdk.overrideAttrs` would silently inherit Zulu's (binary-unpack) phases,
# which don't make sense for a from-source gradle build, so Darwin gets its
# own derivation below. Zulu is only used there as the `--with-boot-jdk`
# bootstrap compiler.

# The version scheme is different between OpenJDK & Corretto.
# See https://github.com/corretto/corretto-17/blob/release-17.0.8.8.1/build.gradle#L40
# "major.minor.security.build.revision"
let
  sourceFile = ./. + "/${majorVersion}/source.json";
  source = nixpkgs-openjdk-updater.openjdkSource {
    inherit sourceFile;
    featureVersionPrefix = majorVersion;
  };
  version = lib.removePrefix "refs/tags/" source.src.rev; # "17.0.8.8.1"
  jdk =
    {
      "11" = jdk11;
      "17" = jdk17;
      "21" = jdk21;
      "25" = jdk25;
    }
    .${majorVersion};
  is11 = majorVersion == "11";
  is17 = majorVersion == "17";
  is21 = majorVersion == "21";
  is25 = majorVersion == "25";
  pname = "corretto${majorVersion}";

  mkTests = pkg: {
    version = testers.testVersion { package = pkg; };
    vendor = runCommand "${pname}-vendor" { nativeBuildInputs = [ pkg ]; } ''
      output=$(${pkg.meta.mainProgram} -XshowSettings:properties -version 2>&1 | grep vendor)
      grep -Fq "java.vendor = Amazon.com Inc." - <<< "$output" && touch $out
    '';
    compiler = runCommand "${pname}-compiler" { nativeBuildInputs = [ pkg ]; } ''
      cat << EOF  > Main.java
      class Main {
          public static void main(String[] args) {
              System.out.println("Hello, World!");
          }
      }
      EOF
      ${pkg}/bin/javac Main.java
      ${pkg}/bin/java Main | grep -q "Hello, World!" && touch $out
    '';
  };

  metaCommon = {
    homepage = "https://aws.amazon.com/corretto";
    license = lib.licenses.gpl2Only;
    description = "Amazon's distribution of OpenJDK";
    maintainers = with lib.maintainers; [ rollf ];
    # By default, aarch64-darwin builds without Xcode's `metal`/`metallib`
    # shader compiler (proprietary, only ships with a full Xcode install,
    # not nixpkgs' CLT-derived apple-sdk) by skipping the Metal-accelerated
    # Java2D pipeline - see postPatch. Pass `withAppleMetal = true` (and a
    # `pkgs.xcode` supplied via its `requireFile` instructions) to build
    # with the real pipeline instead.
    platforms = lib.platforms.linux ++ [ "aarch64-darwin" ];
    teams = [ ];
    mainProgram = "java";
  };
in
if stdenv.hostPlatform.isDarwin then
  stdenv.mkDerivation (finalAttrs: {
    inherit pname version;
    inherit (source) src;

    nativeBuildInputs = [
      jdk # boot JDK for `--with-boot-jdk`, see postPatch
      gradle
      libarchive # `bsdtar`
      rsync
      autoconf
      which
      zip
      cups
      libiconv
      makeWrapper
    ]
    ++ lib.optional withAppleMetal xcode;

    env = lib.optionalAttrs withAppleMetal {
      # Makes configure's `xcrun -sdk macosx metal`/`metallib` lookups (see
      # make/autoconf/toolchain.m4) resolve to the real Xcode instead of
      # nixpkgs' CLT-derived apple-sdk, which doesn't ship compiler binaries.
      DEVELOPER_DIR = "${xcode}/Contents/Developer";
    };

    patches =
      if is11 then
        # No Metal pipeline exists in corretto11 at all, so there's nothing
        # to skip/opt into here regardless of withAppleMetal.
        [ ./11/gradle8.patch ]
      else if is17 then
        [ ./17/gradle8.patch ] ++ lib.optional (!withAppleMetal) ./17/skip-metal.patch
      else if is21 then
        [ ./21/gradle8.patch ] ++ lib.optional (!withAppleMetal) ./21/skip-metal.patch
      else if is25 then
        [ ./25/remove_removal_of_wformat_during_test_compilation.patch ]
        ++ lib.optional (!withAppleMetal) ./25/skip-metal.patch
      else
        [ ];

    postPatch =
      let
        extra_config = builtins.concatStringsSep " " extraConfig;
      in
      ''
        # These fixes are necessary as long as we use Gradle 9 to build
        # Corretto but upstream is not yet using it. I.e. as long as upstream
        # hasn't fixed compatibility with Gradle 9 issues.
        find ./installers -type d -exec cp ./version.txt {}/version.txt \;
        find ./installers -name 'build.gradle' -exec sed -i '/fileMode =/d' {} \;
        for d in source pre-build; do
          # These subprojects (see settings.gradle) don't exist. Create them
          # here so that Gradle doesn't complain.
          mkdir ./$d
          cp ./version.txt ./$d/version.txt
        done

        # `/usr/bin/rsync` is invoked to copy the source tree. We don't have that.
        for file in $(find installers -name "build.gradle"); do
          substituteInPlace $file --replace-warn "workingDir '/usr/bin'" "workingDir '.'"
        done

        # `SetFile` (a classic Mac OS resource-fork tool from Xcode's command
        # line tools) isn't packaged in nixpkgs. It only sets a cosmetic
        # bundle-type flag on the output .jdk bundle, so no-op the call.
        substituteInPlace installers/mac/tar/build.gradle \
          --replace-warn "'SetFile'" "'true'" \
          --replace-warn "\"SetFile\"" "\"true\""

        # Corretto's own configure flags (see installers/mac/tar/build.gradle)
        # don't give us a boot JDK or sysroot, unlike the OpenJDK flags we
        # reuse on Linux (there is no from-source OpenJDK-on-Darwin
        # derivation to borrow flags from). Supply them here instead; this is
        # appended last so it overrides Corretto's own flags.
        gradleFlagsArray+=(-Pcorretto.extra_config="--with-cacerts-file=$NIX_BUILD_TOP/cacerts-gen/cacerts --with-boot-jdk=${jdk.home} --with-sysroot=$SDKROOT --disable-precompiled-headers --with-cups=${cups.dev} ${extra_config}")

        # The tar packaging expects commitId.txt, which git checkouts don't
        # have.
        substituteInPlace build.gradle --replace-warn "'README.md', 'commitId.txt', 'version.txt'" "'README.md', 'version.txt'"

        # The tar packaging also expects README.JAVASE, which is missing too.
        gradleFlagsArray+=(-Pcorretto.excludeReadmeJavaSE=true)
      '';

    # since we dontConfigure, we must run this manually
    preBuild = ''
      gradleConfigureHook

      mkdir "$NIX_BUILD_TOP/cacerts-gen"
      (
        cd "$NIX_BUILD_TOP/cacerts-gen"
        JAVA_TOOL_OPTIONS="-Dkeystore.pkcs12.certProtectionAlgorithm=NONE -Dkeystore.pkcs12.macAlgorithm=NONE" \
          ${jre-generate-cacerts} ${jdk.home}/bin/keytool ${cacert}/etc/ssl/certs/ca-bundle.crt
      )
    '';

    gradleBuildTask = ":installers:mac:tar:packaging";

    postBuild = ''
      # Prepare for the installPhase so that it looks like a normal OpenJDK
      # had been built. The mac tar wraps a `<name>.jdk/Contents/Home/...`
      # bundle rather than Linux's flat `jdk/...`; flatten it the same way.
      dir=build/jdkImageName/images
      mkdir -p $dir
      file=$(find ./installers -name 'amazon-corretto-*.tar.gz')
      tar -xzf "$file" -C $dir
      mv "$dir"/amazon-corretto-*.jdk/Contents/Home "$dir/jdk"
      chmod +x $dir/jdk/bin/*
    '';

    installPhase = ''
      mkdir -p $out/lib $out/share
      mv build/jdkImageName/images/jdk $out/lib/corretto
    ''
    + lib.optionalString (!withAppleMetal) ''
      # No real shaders.metallib was built (see postPatch), so default the
      # Metal-accelerated Java2D pipeline off to avoid Swing/AWT apps
      # hitting a missing resource at runtime. Still fully overridable: an
      # explicit -Dsun.java2d.metal=... on the command line, or the
      # caller's own JDK_JAVA_OPTIONS, takes precedence over this default.
      wrapProgram $out/lib/corretto/bin/java \
        --set-default JDK_JAVA_OPTIONS "-Dsun.java2d.metal=false"
    ''
    + ''
      ln -s $out/lib/corretto $out/lib/openjdk
      ln -s $out/lib/corretto/bin $out/bin
      ln -s $out/lib/corretto/include $out/include
      ln -s $out/lib/corretto/man $out/share/man
      ln -s $out/lib/corretto/lib/src.zip $out/lib/src.zip
    '';

    passthru = {
      home = "${finalAttrs.finalPackage}/lib/corretto";
      tests = mkTests finalAttrs.finalPackage;
    };

    meta = metaCommon;
  })
else
  jdk.overrideAttrs (
    finalAttrs: oldAttrs: {
      inherit pname version;
      inherit (source) src;

      nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [
        jdk
        gradle
        libarchive # `bsdtar`
        rsync
      ];

      dontConfigure = true;

      patches =
        if is11 then
          (oldAttrs.patches or [ ])
          ++ [
            ./11/gradle8.patch
          ]
        else if is17 then
          # Corretto17 has incorporated this patch already so it fails to apply.
          # We thus skip it here.
          # See https://github.com/corretto/corretto-17/pull/158
          lib.remove (fetchurl {
            url = "https://git.alpinelinux.org/aports/plain/community/openjdk17/FixNullPtrCast.patch?id=41e78a067953e0b13d062d632bae6c4f8028d91c";
            sha256 = "sha256-LzmSew51+DyqqGyyMw2fbXeBluCiCYsS1nCjt9hX6zo=";
          }) (oldAttrs.patches or [ ])
          ++ [ ./17/gradle8.patch ]
        else if is21 then
          (oldAttrs.patches or [ ])
          ++ [
            ./21/gradle8.patch
          ]
        else if is25 then
          (oldAttrs.patches or [ ])
          ++ [
            # See patches in openjdk/generic.nix.
            ./25/remove_removal_of_wformat_during_test_compilation.patch
          ]
        else
          (oldAttrs.patches or [ ]);

      postPatch =
        let
          extra_config = builtins.concatStringsSep " " extraConfig;
          jdk_configure_flags = "'" + builtins.concatStringsSep "', '" oldAttrs.configureFlags + "'";
        in
        (oldAttrs.postPatch or "")
        + ''
          # The rpm/deb task definitions require a Gradle plugin which we don't
          # have and so the build fails. We'll simply empty them here because
          # they are not needed anyways. The directories are kept because Gradle
          # still expects them.
          rm -rf installers/linux/universal/{rpm,deb}/{*,.*}

          # These fixes are necessary as long as we use Gradle 9 to build
          # Corretto but upstream is not yet using it. I.e. as long as upstream
          # hasn't fixed compatibility with Gradle 9 issues.
          find /build/source/installers -type d -exec cp /build/source/version.txt {}/version.txt \;
          find /build/source/installers -name 'build.gradle' -exec sed -i '/fileMode =/d' {} \;
          for d in source pre-build; do
            # These subprojects (see settings.gradle) don't exist. Create them
            # here so that Gradle doesn't complain.
            mkdir /build/source/$d
            cp /build/source/version.txt /build/source/$d/version.txt
          done

          # `/usr/bin/rsync` is invoked to copy the source tree. We don't have that.
          for file in $(find installers -name "build.gradle"); do
            substituteInPlace $file --replace-warn "workingDir '/usr/bin'" "workingDir '.'"
          done

          # Prepend corresponding OpenJDK flags to Corretto's own configure flags.
          # This will provide us with the version-specific fixes (see
          # openjdk/generic.nix) while giving Corretto's flags precedence.
          # Note that the OpenJdK flags contain "--with-boot-jdk=..."!
          substituteInPlace build.gradle --replace-fail "correttoCommonFlags = [" "correttoCommonFlags = [${jdk_configure_flags} ,"
          # Finally, *append* our flags. build.gradle places corretto.extra_config
          # after Corretto's own flags, so our --with-cacerts-file (see preBuild)
          # overrides Corretto's, and the nix-corretto-version specific flags in
          # extra_config come last and can override ours.
          gradleFlagsArray+=(-Pcorretto.extra_config="--with-cacerts-file=$NIX_BUILD_TOP/cacerts-gen/cacerts ${extra_config}")

          # The tar packaging expects commitId.txt, which git checkouts don't
          # have.
          substituteInPlace build.gradle --replace-warn "'README.md', 'commitId.txt', 'version.txt'" "'README.md', 'version.txt'"

          # The tar packaging also expects README.JAVASE, which is missing too.
          # N.B.: build.gradle says
          # "If this is a certified release build, exclude the README.JAVASE file"
          # The Nix build is not "certified" but we do not have that file anyhow.
          gradleFlagsArray+=(-Pcorretto.excludeReadmeJavaSE=true)
        '';

      # since we dontConfigure, we must run this manually
      # dontConfigure also skips OpenJDK's preConfigure, so build
      # lib/security/cacerts from cacert here, the same way it does.
      preBuild = ''
        gradleConfigureHook

        mkdir "$NIX_BUILD_TOP/cacerts-gen"
        (
          cd "$NIX_BUILD_TOP/cacerts-gen"
          JAVA_TOOL_OPTIONS="-Dkeystore.pkcs12.certProtectionAlgorithm=NONE -Dkeystore.pkcs12.macAlgorithm=NONE" \
            ${jre-generate-cacerts} ${jdk.home}/bin/keytool ${cacert}/etc/ssl/certs/ca-bundle.crt
        )
      '';

      gradleBuildTask = ":installers:linux:universal:tar:packageBuildResults";

      postBuild = ''
        # Prepare for the installPhase so that it looks like if a normal
        # OpenJDK had been built.
        dir=build/jdkImageName/images
        mkdir -p $dir
        file=$(find ./installers -name 'amazon-corretto-${version}*.tar.gz')
        tar -xzf $file -C $dir
        mv $dir/amazon-corretto-* $dir/jdk
        chmod +x $dir/jdk/bin/*
      ''
      + oldAttrs.postBuild or "";

      installPhase = oldAttrs.installPhase + ''
        # The installPhase will place everything in $out/lib/openjdk and
        # reference through symlinks. We don't rewrite the installPhase but at
        # least move the folder to convey that this is not OpenJDK anymore.
        mv $out/lib/openjdk $out/lib/corretto
        ln -s $out/lib/corretto $out/lib/openjdk
      '';

      passthru =
        let
          pkg = finalAttrs.finalPackage;
        in
        oldAttrs.passthru // { tests = mkTests pkg; };

      meta = oldAttrs.meta // metaCommon;
    }
  )
