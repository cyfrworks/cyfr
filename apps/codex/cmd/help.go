package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// groupCommandOrder defines the display order of commands within each group.
// Commands not listed here fall back to alphabetical order.
var groupCommandOrder = map[string][]string{
	"server":    {"init", "up", "down", "upgrade", "update"},
	"identity":  {"login", "logout", "whoami", "status"},
	"component": {"search", "list", "inspect", "pull", "register", "setup", "run", "remove", "publish"},
	"security":  {"secret", "policy", "key", "permission"},
	"admin":     {"log", "aqua", "storage", "registry", "context", "call", "notify"},
}

// customUsage renders the help output with commands ordered by workflow
// within each group, rather than Cobra's default alphabetical sorting.
// Only applies custom group rendering to the root command; subcommands
// fall back to a standard layout.
func customUsage(cmd *cobra.Command) error {
	if cmd.HasParent() {
		return defaultSubcommandUsage(cmd)
	}

	out := cmd.OutOrStdout()

	// Usage line
	fmt.Fprintf(out, "Usage:\n  %s [command]\n\n", cmd.UseLine())

	// Collect commands by group
	grouped := map[string][]*cobra.Command{}
	var ungrouped []*cobra.Command
	for _, c := range cmd.Commands() {
		if !c.IsAvailableCommand() && c.Name() != "help" {
			continue
		}
		if c.GroupID != "" {
			grouped[c.GroupID] = append(grouped[c.GroupID], c)
		} else {
			ungrouped = append(ungrouped, c)
		}
	}

	// Print groups in registration order with workflow-ordered commands
	for _, g := range cmd.Groups() {
		cmds := grouped[g.ID]
		if len(cmds) == 0 {
			continue
		}
		ordered := orderCommands(cmds, g.ID)
		fmt.Fprintf(out, "%s\n", g.Title)
		for _, c := range ordered {
			fmt.Fprintf(out, "  %-12s%s\n", c.Name(), c.Short)
		}
		fmt.Fprintln(out)
	}

	// Ungrouped commands under "Additional Commands"
	if len(ungrouped) > 0 {
		fmt.Fprintln(out, "Additional Commands:")
		for _, c := range ungrouped {
			fmt.Fprintf(out, "  %-12s%s\n", c.Name(), c.Short)
		}
		fmt.Fprintln(out)
	}

	// Flags
	fmt.Fprintln(out, "Flags:")
	fmt.Fprint(out, cmd.Flags().FlagUsages())
	fmt.Fprintln(out)
	fmt.Fprintf(out, "Use \"%s [command] --help\" for more information about a command.\n", cmd.CommandPath())

	return nil
}

// defaultSubcommandUsage renders a standard usage layout for subcommands,
// preserving examples and available subcommands.
func defaultSubcommandUsage(cmd *cobra.Command) error {
	out := cmd.OutOrStdout()

	// Usage line
	fmt.Fprintf(out, "Usage:\n  %s\n", cmd.UseLine())
	if cmd.HasAvailableSubCommands() {
		fmt.Fprintf(out, "  %s [command]\n", cmd.CommandPath())
	}

	// Examples
	if cmd.HasExample() {
		fmt.Fprintf(out, "\nExamples:\n%s\n", cmd.Example)
	}

	// Available subcommands
	if cmd.HasAvailableSubCommands() {
		fmt.Fprintln(out, "\nAvailable Commands:")
		for _, c := range cmd.Commands() {
			if c.IsAvailableCommand() || c.Name() == "help" {
				fmt.Fprintf(out, "  %-12s%s\n", c.Name(), c.Short)
			}
		}
	}

	// Local flags
	if cmd.HasAvailableLocalFlags() {
		fmt.Fprintf(out, "\nFlags:\n%s", cmd.LocalFlags().FlagUsages())
	}

	// Inherited flags
	if cmd.HasAvailableInheritedFlags() {
		fmt.Fprintf(out, "\nGlobal Flags:\n%s", cmd.InheritedFlags().FlagUsages())
	}

	if cmd.HasAvailableSubCommands() {
		fmt.Fprintf(out, "\nUse \"%s [command] --help\" for more information about a command.\n", cmd.CommandPath())
	}

	return nil
}

// orderCommands sorts commands according to the predefined order for a group.
// Commands not in the predefined order are appended alphabetically at the end.
func orderCommands(cmds []*cobra.Command, groupID string) []*cobra.Command {
	order, ok := groupCommandOrder[groupID]
	if !ok {
		return cmds
	}

	byName := make(map[string]*cobra.Command, len(cmds))
	for _, c := range cmds {
		byName[c.Name()] = c
	}

	var result []*cobra.Command
	for _, name := range order {
		if c, ok := byName[name]; ok {
			result = append(result, c)
			delete(byName, name)
		}
	}

	// Append any remaining commands not in the predefined order
	for _, c := range cmds {
		if _, remaining := byName[c.Name()]; remaining {
			result = append(result, c)
		}
	}

	return result
}
