{
  description = "nix-flake-recursive-bump-input-versions: Claude Code skill for cascading lock-bump PRs across a multi-repo Nix flake tree";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-skills, ... }@inputs:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "nix-flake-recursive-bump-input-versions";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
