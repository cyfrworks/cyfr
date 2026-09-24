# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EnvExampleSecretsTest do
  @moduledoc """
  Checks that active assignments in every tracked env example
  (`.env.example` and each service's `.env.*.example`) contain no values
  matching the credential patterns below. A key the stack needs — the
  worker root, the bridge key, the builds key, a service key — is left
  empty for `cyfr init` or the operator to generate, never shipped.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Value shapes that are credentials wherever they appear.
  @credential_shapes [
    {"Google OAuth client secret", ~r/GOCSPX-[A-Za-z0-9_\-]{20,}/},
    {"Google API key", ~r/AIza[0-9A-Za-z\-_]{35}/},
    {"GitHub token", ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/},
    {"OpenAI-style key", ~r/\bsk-[A-Za-z0-9\-_]{20,}\b/},
    {"AWS access key id", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"32-byte key as hexadecimal", ~r/=\s*"?[0-9A-Fa-f]{64}\b/}
  ]

  defp examples do
    files = Path.wildcard(Path.join(@root, ".env*.example"), match_dot: true)

    assert Path.join(@root, ".env.example") in files and length(files) >= 4,
           "the scan found only #{inspect(Enum.map(files, &Path.basename/1))}"

    files
  end

  test "no env example carries a credential-shaped value on an assignment line" do
    offenders =
      for path <- examples(),
          {line, no} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          {name, shape} <- @credential_shapes,
          Regex.match?(shape, line),
          do: "  #{Path.basename(path)} line #{no}: #{name}"

    assert offenders == [],
           "credential-shaped values in the env examples:\n#{Enum.join(offenders, "\n")}"
  end

  # The keys are generated per deployment: shipped with a value, every
  # deployment that copied the example would share it.
  test "every key the stack needs is shipped empty" do
    for key <- ~w(CYFR_OPUS_KEY CYFR_MCP_BRIDGE_KEY OPUS_SERVICE_KEY CYFR_LOCUS_BUILDS_KEY) do
      text = File.read!(Path.join(@root, ".env.example"))
      assert text =~ ~r/^(# )?#{key}=$/m, ".env.example must ship #{key} empty"
    end
  end
end
