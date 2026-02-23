{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        inherit (nixpkgs) lib;
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python312;

        # cadquery-ocp needs vtk 9.3
        vtkDeriv = import "${pkgs.path}/pkgs/development/libraries/vtk/generic.nix" {
          #version = "9.3.1";
          majorVersion = "9.3";
          minorVersion = "1";
          sourceSha256 = "sha256-g1TsCE6g0tw9I9vkJDgjxL/CcDgtDOjWWJOf1QBhyrg=";
        };
        vtk =
          (pkgs.callPackage vtkDeriv {
            enablePython = true;
            inherit python;
            #pythonSupport = true;

            # Other stuff that callPackage doesn't fill in for some reason?
            qtdeclarative = pkgs.qt5.qtdeclarative;
            qttools = pkgs.qt5.qttools;
            qtx11extras = pkgs.qt5.qtx11extras;
            qtEnv = pkgs.qt5.qtEnv;
          }).overrideAttrs
            (old: {
              # cadquery-ocp wheel looks for versioned .so file names
              # TODO: figure out why this doesn't work
              #cmakeFlags = (builtins.filter (f: !(builtins.match "^-DVTK_VERSIONED_INSTALL=.*" f)) old.cmakeFlags) ++ [
              #  "-DVTK_VERSIONED_INSTALL=ON"
              #];
              cmakeFlags = old.cmakeFlags ++ [
                "-DVTK_VERSIONED_INSTALL=ON"
              ];
            });

        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };
        editableOverlay = workspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT";
        };
        hacks = pkgs.callPackage pyproject-nix.build.hacks { };

        pyprojectOverrides = final: prev: {
          # Example override to fix build
          pyperclip = prev.pyperclip.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [
              prev.setuptools
            ];
          });
          cadquery-ocp = prev.cadquery-ocp.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [
              vtk
            ];

            # TODO: this no longer happens once cadquery was included???
            # HACK: OCP imports fail with
            # `ImportError: /nix/store/5gz8cxcfjxxc5jy84cbb3pmfvhq1zcj3-cadquery-ocp-7.8.1.1.post1/lib/python3.12/site-packages/cadquery_ocp.libs/libTKIVtk-a1a167e9.so.7.8.1: undefined symbol: _ZNK9vtkObject20GetObjectDescriptionEv`
            # if vtk isn't imported first?
            postInstall = ''
              main_init=$out/${python.sitePackages}/OCP/__init__.py
              echo 'import vtk'$'\n'"$(cat $main_init)" > $main_init
            '';
          });
        };

        pythonSet =
          (pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          }).overrideScope
            (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
                pyprojectOverrides
              ]
            );

        editablePythonSet = pythonSet.overrideScope editableOverlay;
        virtualenv = editablePythonSet.mkVirtualEnv "hello-dev-env" workspace.deps.all;

        inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;

        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
      in
      {
        packages = {
          hello = mkApplication {
            venv = pythonSet.mkVirtualEnv "hello-app-env" workspace.deps.default;
            package = pythonSet.hello;
          };
          default = self.packages.${system}.hello;
        };
        formatter = treefmtEval.config.build.wrapper;
        checks = {
          formatting = treefmtEval.config.build.check self;
        };
        devShells = {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
              pkgs.sphinx
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = editablePythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
              . ${virtualenv}/bin/activate
            '';
          };
        };
      }
    );
}
