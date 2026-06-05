# The skill source's upstream owner, shared by this repo's flake.nix and
# every per-skill skills/*/flake.nix so agent-skill-flake namespaces package keys
# as `agent-skill-<owner>-<name>`. Defined once here and imported as the
# `source` argument. A flake can't read its own `github:owner/repo` off
# `self`, so the owner is stated rather than derived.
{ owner = "nhooey"; }
