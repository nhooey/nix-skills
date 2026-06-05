{
  description = "nix-garnix-ci: Claude Code skill for wiring up Garnix CI on a Nix flake";

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
      skillName = "nix-garnix-ci";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
