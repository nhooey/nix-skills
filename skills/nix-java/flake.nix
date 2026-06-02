{
  description = "nix-java: Claude Code skill for JVM-specific patterns in Nix flakes";

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
      skillName = "nix-java";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
