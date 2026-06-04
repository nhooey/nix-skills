{
  description = "nix-clojure: Claude Code skill for Clojure / ClojureScript packaging in Nix flakes";

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
      skillName = "nix-clojure";
      src = ./.;
      packagePrefix = "agent-skills-pack-";
    };
}
