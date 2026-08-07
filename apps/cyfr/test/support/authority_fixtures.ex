# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Test.AuthorityFixtures do
  @moduledoc """
  Shared fixtures for the Authority test suite: a small consented graph
  with named needs, an unnamed edge, a privileged onward edge (for
  trampoline tests) and tool/tool-server resources.

  Graph:

      daily-report ─@ingress→ (tools: storage.read, tool server gh)
      daily-report ─|source→ supabase (vault-source, egress, storage tools)
      daily-report ─|dest──→ supabase (vault-dest)
      daily-report ────────→ ta       (invocation-only, unnamed slot)
      supabase ────────────→ http     (privileged onward edge)
  """

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"
  @http "catalyst:local.http"
  @reagent "reagent:local.ta"
  @server_digest "sha256:github-server"

  def formula_ref, do: @formula
  def catalyst_ref, do: @catalyst
  def http_ref, do: @http
  def reagent_ref, do: @reagent
  def server_digest, do: @server_digest

  def limits_map(overrides \\ %{}) do
    Map.merge(
      %{
        "timeout" => "15m",
        "max_memory_bytes" => 67_108_864,
        "max_request_size" => 1_048_576,
        "max_response_size" => 5_242_880,
        "rate_limit" => %{"requests" => 100, "window" => "1m"},
        "max_concurrent_tasks" => 30,
        "batch_timeout" => "5m"
      },
      overrides
    )
  end

  def graph_map do
    %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @formula => %{
          "limits" => limits_map(),
          "edges" => %{
            "@ingress" => %{
              "tools" => ["storage.read"],
              "tool_servers" => [
                %{"server_digest" => @server_digest, "tool_patterns" => ["issues_*", "repo_get"]}
              ]
            },
            "#{@catalyst}|source" => %{
              "vault" => %{
                "entry_id" => "vault-source",
                "binding_digest" => "sha256:bind-source",
                "projection" => %{"fields" => ["url", "anon_key"]}
              },
              "egress" => %{"domains" => ["prod.supabase.co"], "schemes" => ["https"]},
              "tools" => ["storage.read", "storage.write"]
            },
            "#{@catalyst}|dest" => %{
              "vault" => %{
                "entry_id" => "vault-dest",
                "binding_digest" => "sha256:bind-dest",
                "projection" => %{"fields" => ["url", "service_key"]}
              }
            },
            @reagent => %{}
          }
        },
        @catalyst => %{
          "limits" => limits_map(%{"timeout" => "30s"}),
          "edges" => %{
            @http => %{
              "egress" => %{"domains" => ["internal.example"]},
              "tools" => ["execution.run"]
            }
          }
        },
        @http => %{"limits" => limits_map(%{"timeout" => "10s"}), "edges" => %{}},
        @reagent => %{"limits" => limits_map(%{"timeout" => "1m"}), "edges" => %{}}
      }
    }
  end

  def blob! do
    {:ok, blob} = Blob.parse(graph_map())
    blob
  end

  def activation do
    %{
      @formula => "sha256:act-formula",
      @catalyst => "sha256:act-catalyst",
      @http => "sha256:act-http",
      @reagent => "sha256:act-reagent"
    }
  end

  def profile(overrides \\ %{}) do
    Map.merge(
      %{
        profile_id: "prof-1",
        consent_id: "consent-1",
        source_ref: @formula,
        kind: :owner,
        invoke_mode: :open_inert,
        activation: activation()
      },
      overrides
    )
  end

  @doc "Root authority over the fixture graph. Opts pass through to root/3."
  def root!(profile_overrides \\ %{}, opts \\ []) do
    {:ok, auth} = Authority.root(profile(profile_overrides), blob!(), opts)
    auth
  end

  @doc "An invoke target with resolver-supplied fields defaulted."
  def invoke(reference, opts \\ []) do
    {:invoke,
     %{
       reference: reference,
       need: Keyword.get(opts, :need),
       activation_digest: Keyword.get(opts, :activation_digest),
       declared_needs: Keyword.get(opts, :declared_needs, [])
     }}
  end

  @doc "The formula's declared needs in the fixture manifest."
  def formula_needs, do: ["source", "dest"]
end
