# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InstanceEntriesTest do
  @moduledoc """
  The instance's own credentials (`Sanctum.InstanceEntries`): the
  administrator's verbs and the confirmations each needs, the
  compare-and-sets a widening is written by, the attach path's read in
  its order, the caps it claims under, and what each change announces.
  """

  # The component-facts port and the platform settings are node-wide, and
  # one case attaches to the confirmation's own announcement.
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.Test.QueryCounter
  alias Sanctum.Consent.Components
  alias Sanctum.Context
  alias Sanctum.InstanceEntries
  alias Sanctum.TestContext

  defmodule Facts do
    @moduledoc """
    A component-facts port the cases write: the registry rows a node
    reference names, and the release digest the install media ships for
    each, by node key.
    """
    @behaviour Sanctum.Consent.Components

    @rows {__MODULE__, :rows}
    @shipped {__MODULE__, :shipped}

    def put(rows, shipped) do
      :persistent_term.put(@rows, rows)
      :persistent_term.put(@shipped, shipped)
    end

    def clear do
      :persistent_term.erase(@rows)
      :persistent_term.erase(@shipped)
    end

    @impl true
    def resolve(_ctx, _component), do: {:error, :not_found}

    @impl true
    def resolve_verified(_ctx, _component), do: {:error, :not_found}

    @impl true
    def get_component(_ctx, name, version, publisher, type) do
      case Map.fetch(:persistent_term.get(@rows, %{}), {type, publisher, name, version}) do
        {:ok, row} -> {:ok, row}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def agent_rows(_ctx), do: {:ok, []}

    @impl true
    def shipped_nodes(_ctx, rows) do
      shipped = :persistent_term.get(@shipped, %{})

      answered =
        for row <- rows,
            key = Prima.ComponentRow.node_key(row),
            Map.has_key?(shipped, key),
            into: %{},
            do: {key, Map.fetch!(shipped, key)}

      {:ok, answered}
    end
  end

  # An inference-only account: chat completions and the model list, and
  # nothing else of the provider's API.
  @inference %{
    "hosts" => ["api.openai.com"],
    "methods" => ["GET", "POST"],
    "paths" => ["/v1/chat/completions", "/v1/models"]
  }

  @secret "sk-instance-material"

  @events for kind <- ~w(created rotated rebound audience policy caps revoked deleted)a,
              do: [:cyfr, :sanctum, :instance_entry, kind]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    previous =
      try do
        Components.impl!()
      rescue
        Components.NotInstalledError -> nil
      end

    Components.install!(Facts)

    on_exit(fn ->
      Facts.clear()
      if previous, do: Components.install!(previous), else: Components.reset()
    end)

    test = self()
    handler = "instance-entries-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      @events,
      fn event, _measurements, metadata, _config ->
        send(test, {:instance_entry, List.last(event), metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {admin, _user} = TestContext.person!(%{TestContext.local() | platform_admin: true})
    {:ok, admin: admin}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp params(over \\ %{}) do
    Map.merge(
      %{
        name: "shared-openai-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "openai.com",
        fields: %{"API_KEY" => @secret},
        destination: @inference,
        audience: "everyone"
      },
      over
    )
  end

  defp create!(admin, over \\ %{}) do
    params = params(over)

    ctx =
      TestContext.confirmed(admin, :credential_entry, %{
        operation: "instance_entry.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = InstanceEntries.create(ctx, params)
    assert_received {:instance_entry, :created, %{entry_id: id}}
    assert id == entry.id
    entry
  end

  # A proof of the widening `arguments` name, with the preview the deciding
  # site shows for it: what the change widens, never a secret.
  defp sharing(admin, operation, arguments, entry, details) do
    TestContext.confirmed(admin, :credential_sharing, %{
      operation: operation,
      arguments: arguments,
      resource: entry.name,
      details: details
    })
  end

  @policy_widening %{"component_policy" => "shipped → any"}

  # A person signed in at this home, named by their own id: the same
  # person for the same name throughout a case.
  defp person(name) do
    {ctx, _user} =
      TestContext.person!(
        Context.build(
          user_id: "local|local|ie-" <> name,
          provider: "local",
          namespace: name,
          athanor_id: TestContext.athanor_id(),
          permissions: Context.person_permissions(),
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    ctx
  end

  defp id(name), do: person(name).user_id

  # The person denied on this server, through the transition a door's deny
  # runs: every list they were on is left in the same transaction.
  defp deny!(user_id) do
    {:ok, _change} =
      Arca.SecurityTransitions.deny_user(Prima.Actor.system(), user_id,
        verify: fn _rows -> :ok end
      )

    :ok
  end

  defp request(path, method \\ "POST"),
    do: %{uri: URI.parse("https://api.openai.com" <> path), method: method}

  @custom %{node_ref: "catalyst:local.my-chat:1.0.0", activation_digest: "sha256:custom"}
  @shipped %{node_ref: "catalyst:local.openai:1.4.0", activation_digest: "sha256:seed-openai"}

  # The custom node a person wrote, the shipped catalyst as the install
  # media ships it, and the facts the port answers for each.
  defp facts! do
    custom = %{component_type: "catalyst", publisher: "local", name: "my-chat", version: "1.0.0"}
    shipped = %{component_type: "catalyst", publisher: "local", name: "openai", version: "1.4.0"}

    Facts.put(
      %{
        {"catalyst", "local", "my-chat", "1.0.0"} => custom,
        {"catalyst", "local", "openai", "1.4.0"} => shipped
      },
      %{"catalyst:local.openai" => "sha256:seed-openai"}
    )
  end

  defp usage(entry_id) do
    {:ok, %{totals: totals, people: people}} =
      Arca.InstanceEntryUsage.usage(Prima.Actor.system(), entry_id, 1)

    {Enum.sum(Enum.map(totals, & &1.count)), people}
  end

  defp stored(entry_id) do
    {:ok, entry} = Arca.InstanceEntries.get(Prima.Actor.system(), entry_id)
    entry
  end

  defp tomorrow_midnight do
    today = DateTime.to_date(Arca.ServerMetaStorage.now!())
    DateTime.new!(Date.add(today, 1), ~T[00:00:00.000000], "Etc/UTC")
  end

  # A profile in `athanor` whose head consent binds the instance entry.
  defp dependent!(athanor, entry) do
    profile = "prof_dep_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Arca.ProfileStorage.put(%{
        id: profile,
        athanor_id: athanor,
        source_ref: "catalyst:local.#{profile}",
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: athanor,
          profile_id: profile,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary("{}"),
          resolved_policy: "{}",
          activation: "{}",
          admitted_origins: [:interactive],
          granted_by: "test",
          granted_via: "interactive"
        },
        [
          %{
            binding_key: "catalyst:local.#{profile}|@ingress|default",
            scope: "instance",
            instance_entry_id: entry.id,
            binding_digest: entry.binding_digest
          }
        ],
        nil
      )

    profile
  end

  defp profile_status(athanor, profile) do
    {:ok, row} = Arca.ProfileStorage.get(Prima.Actor.in_athanor(athanor), profile)
    row.status
  end

  # ---------------------------------------------------------------------------
  # The evidence cases
  # ---------------------------------------------------------------------------

  test "the fourth claim is refused with its database reset", %{admin: admin} do
    entry = create!(admin, %{person_daily: 3})
    alice = person("alice")

    for n <- 1..3 do
      assert {:ok, %{id: id}, %{"fields" => %{"API_KEY" => @secret}}} =
               InstanceEntries.resolve(alice, entry.id, request("/v1/chat/completions"), @custom)

      assert id == entry.id
      assert {^n, _people} = usage(entry.id)
    end

    reset = tomorrow_midnight()

    assert {:error, {:connection_cap, ^reset}} =
             InstanceEntries.resolve(alice, entry.id, request("/v1/chat/completions"), @custom)

    # The refused request counted nothing; another person's day is their own.
    alice_id = alice.user_id
    assert {3, [%{user_id: ^alice_id, count: 3}]} = usage(entry.id)

    assert {:ok, _view, _payload} =
             InstanceEntries.resolve(
               person("bob"),
               entry.id,
               request("/v1/models", "GET"),
               @custom
             )
  end

  test "any and shipped enforce the stored component policy at each resolution",
       %{admin: admin} do
    facts!()
    entry = create!(admin)
    alice = person("alice")
    chat = request("/v1/chat/completions")
    modified = %{@shipped | activation_digest: "sha256:edited-copy"}

    # `any` imposes no provenance: a consented custom node and a modified
    # shipped copy are admitted within the destination.
    assert entry.component_policy == "any"
    assert {:ok, _, _} = InstanceEntries.resolve(alice, entry.id, chat, @custom)
    assert {:ok, _, _} = InstanceEntries.resolve(alice, entry.id, chat, modified)
    assert {2, _} = usage(entry.id)

    # Tightening needs the session alone, and the next resolution reads it.
    assert {:ok, :changed} =
             InstanceEntries.set_component_policy(admin, %{
               entry_id: entry.id,
               component_policy: "shipped"
             })

    for refused <- [
          @custom,
          modified,
          # Facts the port cannot answer, and facts not given at all.
          %{@shipped | node_ref: "catalyst:local.openai:9.9.9"},
          %{@shipped | node_ref: "not a reference"},
          %{@shipped | activation_digest: ""},
          %{},
          nil
        ] do
      assert {:error, :component_not_admitted} =
               InstanceEntries.resolve(alice, entry.id, chat, refused),
             inspect(refused)
    end

    # None of those took a claim.
    assert {2, _} = usage(entry.id)

    # The pristine shipped node is admitted.
    assert {:ok, _, _} = InstanceEntries.resolve(alice, entry.id, chat, @shipped)
    assert {3, _} = usage(entry.id)

    # With the port uninstalled the facts are unreadable: refused, no claim.
    Components.reset()

    assert {:error, :component_not_admitted} =
             InstanceEntries.resolve(alice, entry.id, chat, @shipped)

    Components.install!(Facts)
    assert {3, _} = usage(entry.id)

    # Widening back to `any` asks the confirmation; once given, the custom
    # node is admitted again at its next resolution.
    widening = %{entry_id: entry.id, component_policy: "any"}

    assert {:error, {:confirmation_required, %{operation: "instance_entry.set_component_policy"}}} =
             InstanceEntries.set_component_policy(admin, widening)

    assert {:error, :component_not_admitted} =
             InstanceEntries.resolve(alice, entry.id, chat, @custom)

    confirmed =
      sharing(admin, "instance_entry.set_component_policy", widening, entry, @policy_widening)

    assert {:ok, :changed} = InstanceEntries.set_component_policy(confirmed, widening)
    assert {:ok, _, _} = InstanceEntries.resolve(alice, entry.id, chat, @custom)

    # A stored policy that is neither word admits nothing.
    refute InstanceEntries.admits?(alice, %{component_policy: "custom"}, @shipped)
    refute InstanceEntries.admits?(alice, %{component_policy: nil}, @shipped)
  end

  test "widening a component policy requires confirmation and rejects a stale write",
       %{admin: admin} do
    entry = create!(admin, %{component_policy: "shipped"})
    widening = %{entry_id: entry.id, component_policy: "any"}

    # No proof: the confirmation is asked and nothing is written.
    assert {:error, {:confirmation_required, %{operation: "instance_entry.set_component_policy"}}} =
             InstanceEntries.set_component_policy(admin, widening)

    assert stored(entry.id).component_policy == "shipped"
    refute_received {:instance_entry, :policy, _}

    # A proof for another entry, or for another setting, is no proof of
    # this change.
    other = create!(admin, %{component_policy: "shipped"})

    for elsewhere <- [
          sharing(
            admin,
            "instance_entry.set_component_policy",
            %{widening | entry_id: other.id},
            other,
            @policy_widening
          ),
          sharing(
            admin,
            "instance_entry.set_audience",
            %{entry_id: entry.id, audience: "everyone", members: []},
            entry,
            %{"audience" => "everyone"}
          )
        ] do
      assert {:error, {:confirmation_required, _}} =
               InstanceEntries.set_component_policy(elsewhere, widening)
    end

    assert stored(entry.id).component_policy == "shipped"

    # A stale write: between the read the widening was decided against and
    # its write, the stored policy moves. The write is refused, nothing of
    # this request lands, and it is not retried.
    race_id = "instance-entries-race-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      race_id,
      [:cyfr, :sanctum, :confirmation, :consumed],
      fn _event, _measurements, %{operation: "instance_entry.set_component_policy"}, id ->
        :ok =
          Arca.InstanceEntries.set_component_policy(Prima.Actor.system(), id, "shipped", "any")
      end,
      entry.id
    )

    confirmed =
      sharing(admin, "instance_entry.set_component_policy", widening, entry, @policy_widening)

    try do
      assert {:error, :conflict} = InstanceEntries.set_component_policy(confirmed, widening)
    after
      :telemetry.detach(race_id)
    end

    refute_received {:instance_entry, :policy, _}

    # The confirmation was consumed by the refused write: repeating the
    # request reads the policy again and decides afresh, here unchanged.
    assert {:ok, :unchanged} = InstanceEntries.set_component_policy(confirmed, widening)
    refute_received {:instance_entry, :policy, _}

    # The narrowing needs the session alone; with a proof the widening lands.
    assert {:ok, :changed} =
             InstanceEntries.set_component_policy(admin, %{widening | component_policy: "shipped"})

    assert_received {:instance_entry, :policy, %{entry_id: id}}
    assert id == entry.id

    confirmed =
      sharing(admin, "instance_entry.set_component_policy", widening, entry, @policy_widening)

    assert {:ok, :changed} = InstanceEntries.set_component_policy(confirmed, widening)
    assert stored(entry.id).component_policy == "any"

    # Null, empty, unknown and collection-valued input is refused, and a
    # mutation names its entry and its policy.
    for bad <- [nil, "", "custom", "ANY", ["any"], %{"any" => true}, :any] do
      assert {:error, :invalid_component_policy} =
               InstanceEntries.set_component_policy(admin, %{
                 entry_id: entry.id,
                 component_policy: bad
               })
    end

    assert {:error, :invalid_component_policy} =
             InstanceEntries.set_component_policy(admin, %{entry_id: entry.id})

    assert {:error, :entry_required} =
             InstanceEntries.set_component_policy(admin, %{component_policy: "any"})
  end

  # ---------------------------------------------------------------------------
  # Who may administer, and what each change confirms
  # ---------------------------------------------------------------------------

  describe "the administrator's verbs" do
    test "a member calling any of them is refused, before anything is read", %{admin: admin} do
      entry = create!(admin)
      member = %{admin | platform_admin: false}

      QueryCounter.assert_queries(0, fn ->
        for refused <- [
              InstanceEntries.list(member),
              InstanceEntries.usage(member, entry.id, 1),
              InstanceEntries.create(member, params()),
              InstanceEntries.rotate(member, %{
                entry_id: entry.id,
                fields: %{"API_KEY" => "x"},
                expected_payload_rev: 0
              }),
              InstanceEntries.rebind(member, %{entry_id: entry.id, destination: @inference}),
              InstanceEntries.set_audience(member, %{entry_id: entry.id, audience: "listed"}),
              InstanceEntries.set_component_policy(member, %{
                entry_id: entry.id,
                component_policy: "shipped"
              }),
              InstanceEntries.set_caps(member, %{entry_id: entry.id, person_daily: 1}),
              InstanceEntries.revoke(member, entry.id),
              InstanceEntries.delete(member, entry.id)
            ] do
          assert refused == {:error, :platform_admin_required}
        end
      end)

      # A key, which is no interactive session, is refused its consent class.
      key = %{admin | auth_method: :api_key}
      assert {:error, {:surface_not_permitted, :api_key}} = InstanceEntries.list(key)

      assert {:ok, %{status: "active"}} = Arca.InstanceEntries.get(Prima.Actor.system(), entry.id)
    end

    test "create and rotate each need a proof of credential_entry", %{admin: admin} do
      params = params()

      assert {:error, {:confirmation_required, %{operation: "instance_entry.create"}}} =
               InstanceEntries.create(admin, params)

      assert {:ok, []} = Arca.InstanceEntries.list(Prima.Actor.system())
      refute_received {:instance_entry, :created, _}

      entry = create!(admin)

      rotation = %{
        entry_id: entry.id,
        fields: %{"API_KEY" => "sk-rotated"},
        expected_payload_rev: 0
      }

      assert {:error, {:confirmation_required, %{operation: "instance_entry.rotate"}}} =
               InstanceEntries.rotate(admin, rotation)

      confirmed =
        TestContext.confirmed(admin, :credential_entry, %{
          operation: "instance_entry.rotate",
          arguments: rotation,
          resource: entry.name
        })

      assert {:ok, 1} = InstanceEntries.rotate(confirmed, rotation)
      assert_received {:instance_entry, :rotated, %{entry_id: id}}
      assert id == entry.id

      assert {:ok, _, %{"fields" => %{"API_KEY" => "sk-rotated"}}} =
               InstanceEntries.resolve(
                 person("alice"),
                 entry.id,
                 request("/v1/models", "GET"),
                 @custom
               )

      # A rotation keeps the field schema; changing it is refused before a
      # confirmation is asked (against the revision the entry now holds).
      assert {:error, :schema_change_requires_rebind} =
               InstanceEntries.rotate(admin, %{
                 rotation
                 | fields: %{"OTHER" => "x"},
                   expected_payload_rev: 1
               })
    end

    test "a create's arguments are each held to their rule before a confirmation is asked",
         %{admin: admin} do
      # Omitting the policy stores `any`; either word is stored as given.
      assert create!(admin).component_policy == "any"
      assert create!(admin, %{component_policy: "shipped"}).component_policy == "shipped"
      assert create!(admin, %{component_policy: "any"}).component_policy == "any"

      refused = [
        {%{component_policy: nil}, :invalid_component_policy},
        {%{component_policy: ""}, :invalid_component_policy},
        {%{component_policy: "custom"}, :invalid_component_policy},
        {%{component_policy: ["any"]}, :invalid_component_policy},
        {%{component_policy: %{"any" => true}}, :invalid_component_policy},
        {%{destination: Map.delete(@inference, "methods")},
         {:invalid_destination, {:required, "methods"}}},
        {%{destination: Map.delete(@inference, "paths")},
         {:invalid_destination, {:required, "paths"}}},
        {%{destination: nil}, :destination_required},
        {%{audience: "some"}, :invalid_audience},
        {%{audience: nil}, :invalid_audience},
        {%{audience: "listed", members: [""]}, :invalid_members},
        {%{person_daily: -1}, :invalid_caps},
        {%{total_daily: Arca.InstanceEntries.max_cap() + 1}, :invalid_caps},
        {%{kind: "password"}, {:invalid_kind, ~w(api_key oauth bundle)}},
        {%{name: ""}, :name_required}
      ]

      for {over, reason} <- refused do
        assert {:error, ^reason} = InstanceEntries.create(admin, params(over)), inspect(over)
      end

      assert {:error, :destination_required} =
               InstanceEntries.create(admin, Map.delete(params(), :destination))

      # Refused before a confirmation: none was opened, so none waits.
      refute_received {:instance_entry, :created, _}
    end

    test "widening the audience needs credential_sharing; narrowing and an unchanged one the session",
         %{admin: admin} do
      [alice, bob, carol] = for name <- ~w(alice bob carol), do: id(name)
      entry = create!(admin, %{audience: "listed", members: [alice, bob]})
      add = %{entry_id: entry.id, audience: "listed", members: Enum.sort([alice, bob, carol])}
      everyone = %{entry_id: entry.id, audience: "everyone", members: []}

      for widening <- [add, everyone] do
        assert {:error, {:confirmation_required, %{operation: "instance_entry.set_audience"}}} =
                 InstanceEntries.set_audience(admin, widening)
      end

      # Unchanged, in any order: the session, no write, no announcement.
      assert {:ok, :unchanged} =
               InstanceEntries.set_audience(admin, %{add | members: [bob, alice]})

      refute_received {:instance_entry, :audience, _}

      # Narrowing: the session alone.
      narrow = %{add | members: [alice]}
      assert {:ok, :changed} = InstanceEntries.set_audience(admin, narrow)
      assert_received {:instance_entry, :audience, %{entry_id: id}}
      assert id == entry.id

      assert {:ok, []} = InstanceEntries.offered(person("bob"))

      assert {:error, :not_offered} =
               InstanceEntries.resolve(
                 person("bob"),
                 entry.id,
                 request("/v1/models", "GET"),
                 @custom
               )

      # A proof for the widening it names lands it; Bob, re-added by it, is
      # offered the entry again.
      readd = %{add | members: Enum.sort([alice, bob])}

      confirmed =
        sharing(admin, "instance_entry.set_audience", readd, entry, %{
          "audience" => "listed",
          "people_added" => "1"
        })

      assert {:ok, :changed} = InstanceEntries.set_audience(confirmed, readd)
      assert {:ok, [%{id: id}]} = InstanceEntries.offered(person("bob"))
      assert id == entry.id

      confirmed =
        sharing(admin, "instance_entry.set_audience", everyone, entry, %{"audience" => "everyone"})

      assert {:ok, :changed} = InstanceEntries.set_audience(confirmed, everyone)
      assert {:ok, [%{audience: "everyone", members: []}]} = InstanceEntries.list(admin)

      assert {:error, :invalid_audience} =
               InstanceEntries.set_audience(admin, %{everyone | audience: "anyone"})
    end

    test "an audience write racing a change of what it was decided against is refused, not retried",
         %{admin: admin} do
      [alice, bob, carol] = for name <- ~w(alice bob carol), do: id(name)
      entry = create!(admin, %{audience: "listed", members: [alice, bob]})

      widening = %{
        entry_id: entry.id,
        audience: "listed",
        members: Enum.sort([alice, bob, carol])
      }

      race_id = "instance-entries-audience-race-#{System.unique_integer([:positive])}"

      # Between the read the widening was decided against and its write,
      # another administrator removes Bob.
      :telemetry.attach(
        race_id,
        [:cyfr, :sanctum, :confirmation, :consumed],
        fn _event, _measurements, %{operation: "instance_entry.set_audience"}, id ->
          :ok =
            Arca.InstanceEntries.set_audience(
              Prima.Actor.system(),
              id,
              %{audience: "listed", members: [alice, bob]},
              %{audience: "listed", members: [alice]}
            )
        end,
        entry.id
      )

      confirmed =
        sharing(admin, "instance_entry.set_audience", widening, entry, %{
          "audience" => "listed",
          "people_added" => "1"
        })

      try do
        assert {:error, :conflict} = InstanceEntries.set_audience(confirmed, widening)
      after
        :telemetry.detach(race_id)
      end

      # Bob stays removed and Carol was never added.
      assert {:ok, [%{members: [^alice]}]} = InstanceEntries.list(admin)
      refute_received {:instance_entry, :audience, _}
    end

    # Another administrator's write lands between this request's read and
    # its write, changing the cap this request does not name (written as
    # that administrator read the pair): each cap keeps its own writer's
    # value.
    test "a caps write touches only the caps it names, so a concurrent write to the other stands",
         %{admin: admin} do
      for {named, other, expected} <- [
            {%{person_daily: 7}, %{person_daily: 5, total_daily: 0}, {7, 0}},
            {%{total_daily: 9}, %{person_daily: 0, total_daily: 50}, {0, 9}}
          ] do
        entry = create!(admin, %{person_daily: 5, total_daily: 50})
        test = self()
        handler = "caps-race-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == "instance_entries" and
                 String.starts_with?(meta[:query] || "", "SELECT") and
                 Process.get(:fired) == nil do
              Process.put(:fired, true)
              :ok = Arca.InstanceEntries.set_caps(Prima.Actor.system(), entry.id, other)
            end
          end,
          nil
        )

        try do
          assert {:ok, :changed} =
                   InstanceEntries.set_caps(admin, Map.put(named, :entry_id, entry.id))
        after
          :telemetry.detach(handler)
        end

        assert Process.delete(:fired) == true
        %{person_daily: person, total_daily: total} = stored(entry.id)
        assert {person, total} == expected
      end
    end

    # What a person reads before proving a widening is the widening itself,
    # never a value: the audience it becomes or how many people it adds,
    # and the policy it moves from and to.
    test "a credential_sharing confirmation's preview names the change it confirms",
         %{admin: admin} do
      [alice, bob, carol] = for name <- ~w(alice bob carol), do: id(name)
      listed = create!(admin, %{audience: "listed", members: [alice]})
      shipped = create!(admin, %{component_policy: "shipped"})

      for {change, operation, entry, details} <- [
            {&InstanceEntries.set_audience/2,
             %{entry_id: listed.id, audience: "listed", members: [alice, bob, carol]}, listed,
             %{"audience" => "listed", "people_added" => "2"}},
            {&InstanceEntries.set_audience/2,
             %{entry_id: listed.id, audience: "everyone", members: []}, listed,
             %{"audience" => "everyone"}},
            {&InstanceEntries.set_component_policy/2,
             %{entry_id: shipped.id, component_policy: "any"}, shipped, @policy_widening}
          ] do
        assert {:error, {:confirmation_required, %{id: secret}}} = change.(admin, operation)

        {:ok, row} =
          Arca.PendingConfirmations.get(Context.actor(admin), Prima.Confirmation.ref(secret))

        preview = Jason.decode!(row.preview)
        assert preview["resource"] == entry.name
        assert preview["details"] == details
        refute row.preview =~ @secret
        for person <- [alice, bob, carol], do: refute(row.preview =~ person)
      end
    end

    test "an over-long name or provider is refused naming its field, before a confirmation",
         %{admin: admin} do
      long = String.duplicate("n", 256)

      for {over, field} <- [{%{name: long}, :name}, {%{provider_hint: long}, :provider_hint}] do
        assert {:error, {:invalid, %{^field => [_ | _]}}} =
                 InstanceEntries.create(admin, params(over))
      end

      assert {:error, {:invalid, %{members: [_ | _]}}} =
               InstanceEntries.create(admin, params(%{audience: "listed", members: [long]}))

      assert {:ok, []} = Arca.InstanceEntries.list(Prima.Actor.system())

      # 255 characters is the column's bound, and is taken.
      assert %{name: name} = create!(admin, %{name: String.duplicate("é", 255)})
      assert String.length(name) == 255
    end

    # PostgreSQL's `varchar(255)` counts code points, and a letter with a
    # combining mark is one grapheme of two: the bound counts what the
    # column counts, so neither adapter is asked to store more.
    test "the bound counts code points, refusing a combining-mark name or member id first",
         %{admin: admin} do
      combining = String.duplicate("e\u0301", 200)
      assert String.length(combining) == 200

      assert {:error, {:invalid, %{name: [_ | _]}}} =
               InstanceEntries.create(admin, params(%{name: combining}))

      assert {:error, {:invalid, %{members: [_ | _]}}} =
               InstanceEntries.create(admin, params(%{audience: "listed", members: [combining]}))

      assert {:ok, []} = Arca.InstanceEntries.list(Prima.Actor.system())
    end

    test "a rotation against a revision that moved is a conflict before anything is confirmed",
         %{admin: admin} do
      entry = create!(admin)

      stale = %{entry_id: entry.id, fields: %{"API_KEY" => "sk-rotated"}, expected_payload_rev: 5}

      assert {:error, :payload_conflict} = InstanceEntries.rotate(admin, stale)
      refute_received {:instance_entry, :rotated, _}
    end

    test "a denied person is refused from a listed audience, naming them, and nothing is written",
         %{admin: admin} do
      alice = id("alice")
      bob = id("bob")
      deny!(bob)

      entry = create!(admin, %{audience: "listed", members: [alice]})
      adding = %{entry_id: entry.id, audience: "listed", members: Enum.sort([alice, bob])}

      confirmed =
        sharing(admin, "instance_entry.set_audience", adding, entry, %{
          "audience" => "listed",
          "people_added" => "1"
        })

      assert {:error, {:person_denied, ^bob}} = InstanceEntries.set_audience(confirmed, adding)
      assert {:ok, [%{members: [^alice]}]} = InstanceEntries.list(admin)
      refute_received {:instance_entry, :audience, _}

      params = params(%{audience: "listed", members: [bob]})

      confirmed =
        TestContext.confirmed(admin, :credential_entry, %{
          operation: "instance_entry.create",
          arguments: params,
          resource: params.name
        })

      assert {:error, {:person_denied, ^bob}} = InstanceEntries.create(confirmed, params)
      assert {:ok, [_only]} = InstanceEntries.list(admin)
    end

    test "caps: an absent cap keeps its stored value, null takes the default, an unchanged pair announces nothing",
         %{admin: admin} do
      entry = create!(admin, %{person_daily: 5, total_daily: 50})

      assert {:ok, :changed} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, person_daily: 7})

      assert %{person_daily: 7, total_daily: 50} = stored(entry.id)
      assert_received {:instance_entry, :caps, _}

      assert {:ok, :changed} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, total_daily: nil})

      assert %{person_daily: 7, total_daily: nil} = stored(entry.id)

      assert {:ok, :unchanged} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, person_daily: 7})

      assert {:ok, :unchanged} = InstanceEntries.set_caps(admin, %{entry_id: entry.id})
      assert_received {:instance_entry, :caps, _}
      refute_received {:instance_entry, :caps, _}

      assert {:error, :invalid_caps} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, person_daily: -1})

      assert {:error, :invalid_caps} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, total_daily: "10"})
    end

    test "a rebind moves the destination and blocks every dependent profile", %{admin: admin} do
      entry = create!(admin)
      a = dependent!("ath_a", entry)
      b = dependent!("ath_b", entry)
      models = Map.put(@inference, "paths", ["/v1/models"])

      assert {:ok, %{binding_digest: digest, affected: affected}} =
               InstanceEntries.rebind(admin, %{entry_id: entry.id, destination: models})

      assert digest != entry.binding_digest
      assert Enum.sort(affected) == Enum.sort([{"ath_a", a}, {"ath_b", b}])
      assert profile_status("ath_a", a) == "needs_consent"
      assert_received {:instance_entry, :rebound, _}

      assert {:error, :destination_mismatch} =
               InstanceEntries.resolve(
                 person("alice"),
                 entry.id,
                 request("/v1/chat/completions"),
                 @custom
               )

      assert {:error, :no_binding_changes} =
               InstanceEntries.rebind(admin, %{entry_id: entry.id, destination: models})

      assert {:error, {:invalid_destination, {:required, "paths"}}} =
               InstanceEntries.rebind(admin, %{
                 entry_id: entry.id,
                 destination: Map.delete(models, "paths")
               })

      refute_received {:instance_entry, :rebound, _}
    end

    test "usage refuses days outside the kept window before any read", %{admin: admin} do
      entry = create!(admin)

      QueryCounter.assert_queries(0, fn ->
        for days <- [0, -1, Arca.InstanceEntryUsage.kept_days() + 1, "1", nil, 1.5] do
          assert {:error, :invalid_days} = InstanceEntries.usage(admin, entry.id, days)
        end
      end)

      {:ok, _, _} =
        InstanceEntries.resolve(person("alice"), entry.id, request("/v1/models", "GET"), @custom)

      alice = id("alice")

      assert {:ok, %{totals: [%{count: 1}], people: [%{user_id: ^alice, count: 1}]}} =
               InstanceEntries.usage(admin, entry.id, Arca.InstanceEntryUsage.kept_days())
    end
  end

  # ---------------------------------------------------------------------------
  # The attach path
  # ---------------------------------------------------------------------------

  describe "resolve/4" do
    test "a person outside a listed audience is offered nothing and resolves nothing",
         %{admin: admin} do
      listed = create!(admin, %{audience: "listed", members: [id("alice")]})
      everyone = create!(admin)

      assert {:ok, offered} = InstanceEntries.offered(person("alice"))
      assert Enum.sort(Enum.map(offered, & &1.id)) == Enum.sort([listed.id, everyone.id])

      assert {:ok, [%{id: id} = offer]} = InstanceEntries.offered(person("bob"))
      assert id == everyone.id
      refute inspect(offer) =~ @secret
      refute Map.has_key?(offer, :members)

      assert {:error, :not_offered} =
               InstanceEntries.resolve(
                 person("bob"),
                 listed.id,
                 request("/v1/models", "GET"),
                 @custom
               )

      assert {:error, :not_offered} =
               InstanceEntries.resolve(
                 person("bob"),
                 "ine_missing",
                 request("/v1/models", "GET"),
                 @custom
               )

      assert {0, []} = usage(listed.id)
    end

    test "a request outside the destination unseals nothing and takes no claim", %{admin: admin} do
      entry = create!(admin)
      alice = person("alice")

      for {path, method, scheme_port} <- [
            {"/v1/files", "POST", "https://api.openai.com"},
            {"/v1/chat/completions", "DELETE", "https://api.openai.com"},
            {"/v1/chat/completions", "POST", "http://api.openai.com"},
            {"/v1/chat/completions", "POST", "https://api.openai.com:8443"},
            {"/v1/chat/completions", "POST", "https://evil.example.com"}
          ] do
        outside = %{uri: URI.parse(scheme_port <> path), method: method}

        assert {:error, :destination_mismatch} =
                 InstanceEntries.resolve(alice, entry.id, outside, @custom),
               "#{method} #{scheme_port}#{path}"
      end

      assert {0, []} = usage(entry.id)
      assert stored(entry.id).last_used_at == nil

      assert {:ok, _, _} =
               InstanceEntries.resolve(alice, entry.id, request("/v1/models", "GET"), @custom)

      assert %DateTime{} = stored(entry.id).last_used_at
    end

    test "a claim taken stands when the material does not open", %{admin: admin} do
      entry = create!(admin)

      Arca.Repo.update_all(
        Ecto.Query.from(i in Arca.Schemas.InstanceEntry, where: i.id == ^entry.id),
        set: [sealed_payload: "not an envelope"]
      )

      assert {:error, :unseal_failed} =
               InstanceEntries.resolve(
                 person("alice"),
                 entry.id,
                 request("/v1/models", "GET"),
                 @custom
               )

      # The request was admitted and counted, as a rate window counts a
      # refused request.
      alice = id("alice")
      assert {1, [%{user_id: ^alice, count: 1}]} = usage(entry.id)
    end

    test "an unset cap takes its setting's default, and a setting of 0 admits no use",
         %{admin: admin} do
      entry = create!(admin)
      chat = request("/v1/chat/completions")

      for setting <- ["instance_entry_person_daily", "instance_entry_total_daily"] do
        Sanctum.Test.Settings.put(setting, 0)

        assert {:error, {:connection_cap, _reset}} =
                 InstanceEntries.resolve(person("alice"), entry.id, chat, @custom),
               setting

        Sanctum.Test.Settings.reset(setting)
      end

      assert {0, []} = usage(entry.id)

      # The total's default bounds everyone together.
      Sanctum.Test.Settings.put("instance_entry_total_daily", 1)
      assert {:ok, _, _} = InstanceEntries.resolve(person("alice"), entry.id, chat, @custom)

      assert {:error, {:connection_cap, _reset}} =
               InstanceEntries.resolve(person("bob"), entry.id, chat, @custom)

      # An entry's own cap wins over the setting; its 0 admits no use.
      capped = create!(admin, %{person_daily: 0, total_daily: 10})

      assert {:error, {:connection_cap, _reset}} =
               InstanceEntries.resolve(person("alice"), capped.id, chat, @custom)
    end

    test "a revoke blocks every dependent in every athanor, and the next attach is refused",
         %{admin: admin} do
      entry = create!(admin)
      a = dependent!("ath_a", entry)
      b = dependent!("ath_b", entry)
      chat = request("/v1/chat/completions")

      assert {:ok, _, _} = InstanceEntries.resolve(person("alice"), entry.id, chat, @custom)

      assert {:ok, %{affected: affected}} = InstanceEntries.revoke(admin, entry.id)
      assert Enum.sort(affected) == Enum.sort([{"ath_a", a}, {"ath_b", b}])

      for {athanor, profile} <- affected,
          do: assert(profile_status(athanor, profile) == "needs_consent")

      assert_received {:instance_entry, :revoked, %{entry_id: id}}
      assert id == entry.id

      assert {:error, {:entry_unavailable, "revoked"}} =
               InstanceEntries.resolve(person("alice"), entry.id, chat, @custom)

      assert {:ok, []} = InstanceEntries.offered(person("alice"))
      assert {1, _} = usage(entry.id)

      # A delete erases the material and blocks again.
      assert {:ok, %{affected: again}} = InstanceEntries.delete(admin, entry.id)
      assert Enum.sort(again) == Enum.sort(affected)
      assert %{status: "tombstoned", sealed_payload: nil} = stored(entry.id)
      assert_received {:instance_entry, :deleted, _}

      assert {:error, :not_offered} =
               InstanceEntries.resolve(person("alice"), entry.id, chat, @custom)
    end

    # A refresh that fails after the entry was revoked marks nothing, so a
    # stale refresh can never undo the revoke through the `needs_reauth` →
    # `active` reactivation a commit carries.
    test "a stale refresh after a revoke writes nothing and cannot reactivate the entry",
         %{admin: admin} do
      entry = create!(admin)
      assert {:ok, _} = InstanceEntries.revoke(admin, entry.id)

      assert {:error, {:entry_unavailable, "revoked"}} =
               Arca.InstanceEntries.set_status(Prima.Actor.system(), entry.id, "needs_reauth")

      assert {:error, {:entry_unavailable, "revoked"}} =
               Arca.InstanceEntries.commit_payload(Prima.Actor.system(), entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-by-a-late-refresh",
                 status: "active"
               })

      assert %{status: "revoked", payload_rev: 0} = after_ = stored(entry.id)
      refute after_.sealed_payload == "sealed-by-a-late-refresh"

      assert {:error, {:entry_unavailable, "revoked"}} =
               InstanceEntries.resolve(
                 person("alice"),
                 entry.id,
                 request("/v1/models", "GET"),
                 @custom
               )
    end

    # The audience list is a filter; the person's own standing is read
    # first. A denied person a member row still names (written past the
    # denial, here directly) resolves nothing: no claim, nothing unsealed.
    test "a person who is not active is refused before the audience is read", %{admin: admin} do
      bob = person("bob")
      entry = create!(admin, %{audience: "listed", members: [id("alice")]})
      deny!(bob.user_id)

      Arca.Repo.insert_all(Arca.Schemas.InstanceEntryMember, [
        %{instance_entry_id: entry.id, user_id: bob.user_id, inserted_at: DateTime.utc_now()}
      ])

      assert {:error, :denied} =
               InstanceEntries.resolve(bob, entry.id, request("/v1/models", "GET"), @custom)

      assert {0, []} = usage(entry.id)
      assert stored(entry.id).last_used_at == nil

      # One with no person row at all is not active either.
      stranger = %{bob | user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix())}

      assert {:error, :denied} =
               InstanceEntries.resolve(stranger, entry.id, request("/v1/models", "GET"), @custom)

      assert Prima.Refusal.classify(:denied).class == :forbidden
    end

    test "an anonymous caller resolves and is offered nothing", %{admin: admin} do
      entry = create!(admin)
      anonymous = %{person("alice") | anonymous: true}

      assert {:error, :anonymous_denied} = InstanceEntries.offered(anonymous)

      assert {:error, :anonymous_denied} =
               InstanceEntries.resolve(anonymous, entry.id, request("/v1/models", "GET"), @custom)

      assert {0, []} = usage(entry.id)
    end
  end

  describe "what is announced and kept" do
    test "each change announces the entry id, its kind and who acted, never a value",
         %{admin: admin} do
      entry = create!(admin)

      assert {:ok, :changed} =
               InstanceEntries.set_caps(admin, %{entry_id: entry.id, person_daily: 3})

      assert {:ok, _} = InstanceEntries.revoke(admin, entry.id)
      assert {:ok, _} = InstanceEntries.delete(admin, entry.id)

      for kind <- [:caps, :revoked, :deleted] do
        assert_received {:instance_entry, ^kind, metadata}
        assert metadata == %{entry_id: entry.id, kind: kind, user_id: admin.user_id}
      end

      # The material, the name and the destination are on no announcement,
      # and the sealed row holds no plaintext.
      refute_received {:instance_entry, _, _}
      refute inspect(stored(entry.id)) =~ @secret
    end

    test "the entry is sealed under its own id and hint, and created by the administrator",
         %{admin: admin} do
      entry = create!(admin)
      row = stored(entry.id)

      assert row.created_by == admin.user_id
      assert row.attach_only == true
      refute row.sealed_payload =~ @secret

      assert {:ok, plaintext} =
               Sanctum.Cipher.decrypt(
                 row.sealed_payload,
                 Sanctum.CipherAAD.instance_entry(entry.id, "openai.com")
               )

      assert plaintext =~ @secret

      assert {:error, _} =
               Sanctum.Cipher.decrypt(
                 row.sealed_payload,
                 Sanctum.CipherAAD.instance_entry(entry.id, "other.com")
               )
    end

    test "the usage sweep removes the days past the kept window, naming no entry", %{admin: admin} do
      entry = create!(admin)
      today = DateTime.to_date(Arca.ServerMetaStorage.now!())
      kept = Arca.InstanceEntryUsage.kept_days()

      {2, _} =
        Arca.Repo.insert_all(
          Arca.Schemas.InstanceEntryUsage,
          for {who, days_ago} <- [{"usr_old", kept + 1}, {"usr_kept", kept}] do
            %{
              instance_entry_id: entry.id,
              user_id: who,
              day: Date.add(today, -days_ago),
              count: 1,
              updated_at: DateTime.utc_now()
            }
          end
        )

      assert {:ok, 1} = InstanceEntries.sweep_usage()
      assert {:ok, 0} = InstanceEntries.sweep_usage()
    end
  end
end
