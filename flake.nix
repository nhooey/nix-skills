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

    # ---------------------------------------------------------------------
    # Dev-shell skill sources (inlined — consumed only by `devshells` below)
    # ---------------------------------------------------------------------
    # The project dev shell installs one curated skill set: the git/GitHub
    # pack plus skillspkgs' `authoring` combination — combined via
    # flake-skills' `mkCombination` in `outputs` (`devshellSkills`). These
    # were previously isolated in a `skills-devshell/` sub-flake, but a
    # same-repo sub-flake can only be addressed by a relative `path:` input
    # (which sandboxed/transitive consumers reject) or a brittle self-URL
    # (which breaks on any repo/owner/host rename), so they are inlined here
    # instead. They follow the parent `nixpkgs` but NOT `flake-skills`: the
    # root pins a newer owner-namespacing `flake-skills`, and forcing the
    # `authoring` combination's transitive sources onto it surfaces an
    # ownerless aggregate-key the strict namespace check rejects. Letting each
    # source keep its own (compatible) `flake-skills` matches how the old
    # sub-flake's isolated lock worked. `mkCombination` still runs from the
    # root's `flake-skills.lib`, so the combiner is this repo's pinned rev.

    skills-git = {
      url = "github:nhooey/skills-git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # skillspkgs' curated `authoring` combination, surfaced through its own
    # subdir flake (`mkCombination` keeps a combination re-composable). This is
    # a `?dir=` into a *different* repo, which fetches cleanly for transitive
    # consumers — unlike the self-referential `?dir=` we avoid above.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-parts, flake-skills, skills-git
    , skillspkgs-combinations, ... }@inputs:
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
      mkEnv = system: packName: skillNames:
        flake-skills.lib.mkSkillsEnv {
          pkgs = nixpkgs.legacyPackages.${system};
          name = packName;
          skills = builtins.map (n: base.bySkillName.${system}.${n}) skillNames;
        };

      # The project dev-shell skill set, combined from the inlined skill
      # sources (git/GitHub pack + skillspkgs' `authoring` combination).
      # `reconcileScript` is a `system -> string` function the dev shell
      # splices into a startup hook.
      devshellSkills = flake-skills.lib.mkCombination {
        inherit nixpkgs;
        name = "skills-nix-devshell";
        envName = "agent-skills-skills-nix-devshell";
        packagePrefix = "agent-skill-";
        sources = [
          { source = skills-git; }
          { source = skillspkgs-combinations.combinations.authoring; }
        ];
      };
    in flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [ inputs.devshell.flakeModule inputs.treefmt-nix.flakeModule ];

      # Expose the declarative reconcile one-liner (system -> shell snippet at
      # --scope=project) so downstream consumers can install this pack with
      # the same idiom the aggregate flakes use, instead of reaching into
      # apps.reconcile.program and appending the scope flag.
      flake.reconcileScript = base.reconcileScript;

      perSystem = { system, ... }: {
        packages = base.packages.${system} // builtins.mapAttrs
          (packName: skillNames: mkEnv system packName skillNames) packs;

        apps = base.apps.${system};

        # Auto-reconcile the dev-shell skill set (git/GitHub + the authoring
        # combination) at project scope on `nix develop`. `devshellSkills`
        # (above) yields the reconcile one-liner per system; this just
        # splices it in.
        devshells.default = {
          name = "skills-nix";
          motd = ''
            {bold}{14}🚀 Entering skills-nix dev shell{reset}
            Run {bold}menu{reset} to list available commands.
          '';
          devshell.startup.install-skills.text = ''
            ${devshellSkills.reconcileScript system}
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
