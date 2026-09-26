Feature: Child pi sessions boot without an interactive trust prompt
  sub-spawn.sh must start every child pi session on a brand-new treehouse
  worktree with zero manual intervention. Each fresh worktree path is a folder
  pi has never seen, so it has no saved trust decision for it; the child's
  isolated agent directory also carries no defaultProjectTrust policy. Pi
  therefore stops on the folder-trust prompt before it processes the kickoff
  message, and the orchestrator has to press Enter by hand.

  Background:
    Given a scratch repository whose worktrees contain a .pi/settings.json
      resource that requires a project-trust decision
    And a treehouse worktree path that pi has never seen
    And a pi that resolves project trust in the documented order: command-line
      override first, then a saved decision in trust.json for the current
      directory or a parent, then the defaultProjectTrust setting, and
      otherwise an interactive prompt that blocks until a keystroke decides
      (the default option persists the decision to trust.json)

  Scenario: Resolve project trust on a fresh worktree without a keystroke [REQ-1]
    When sub-spawn.sh spawns the task
    Then the child pi resolves project trust without showing a blocking prompt
    And the child pi never receives a trust-granting keystroke

  Scenario: Leave no persistent trust decision behind [REQ-2]
    Given the spawn has completed
    When the child has booted
    Then the user trust store contains no decision for the worktree path
    And the user settings file is unchanged

  Scenario: Process the kickoff instead of stranding it [REQ-3]
    Given the spawn has completed
    When the child has booted
    Then the child pi reports the kickoff message accepted and is working on it
