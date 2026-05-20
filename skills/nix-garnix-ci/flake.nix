{
  description = "nix-garnix-ci: Claude Code skill for wiring up Garnix CI on a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:nhooey/flake-skills/configurable-package-prefix";
    flake-skills.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "nix-garnix-ci";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
