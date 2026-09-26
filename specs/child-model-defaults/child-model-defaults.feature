Feature: Model defaults inherited into the child agent settings (prepare_child_agent_dir)
  The isolated agent directory given to a child pi session must carry the
  orchestrator's model defaults (defaultProvider / defaultModel /
  enabledModels) alongside an empty package list. Without those keys, a child
  whose target repo has no project-level .pi/settings.json has no configured
  default and pi falls through to its built-in per-provider fallback map,
  landing on an arbitrary model. Inheritance must be defensive: a missing,
  malformed, or wrong-shaped global settings file — or a missing jq binary —
  must never break child spawning or leave an empty settings.json, and the
  package isolation (packages: []) must hold unconditionally.

  Scenario: Inherit model defaults from the global settings [REQ-1]
    Given a global agent settings file with defaultProvider "anthropic",
      defaultModel "claude-sonnet-4-6", and a non-empty enabledModels list
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json equals the three inherited model keys
      merged with "packages": []

  Scenario: Drop null-valued model keys from the inherited defaults [REQ-2]
    Given a global agent settings file where a model key is present but null
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json contains no key with a null value

  Scenario: Never inherit packages or unrelated keys from the global settings [REQ-3]
    Given a global agent settings file that also declares a non-empty
      "packages" array and an unrelated key
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json has "packages" set to an empty array
    And no key other than the three model keys and "packages" appears in it

  Scenario: Produce a packages-only settings.json when the global settings are missing [REQ-4]
    Given no global agent settings file exists
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json is an object with only "packages": []
    And prepare_child_agent_dir exits successfully

  Scenario: Produce a packages-only settings.json when the global settings are malformed [REQ-5]
    Given a global agent settings file that is not valid JSON
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json is an object with only "packages": []
    And prepare_child_agent_dir exits successfully

  Scenario: Produce a packages-only settings.json when the global settings have the wrong shape [REQ-6]
    Given a global agent settings file that is valid JSON but an array
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json is an object with only "packages": []
    And prepare_child_agent_dir exits successfully

  Scenario: Produce a packages-only settings.json when jq is unavailable [REQ-7]
    Given a global agent settings file with model defaults
    And no jq executable is on PATH
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json is an object with only "packages": []
    And prepare_child_agent_dir exits successfully without printing an error

  Scenario: Keep the touched shell script shellcheck-clean [REQ-8]
    Given shellcheck is available
    When scripts/_sub-common.sh is checked with shellcheck and bash -n
    Then both report no findings
