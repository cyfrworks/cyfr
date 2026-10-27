// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"unicode"

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
	Use:     "pair <code>",
	Short:   "Pair a new device",
	GroupID: "security",
	Long: `Pair a new device. Open this CYFR's /pair page on that device first: it makes
its own key and shows that key's code. Give the code here, with or without its
spaces, and this prints a pairing link for that device alone. Open the link on
the device, in the same browser, before it expires, and it pairs as you in the
athanor in focus. Pairing needs a fresh confirmation, which you give in Prism;
once you hold a passkey or a paired device here, it is given with one of them.

The link pairs only the device whose code you gave: any other device that opens
it is refused. Give a code that begins with - after --.`,
	Example: `  cyfr pair "sv5Q Hby2 ooLr BWLs _JOr jk8g oRiw YWrr CDbE 2Rui E0o"
  cyfr pair -- -Kq3 ...                  (a code that begins with -)
  cyfr pair list
  cyfr pair revoke pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d`,
	Args: cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		digest, err := keyDigestFromCode(strings.Join(args, ""))
		if err != nil {
			return err
		}
		result, err := newClient().CallTool(cmd.Context(), ops.Pairing, ops.PairingBeginArgs{KeyDigest: digest})
		if err != nil {
			return handleToolError(err, "Pairing failed")
		}
		return renderPairingLink(result, digest)
	},
}

// keyDigestFromCode reads the code the new device shows, typed with or
// without the spaces between its groups: the digest of its key, unpadded
// base64url of 32 bytes (Prima.Device.key_digest/1).
func keyDigestFromCode(code string) (string, error) {
	digest := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, code)
	bytes, err := base64.RawURLEncoding.Strict().DecodeString(digest)
	if err != nil || len(bytes) != 32 || base64.RawURLEncoding.EncodeToString(bytes) != digest {
		return "", errors.New("That is not the code a new device shows. Open this CYFR's /pair page on the device and give the code it shows.")
	}
	return digest, nil
}

// keyCode spells a key digest as a person reads it: groups of four,
// separated by single spaces (Prima.Device.key_code/1).
func keyCode(digest string) string {
	var groups []string
	for len(digest) > 4 {
		groups = append(groups, digest[:4])
		digest = digest[4:]
	}
	return strings.Join(append(groups, digest), " ")
}

// renderPairingLink prints the link pairing.begin answered, the code of the
// device it is for and its expiry. The home builds the link; the CLI only
// shows it.
func renderPairingLink(result map[string]any, digest string) error {
	link, _ := result["invitation_url"].(string)
	if link == "" {
		return errors.New("Pairing failed: the server answered no pairing link.")
	}
	expiresAt, _ := result["expires_at"].(string)
	clientID, _ := result["client_id"].(string)

	if answered, _ := result["key_digest"].(string); answered != digest {
		return errors.New("Pairing failed: the server answered a link for another device's code.")
	}

	if flagJSON {
		output.JSON(map[string]any{
			"invitation_url": link,
			"expires_at":     expiresAt,
			"client_id":      clientID,
			"key_digest":     digest,
		})
		return nil
	}

	fmt.Printf("Open this link on the device showing %s before %s:\n\n  %s\n\n", keyCode(digest), expiresAt, link)
	fmt.Println("It works once, and only for that device: it acts as you until you revoke it.")
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
				"SOURCE":              str(client["source"]),
				"PAIRED":              str(client["paired_at"]),
				"CERTIFICATE EXPIRES": str(client["certificate_expires_at"]),
			})
		}
		output.Table([]string{"CLIENT", "SOURCE", "PAIRED", "CERTIFICATE EXPIRES"}, rows)
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
		opts = append(opts, prompt.Option{Label: id, Value: id})
	}
	return opts, nil
}
