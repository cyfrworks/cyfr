package main

import (
	"os"

	"github.com/cyfr/codex/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
