{
  description = "Thin asynchronous ADARD harness over Prolog-RLM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/bfc1b8a4574108ceef22f02bafcf6611380c100d";

    prolog-rlm = {
      url = "github:lost-rob0t/prolog-rlm/7df793f7e484bd947839b4670a474926f1b7c5dc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, prolog-rlm }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packageFor = system:
        let
          pkgs = import nixpkgs { inherit system; };
          runtime = prolog-rlm.packages.${system}.prolog-rlm;
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "consortium";
          version = "0.1.0";
          src = self;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/consortium" "$out/bin"
            cp -R bin emacs prolog consortium.toml schema "$out/share/consortium/"
            makeWrapper ${runtime}/bin/prolog-rlm-swipl "$out/bin/consortium" \
              --add-flags "-q -s $out/share/consortium/bin/consortium.pl --"
            runHook postInstall
          '';
        };
      pythonFor = pkgs: pkgs.python3.withPackages (ps: [ ps.jsonschema ]);
    in {
      packages = forAllSystems (system:
        let consortium = packageFor system;
        in {
          inherit consortium;
          default = consortium;
        });

      apps = forAllSystems (system: {
        consortium = {
          type = "app";
          program = "${self.packages.${system}.consortium}/bin/consortium";
        };
        daemon = {
          type = "app";
          program = "${self.packages.${system}.consortium}/bin/consortium";
        };
        default = self.apps.${system}.consortium;
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          runtime = prolog-rlm.packages.${system}.prolog-rlm;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs."swi-prolog"
              pkgs.emacs-nox
              pkgs.git
              (pythonFor pkgs)
              runtime
            ];
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          runtime = prolog-rlm.packages.${system}.prolog-rlm;
          consortium = self.packages.${system}.consortium;
        in {
          source-load = pkgs.runCommand "consortium-source-load" {
            nativeBuildInputs = [ pkgs."swi-prolog" runtime ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            swipl -q -g \
              "load_files(['${self}/prolog/consortium_agent.pl','${self}/prolog/consortium_protocol.pl'],[silent(false)]),halt"
            touch "$out"
          '';

          deterministic-tests = pkgs.runCommand "consortium-deterministic-tests" {
            nativeBuildInputs = [ pkgs."swi-prolog" runtime ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            swipl -q -s ${self}/test/run_tests.pl
            touch "$out"
          '';

          emacs-client-tests = pkgs.runCommand "consortium-emacs-client-tests" {
            nativeBuildInputs = [ pkgs.emacs-nox consortium ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            export CONSORTIUM_COMMAND="${consortium}/bin/consortium"
            emacs -Q --batch \
              -L ${self}/emacs \
              -l ${self}/test/consortium_emacs_tests.el \
              -f ert-run-tests-batch-and-exit
            touch "$out"
          '';

          contract-validation = pkgs.runCommand "consortium-contract-validation" {
            nativeBuildInputs = [ (pythonFor pkgs) ];
          } ''
            python ${self}/test/validate_contracts.py
            touch "$out"
          '';

          executable-smoke = pkgs.runCommand "consortium-executable-smoke" {
            nativeBuildInputs = [ consortium ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" "$TMPDIR/outside-source"
            cd "$TMPDIR/outside-source"
            consortium --help > help.txt
            grep -q "Persistent JSON Lines methods" help.txt
            touch "$out"
          '';

          package = consortium;
          upstream-packaged-library-load =
            prolog-rlm.checks.${system}.packaged-library-load;
          upstream-wrapper-load = prolog-rlm.checks.${system}.wrapper-load;
        });
    };
}
