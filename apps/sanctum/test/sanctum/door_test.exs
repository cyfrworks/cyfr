# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorTest do
  @moduledoc """
  The door judges people (`Sanctum.Door`): a local person is admitted
  unless a deny names them; a remote person, and a remote newcomer, by `*`
  or an allow naming their identifier, unless a deny names them; an
  unadmitted remote one leaves one request naming the identifier; a deny
  naming the platform administrator is refused where it is written; and a
  store that cannot answer admits no one and denies no one.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Door
  alias Sanctum.Door.Store
  alias Sanctum.Test.People
  alias Sanctum.Test.RegistryStub

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp uid(n), do: "github|https://github.com|door#{n}"
  defp identifier(n), do: "per_" <> Prima.Digest.sha256_hex("door-#{n}")

  # A person whose keys this server holds, with a sign-in method linked.
  defp local!(n) do
    {:ok, user} =
      People.linked(%{
        id: uid(n),
        provider: "github",
        email: "person#{n}@example.com",
        verified: true
      })

    user
  end

  # A person whose keys another CYFR holds, named here by their identifier.
  defp remote!(n) do
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          admission: "remote",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier(n)),
          provider: "cyfr",
          issuer: "https://dir.example",
          subject: identifier(n),
          first_seen_at: now,
          last_seen_at: now
        }
      )

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user.id,
        provenance: "remote",
        identifier: identifier(n),
        directory_url: "https://dir.example"
      })

    user
  end

  defp enrolled!(user, n) do
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user.id),
        set: [identifier: identifier(n)]
      )

    :ok
  end

  defp session_for(user) do
    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: user[:email],
        provider: "github",
        authenticated: true,
        permissions: [:read]
      )

    {:ok, session} =
      Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

    session
  end

  describe "a local person" do
    test "is admitted with no entry at all, and refused only by a deny naming them" do
      alice = local!(1)
      bob = local!(2)

      assert Store.list() == []
      assert {:ok, :allowed} = Door.admit_person(alice)

      {:ok, _} = Store.deny("person", alice.id, "ops")
      assert {:error, :denied} = Door.admit_person(alice)
      assert {:ok, :allowed} = Door.admit_person(bob)

      # `*` admits nobody past a deny.
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      assert {:error, :denied} = Door.admit_person(alice)
    end

    test "is refused by a deny of the identifier they enrolled under" do
      alice = local!(3)
      enrolled!(alice, 3)

      {:ok, _} = Store.deny("identifier", identifier(3), "ops")
      assert {:error, :denied} = Door.admit_person(alice)
    end

    test "is never asked for an allow, and leaves no request when denied" do
      alice = local!(4)
      {:ok, _} = Store.deny("person", alice.id, "ops")

      assert {:error, {:door, :denied}} = Door.sign_in(alice)
      assert Store.requests() == []
    end
  end

  describe "a remote person" do
    test "is admitted by * or by an allow naming their identifier, and refused otherwise" do
      carol = remote!(10)
      assert {:error, :not_allowed} = Door.admit_person(carol)

      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      assert {:ok, :allowed} = Door.admit_person(carol)
      :ok = Store.remove(wildcard.id)

      {:ok, _} = Store.allow("identifier", identifier(10), "ops")
      assert {:ok, :allowed} = Door.admit_person(carol)
      assert {:error, :not_allowed} = Door.admit_person(remote!(11))
    end

    test "a deny of the person or of the identifier wins over * and over the allow" do
      carol = remote!(12)
      dave = remote!(13)
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      {:ok, _} = Store.allow("identifier", identifier(13), "ops")

      {:ok, _} = Store.deny("person", carol.id, "ops")
      {:ok, _} = Store.deny("identifier", identifier(13), "ops")

      assert {:error, :denied} = Door.admit_person(carol)
      assert {:error, :denied} = Door.admit_person(dave)
    end

    test "an unadmitted one leaves one request naming the identifier, which resolve admits" do
      carol = remote!(14)

      assert {:error, {:door, :not_allowed}} = Door.sign_in(carol)
      assert {:error, {:door, :not_allowed}} = Door.sign_in(carol)

      assert [%{kind: "identifier", status: "requested"} = request] = Store.requests()
      assert request.value == identifier(14)
      assert {:error, :not_allowed} = Door.admit_person(carol)

      {:ok, _} = Store.resolve(request.id, :allow, "ops")
      assert {:ok, :allowed} = Door.sign_in(carol)
    end

    test "a denied one gets no request, and an admitted one writes nothing" do
      carol = remote!(15)
      dave = remote!(16)
      {:ok, _} = Store.deny("identifier", identifier(15), "ops")
      {:ok, _} = Store.allow("identifier", identifier(16), "ops")
      before = Store.list()

      assert {:error, {:door, :denied}} = Door.sign_in(carol)
      assert {:ok, :allowed} = Door.sign_in(dave)
      assert Store.list() == before
    end
  end

  describe "an invitation's allow" do
    test "admits a later sign-in of the remote person, with no invitation" do
      carol = remote!(40)
      assert {:error, :not_allowed} = Door.admit_person(carol)

      assert {:ok, %{effect: "allow", status: "allowed", note: "invitation inv_40"}} =
               Store.allow_unless_denied("identifier", identifier(40), "usr_issuer",
                 note: "invitation inv_40"
               )

      assert {:ok, :allowed} = Door.admit_person(carol)
      assert {:ok, :allowed} = Door.sign_in(carol)
      assert {:ok, :allowed} = Door.admit_identifier(identifier(40))
    end

    test "is outranked by a deny written after it, of the person or of the identifier" do
      carol = remote!(41)
      dave = remote!(42)
      {:ok, _} = Store.allow_unless_denied("identifier", identifier(41), "usr_issuer")
      {:ok, _} = Store.allow_unless_denied("identifier", identifier(42), "usr_issuer")

      {:ok, _} = Store.deny("person", carol.id, "ops")
      {:ok, %{effect: "deny"}} = Store.deny("identifier", identifier(42), "ops")

      assert {:error, {:door, :denied}} = Door.sign_in(carol)
      assert {:error, {:door, :denied}} = Door.sign_in(dave)
    end

    test "over a deny leaves the deny and answers denied" do
      dave = remote!(43)
      {:ok, deny} = Store.deny("identifier", identifier(43), "ops", note: "no")

      assert {:error, :denied} =
               Store.allow_unless_denied("identifier", identifier(43), "usr_issuer",
                 note: "invitation inv_43"
               )

      assert [^deny] = Enum.filter(Store.list(), &(&1.value == identifier(43)))
      assert {:error, :denied} = Door.admit_person(dave)
    end
  end

  describe "a remote newcomer" do
    test "is admitted by * or an allow of their identifier, and a refusal leaves one request" do
      assert {:error, {:door, :not_allowed}} = Door.sign_in_identifier(identifier(20))
      assert [%{kind: "identifier"} = request] = Store.requests()
      assert request.value == identifier(20)
      refute Door.identifier_admitted?(identifier(20))

      {:ok, _} = Store.allow("identifier", identifier(21), "ops")
      assert {:ok, :allowed} = Door.sign_in_identifier(identifier(21))
      assert Door.identifier_admitted?(identifier(21))

      {:ok, _} = Store.deny("identifier", identifier(22), "ops")
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      assert {:ok, :allowed} = Door.admit_identifier(identifier(20))
      assert {:error, {:door, :denied}} = Door.sign_in_identifier(identifier(22))
    end
  end

  describe "the entries" do
    test "an allow names an identifier or *, a deny a person or an identifier" do
      alice = local!(30)

      for {verb, kind, value} <- [
            {:allow, "person", alice.id},
            {:deny, "wildcard", "*"},
            {:allow, "email", "a@example.com"},
            {:deny, "user_id", uid(30)}
          ] do
        assert_raise FunctionClauseError, fn -> apply(Store, verb, [kind, value, "ops"]) end
      end

      assert_raise FunctionClauseError, fn ->
        apply(Store, :request, ["email", "a@example.com", "ops"])
      end

      assert Store.list() == []
    end

    test "a deny naming the platform administrator is refused, by person or by identifier" do
      operator = local!(31)
      enrolled!(operator, 31)
      {:ok, _} = Sanctum.TestContext.ensure_platform(operator.id)

      assert {:error, :platform_admin} = Store.deny("person", operator.id, "ops")
      assert {:error, :platform_admin} = Store.deny("identifier", identifier(31), "ops")
      assert Store.list() == []
      assert {:ok, :allowed} = Door.admit_person(operator)
    end

    test "concurrent requests and allows for one identifier leave one row each, and nobody sees a conflict" do
      requests =
        1..6
        |> Task.async_stream(fn _ -> Store.request("identifier", identifier(32), "ops") end,
          max_concurrency: 6,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(requests, &match?({:ok, _, _}, &1))
      assert Enum.count(requests, &match?({:ok, :created, _}, &1)) == 1

      allows =
        1..4
        |> Task.async_stream(fn _ -> Store.allow("identifier", identifier(33), "ops") end,
          max_concurrency: 4,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(allows, &match?({:ok, %{status: "allowed"}}, &1))
      assert Enum.count(Store.list(), &(&1.value in [identifier(32), identifier(33)])) == 2
    end

    test "a deny row is honoured whatever its status column says" do
      carol = remote!(34)
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      {:ok, deny} = Store.deny("identifier", identifier(34), "ops")

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(e in Arca.Schemas.ServerAllowlistEntry, where: e.id == ^deny.id),
          set: [status: "requested"]
        )

      assert {:error, :denied} = Door.admit_person(carol)
    end

    test "rejecting a request removes it" do
      {:ok, :created, request} = Store.request("identifier", identifier(35), "ops")
      assert :ok = Store.resolve(request.id, :reject, "ops")
      assert Store.list() == []
    end
  end

  describe "an entry made from a handle" do
    defp door(action, value, note \\ nil) do
      operator = Sanctum.Context.build(user_id: "usr_operator", authenticated: true)
      args = %{"action" => action, "value" => value}
      args = if note, do: Map.put(args, "note", note), else: args
      Sanctum.Provider.handle("door", operator, args)
    end

    test "a handle reassigned after an allow was made from it moves no access" do
      first = remote!(40)
      second = remote!(41)

      RegistryStub.handles!(%{"alice" => identifier(40)})
      assert {:ok, allowed} = door("allow", "@alice")
      assert %{kind: "identifier", label: "alice"} = allowed
      assert allowed.value == identifier(40)

      # The registry gives the handle to someone else.
      RegistryStub.handles!(%{"alice" => identifier(41)})
      assert {:ok, identifier(41)} == Sanctum.Handle.identifier("alice")

      assert [%{kind: "identifier", effect: "allow", label: "alice"} = entry] = Store.list()
      assert entry.value == identifier(40)
      assert {:ok, :allowed} = Door.admit_person(first)
      assert {:error, :not_allowed} = Door.admit_person(second)
      assert {:error, :not_allowed} = Door.admit_identifier(identifier(41))
    end

    test "a deny by handle writes the identifier the handle names, and a platform administrator's is refused" do
      carol = remote!(42)
      operator = local!(43)
      enrolled!(operator, 43)
      {:ok, _} = Sanctum.TestContext.ensure_platform(operator.id)
      {:ok, _} = Store.allow("wildcard", "*", "ops")

      RegistryStub.handles!(%{"carol" => identifier(42), "ops" => identifier(43)})
      assert {:ok, %{effect: "deny", label: "carol", ejected: 1}} = door("deny", "@carol")
      assert {:error, :denied} = Door.admit_person(carol)

      assert {:error, {:invalid_argument, _}} = door("deny", "@ops")
      refute Enum.any?(Store.list(), &(&1.value == identifier(43)))
    end

    test "each write states the label anew: another handle relabels, the identifier clears it" do
      {:ok, entry} = Store.allow("identifier", identifier(44), "ops", label: "alice")
      assert entry.label == "alice"

      {:ok, entry} = Store.deny("identifier", identifier(44), "ops", label: "alicia")
      assert %{effect: "deny", label: "alicia"} = entry

      {:ok, entry} = Store.allow("identifier", identifier(44), "ops", note: "back")
      assert %{effect: "allow", label: nil, note: "back"} = entry
      assert [%{label: nil}] = Store.list()

      # Only an identifier entry is made from a handle, spelled as one.
      assert {:error, {:invalid, %{label: _}}} =
               Store.allow("wildcard", "*", "ops", label: "alice")

      assert {:error, {:invalid, %{label: _}}} =
               Store.allow("identifier", identifier(45), "ops", label: "Not A Handle")

      # Through the operation: by handle, then by the identifier itself.
      RegistryStub.handles!(%{"alice" => identifier(44)})
      assert {:ok, %{label: "alice"}} = door("allow", "@alice")
      assert {:ok, shown} = door("allow", identifier(44))
      refute Map.has_key?(shown, :label)
    end

    test "with the registry down, no registry, or a handle no one holds, nothing is written" do
      RegistryStub.handles!(%{"alice" => :close})

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :registry_unavailable} = door("allow", "@alice")
        assert {:error, :registry_unavailable} = door("deny", "@alice")
      end)

      RegistryStub.handles!(%{})
      assert {:error, :handle_not_found} = door("allow", "@nobody")
      assert {:error, :handle_not_found} = door("deny", "@nobody")

      Application.put_env(:sanctum, :registry_url, "none")
      assert {:error, :no_registry} = door("allow", "@alice")
      assert {:error, :no_registry} = door("deny", "@alice")

      assert Store.list() == []
      assert Store.requests() == []
    end

    test "a misspelled handle is an invalid argument, and the registry is not asked" do
      RegistryStub.start!(fn _ -> flunk("no request is sent") end)

      for value <- ["@Alice", "@", "@a/b", "@-alice"] do
        assert {:error, {:invalid_argument, sentence}} = door("allow", value)
        assert sentence =~ "not a handle"
      end

      refute_received {:registry_request, _}
      assert Store.list() == []
    end

    test "the resolution writes nothing: no entry exists until the write" do
      RegistryStub.handles!(%{"alice" => identifier(46)})

      assert {:ok, identifier(46)} == Sanctum.Handle.identifier("alice")
      assert_received {:registry_request, %{path: "/v1/handles/alice"}}
      assert Store.list() == []
      assert {:error, :not_allowed} = Door.admit_identifier(identifier(46))

      assert {:ok, _} = door("allow", "@alice")
      assert [%{label: "alice"} = entry] = Store.list()
      assert entry.value == identifier(46)
    end
  end

  describe "reconcile/0 — the door outlives nothing" do
    # A remote person's session records their head, read fresh from their
    # directory: a scripted one here.
    setup do
      tls = Sanctum.Test.DirectoryServer.tls()
      Sanctum.Test.DirectoryServer.listen!()
      Sanctum.Test.DirectoryServer.seam!(tls)
      %{directory: Sanctum.Test.DirectoryServer.start!(tls)}
    end

    defp remote_at!(directory, n) do
      user = local!(n)
      identity = Sanctum.Test.DirectoryServer.identity!(directory.dir, directory.url)
      :ok = Sanctum.Test.DirectoryServer.remote_person!(user.id, identity)
      user
    end

    test "closing * ejects the remote people it admitted, and never a local person", %{
      directory: directory
    } do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      stranger = remote_at!(directory, 40)
      local = local!(41)

      stranger_session = session_for(stranger)
      local_session = session_for(local)

      :ok = Store.remove(wildcard.id)

      # `*` names nobody, so there is no entry to read the ejected off —
      # the door is re-asked about everyone instead.
      assert {:ok, 1} = Door.reconcile()

      assert {:error, :invalid_session} = Sanctum.Session.get(stranger_session.token)
      assert {:ok, _} = Sanctum.Session.get(local_session.token)
    end

    test "ejecting is not denying: standing survives", %{directory: directory} do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      stranger = remote_at!(directory, 42)
      session = session_for(stranger)

      :ok = Store.remove(wildcard.id)
      assert {:ok, 1} = Door.reconcile()
      assert {:error, :invalid_session} = Sanctum.Session.get(session.token)

      {:ok, after_eject} = Sanctum.Tenancy.Users.get(stranger.id)
      assert after_eject.status == "active"
      assert after_eject.denied_at == nil
    end
  end

  describe "reconcile/0 — past the first page" do
    # More people than one page, with a refused person on the second: a
    # sign-in that moves them up the recency order while the walk reads the
    # first page must not let them through the walk.
    test "a refused person whose last sign-in moves between pages is still ejected" do
      now = DateTime.utc_now()

      people =
        for i <- 1..600 do
          seen = DateTime.add(now, -i, :second)

          %{
            id: "door-page-#{String.pad_leading(Integer.to_string(i), 4, "0")}",
            email: "page#{i}@example.com",
            email_verified: true,
            admission: "open",
            status: "active",
            security_generation: 1,
            first_seen_at: seen,
            last_seen_at: seen,
            created_at: seen,
            updated_at: seen
          }
        end

      {600, _} = Arca.Repo.insert_all(Arca.Schemas.User, people)

      refused = local!(50)
      session = session_for(refused)
      tenant = Sanctum.TestContext.local()

      {:ok, key} =
        Sanctum.TestContext.create_key(%{tenant | user_id: refused.id}, %{name: "late"})

      {:ok, _} = Store.deny("person", refused.id, "ops")

      # Seen longest ago, so the most recently seen first puts them on the
      # second page; their id sorts after every filler's, so id order does.
      set_last_seen!(refused.id, DateTime.add(now, -86_400, :second))

      test = self()
      handler = "door-page-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          &__MODULE__.sign_in_after_first_page/4,
          %{test: test, user_id: refused.id, at: DateTime.add(now, 3_600, :second)}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, 1} = Door.reconcile()
      assert_received :signed_in_between_pages

      assert {:error, :invalid_session} = Sanctum.Session.get(session.token)
      assert {:error, _} = Sanctum.ApiKey.validate(key.api_key)
    end
  end

  # The refused person signs in once the walk's first page of people has
  # been read in the walking process: their last sign-in moves to now.
  @doc false
  def sign_in_after_first_page(_event, _measurements, %{source: "users", query: query}, config) do
    if self() == config.test and query =~ "LIMIT" and not Process.get(:signed_in?, false) do
      Process.put(:signed_in?, true)
      set_last_seen!(config.user_id, config.at)
      send(config.test, :signed_in_between_pages)
    end
  end

  def sign_in_after_first_page(_event, _measurements, _metadata, _config), do: :ok

  defp set_last_seen!(user_id, at) do
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(u in Arca.Schemas.User, where: u.id == ^user_id),
        set: [last_seen_at: at]
      )

    :ok
  end

  describe "a door that cannot be read" do
    # Absent data, denied access and unavailable infrastructure are three
    # answers, and the door is where the difference decides who gets in.
    # Dropping the table inside the sandbox transaction is the one way to
    # make the store fail the way it would in an outage; Postgres aborts
    # the transaction on the first such failure, so each case here reads
    # the door and then stops rather than asserting on other tables.
    defp drop_door do
      Arca.Repo.query!("DROP TABLE server_allowlist")
    end

    test "refuses a person as :unavailable — not as :denied, and not as :not_allowed" do
      alice = local!(60)
      drop_door()

      assert {:error, :unavailable} = Door.admit_person(alice)
    end

    test "a sign-in's refusal carries :unavailable and queues no request" do
      carol = remote!(61)
      handler = "door-outage-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :door, :refused],
        fn _e, _m, meta, _c -> send(parent, {:refused, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      drop_door()

      assert {:error, {:door, :unavailable}} = Door.sign_in(carol)

      # Only `:not_allowed` queues a request. An outage is not an answer to
      # record, and writing one would be a write into the same dead store.
      assert_receive {:refused, %{reason: :unavailable}}
    end

    test "an invite is not admitted through an unreadable door" do
      drop_door()

      refute Door.identifier_admitted?(identifier(62))
    end

    test "reconcile ejects nobody it could not ask about" do
      local!(63)
      drop_door()

      # The walk reads the users rows first and the door per person, so the
      # refusal it sees is `:unavailable` — which is not a refusal. Ejecting
      # on it would take every session and key on the server the first time
      # the store blinked.
      assert {:ok, 0} = Door.reconcile()
    end
  end
end
