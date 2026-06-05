{
  description = "nix-skills: Claude Code skills marketplace as a Nix flake";

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
    # `agent-skill-flake` is the builder library, not a skill — it turns skill
    # directories into installable flakes and aggregates them.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-parts,
      agent-skill-flake,
      ...
    }@inputs:
    let
      # The skills this repo outputs: every skill under ./skills built into
      # per-skill packages (consumed by `packs`/`mkEnv` below) plus the base
      # install/preview apps.
      base = agent-skill-flake.lib.mkAllSkillsFlake {
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
        agent-skill-flake.lib.mkSkillsEnv {
          pkgs = nixpkgs.legacyPackages.${system};
          name = packName;
          skills = builtins.map (n: base.bySkillName.${system}.${n}) skillNames;
        };

      # Root-side wiring for the `skills-devshell/` sub-flake: the dev-shell
      # skill set (skillspkgs' authoring-with-git combination) is defined in
      # the isolated `skills-devshell/` sub-flake and invoked here at RUNTIME
      # (not a root input), so this flake keeps zero skill inputs and never
      # drags the skill mesh into its lock.
      devshellSkills = agent-skill-flake.lib.devshellSkillsHook { };
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

          devshells.default = {
            name = "nix-skills";
            motd = ''
              {bold}{14}🚀 Entering nix-skills dev shell{reset}
              Run {bold}menu{reset} to list available commands.
            '';
            # Reconcile the dev-shell skill set at project scope on `nix
            # develop`, running the reconcile app from the `skills-devshell/`
            # sub-flake.
            devshell.startup.install-skills.text = devshellSkills.startup;
            commands = [
              {
                category = "skills";
                name = "reap-skills";
                help = "Remove every skill this dev shell installed (one owner)";
                command = devshellSkills.reap;
              }
              {
                category = "skills";
                name = "update-skills-devshell";
                help = "Bump the skills-devshell/ sub-flake lock (the skill set)";
                command = ''nix flake update --flake "$PRJ_ROOT/skills-devshell" "$@"'';
              }
            ];
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
