# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.EgressTest do
  @moduledoc """
  A guest's outbound target is pinned by CYFR under the calling attempt's
  admitted authority (`Crucible.Host.Egress`), in this order: the host
  matched against the stored authority edge's `egress.domains`, denied
  without an edge; a redirect refused unless it names a pin the attempt
  holds and keeps that pin's scheme, host and port; only then the host
  resolved once, IPv4 first and IPv6 only when no IPv4 address resolves,
  so a refused host is never looked up; a metadata address refused
  whatever the policy grants; and a private address refused unless the
  edge grants it. Every `egress_pin_cases` and
  `egress_policy_cases` vector of `tests/fixtures/host_api.json` is
  answered as it names, and every refusal is recorded as a denial of the
  attempt's component.

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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

  # An authority whose edge's egress allows `domains` and grants the
  # private addresses `private_ips`.
  defp egress(domains, private_ips) do
    %{
      Authority.zero()
      | resources: %Edge{
          egress: %{domains: domains, methods: [], schemes: [], private_ips: private_ips}
        }
    }
  end

  defp attached!(domains, private_ips \\ []),
    do: AttemptFixtures.attached!(authority: egress(domains, private_ips))

  defp now, do: System.system_time(:millisecond)

  describe "the egress_pin cases of tests/fixtures/host_api.json" do
    test "each is pinned or refused as it names under an edge allowing every host" do
      assert Enum.map(@vectors["egress_pin_cases"], & &1["name"]) ==
               ~w(fetch stream redirect denied metadata resolution redirect_credentials)

      # The addresses the vectors answer: the fetch's, then the redirect's
      # hop to the same host.
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}, {203, 0, 113, 11}])
      Resolver.script("login.other.test", :inet, [{203, 0, 113, 50}])

      fixture = attached!(["*"])
      run_cases(fixture, @vectors["egress_pin_cases"])

      # The hop to another origin was refused before its host was resolved.
      refute Enum.any?(Resolver.looked_up(), fn {host, _family} -> host == "login.other.test" end)

      assert fixture |> denials() |> Enum.map(& &1.decision) == List.duplicate("denied", 4)
    end
  end

  describe "the egress_policy_cases of tests/fixtures/host_api.json" do
    test "each is pinned or refused as it names, in order, under the edge's domains" do
      cases = @vectors["egress_policy_cases"]

      assert Enum.map(cases, & &1["name"]) ==
               ~w(fetch outside_domains redirect_other_port redirect_default_port
                  redirect_strip_credentials fetch_ipv6 redirect_ipv6_spelling)

      [domains] = cases |> Enum.map(& &1["domains"]) |> Enum.uniq()

      # The fetch's address, then the one every later hop to the same host
      # is answered. The hosts the cases refuse resolve to nothing, and are
      # never asked for.
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}, {203, 0, 113, 11}])

      fixture = attached!(domains)
      pins = run_cases(fixture, cases)

      # A first fetch outside the domains, and a hop to another origin,
      # were refused before their hosts were resolved.
      looked_up = Enum.map(Resolver.looked_up(), fn {host, _family} -> host end)
      refute "outside.example.org" in looked_up
      refute "static.cdn.example.test" in looked_up

      # `expect` is what the decision was made of: the host against the
      # domains, and a redirect's URL against the URL of the pin it names.
      urls = Map.new(cases, fn vector -> {vector["name"], args(vector)["url"]} end)
      pin_urls = Map.new(pins, fn {vector_id, {name, _minted}} -> {vector_id, urls[name]} end)

      for vector <- cases do
        %{"url" => url} = args = args(vector)
        expect = vector["expect"]

        assert expect["domain_allowed"] ==
                 Prima.Network.domain_allowed?(URI.parse(url).host, domains),
               vector["name"]

        if from = args["from"] do
          assert expect["same_origin"] == Prima.Network.same_origin?(url, pin_urls[from]),
                 vector["name"]
        end
      end

      assert fixture |> denials() |> Enum.map(& &1.decision) == List.duplicate("denied", 3)
    end
  end

  # Drive a section's cases in order, each redirect's `from` bound to the
  # pin this attempt was answered for the vector's pin of that id, and
  # each answer compared with the vector's, the pin's minted id and its
  # expiry aside. Answers the vector's pin ids, each with the name of the
  # case it answered and the id minted for it.
  defp run_cases(fixture, cases) do
    Enum.reduce(cases, %{}, fn vector, pins ->
      args = args(vector)

      args =
        case args do
          %{"from" => from} -> %{args | "from" => pins |> Map.fetch!(from) |> elem(1)}
          args -> args
        end

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
          Map.put(pins, wire["id"], {vector["name"], pin.id})

        {:error, name, %{}} ->
          assert {:error, String.to_existing_atom(name)} == answer, vector["name"]
          pins
      end
    end)
  end

  defp args(vector) do
    %{"v" => 1, "op" => "egress_pin", "args" => args} = Jason.decode!(vector["body"])
    args
  end

  describe "the address" do
    test "is resolved IPv4 first, and IPv6 only when no IPv4 address resolves" do
      fixture = attached!(["*"])

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
      granted = attached!(["*"], ["10.0.0.0/8"])

      assert {:ok, %PinnedTarget{ip: "10.0.0.5", family: 4}} =
               pin(granted, "http://private.test/admin", :fetch, resolver: Sanctum.Test.Resolver)

      assert {:error, :denied} = pin(granted, "http://192.168.1.10/", :fetch)

      # An edge allowing every host grants no private address it does not name.
      public_only = attached!(["*"])
      assert {:error, :denied} = pin(public_only, "http://10.0.0.5/", :fetch)
      assert {:ok, %PinnedTarget{}} = pin(public_only, "https://203.0.113.10/", :fetch)
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

      fixture = attached!(["*"])

      assert {:error, :denied} =
               pin(fixture, "http://private.test/", :fetch, resolver: Sanctum.Test.Resolver)

      assert {:error, :denied} = pin(fixture, "http://10.0.0.5/", :fetch)
    end

    test "at a metadata address is refused before any policy, whatever the edge grants" do
      fixture = attached!(["*"], ["169.254.0.0/16", "fe80::/10"])

      assert {:error, :metadata} = pin(fixture, "http://169.254.169.254/latest/", :fetch)

      assert {:error, :metadata} =
               pin(fixture, "http://metadata.test/", :fetch, resolver: Sanctum.Test.Resolver)

      assert [_, _] = denials(fixture)
    end
  end

  describe "the host" do
    test "is pinned only where the edge's egress domains allow it" do
      fixture = attached!(["public.test", "*.example.test"])
      resolver = [resolver: Sanctum.Test.Resolver]

      assert {:ok, %PinnedTarget{host: "public.test"}} =
               pin(fixture, "https://public.test/", :fetch, resolver)

      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("api.example.test.evil.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("dual.test", :inet, [{203, 0, 113, 20}])

      # Matched case-folded.
      for url <- ["https://api.example.test/", "https://API.Example.TEST/"] do
        assert {:ok, %PinnedTarget{host: "api.example.test"}} = pin(fixture, url, :fetch), url
      end

      # The wildcard names every name below its base, and neither the base
      # itself nor a name that only contains it.
      for url <- ["https://example.test/", "https://api.example.test.evil.test/"] do
        assert {:error, :denied} = pin(fixture, url, :fetch), url
      end

      # A name outside the domains, and an IPv6 literal the domains do not
      # spell.
      assert {:error, :denied} = pin(fixture, "https://dual.test/", :fetch)
      assert {:error, :denied} = pin(fixture, "http://[2001:db8::20]:8080/", :stream)

      # No name the domains refuse was looked up.
      looked_up = Enum.map(Resolver.looked_up(), fn {host, _family} -> host end)

      for host <- ~w(example.test api.example.test.evil.test dual.test 2001:db8::20),
          do: refute(host in looked_up, host)

      rows = denials(fixture)
      assert length(rows) == 4
      assert Enum.any?(rows, &(&1.decision_reason =~ "[2001:db8::20]"))
    end

    test "is denied under an authority with no egress edge, and allowed by \"*\"" do
      for authority <- [
            Authority.zero(),
            %{Authority.zero() | resources: :none},
            %{Authority.zero() | resources: %Edge{}}
          ] do
        fixture = AttemptFixtures.attached!(authority: authority)
        assert {:error, :denied} = pin(fixture, "https://203.0.113.10/", :fetch)
        assert {:error, :denied} = pin(fixture, "http://[2001:db8::20]:8080/", :stream)
        assert [_, _] = denials(fixture)
      end

      assert Resolver.looked_up() == []

      fixture = attached!(["*"])
      assert {:ok, %PinnedTarget{}} = pin(fixture, "https://203.0.113.10/", :fetch)
      assert {:ok, %PinnedTarget{}} = pin(fixture, "http://[2001:db8::20]:8080/", :stream)
    end
  end

  describe "a redirect" do
    test "keeps the pin's credentials only on its own scheme, host and port" do
      fixture = attached!(["*"])
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("other.example.test", :inet, [{203, 0, 113, 12}])

      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/a", :fetch)

      for url <- ["https://API.example.test/b", "https://api.example.test:443/b"] do
        assert {:ok, %PinnedTarget{host: "api.example.test", port: 443}} =
                 pin(fixture, url, :redirect, from: from),
               url
      end

      for url <- [
            "http://api.example.test/b",
            "https://api.example.test:8443/b",
            "https://other.example.test/b"
          ] do
        assert {:error, :redirect_credentials} = pin(fixture, url, :redirect, from: from), url
      end

      # A pin this attempt was never answered, or another attempt's.
      other = attached!(["*"])
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

    test "that its names refuse is never resolved" do
      fixture = attached!(["*.example.test"])
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("other.example.test", :inet, [{203, 0, 113, 12}])
      Resolver.script("outside.example.org", :inet, [{203, 0, 113, 60}])

      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/a", :fetch)

      # Outside the domains, to another origin within them, to another
      # port of the pin's host, and from a pin the attempt does not hold.
      assert {:error, :denied} =
               pin(fixture, "https://outside.example.org/b", :redirect, from: from)

      for {url, from} <- [
            {"https://other.example.test/b", from},
            {"https://api.example.test:8443/b", from},
            {"https://api.example.test/b", "pin_unknown"}
          ] do
        assert {:error, :redirect_credentials} = pin(fixture, url, :redirect, from: from), url
      end

      # The fetch's lookup is the only one.
      assert Resolver.looked_up() == [{"api.example.test", :inet}]
    end

    test "on its pin's origin is still decided on the address it resolves to" do
      fixture = attached!(["api.example.test"])

      Resolver.script("api.example.test", :inet, [
        {203, 0, 113, 10},
        {10, 0, 0, 7},
        {169, 254, 169, 254}
      ])

      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/a", :fetch)

      # A private address the edge does not grant, then a metadata address.
      assert {:error, :denied} = pin(fixture, "https://api.example.test/b", :redirect, from: from)

      assert {:error, :metadata} =
               pin(fixture, "https://api.example.test/c", :redirect, from: from)
    end

    test "across IPv6 spellings of one address is on one origin" do
      fixture = attached!(["2001:db8::20", "2001:0db8:0:0:0:0:0:20"])

      assert {:ok, %PinnedTarget{id: from}} =
               pin(fixture, "http://[2001:db8::20]:8080/events", :stream)

      assert {:ok, %PinnedTarget{host: "[2001:0db8:0:0:0:0:0:20]", port: 8080}} =
               pin(fixture, "http://[2001:0db8:0:0:0:0:0:20]:8080/next", :redirect, from: from)

      assert {:error, :redirect_credentials} =
               pin(fixture, "http://[2001:db8::20]:8081/next", :redirect, from: from)
    end

    test "from a pin remembered under another shape is refused, and the sweep drops it" do
      fixture = attached!(["*"])
      caller = AttemptFixtures.caller(fixture)
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      key = {caller.attempt, "pin_old_shape"}

      true = :ets.insert(Egress, {key, "api.example.test", "https", now() + @window})

      assert {:error, :redirect_credentials} =
               pin(fixture, "https://api.example.test/b", :redirect, from: "pin_old_shape")

      send(Egress.Pins, :sweep)
      :sys.get_state(Egress.Pins)
      assert :ets.lookup(Egress, key) == []
    end
  end

  describe "a refusal" do
    test "is recorded as a denial of the attempt's component, naming its host and never its URL" do
      fixture = attached!(["*.example.test", "10.0.0.5", "169.254.169.254", "*.invalid"])
      Resolver.script("api.example.test", :inet, [{203, 0, 113, 10}])
      Resolver.script("login.other.test", :inet, [{203, 0, 113, 50}])
      assert {:ok, %PinnedTarget{id: from}} = pin(fixture, "https://api.example.test/", :fetch)

      assert {:error, :denied} = pin(fixture, "http://10.0.0.5/a?token=sk-denied", :fetch)
      assert {:error, :metadata} = pin(fixture, "http://169.254.169.254/b?token=sk-meta", :fetch)

      assert {:error, :resolution} =
               pin(fixture, "https://nothing.example.invalid/c?token=sk-dns", :fetch)

      assert {:error, :denied} = pin(fixture, "https://login.other.test/d?token=sk-out", :fetch)

      assert {:error, :redirect_credentials} =
               pin(fixture, "https://api.example.test:8443/e?token=sk-hop", :redirect, from: from)

      rows = denials(fixture)
      assert length(rows) == 5

      for row <- rows do
        assert row.event_type == "denied" and row.decision == "denied"
        assert row.athanor_id == fixture.athanor_id
        refute row.decision_reason =~ "sk-"
        refute row.decision_reason =~ "?"
      end

      reasons = Enum.map_join(rows, "\n", & &1.decision_reason)

      for host <-
            ~w(10.0.0.5 169.254.169.254 nothing.example.invalid login.other.test api.example.test),
          do: assert(reasons =~ host)
    end

    test "is lost for an attempt its caller does not hold, with nothing resolved or recorded" do
      fixture = attached!(["*"])
      caller = %{AttemptFixtures.caller(fixture) | runner: "runner_other"}

      assert {:error, :lost} = pin(fixture, "http://10.0.0.5/", :fetch, caller: caller)
      assert Resolver.looked_up() == []
      assert denials(fixture) == []
      assert Process.alive?(fixture.pid)
    end

    test "of args that do not read is malformed through the host, and records nothing" do
      fixture = attached!(["*"])

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
