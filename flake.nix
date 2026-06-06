{
  description = "nix-skills: Claude Code skills marketplace as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
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
      # per-skill packages plus the base install/preview apps.  The `name`
      # argument names the aggregate "all" bundle by owner + topic rather than
      # letting it default to the owner-wide `agent-skills-nhooey-all`.  That
      # owner-all is unresolvable — no single repo holds all of nhooey's skills
      # — and collides across every nhooey repo under skillspkgs / nur-packages'
      # last-write-wins `//` merge; the owner+topic name survives, mirroring
      # git-skills's `agent-skills-nhooey-git-all`.  The aggregate carries the
      # home-manager `isFlakeSkillsEnv` passthru itself, so `default` is
      # directly installable — no hand-rolled pack needed.
      base = agent-skill-flake.lib.mkAllSkillsFlake {
        inherit nixpkgs;
        source = import ./source.nix;
        skillsDir = ./skills;
        packagePrefix = "agent-skill-";
        name = "agent-skills-nhooey-nix-all";
      };

    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        # Bundles numtide/devshell + the motd, install-skills startup, and the
        # standard (ci/dev/maintenance) + skills command lists, replacing the
        # hand-rolled devshell wiring this repo used to carry. The runtime
        # `skills-devshell/` sub-flake is reconciled by the module's startup.
        inputs.agent-skill-flake.flakeModules.devshellSkills
        inputs.treefmt-nix.flakeModule
      ];

      # The module defaults already target `skills-devshell/` at project scope
      # with reconcile/purge, so only the devShell name differs from stock.
      agent-skill-flake.devshellSkills.name = "nix-skills";

      # Expose the declarative reconcile one-liner (system -> shell snippet at
      # --scope=project) so downstream consumers can install this pack with
      # the same idiom the aggregate flakes use, instead of reaching into
      # apps.reconcile.program and appending the scope flag.
      flake.reconcileScript = base.reconcileScript;

      perSystem =
        { system, ... }:
        {
          packages = base.packages.${system};

          apps = base.apps.${system};

          # The devShell (motd, install-skills startup reconciling the
          # `skills-devshell/` sub-flake, and the standard + skills command
          # lists) comes entirely from the imported devshellSkills module.

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
