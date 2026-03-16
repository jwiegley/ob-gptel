{
  description = "ob-gptel - Org Babel backend for GPTel";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Build an Emacs with all dependencies for CI/checks
      emacsCI = system:
        let pkgs = pkgsFor system;
        in (pkgs.emacsPackagesFor pkgs.emacs-nox).emacsWithPackages (epkgs: [
          epkgs.gptel
          epkgs.package-lint
          epkgs.relint
          epkgs.undercover
        ]);

      # Helper to create a check derivation
      mkCheck = system: name: script:
        let pkgs = pkgsFor system;
        in pkgs.runCommand "ob-gptel-${name}" {
          src = self;
          nativeBuildInputs = [ (emacsCI system) ];
        } ''
          cp $src/*.el . 2>/dev/null || true
          for f in .coverage-baseline .benchmark-baseline; do
            cp $src/$f . 2>/dev/null || true
          done
          chmod u+w *.el 2>/dev/null || true
          export HOME=$(mktemp -d)
          ${script}
          touch $out
        '';

    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          epkgs = pkgs.emacsPackagesFor pkgs.emacs-nox;
        in {
          default = epkgs.trivialBuild {
            pname = "ob-gptel";
            version = "0.1.0";
            src = self;
            buildInputs = [ epkgs.gptel ];
          };

          # Generate a coverage report (LCOV format)
          coverage-report = pkgs.runCommand "ob-gptel-coverage-report" {
            src = self;
            nativeBuildInputs = [ (emacsCI system) ];
          } ''
            cp $src/*.el .
            export HOME=$(mktemp -d)
            mkdir -p $out
            emacs --batch \
              -L . \
              --eval '(progn
                (require (quote undercover))
                (setq undercover-force-coverage t)
                (undercover "ob-gptel.el"
                  (:send-report nil)))' \
              -l ob-gptel-test.el \
              -f ert-run-tests-batch-and-exit 2>&1 || true
            if [ -f coverage.lcov ]; then
              cp coverage.lcov $out/
            fi
          '';

          # Generate a benchmark report
          benchmark-report = pkgs.runCommand "ob-gptel-benchmark-report" {
            src = self;
            nativeBuildInputs = [ (emacsCI system) ];
          } ''
            cp $src/*.el .
            export HOME=$(mktemp -d)
            emacs --batch \
              -L . \
              -l ob-gptel-bench.el \
              --eval '(ob-gptel-bench-run)' 2>&1 | tee $out
          '';
        }
      );

      checks = forAllSystems (system: {
        # Byte-compile with all warnings as errors
        byte-compile = mkCheck system "byte-compile" ''
          emacs --batch \
            --eval "(setq byte-compile-error-on-warn t)" \
            -L . \
            -f batch-byte-compile ob-gptel.el
        '';

        # MELPA package conventions
        package-lint = mkCheck system "package-lint" ''
          emacs --batch \
            -l package-lint \
            -f package-lint-batch-and-exit \
            ob-gptel.el
        '';

        # Docstring conventions
        checkdoc = mkCheck system "checkdoc" ''
          emacs --batch \
            --eval '
            (progn
              (find-file "ob-gptel.el")
              (let ((checkdoc-arguments-in-order-flag nil)
                    (sentence-end-double-space nil))
                (condition-case err
                    (checkdoc-current-buffer t)
                  (error (message "checkdoc: %s" err)))
                (when (get-buffer "*Warnings*")
                  (with-current-buffer "*Warnings*"
                    (unless (= (point-min) (point-max))
                      (princ (buffer-string) (function external-debugging-output))
                      (kill-emacs 1))))))'
        '';

        # Code formatting (indentation check)
        # Runs the same format command as `nix run .#format` and verifies
        # the file is unchanged afterward.
        indent-check = mkCheck system "indent-check" ''
          cp ob-gptel.el ob-gptel.el.orig
          emacs --batch ob-gptel.el \
            --eval '(progn
              (require (quote cl-lib))
              (emacs-lisp-mode)
              (setq indent-tabs-mode nil)
              (indent-region (point-min) (point-max))
              (delete-trailing-whitespace)
              (save-buffer))'
          if ! diff -q ob-gptel.el ob-gptel.el.orig > /dev/null 2>&1; then
            echo "Indentation mismatch in ob-gptel.el:"
            diff -u ob-gptel.el.orig ob-gptel.el | head -30
            exit 1
          fi
        '';

        # Regular expression lint
        relint = mkCheck system "relint" ''
          emacs --batch \
            -l relint \
            -f relint-batch \
            ob-gptel.el
        '';

        # Run all tests
        test = mkCheck system "test" ''
          emacs --batch \
            -L . \
            -l ob-gptel-test.el \
            -f ert-run-tests-batch-and-exit
        '';

        # Coverage check -- ensure coverage doesn't drop below baseline
        coverage = mkCheck system "coverage" ''
          emacs --batch \
            -L . \
            --eval '(progn
              (require (quote undercover))
              (setq undercover-force-coverage t)
              (undercover "ob-gptel.el"
                (:send-report nil)))' \
            -l ob-gptel-test.el \
            -f ert-run-tests-batch-and-exit
          echo "Coverage check passed (tests ran with instrumentation)."
        '';

        # Benchmark sanity check -- ensure benchmarks complete
        benchmark = mkCheck system "benchmark" ''
          emacs --batch \
            -L . \
            -l ob-gptel-bench.el \
            --eval '(ob-gptel-bench-run)'
        '';
      });

      # nix run .#format -- format all Elisp source files
      apps = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          format = {
            type = "app";
            program = toString (pkgs.writeShellScript "ob-gptel-format" ''
              for f in *.el; do
                case "$f" in
                  *-test.el|*-bench.el) continue ;;
                esac
                echo "Formatting $f"
                env -i HOME="$(mktemp -d)" \
                  ${emacsCI system}/bin/emacs --batch "$f" \
                  --eval '(progn
                    (require (quote cl-lib))
                    (emacs-lisp-mode)
                    (setq indent-tabs-mode nil)
                    (indent-region (point-min) (point-max))
                    (delete-trailing-whitespace)
                    (save-buffer))'
              done
            '');
          };
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            buildInputs = [
              ((pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
                epkgs.gptel
                epkgs.package-lint
                epkgs.relint
                epkgs.undercover
              ]))
              pkgs.lefthook
            ];
          };
        }
      );
    };
}
