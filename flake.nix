{
  description = "skills-nix: Claude Code skills marketplace as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, systems, flake-skills, ... }@inputs:
    let
      base = flake-skills.lib.mkAllSkillsFlake {
        inherit nixpkgs;
        skillsDir = ./skills;
        packagePrefix = "agent-skill-";
      };

      forSystems = nixpkgs.lib.genAttrs (import systems);

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

      mkEnv =
        system: packName: skillNames:
        flake-skills.lib.mkSkillsEnv {
          pkgs = nixpkgs.legacyPackages.${system};
          name = packName;
          skills = builtins.map (n: base.packages.${system}."agent-skill-${n}") skillNames;
        };

      packPackages = forSystems (
        system: nixpkgs.lib.mapAttrs (packName: skills: mkEnv system packName skills) packs
      );
    in
    base
    // {
      packages = nixpkgs.lib.recursiveUpdate base.packages packPackages;
    };
}
