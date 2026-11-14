// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/ref"

	"github.com/spf13/cobra"
)

// joinTypeShorthand checks if the first CLI arg is a known type shorthand
// (c, r, f, catalyst, reagent, formula) and the second arg exists.
// If so, it joins them as "type:ref" and returns a modified args slice.
// This enables: "cyfr run c local.claude:0.1.0" → "cyfr run c:local.claude:0.1.0"
func joinTypeShorthand(args []string) []string {
	if len(args) >= 2 && ref.IsTypePrefix(args[0]) {
		joined := args[0] + ":" + args[1]
		return append([]string{joined}, args[2:]...)
	}
	return args
}

// parseReference converts a CLI reference string into the canonical
// string format expected by the runtime's executor.
//
// The CLI does minimal input normalization only — full parsing and validation
// is handled server-side by Prima.ComponentRef.
//
// Normalizations performed:
//   - --type flag injection when ref has no type prefix
//   - Everything else passes through as-is
//
// Refs containing '@' are passed through unchanged — ref.ParseRef + Validate
// reject them (personal slugs are bare; '@' is invalid anywhere in a ref).
func parseReference(rawRef string, compType string) string {
	// If --type flag given and ref has no type prefix, prepend it
	if compType != "" {
		if colonIdx := strings.Index(rawRef, ":"); colonIdx >= 0 {
			firstPart := rawRef[:colonIdx]
			if !strings.Contains(firstPart, ".") && ref.IsTypePrefix(firstPart) {
				// Already has a type prefix, pass through
				return rawRef
			}
		}
		rawRef = compType + ":" + rawRef
	}

	return rawRef
}

func init() {
	runCmd.Flags().Bool("list", false, "List running executions")
	runCmd.Flags().String("logs", "", "View execution logs")
	runCmd.Flags().String("cancel", "", "Cancel a running execution")
	runCmd.Flags().String("input", "", "JSON input for execution")
	runCmd.Flags().String("type", "", "Component type: catalyst, reagent, or formula")
	runCmd.Flags().String("profile", "", "Profile (id or label) whose consent this runs under")
	rootCmd.AddCommand(runCmd)
}

var runCmd = &cobra.Command{
	Use:     "run [type] [reference]",
	Short:   "Execute a component [interactive]",
	GroupID: "component",
	Args:    cobra.RangeArgs(0, 2),
	Long: `Execute a component by reference. The type can be specified as a prefix
(catalyst:, c:, reagent:, r:, formula:, f:) or as a separate first argument.

Pass --input to supply a JSON object as execution input. Use --list to see
running executions, --logs to read a run's record, and --cancel to abort.
Ctrl-C stops waiting; the run goes on until it ends or is cancelled.

Run without arguments for interactive selection.`,
	Example: `  cyfr run c:local.openai
  cyfr run c:local.openai:0.1.0
  cyfr run c local.openai
  cyfr run catalyst:local.openai
  cyfr run local.openai --type catalyst
  cyfr run cyfr.sentiment:1.0.0
  cyfr run c:local.openai --input '{"text":"hello"}'
  cyfr run --list
  cyfr run --logs exec_abc123
  cyfr run --cancel exec_abc123`,
	RunE: func(cmd *cobra.Command, args []string) error {
		reached := nothingSent
		err := runWork(cmd, args, &reached)
		// One rule for the whole command: Ctrl-C (or the terminal closing)
		// wherever it arrives, at a request or at a question, is the
		// person's interruption, said as it stands where it arrived.
		if err != nil && (cmd.Context().Err() != nil || prompt.IsAborted(err)) {
			return interruption{reached.interrupted()}
		}
		return err
	},
}

// How far cyfr run got: what an interruption there leaves.
type runReached struct {
	run    bool
	cancel string
}

var nothingSent = runReached{}

func (r runReached) interrupted() error {
	switch {
	case r.cancel != "":
		return fmt.Errorf("Interrupted; whether run %s was stopped is not known: cyfr run --logs %s shows it.", r.cancel, r.cancel)
	case r.run:
		return errRunGoesOn
	default:
		return errNothingStarted
	}
}

var errRunGoesOn = errors.New("Stopped waiting. A run CYFR already started goes on: cyfr run --list shows it, and cyfr run --cancel <id> stops it.")

var errNothingStarted = errors.New("Interrupted; nothing was started.")

// runWork is cyfr run's work, noting in reached what it has asked for
// that an interruption leaves standing.
func runWork(cmd *cobra.Command, args []string, reached *runReached) error {
	// The input is read before anything is asked of the server, whatever
	// else the line names, so a malformed one sends nothing.
	var execInput map[string]any
	inputStr, _ := cmd.Flags().GetString("input")
	if inputStr != "" {
		var err error
		if execInput, err = runInput(inputStr); err != nil {
			return err
		}
	}

	client := newClient()

	if listFlag, _ := cmd.Flags().GetBool("list"); listFlag {
		result, err := client.CallTool(cmd.Context(), ops.Execution, ops.ExecutionListArgs{Status: ops.Value("running")})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		rows := runRows(result)
		if len(rows) == 0 {
			fmt.Println("Nothing is running.")
			return nil
		}
		output.Table(runHeaders, rows)
		return nil
	}

	if logsID, _ := cmd.Flags().GetString("logs"); logsID != "" {
		result, err := client.CallTool(cmd.Context(), ops.Execution, ops.ExecutionLogsArgs{ExecutionId: logsID})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	}

	if cancelID, _ := cmd.Flags().GetString("cancel"); cancelID != "" {
		reached.cancel = cancelID
		result, err := client.CallTool(cmd.Context(), ops.Execution, ops.ExecutionCancelArgs{ExecutionId: cancelID})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Execution cancelled.")
		}
		return nil
	}

	// CLI shorthand: "cyfr run c local.claude:0.1.0" → join as "c:local.claude:0.1.0"
	args = joinTypeShorthand(args)
	compType, _ := cmd.Flags().GetString("type")
	refString, err := pickTarget(cmd.Context(), args, selector{
		Title: "Select a component to run",
		Empty: "No components found. Register one first.",
		Usage: "Usage: cyfr run <reference>",
		Fetch: func(ctx context.Context) ([]prompt.Option, error) {
			return prompt.FetchComponents(ctx, client)
		},
		Normalize: func(ctx context.Context, arg string) (string, error) {
			// Inject --type, then resolve a missing version for
			// registry refs.
			withType := parseReference(arg, compType)
			return resolveComponentRef(ctx, client, withType)
		},
	})
	if err != nil {
		return err
	}

	if len(args) == 0 && inputStr == "" {
		// The ref came from the picker — offer to collect input the
		// same way.
		supplyInput, err := prompt.Confirm(cmd.Context(), "Supply JSON input?")
		if err != nil {
			return fmt.Errorf("Prompt failed: %w", err)
		}
		if supplyInput {
			typed, err := prompt.InputText(cmd.Context(), "JSON input", `{"key":"value"}`)
			if err != nil {
				return fmt.Errorf("Prompt failed: %w", err)
			}
			if typed != "" {
				if execInput, err = runInput(typed); err != nil {
					return err
				}
			}
		}
	}

	toolArgs := ops.ExecutionRunArgs{Reference: refString}
	if execInput != nil {
		toolArgs.Input = ops.Value(execInput)
	}
	// Which profile's consent this runs under. With several profiles
	// and no selector the server refuses rather than guessing.
	if profile, _ := cmd.Flags().GetString("profile"); profile != "" {
		toolArgs.Profile = ops.Value(profile)
	}

	// Ctrl-C from here ends the wait, not the run: a run the server
	// already started goes on there.
	reached.run = true
	result, err := client.CallTool(cmd.Context(), ops.Execution, toolArgs)
	if err != nil {
		return handleToolError(err)
	}
	return renderResult(result)
}

// runHeaders are the columns of `cyfr run --list`.
var runHeaders = []string{"execution_id", "reference", "status", "started_at"}

// runRows are the listed executions as table rows.
func runRows(result map[string]any) []map[string]string {
	listed, _ := result["executions"].([]any)
	rows := make([]map[string]string, 0, len(listed))
	for _, item := range listed {
		run, _ := item.(map[string]any)
		row := map[string]string{}
		for _, h := range runHeaders {
			if v, ok := run[h].(string); ok {
				row[h] = v
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// runInput is a run's --input: a JSON object, the one shape a run's input
// takes.
func runInput(text string) (map[string]any, error) {
	var value any
	if err := json.Unmarshal([]byte(text), &value); err != nil {
		return nil, fmt.Errorf("Invalid JSON input: %w", err)
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New(`The input must be a JSON object, such as '{"text":"hello"}'.`)
	}
	return object, nil
}
