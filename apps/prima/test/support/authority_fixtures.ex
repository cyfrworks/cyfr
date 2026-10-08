# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Prima.Test.AuthorityFixtures do
  @moduledoc """
  Shared fixtures for the Authority test suite: a small consented graph
  with named needs, an unnamed edge, a privileged onward edge (for
  trampoline tests) and tool/tool-server resources.

  Graph:

      daily-report ─@ingress→ (tools: storage.read, tool server gh)
      daily-report ─|source→ supabase (vault-source, attached, egress, storage tools)
      daily-report ─|dest──→ supabase (vault-dest, disclose-only)
      daily-report ────────→ ta       (invocation-only, unnamed slot)
      supabase ────────────→ http     (privileged onward edge)
  """

  alias Prima.Authority
  alias Prima.Authority.Blob

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"
  @http "catalyst:local.http"
  @reagent "reagent:local.ta"
  @server_digest "sha256:github-server"

  def formula_ref, do: @formula
  def catalyst_ref, do: @catalyst
  def server_digest, do: @server_digest

  @doc "A destination's wire map: `hosts`, over https."
  def destination_map(hosts \\ ["prod.supabase.co"]), do: %{"hosts" => hosts, "scheme" => "https"}

  @doc "An attach rule's wire map: the bearer header."
  def attach_map,
    do: %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}

  @doc """
  A bound vault resource's wire map, sitting on `edge_key` of `node_ref`:
  an athanor entry with its binding key for that place, the default slot
  unless `:name` names an account. Options: `:name`, `:scope`,
  `:destination`, `:attach` (absent: disclose-only), `:projection`,
  `:lender`, `:named`.
  """
  def bound_vault(node_ref, edge_key, entry_id, digest, opts \\ []) do
    %{
      "entry_id" => entry_id,
      "binding_digest" => digest,
      "scope" => Keyword.get(opts, :scope, "athanor"),
      "binding_key" => Blob.binding_key(node_ref, edge_key, Keyword.get(opts, :name)),
      "destination" => Keyword.get(opts, :destination, destination_map())
    }
    |> put_present("attach", Keyword.get(opts, :attach))
    |> put_present("projection", Keyword.get(opts, :projection))
    |> put_present("lender", Keyword.get(opts, :lender))
    |> put_present("named", Keyword.get(opts, :named))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
                %{
                  "server_digest" => @server_digest,
                  "server_name" => "github",
                  "tool_patterns" => ["issues.*", "repo_get"]
                }
              ]
            },
            "#{@catalyst}|source" => %{
              "vault" =>
                bound_vault(@formula, "#{@catalyst}|source", "vault-source", "sha256:bind-source",
                  attach: attach_map(),
                  projection: %{"fields" => ["url", "anon_key"]}
                ),
              "egress" => %{"domains" => ["prod.supabase.co"], "schemes" => ["https"]},
              "tools" => ["storage.read", "storage.write"]
            },
            "#{@catalyst}|dest" => %{
              "vault" =>
                bound_vault(@formula, "#{@catalyst}|dest", "vault-dest", "sha256:bind-dest",
                  projection: %{"fields" => ["url", "service_key"]}
                )
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

  @doc "The compiled platform ceiling, with no operator override lowering it."
  def ceiling, do: Prima.Limits.Ceiling.lowered(%{})

  @doc """
  Root authority over the fixture graph. Opts pass through to root/3, with
  `:ceiling` defaulting to `ceiling/0`.
  """
  def root!(profile_overrides \\ %{}, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :ceiling, &ceiling/0)
    {:ok, auth} = Authority.root(profile(profile_overrides), blob!(), opts)
    auth
  end

  @doc """
  An invoke target with resolver-supplied fields defaulted, naming the
  account `:connection` when given.
  """
  def invoke(reference, opts \\ []) do
    target = %{
      reference: reference,
      need: Keyword.get(opts, :need),
      activation_digest: Keyword.get(opts, :activation_digest),
      declared_needs: Keyword.get(opts, :declared_needs, [])
    }

    case Keyword.fetch(opts, :connection) do
      {:ok, connection} -> {:invoke, Map.put(target, :connection, connection)}
      :error -> {:invoke, target}
    end
  end

  @doc "The formula's declared needs in the fixture manifest."
  def formula_needs, do: ["source", "dest"]
end
