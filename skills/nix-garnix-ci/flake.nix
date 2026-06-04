{
  description = "nix-garnix-ci: Claude Code skill for wiring up Garnix CI on a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, flake-skills, ... }@inputs:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      source = import ../../source.nix;
      skillName = "nix-garnix-ci";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
