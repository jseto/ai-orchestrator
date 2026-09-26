Feature: Weekly conversation and operation log
  Append-only log of orchestrator conversations and operations. One file per
  ISO week, entries kept for 6 months, stored in a gitignored folder inside
  the repository. Logs are written and swept during normal operation; they are
  read only on demand to help resolve an operational issue.

  Scenario: Append an entry to the current week's log [REQ-1]
    Given the conversation log directory exists
    When the script runs "append conversation <message>"
    Then a log file named with the current ISO week is appended in the log directory
    And the last line of that file contains the UTC timestamp, the kind, and the message

  Scenario: Fold embedded newlines so an entry stays on one line [REQ-2]
    Given the conversation log directory exists
    When the script runs "append operation <message containing a newline>"
    Then the weekly log file gains exactly one physical line
    And the newline inside the message is stored as an escaped sequence

  Scenario: Start a new log file when the ISO week changes [REQ-3]
    Given the conversation log directory contains the log file of two weeks ago
    When the script runs "append conversation <message>" in the current week
    Then a new log file named with the current ISO week is created
    And the older week's file is left untouched

  Scenario: Remove log files older than 6 months on every call [REQ-4]
    Given the conversation log directory contains a log file whose week is older than 6 months
    And the conversation log directory contains a log file from a recent week
    When the script runs "append conversation <message>"
    Then the older-than-6-months log file is deleted
    And the recent log file still exists
    And the current week's log file receives the new entry

  Scenario: Create the log directory on demand [REQ-5]
    Given the conversation log directory does not exist
    When the script runs "append conversation <message>"
    Then the log directory is created inside the repository
    And the current week's log file exists in it

  Scenario: Keep the log directory out of git [REQ-6]
    Given the repository .gitignore lists the logs directory
    When git checks whether a log file under logs/conversations is ignored
    Then git reports the log file as ignored

  Scenario: Never emit existing log content [REQ-7]
    Given the log directory contains a log file with known content
    When the script runs any command
    Then the command's stdout and stderr contain none of the stored log content

  Scenario: Never read existing logs during normal operation [REQ-8]
    Given the current week's log file exists but is not readable
    When the script runs "append conversation <message>"
    Then the command succeeds
    And the new entry is appended to the file

  Scenario: Reject invalid usage without writing an entry [REQ-9]
    When the script runs without arguments or with an invalid kind
    Then the command exits with a non-zero status
    And stderr starts with "ERROR:"
    And no log file is created

  Scenario: Document usage and the read-on-demand rule in help [REQ-10]
    When the script runs "--help"
    Then the command exits with a zero status
    And stdout shows the usage line and the command list
    And stdout states that logs are read only to resolve operational issues
