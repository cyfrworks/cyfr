// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

// The CLI pairs other devices and is not one: it holds no device key and
// speaks over its own transport, as every command does. Pairing and
// revoking need a fresh confirmation, which they meet through the wait every
// tool call goes through (mcp.Client.Confirm).

func init() {
	rootCmd.AddCommand(pairCmd)
	pairCmd.AddCommand(pairListCmd)
	pairCmd.AddCommand(pairRevokeCmd)
}

var pairCmd = &cobra.Command{
	Use:     "pair",
	Short:   "Pair a new device",
	GroupID: "security",
	Long: `Show a pairing link for a new device. Open it on that device, in its browser,
before it expires: the device makes its own key and pairs as you in the athanor
in focus. Pairing needs a fresh confirmation, which you give in Prism.

Whoever opens the link first pairs a device that acts as you until you revoke
it, so show it only to the device you mean to pair.`,
	Example: `  cyfr pair
  cyfr pair list
  cyfr pair revoke pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Pairing, ops.PairingBeginArgs{})
		if err != nil {
			return handleToolError(err, "Pairing failed")
		}
		return renderPairingLink(result)
	},
}

// renderPairingLink prints the link pairing.begin answered and its expiry.
// The home builds the link; the CLI only shows it.
func renderPairingLink(result map[string]any) error {
	link, _ := result["invitation_url"].(string)
	if link == "" {
		return errors.New("Pairing failed: the server answered no pairing link.")
	}
	expiresAt, _ := result["expires_at"].(string)
	clientID, _ := result["client_id"].(string)

	if flagJSON {
		output.JSON(map[string]any{
			"invitation_url": link,
			"expires_at":     expiresAt,
			"client_id":      clientID,
		})
		return nil
	}

	fmt.Printf("Open this link on the new device before %s:\n\n  %s\n\n", expiresAt, link)
	fmt.Println("It works once. Whoever opens it first pairs a device that acts as you until you revoke it.")
	if clientID != "" {
		fmt.Printf("The device will pair as %s.\n", clientID)
	}
	return nil
}

var pairListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List paired devices",
	Long:    "List your paired devices in the athanor in focus, with when each paired and when its certificate expires.",
	Example: "  cyfr pair list",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Pairing, ops.PairingListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}

		clients, _ := result["clients"].([]any)
		if len(clients) == 0 {
			fmt.Println("No paired devices. Pair one with 'cyfr pair'.")
			return nil
		}

		rows := make([]map[string]string, 0, len(clients))
		for _, item := range clients {
			client, _ := item.(map[string]any)
			rows = append(rows, map[string]string{
				"CLIENT":              str(client["client_id"]),
				"LABEL":               str(client["label"]),
				"SOURCE":              str(client["source"]),
				"PAIRED":              str(client["paired_at"]),
				"CERTIFICATE EXPIRES": str(client["certificate_expires_at"]),
			})
		}
		output.Table([]string{"CLIENT", "LABEL", "SOURCE", "PAIRED", "CERTIFICATE EXPIRES"}, rows)
		return nil
	},
}

var pairRevokeCmd = &cobra.Command{
	Use:     "revoke [client-id]",
	Short:   "Revoke a paired device",
	Long:    "Revoke one paired device: its certificates stop working and it must pair again. Revoking needs a fresh confirmation, which you give in Prism. Run without arguments for interactive selection.",
	Example: "  cyfr pair revoke pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		clientID, err := pickTarget(cmd.Context(), args, selector{
			Title:   "Select a paired device to revoke",
			Confirm: "Revoke paired device '%s'? It must pair again to connect.",
			Empty:   "No paired devices. Pair one with 'cyfr pair'.",
			Usage:   "Usage: cyfr pair revoke <client-id>",
			Fetch:   pairedClientOptions,
		})
		if err != nil || clientID == "" {
			return err
		}

		result, err := newClient().CallTool(cmd.Context(), ops.Pairing, ops.PairingRevokeArgs{ClientId: clientID})
		if err != nil {
			return handleToolError(err, "Revoke failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Paired device '%s' revoked.\n", clientID)
		}
		return nil
	},
}

// pairedClientOptions lists the paired devices as picker options.
func pairedClientOptions(ctx context.Context) ([]prompt.Option, error) {
	result, err := newClient().CallTool(ctx, ops.Pairing, ops.PairingListArgs{})
	if err != nil {
		return nil, err
	}

	clients, _ := result["clients"].([]any)
	opts := make([]prompt.Option, 0, len(clients))
	for _, item := range clients {
		client, _ := item.(map[string]any)
		id := str(client["client_id"])
		label := id
		if name := str(client["label"]); name != "" {
			label = fmt.Sprintf("%s (%s)", name, id)
		}
		opts = append(opts, prompt.Option{Label: label, Value: id})
	}
	return opts, nil
}
