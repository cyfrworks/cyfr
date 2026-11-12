# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.ShippedBoundTest do
  @moduledoc """
  One directory request's bound at the value a release compiles.

  The suite compiles a 5 s bound (`config/test.exs`). A release's
  configuration sets none, so `Sanctum.Directory.Client` compiles the
  default its `Application.compile_env/3` names; the proof is in two
  halves: that default, read from the code and absent from the release's
  configuration, is the bound a release abandons an unanswered request at,
  and the client obeys whatever bound it was compiled with
  (`Sanctum.Directory.ClientTest`, "a directory that never answers is
  abandoned at the request's bound", at the suite's bound).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)
  @client "apps/sanctum/lib/sanctum/directory/client.ex"

  # A module attribute's expression as the client's source sets it.
  defp attribute_ast(name) do
    {_ast, found} =
      @root
      |> Path.join(@client)
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:@, _, [{^name, _, [value]}]} = node, nil -> {node, value}
        node, acc -> {node, acc}
      end)

    refute is_nil(found), "#{@client} sets no @#{name}"
    found
  end

  test "a release abandons an unanswered request at 10 s, a third of its operation's 30 s" do
    release = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)
    refute Keyword.has_key?(Keyword.get(release, :sanctum, []), :directory_request_ms)

    assert {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _,
            [:sanctum, :directory_request_ms, request_ms]} = attribute_ast(:request_ms)

    assert request_ms == 10_000

    # Each request is bounded by the lesser of this and what is left of
    # its operation's deadline, so one unanswered request leaves the
    # operation time for two more.
    assert attribute_ast(:operation_ms) == 30_000
    assert div(attribute_ast(:operation_ms), request_ms) == 3
  end
end
