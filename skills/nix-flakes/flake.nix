{
  description = "nix-flakes: Claude Code skill for generic Nix flake conventions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:nhooey/flake-skills/configurable-package-prefix";
    flake-skills.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "nix-flakes";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
