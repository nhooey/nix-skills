{
  description = "nix-skills dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (skillspkgs' authoring-with-git combination) live only in THIS flake's lock, so the root nix-skills stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides
    # `mkDevshellSkillsFlake`. Followed by every skill source below so the
    # whole tree shares one evaluation.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # skillspkgs' curated `authoring-with-git` combination (nix + humanizer +
    # anthropic/daymade skill-creation + superpowers + the whole git/GitHub
    # pack), surfaced through its own subdir flake so it stays re-composable as
    # a source. This is the dev shell's entire skill set in one combination.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        agent-skill-flake.follows = "agent-skill-flake";
      };
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
      packagePrefix = "agent-skill-";
      sources = [
        { source = skillspkgs-combinations.combinations.authoring-with-git; }
      ];
    };
}
