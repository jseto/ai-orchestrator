Feature: Launch pi in a durable local tmux session

  Scenario: Create the named session in the repository with forwarded arguments [REQ-1]
    Given no local pi tmux session exists
    When the user runs pi.sh with extra pi arguments
    Then pi.sh creates a detached session in the repository root
    And forwards the extra arguments to pi

  Scenario: Reuse an existing local session [REQ-2]
    Given the local pi tmux session already exists
    When the user runs pi.sh
    Then pi.sh does not start another pi process
    And attaches or switches to the existing session

  Scenario: Choose an in-tmux handoff [REQ-3]
    Given the user is already inside tmux
    When the user runs pi.sh
    Then pi.sh switches the current client to the local session

  Scenario: Reject reserved session names [REQ-4]
    Given PI_TMUX_SESSION names pi-main or a pi task session
    When the user runs pi.sh
    Then pi.sh exits with an error before creating a session
