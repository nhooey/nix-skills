{
  description = "nix-skills dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources live only in THIS flake's lock, so the root nix-skills stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides
    # `mkDevshellSkillsFlake`.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # skillspkgs' per-family combinations, surfaced through their own subdir
    # flake. nix-skills is a skill collection, so it takes the
    # `skill-collections` combination.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      skillspkgs-combinations,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "nix-skills-devshell";
      envName = "agent-skills-nix-skills-devshell";
      sources = [
        # The skill-collections family's combination, the shell's one source:
        # the shared base plus skill authoring. Nix-skills uses no language or
        # tool the rest of the family doesn't, so it adds nothing.
        { source = skillspkgs-combinations.combinations.skill-collections; }
      ];
    };
}
