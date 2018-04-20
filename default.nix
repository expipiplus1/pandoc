# This Nix file can be handy when working on the github version of pandoc.
#
# To build pandoc run:
#    nix-build
# To run a nix shell with everthing needed to build pandoc with cabal:
#    nix-shell
# To build pandoc for use on Linux and macOS systems without Nix:
#    nix-build -A patched
{ pkgs ? import <nixpkgs> {} }:
let haskellPackages = pkgs.haskellPackages;
    overrides = self: super: { };
    source-overrides = {
      doctemplates = "0.2.1";
      texmath = "0.10";
      pandoc-types = pkgs.fetchFromGitHub {
        owner = "jgm";
        repo = "pandoc-types";
        rev = "b7254385586aa20be0e3e838c25ddb04525b7d5d";
        sha256 = "0j859dfr4mzk4yxjm1gi69m94h9qllrmax9aisv6h4sqxgnp8c3b";
      };
    };
    filterHaskellSource = src:
      builtins.filterSource (path: type:
        pkgs.lib.all (i: i != baseNameOf path) [ ".git" "dist-newstyle" "cabal.project.local" "dist" ".stack-work" ".DS_Store" "default.nix" "result" ]
          && pkgs.lib.all (i: !(pkgs.lib.hasSuffix i path)) [ ".lkshf" ]
          && pkgs.lib.all (i: !(pkgs.lib.hasPrefix i path)) [ ".ghc.environment." ]
        ) src;

    # Normal nix derivation
    drv = (
        haskellPackages.extend (
          pkgs.lib.composeExtensions (
            haskellPackages.packageSourceOverrides source-overrides
          ) overrides
        )
      ).callCabal2nix "pandoc" (filterHaskellSource ./.) {};

    # Like drv but with static linking for haskell libraries
    static = pkgs.haskell.lib.justStaticExecutables (drv.overrideAttrs (old: {
        buildInputs = old.buildInputs ++ [
          pkgs.zlib.static
          haskellPackages.file-embed
        ];
        configureFlags = [
          "-fembed_data_files"
          "--disable-executable-dynamic"
        ];
      }));

    # Patch binaries for use on macOS and linux systems without nix
    # and bundle the required gmp and lua libraries
    patched = pkgs.stdenv.mkDerivation {
        name = "pandoc-patched";
        buildInputs = [
          static
          pkgs.zip
          pkgs.gnutar
        ];
        unpackPhase = "true";
        buildPhase = "true";
        installPhase = if pkgs.stdenv.isDarwin
          then ''
              mkdir -p $out/bin
              cp ${static}/bin/pandoc $out/bin
              cp ${pkgs.gmp}/lib/libgmp.10.dylib $out/bin
              cp ${pkgs.lua5_3}/lib/liblua.5.3.4.dylib $out/bin
              chmod +w $out/bin/*
              echo patching libgmp and liblua
              install_name_tool -id "@executable_path/libgmp.10.dylib" "$out/bin/libgmp.10.dylib"
              install_name_tool -id "@executable_path/liblua.5.3.4.dylib" "$out/bin/liblua.5.3.4.dylib"
              for fn in $out/bin/*; do
                echo patching $fn
                install_name_tool -change "${pkgs.libiconv}/lib/libiconv.dylib" /usr/lib/libiconv.dylib "$fn"
                install_name_tool -change "${pkgs.stdenv.libc}/lib/libSystem.B.dylib" /usr/lib/libSystem.B.dylib "$fn"
                install_name_tool -change "${pkgs.gmp}/lib/libgmp.10.dylib" "@executable_path/libgmp.10.dylib" "$fn"
                install_name_tool -change "${pkgs.lua5_3}/lib/liblua.5.3.4.dylib" "@executable_path/liblua.5.3.4.dylib" "$fn"
              done
              (cd $out/.. && zip -r $out/pandoc-macOS.zip `basename $out`/bin)
            ''
          else ''
              mkdir -p $out/bin
              cp ${static}/bin/pandoc $out/bin
              cp ${pkgs.gmp}/lib/libgmp.so* $out/bin
              cp ${pkgs.lua5_3}/lib/liblua.so* $out/bin
              chmod +w $out/bin/pandoc
              patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 $out/bin/pandoc
              patchelf --set-rpath '$ORIGIN' $out/bin/pandoc
              (cd $out/.. && tar -czf $out/pandoc-linux.tar.gz `basename $out`/bin)
            '';
    };
in if pkgs.lib.inNixShell then drv.env else drv // { inherit static patched; }
