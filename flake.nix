{
  description = "skills-nix: Claude Code skills marketplace as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The dev-shell skill set (git/GitHub + skillspkgs' authoring combination)
    # as its own sub-flake, so its skill-source inputs stay isolated in
    # `skills-devshell/flake.lock` rather than this flake's inputs. The
    # combination is formed there; the dev shell consumes its `reconcileScript`.
    skills-devshell = {
      url = "github:nhooey/skills-nix?dir=skills-devshell";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      flake-parts,
      flake-skills,
      ...
    }@inputs:
    let
      # The skills this repo outputs: every skill under ./skills built into
      # per-skill packages (consumed by `packs`/`mkEnv` below) plus the base
      # install/preview apps. The skills-git pack and authoring-only skills
      # installed in the dev shell come from external inputs — see
      # `skills-git` and `skillspkgs-combinations`.
      base = flake-skills.lib.mkAllSkillsFlake {
        inherit nixpkgs;
        source = import ./source.nix;
        skillsDir = ./skills;
        packagePrefix = "agent-skill-";
      };

      packs = {
        # All nix-* skills.
        agent-skills-nix-all = [
          "nix-clojure"
          "nix-flake-recursive-bump-input-versions"
          "nix-flakes"
          "nix-garnix-ci"
          "nix-java"
        ];
      };

      # A pack list is bare skill names; `base.bySkillName` indexes the
      # per-skill drvs by that stable identity, so the lookup is independent
      # of how the package keys are owner-namespaced.
      mkEnv =
        system: packName: skillNames:
        flake-skills.lib.mkSkillsEnv {
          pkgs = nixpkgs.legacyPackages.${system};
          name = packName;
          skills = builtins.map (n: base.bySkillName.${system}.${n}) skillNames;
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      # Expose the declarative reconcile one-liner (system -> shell snippet at
      # --scope=project) so downstream consumers can install this pack with
      # the same idiom the aggregate flakes use, instead of reaching into
      # apps.reconcile.program and appending the scope flag.
      flake.reconcileScript = base.reconcileScript;

      perSystem =
        { system, ... }:
        {
          packages =
            base.packages.${system}
            // builtins.mapAttrs (packName: skillNames: mkEnv system packName skillNames) packs;

          apps = base.apps.${system};

          # Auto-reconcile the dev-shell skill set (git/GitHub + the authoring
          # combination) at project scope on `nix develop`. The skills-devshell
          # sub-flake outputs the reconcile one-liner as text per system; this
          # just splices it in.
          devshells.default = {
            name = "skills-nix";
            motd = ''
              {bold}{14}🚀 Entering skills-nix dev shell{reset}
              Run {bold}menu{reset} to list available commands.
            '';
            devshell.startup.install-skills.text = ''
              ${inputs.skills-devshell.reconcileScript.${system}}
            '';
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              shfmt.enable = true;
              yamlfmt.enable = true;
            };
          };
        };
    };
}
