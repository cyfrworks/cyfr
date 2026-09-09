# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EnvExampleSecretsTest do
  @moduledoc """
  Checks that active assignments in `.env.example` contain no values
  matching the credential patterns below.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Value shapes that are credentials wherever they appear.
  @credential_shapes [
    {"Google OAuth client secret", ~r/GOCSPX-[A-Za-z0-9_\-]{20,}/},
    {"Google API key", ~r/AIza[0-9A-Za-z\-_]{35}/},
    {"GitHub token", ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/},
    {"OpenAI-style key", ~r/\bsk-[A-Za-z0-9\-_]{20,}\b/},
    {"AWS access key id", ~r/\bAKIA[0-9A-Z]{16}\b/}
  ]

  test ".env.example carries no credential-shaped value on an assignment line" do
    lines =
      @root
      |> Path.join(".env.example")
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim_leading(line), "#") end)

    offenders =
      for {line, no} <- lines,
          {name, shape} <- @credential_shapes,
          Regex.match?(shape, line),
          do: "  line #{no}: #{name}"

    assert offenders == [],
           "credential-shaped values in .env.example:\n#{Enum.join(offenders, "\n")}"
  end
end
