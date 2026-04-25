{
  description = "nix-clojure: Claude Code skill for Clojure / ClojureScript packaging in Nix flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:nhooey/flake-skills";
    flake-skills.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "nix-clojure";
      src = ./.;
    };
}
