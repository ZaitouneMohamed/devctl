# ADR-0011: Interactive menu in pure Bash, fzf optional

- Status: Accepted
- Date: 2026-11-05

## Decision
Menu built with Bash (`read -rsn1` arrow keys + numbers, colors). If `fzf` is installed, pickers use it. No whiptail/dialog/gum.
## Consequences
Zero dependencies, testable with bats; plainer look.
