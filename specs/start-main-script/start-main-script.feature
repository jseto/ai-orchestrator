Feature: start-main.sh — boot the orchestrator's main pi session
  The orchestrator pattern requires the main pi session to live in a tmux
  session named exactly "pi-main", rooted at the main checkout of this repo,
  arranged so children can later occupy the right half of the screen. Booting
  it must take a single command, be safe to run from anywhere, and never
  clobber a session that is already running.

  Scenario: Start a detached session under the exact name pi-main [REQ-1]
    Given no tmux session named "pi-main" exists on the server
    When the script is run with "--detach"
    Then it exits successfully
    And a tmux session named exactly "pi-main" exists on the server

  Scenario: Launch the program named by PI_BIN without child arguments [REQ-2]
    Given no tmux session named "pi-main" exists on the server
    And "PI_BIN" points to a fake pi executable
    When the script is run with "--detach"
    Then the session pane runs the fake pi executable
    And the launched command carries no child arguments such as "-n" or "--no-extensions"

  Scenario: Default to plain pi when PI_BIN is unset [REQ-3]
    Given no tmux session named "pi-main" exists on the server
    And "PI_BIN" is not set
    And a fake "pi" executable is first on PATH
    When the script is run with "--detach"
    Then the session pane runs the fake "pi" executable from PATH

  Scenario: Root the session at the main checkout regardless of invocation cwd [REQ-4]
    Given no tmux session named "pi-main" exists on the server
    When the script is run with "--detach" from an unrelated working directory
    Then the session's working directory is the main checkout of the repository
    And when the script is run with "--detach" from its own location, which lives in a linked worktree when the tests run from one, the session's working directory is still the main checkout of the repository

  Scenario: Configure the new session's window for the orchestrator layout [REQ-5]
    Given no tmux session named "pi-main" exists on the server
    When the script is run with "--detach"
    Then the session's window has main-pane-width set to 50% so children can be arranged on the right half

  Scenario: Preserve an existing session and report where it is [REQ-6]
    Given a running "pi-main" session started by the script
    When the script is run with "--detach"
    Then it exits successfully
    And the session's pane process was not restarted
    And the session's window options were not modified
    And the output names the session and its working directory

  Scenario: Attach to the session by default [REQ-7]
    Given a running "pi-main" session with no attached client
    When the script is run without flags
    Then a tmux client is attached to "pi-main"
    And once that client detaches the script exits successfully

  Scenario: Return without attaching when -d or --detach is given [REQ-8]
    Given a running "pi-main" session with no attached client
    When the script is run with "--detach"
    Then it exits successfully and no client is attached to the session
    And when the script is run with "-d" after the session is removed and recreated by it, it also exits successfully with no client attached

  Scenario: Reject invalid invocation without side effects [REQ-9]
    Given no tmux session named "pi-main" exists on the server
    When the script is run with an unknown option
    Then it fails with an "ERROR:" usage line on standard error
    And no tmux session was created
    When the script is run with an unusable PI_BIN
    Then it fails with an "ERROR:" line on standard error
    And no tmux session was created
