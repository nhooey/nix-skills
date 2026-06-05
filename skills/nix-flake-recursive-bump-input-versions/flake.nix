{
  description = "nix-flake-recursive-bump-input-versions: Claude Code skill for cascading lock-bump PRs across a multi-repo Nix flake tree";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, agent-skill-flake, ... }@inputs:
    agent-skill-flake.lib.mkSkillFlake {
      inherit nixpkgs;
      source = import ../../source.nix;
      skillName = "nix-flake-recursive-bump-input-versions";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
