# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.Test.EdgeFixtures do
  @moduledoc """
  Builders for `%Sanctum.Authority.Blob.Edge{}` and `%Sanctum.Limits{}`
  fixtures in handler unit tests.

  Defaults mirror the catalyst type defaults, with schemes explicitly
  `["https", "http"]` — edges always carry explicit schemes, and handler
  tests that are not about scheme enforcement should pass both.
  """

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Limits

  @spec edge(keyword()) :: Edge.t()
  def edge(opts \\ []) do
    %Edge{
      egress: %{
        domains: Keyword.get(opts, :domains, []),
        methods: Keyword.get(opts, :methods, []),
        schemes: Keyword.get(opts, :schemes, ["https", "http"]),
        private_ips: Keyword.get(opts, :private_ips, [])
      },
      storage: %{
        paths: Keyword.get(opts, :paths, []),
        actions: Keyword.get(opts, :actions, [])
      },
      tools: Keyword.get(opts, :tools, [])
    }
  end

  @spec limits(keyword()) :: Limits.t()
  def limits(opts \\ []) do
    %Limits{
      timeout: Keyword.get(opts, :timeout, "30s"),
      max_memory_bytes: Keyword.get(opts, :max_memory_bytes, 64 * 1024 * 1024),
      max_request_size: Keyword.get(opts, :max_request_size, 1_048_576),
      max_response_size: Keyword.get(opts, :max_response_size, 5_242_880),
      rate_limit: Keyword.get(opts, :rate_limit, %{requests: 100, window: "1m"}),
      max_concurrent_tasks: Keyword.get(opts, :max_concurrent_tasks, 10),
      batch_timeout: Keyword.get(opts, :batch_timeout, "5m")
    }
  end
end
