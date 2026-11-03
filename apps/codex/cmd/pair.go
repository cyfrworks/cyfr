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

// The CLI pairs other devices as their approver: a new device shows its
// key's code (and the address that approves it), and cyfr pair opens the
// pairing for exactly that key. Pairing and revoking need a fresh
// confirmation, which they meet through the wait every tool call goes
// through (mcp.Client.Confirm): on a device of the person's, a passkey in
// Prism or a paired screen, or on this command line when it is a paired
// device of theirs itself (cyfr login).

func init() {
	rootCmd.AddCommand(pairCmd)
	pairCmd.AddCommand(pairListCmd)
	pairCmd.AddCommand(pairRevokeCmd)
}

var pairCmd = &cobra.Command{
	Use:     "pair <code>",
	Short:   "Pair a new device",
	GroupID: "security",
	Long: `Pair a new device. The device makes its own key first and shows that key's
code: a command line running cyfr login, which also shows the address that
approves it, or a CYFR screen. A browser is a device of yours through its
passkey and shows no code. Give the code here, with or without its spaces, or
that address, and this prints a pairing link for that device alone. Paste the
link, or its code, into the device before it expires, and it pairs as you in
the athanor in focus. Pairing needs a fresh confirmation on a device of yours:
a passkey in Prism, or here when this command line is one.

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
	// The approve address a command line shows names the digest in its
	// fragment (<home>/devices/add#key=<digest>).
	if _, fragment, ok := strings.Cut(strings.TrimSpace(code), "/devices/add#key="); ok {
		code = fragment
	}
	digest := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, code)
	bytes, err := base64.RawURLEncoding.Strict().DecodeString(digest)
	if err != nil || len(bytes) != 32 || base64.RawURLEncoding.EncodeToString(bytes) != digest {
		return "", errors.New("That is not the code a new device shows. Run cyfr login on the device and give the code it shows.")
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
	Use:   "list",
	Short: "List your devices",
	Long: `List your devices in the athanor in focus, passkeys among them, each with
what holds its key, when it paired and when its certificate expires. A passkey
may sync to your other machines through its provider: revoking it ends it
wherever it synced. Revoking any other device ends that device alone.`,
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
			fmt.Println("No devices. Pair one with 'cyfr pair'.")
			return nil
		}

		rows := make([]map[string]string, 0, len(clients))
		for _, item := range clients {
			client, _ := item.(map[string]any)
			name := str(client["display_name"])
			if current, _ := client["current"].(bool); current {
				name += " (this one)"
			}
			rows = append(rows, map[string]string{
				"DEVICE":              strings.TrimSpace(name),
				"KIND":                holderLabel(client),
				"REVOKING ENDS":       revokeScope(client),
				"PAIRED":              str(client["paired_at"]),
				"CERTIFICATE EXPIRES": str(client["certificate_expires_at"]),
				"CLIENT":              str(client["client_id"]),
			})
		}
		output.Table([]string{"DEVICE", "KIND", "REVOKING ENDS", "PAIRED", "CERTIFICATE EXPIRES", "CLIENT"}, rows)
		return nil
	},
}

// holderLabel is what holds a device's key, as pairing.list answers its
// holder_kind and synced (tests/fixtures/confirmation_assertion.json,
// exchange.devices): a passkey, which may sync where its provider says so,
// a security chip, or a key encrypted on the device's disk.
func holderLabel(client map[string]any) string {
	switch str(client["holder_kind"]) {
	case "platform":
		if synced, _ := client["synced"].(bool); synced {
			return "Passkey, may sync"
		}
		return "Passkey"
	case "chip":
		return "Security chip"
	case "software":
		return "Encrypted key"
	}
	return "Unknown"
}

// revokeScope is what pairing.revoke ends for a device of this holder
// (exchange.devices's pairing.revoke scope): a passkey's credential
// wherever it synced, any other device alone.
func revokeScope(client map[string]any) string {
	if str(client["holder_kind"]) == "platform" {
		return "this passkey, wherever it synced"
	}
	return "this device"
}

var pairRevokeCmd = &cobra.Command{
	Use:     "revoke [client-id]",
	Short:   "Revoke a device",
	Long:    "Revoke one of your devices: a passkey stops working wherever it synced; any other device's certificates stop working and it must pair again. Revoking needs a fresh confirmation, on a device of yours: here when this command line is one, or in Prism. Run without arguments for interactive selection.",
	Example: "  cyfr pair revoke pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		clientID, err := pickTarget(cmd.Context(), args, selector{
			Title:   "Select a device to revoke",
			Confirm: "Revoke device '%s'? A passkey stops working wherever it synced; any other device must pair again to connect.",
			Empty:   "No devices. Pair one with 'cyfr pair'.",
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
			fmt.Printf("Device '%s' revoked.\n", clientID)
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
		if name := str(client["display_name"]); name != "" {
			label = fmt.Sprintf("%s (%s, %s)", name, holderLabel(client), id)
		}
		opts = append(opts, prompt.Option{Label: label, Value: id})
	}
	return opts, nil
}
