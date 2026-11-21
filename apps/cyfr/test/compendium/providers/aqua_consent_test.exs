# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.AquaConsentTest do
  # The `aqua` tool's write door: every write is a person's own act, so a
  # standing credential is refused at the registry's dispatch gate and is
  # not shown the writes in `tools/list`; the reads stay open to every
  # surface, because a turn resolves its soul through them.
  use ExUnit.Case, async: false

  alias Compendium.Providers.Aqua, as: Tool
  alias Sanctum.Visibility

  @writes ~w(create update delete reset skill_create skill_update skill_delete skill_reset)
  @reads ~w(list get status skill_list skill_get)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations say who may write" do
    actions = Tool.definition().annotations.actions

    for action <- @writes do
      assert actions[action].consent == :interactive, "aqua.#{action} is not interactive"
    end

    for action <- @reads do
      refute Map.has_key?(actions[action], :consent), "aqua.#{action} declares a consent class"
    end
  end

  test "a standing credential cannot write the soul, a role or a scroll", %{ctx: ctx} do
    # A `*` admin key holds every permission and is still refused: the
    # consent class admits a surface, never a permission atom.
    star = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}

    calls = [
      {"skill_create", %{"name" => "sneak", "description" => "d", "content" => "c"}},
      {"skill_update", %{"name" => "capability-acquisition", "content" => "c"}},
      {"reset", %{"all" => true}},
      {"update", %{"name" => "aqua", "content" => "x"}},
      {"create", %{"name" => "sneak", "content" => "x"}},
      {"delete", %{"name" => "aqua"}},
      {"reset", %{"name" => "aqua"}},
      {"skill_delete", %{"name" => "capability-acquisition"}},
      {"skill_reset", %{"name" => "capability-acquisition"}}
    ]

    for {action, args} <- calls do
      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
              }} =
               Sanctum.Gate.call_external("aqua", star, Map.put(args, "action", action)),
             "aqua.#{action} answered a standing credential"
    end

    # The reads stay open to the key — a turn resolves its soul and its
    # scrolls through them.
    assert {:ok, %{skills: _}} =
             Sanctum.Gate.call_external("aqua", star, %{"action" => "skill_list"})

    # Discovery agrees with dispatch: the key is shown the reads alone.
    [aqua] =
      Sanctum.Catalog.list_tools()
      |> Visibility.filter_for_context(star)
      |> Enum.filter(&(&1["name"] == "aqua"))

    shown = get_in(aqua, ["inputSchema", "properties", "action", "enum"])
    assert Enum.sort(shown) == Enum.sort(@reads)
  end

  # Inside a turn's chain the class keeps its surface half: a turn the
  # person's own session started writes a scroll, and one a schedule or a
  # key started is refused before the tool, whatever its member is
  # offered, and writes nothing.
  test "a turn a schedule or a key started cannot write a scroll from its chain" do
    auth = granting(["aqua.skill_create"])
    # The turn's root, as the person's session admitted it; the surface a
    # call is refused on is the one its context names.
    ctx = Sanctum.TestContext.local(:prism)
    lineage = caller!(ctx)

    create = fn ctx, name ->
      Sanctum.Gate.call_in_chain(
        "aqua",
        Sanctum.Context.enter_guest(ctx),
        %{"action" => "skill_create", "name" => name, "description" => "d", "content" => "c"},
        auth,
        lineage: lineage
      )
    end

    for method <- [:scheduled, :api_key] do
      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, ^method}}
              }} = create.(%{ctx | auth_method: method}, "by-#{method}")

      assert {:error, {:not_found, "Scroll", _}} =
               Tool.handle(ctx, %{"action" => "skill_get", "name" => "by-#{method}"})
    end

    assert {:ok, _created} = create.(ctx, "by-person")

    assert {:ok, %{name: "by-person"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "by-person"})
  end

  # A chain authority granting exactly `tools`, the shape the consent blob
  # mints from a manifest's `caps.tools`.
  defp granting(tools) do
    node = "formula:local.assistant"

    {:ok, blob} =
      Prima.Authority.Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => tools}}
          }
        }
      })

    {:ok, auth} =
      Prima.Authority.root(
        %{
          profile_id: "prof-scrolls",
          consent_id: "consent-scrolls",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:scrolls"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  # An in-chain call comes from a real execution's attempt, which the host
  # names in its lineage.
  defp caller!(ctx),
    do: ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])
end
