# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.EgressTest do
  @moduledoc """
  A guest's outbound target is pinned by CYFR under the calling attempt's
  admitted authority (`Crucible.Host.Egress`): the host resolved once,
  IPv4 first and IPv6 only when no IPv4 address resolves, a metadata
  address refused before any policy, a private address refused unless the
  stored authority's edge grants it, and a redirect that would carry the
  request's credentials to another origin refused before anything is
  resolved. Every `egress_pin_cases` vector of
  `tests/fixtures/host_api.json` is answered as it names, and every
  refusal is recorded as a denial of the attempt's component.

  Names resolve through scripted resolvers and never through the network.
  """

  use ExUnit.Case, async: false

  alias Crucible.Host.Egress
  alias Cyfr.Test.AttemptFixtures
  alias Prima.Authority
  alias Prima.Authority.Blob.Edge
  alias Prima.{PinnedTarget, WorkerAuth, WorkerWire}

  @vectors_path Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  @window WorkerAuth.window_ms()

  # The resolver the vectors' names are scripted in: each name answers the
  # addresses the test queued for it, in order, and an address literal is
  # answered as `:inet` answers it. Every lookup is noted, so a test can
  # show a name was never resolved. It runs in the calling process, as the
  # pin resolves in the process that asks for it.
  defmodule Resolver do
    @moduledoc false

    def script(name, family, addresses),
      do: Process.put({__MODULE__, name, family}, addresses)

    def looked_up, do: Process.get({__MODULE__, :looked_up}, []) |> Enum.reverse()

    def getaddr(name, family) do
      name = name |> to_string() |> String.downcase()

      Process.put({__MODULE__, :looked_up}, [
        {name, family} | Process.get({__MODULE__, :looked_up}, [])
      ])

      case :inet.parse_strict_address(String.to_charlist(name)) do
        {:ok, ip} when tuple_size(ip) == 4 and family == :inet -> {:ok, ip}
        {:ok, ip} when tuple_size(ip) == 8 and family == :inet6 -> {:ok, ip}
        {:ok, _other_family} -> {:error, :nxdomain}
        {:error, _name} -> scripted(name, family)
      end
    end

    defp scripted(name, family) do
      case Process.get({__MODULE__, name, family}, []) do
        [ip | rest] ->
          Process.put({__MODULE__, name, family}, if(rest == [], do: [ip], else: rest))
          {:ok, ip}

        [] ->
          {:error, :nxdomain}
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp pin(fixture, url, purpose, opts \\ []) do
    {:ok, request} =
      url
      |> PinnedTarget.request_args(purpose, Keyword.get(opts, :from))
      |> then(fn {:ok, args} -> PinnedTarget.read_request(args) end)

    caller = Keyword.get_lazy(opts, :caller, fn -> AttemptFixtures.caller(fixture) end)

    Egress.pin(caller, request,
      now: Keyword.get_lazy(opts, :now, &now/0),
      resolver: Keyword.get(opts, :resolver, Resolver)
    )
  end

  defp denials(fixture) do
    {:ok, rows} = Arca.PolicyLog.list(athanor_id: fixture.athanor_id, limit: 100)
    Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
  end

  defp private_ips(ips) do
    %{
      Authority.zero()
      | resources: %Edge{egress: %{domains: [], methods: [], schemes: [], private_ips: ips}}
    }
  end

  defp now, do: System.system_time(:millisecond)

  describe "the egress_pin cases of tests/fixtures/host_api.json" do
    test "each is pinned or refused as it names, a redirect naming the pin its hop came from" do
      cases = Map.new(@vectors["egress_pin_cases"], &{&1["name"], &1})

      assert Enum.map(@vectors["egress_pin_cases"], & &1["name"]) ==
               ~w(fetch stream redirect denied metadata resolution redirect_credentials)

      # The addresses the vectors answer: the fetch's, then the redirect's
      # hop to the same host.
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}, {203, 0, 113, 11}])
      Resolver.script("login.other.test", :inet, [{203, 0, 113, 50}])

      fixture = AttemptFixtures.attached!()
      fetch_id = pinned_id(fixture, cases["fetch"], nil)

      for name <- ~w(stream redirect denied metadata resolution redirect_credentials) do
        pinned_id(fixture, cases[name], fetch_id)
      end

      # The hop to another origin was refused before its host was resolved.
      refute Enum.any?(Resolver.looked_up(), fn {host, _family} -> host == "login.other.test" end)

      assert fixture |> denials() |> Enum.map(& &1.decision) == List.duplicate("denied", 4)
    end
  end

  # Drive one case: its args read as the vector writes them, a redirect's
  # `from` bound to the pin this attempt was answered, and its answer
  # compared with the vector's, the pin's minted id and its expiry aside.
  # Answers the pin's id, for the redirects that name it.
  defp pinned_id(fixture, vector, fetch_id) do
    %{"v" => 1, "op" => "egress_pin", "args" => args} = Jason.decode!(vector["body"])
    args = if Map.has_key?(args, "from"), do: %{args | "from" => fetch_id}, else: args
    assert {:ok, request} = PinnedTarget.read_request(args)

    at = now()
    answer = Egress.pin(AttemptFixtures.caller(fixture), request, now: at, resolver: Resolver)
    expected = Jason.decode!(vector["answer"])

    case WorkerWire.read_answer(expected) do
      {:ok, wire} ->
        assert {:ok, %PinnedTarget{} = pin} = answer, vector["name"]
        pinned = PinnedTarget.to_wire(pin)
        assert Map.drop(pinned, ["id", "expires_at"]) == Map.drop(wire, ["id", "expires_at"])
        assert pin.expires_at == at + @window
        assert wire["expires_at"] == vector["fields"]["ts"] + @window
        assert PinnedTarget.valid_id?(pin.id)
        pin.id

      {:error, name, %{}} ->
        assert {:error, String.to_existing_atom(name)} == answer, vector["name"]
        nil
    end
  end

  describe "the address" do
    test "is resolved IPv4 first, and IPv6 only when no IPv4 address resolves" do
      fixture = AttemptFixtures.attached!()

      assert {:ok, %PinnedTarget{ip: "203.0.113.20", family: 4, host: "dual.test"}} =
               pin(fixture, "https://dual.test/", :fetch, resolver: Sanctum.Test.Resolver)

      assert {:ok, %PinnedTarget{ip: "2001:db8::30", family: 6, host: "v6only.test", port: 8443}} =
               pin(fixture, "https://v6only.test:8443/x?q=1", :stream,
                 resolver: Sanctum.Test.Resolver
               )

      # An IPv6 literal is carried in brackets, as the Host header and the
      # certificate name it.
      assert {:ok, %PinnedTarget{ip: "2001:db8::20", family: 6, host: "[2001:db8::20]"}} =
               pin(fixture, "http://[2001:db8::20]:8080/events", :stream)

      assert {:error, :resolution} =
               pin(fixture, "https://nonexistent.test/", :fetch, resolver: Sanctum.Test.Resolver)
    end

    test "is private only where the stored authority's edge grants it" do
      granted = AttemptFixtures.attached!(authority: private_ips(["10.0.0.0/8"]))

      assert {:ok, %PinnedTarget{ip: "10.0.0.5", family: 4}} =
               pin(granted, "http://private.test/admin", :fetch, resolver: Sanctum.Test.Resolver)

      assert {:error, :denied} = pin(granted, "http://192.168.1.10/", :fetch)

      # No edge, and an edge that grants no egress, grant no private address.
      for authority <- [Authority.zero(), %{Authority.zero() | resources: %Edge{}}] do
        fixture = AttemptFixtures.attached!(authority: authority)
        assert {:error, :denied} = pin(fixture, "http://10.0.0.5/", :fetch)
        assert {:ok, %PinnedTarget{}} = pin(fixture, "https://203.0.113.10/", :fetch)
      end
    end

    test "is never granted by the operator's private-egress targets" do
      previous = Application.fetch_env(:sanctum, :private_egress_targets)
      Application.put_env(:sanctum, :private_egress_targets, ["10.0.0.0/8", "private.test"])

      on_exit(fn ->
        case previous do
          {:ok, targets} -> Application.put_env(:sanctum, :private_egress_targets, targets)
          :error -> Application.delete_env(:sanctum, :private_egress_targets)
        end
      end)

      fixture = AttemptFixtures.attached!()

      assert {:error, :denied} =
               pin(fixture, "http://private.test/", :fetch, resolver: Sanctum.Test.Resolver)

      assert {:error, :denied} = pin(fixture, "http://10.0.0.5/", :fetch)
    end

    test "at a metadata address is refused before any policy, whatever the edge grants" do
      fixture = AttemptFixtures.attached!(authority: private_ips(["169.254.0.0/16", "fe80::/10"]))

      assert {:error, :metadata} = pin(fixture, "http://169.254.169.254/latest/", :fetch)

      assert {:error, :metadata} =
               pin(fixture, "http://metadata.test/", :fetch, resolver: Sanctum.Test.Resolver)

      assert [_, _] = denials(fixture)
    end
  end

  describe "a redirect" do
    test "keeps the pin's credentials only on its own scheme and host" do
      fixture = AttemptFixtures.attached!()
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("other.example.test", :inet, [{203, 0, 113, 12}])

      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/a", :fetch)

      assert {:ok, %PinnedTarget{host: "api.example.test"}} =
               pin(fixture, "https://API.example.test:8443/b", :redirect, from: from)

      for url <- ["http://api.example.test/b", "https://other.example.test/b"] do
        assert {:error, :redirect_credentials} = pin(fixture, url, :redirect, from: from), url
      end

      # A pin this attempt was never answered, or another attempt's.
      other = AttemptFixtures.attached!()
      assert {:ok, %PinnedTarget{id: others}} = pin(other, "https://api.example.test/a", :fetch)

      for id <- ["pin_unknown", others] do
        assert {:error, :redirect_credentials} =
                 pin(fixture, "https://api.example.test/b", :redirect, from: id)
      end

      # One remembered past its own expiry, while its request may still be
      # answered, and no longer after that.
      assert {:ok, _pin} =
               pin(fixture, "https://api.example.test/c", :redirect,
                 from: from,
                 now: now() + @window + 1
               )

      assert {:error, :redirect_credentials} =
               pin(fixture, "https://api.example.test/c", :redirect,
                 from: from,
                 now: now() + 3 * @window
               )
    end
  end

  describe "a refusal" do
    test "is recorded as a denial of the attempt's component, naming its host and never its URL" do
      fixture = AttemptFixtures.attached!()
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/", :fetch)

      assert {:error, :denied} = pin(fixture, "http://10.0.0.5/a?token=sk-denied", :fetch)
      assert {:error, :metadata} = pin(fixture, "http://169.254.169.254/b?token=sk-meta", :fetch)

      assert {:error, :resolution} =
               pin(fixture, "https://nothing.example.invalid/c?token=sk-dns", :fetch)

      assert {:error, :redirect_credentials} =
               pin(fixture, "https://login.other.test/d?token=sk-hop", :redirect, from: from)

      rows = denials(fixture)
      assert length(rows) == 4

      for row <- rows do
        assert row.event_type == "denied" and row.decision == "denied"
        assert row.athanor_id == fixture.athanor_id
        refute row.decision_reason =~ "sk-"
        refute row.decision_reason =~ "?"
      end

      reasons = Enum.map_join(rows, "\n", & &1.decision_reason)

      for host <- ~w(10.0.0.5 169.254.169.254 nothing.example.invalid login.other.test),
          do: assert(reasons =~ host)
    end

    test "is lost for an attempt its caller does not hold, with nothing resolved or recorded" do
      fixture = AttemptFixtures.attached!()
      caller = %{AttemptFixtures.caller(fixture) | runner: "runner_other"}

      assert {:error, :lost} = pin(fixture, "http://10.0.0.5/", :fetch, caller: caller)
      assert Resolver.looked_up() == []
      assert denials(fixture) == []
      assert Process.alive?(fixture.pid)
    end

    test "of args that do not read is malformed through the host, and records nothing" do
      fixture = AttemptFixtures.attached!()

      for args <- [
            %{"url" => "ftp://api.example.test/", "purpose" => "fetch"},
            %{"url" => "https://api.example.test/", "purpose" => "redirect"},
            %{"url" => "https://api.example.test/", "purpose" => "fetch", "from" => "pin_x"},
            %{"url" => "https://api.example.test/", "purpose" => "post"}
          ] do
        assert %{"v" => 1, "error" => "malformed"} =
                 AttemptFixtures.call(fixture, "egress_pin", args),
               inspect(args)
      end

      assert denials(fixture) == []
    end
  end
end
