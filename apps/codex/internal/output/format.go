package output

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
)

// JSON prints a value as formatted JSON.
func JSON(v any) {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error formatting JSON: %v\n", err)
		return
	}
	fmt.Println(string(data))
}

// Table prints a list of maps as a formatted table.
func Table(headers []string, rows []map[string]string) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, strings.Join(headers, "\t"))
	fmt.Fprintln(w, strings.Repeat("-\t", len(headers)))

	for _, row := range rows {
		vals := make([]string, len(headers))
		for i, h := range headers {
			vals[i] = row[h]
		}
		fmt.Fprintln(w, strings.Join(vals, "\t"))
	}
	w.Flush()
}

// KeyValue prints a map as key: value pairs, sorted by key.
func KeyValue(data map[string]any) {
	keys := make([]string, 0, len(data))
	for k := range data {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		v := data[k]
		switch val := v.(type) {
		case map[string]any, []any:
			jsonBytes, _ := json.MarshalIndent(val, "                     ", "  ")
			fmt.Printf("%-20s %s\n", k+":", string(jsonBytes))
		default:
			fmt.Printf("%-20s %v\n", k+":", val)
		}
	}
}

// Success prints a success message.
func Success(msg string) {
	fmt.Println(msg)
}

// Debugf writes a diagnostic line to stderr only when CYFR_DEBUG is set. Used to
// make otherwise-silent fallbacks (offline MCP init, config-save failures)
// observable without adding noise to normal runs.
func Debugf(format string, args ...any) {
	if os.Getenv("CYFR_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "[debug] "+format+"\n", args...)
	}
}
