# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Flow do
  @moduledoc """
  Declared flows: which source classes (`Prima.Source`) a component lets
  reach which of its exits, and the one decision every send is held to.

  ## Exits

  An exit is where a component's bytes may leave:

    * an egress domain pattern its `caps.egress.domains` declares, or a
      connect origin its `tincture.connect` declares — spelled as declared;
    * `need:<name>`, a credential need its `needs` block declares;
    * `server:<name>`, a tool server the consent binds by name. The
      manifest cannot know an athanor's servers, so the grammar admits any
      well-formed name and the consent keeps only the flows to a server it
      binds.

  ## Flows

  A manifest declares `caps.flows: [{"from": class, "to": exit}]`. `from`
  is one of `Prima.Source.classes/0`, never `unsettled`, which is a
  refusal and no class. A set of flows is sorted by class order, then
  exit, without duplicates, so equal declarations read as one.

  ## The decision

  `uncovered/2` answers the sources of a run's ledger that nothing lets
  reach a request's exit. A source is covered when:

    * a flow names its class and an exit the request reaches: a domain
      flow whose pattern matches the request's host (`Prima.Network.domain_allowed?/2`,
      so a host narrowed under a declared pattern keeps the pattern's
      flows), or a server flow naming the request's server;
    * the run's launch let its class flow (`:launch_classes`, the classes a
      person let flow to every exit of a launched tree);
    * it is an outside source named by the request's own canonical host,
      exactly: bytes that came from a host may go back to it. A wildcard
      pattern never covers by name.

  A ledger that holds nothing is covered whatever the flows, so a grant
  that declares none keeps working until its run reads a source.
  """

  alias Prima.Source

  @typedoc "One declared flow: a source class and the exit it may reach."
  @type t :: %{from: Source.class(), to: String.t()}

  @typedoc "The exit a request reaches."
  @type exit ::
          {:domain, host :: String.t()}
          | {:server, name :: String.t()}

  @typedoc "What the manifest declares a flow's `to` may name."
  @type declared :: %{
          optional(:domains) => [String.t()],
          optional(:needs) => [String.t()]
        }

  @class_order Source.classes() |> Enum.with_index() |> Map.new()
  @by_spelling Map.new(Source.classes(), &{Atom.to_string(&1), &1})
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/

  @doc """
  The flows of a manifest's `caps.flows` (string keys) or a stored edge's
  (`"from"`, `"to"`), read and held to the grammar: `{:ok, flows}` as a
  set, or `{:error, reason}` naming the first entry that does not read.
  `declared` names the exits the manifest declares (`:domains`, its
  egress domains and connect origins; `:needs`, its need names); pass
  `:any` to check the grammar alone, as a stored edge's flows were
  checked when their consent committed.
  """
  @spec parse(term(), declared() | :any) :: {:ok, [t()]} | {:error, term()}
  def parse(nil, _declared), do: {:ok, []}

  def parse(raw, declared) when is_list(raw) do
    raw
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry, declared) do
        {:ok, flow} -> {:cont, {:ok, [flow | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, flows} -> {:ok, set(flows)}
      error -> error
    end
  end

  def parse(other, _declared), do: {:error, {:flows_not_a_list, other}}

  defp entry(%{} = entry, declared) do
    with :ok <- only_keys(entry),
         {:ok, class} <- class(Map.get(entry, "from")),
         {:ok, to} <- to(Map.get(entry, "to"), declared) do
      {:ok, %{from: class, to: to}}
    end
  end

  defp entry(other, _declared), do: {:error, {:flow_not_an_object, other}}

  defp only_keys(entry) do
    case Map.keys(entry) -- ["from", "to"] do
      [] -> :ok
      unknown -> {:error, {:unknown_flow_keys, Enum.sort(unknown)}}
    end
  end

  defp class(spelling) when is_binary(spelling) do
    case Map.fetch(@by_spelling, spelling) do
      {:ok, class} -> {:ok, class}
      :error -> {:error, {:unknown_flow_class, spelling}}
    end
  end

  defp class(other), do: {:error, {:unknown_flow_class, other}}

  defp to("need:" <> name = exit, declared) do
    cond do
      not Regex.match?(@name, name) -> {:error, {:malformed_flow_exit, exit}}
      declared == :any or name in Map.get(declared, :needs, []) -> {:ok, exit}
      true -> {:error, {:undeclared_flow_exit, exit}}
    end
  end

  defp to("server:" <> name = exit, _declared) do
    if Regex.match?(@name, name), do: {:ok, exit}, else: {:error, {:malformed_flow_exit, exit}}
  end

  defp to(domain, declared) when is_binary(domain) and domain != "" do
    if declared == :any or domain in Map.get(declared, :domains, []),
      do: {:ok, domain},
      else: {:error, {:undeclared_flow_exit, domain}}
  end

  defp to(other, _declared), do: {:error, {:malformed_flow_exit, other}}

  @doc "A list of flows as a set: sorted by class order, then exit, without duplicates."
  @spec set([t()]) :: [t()]
  def set(flows) when is_list(flows) do
    flows
    |> Enum.uniq_by(&{&1.from, &1.to})
    |> Enum.sort_by(&{Map.fetch!(@class_order, &1.from), &1.to})
  end

  @doc "A set of flows as its canonical JSON list."
  @spec to_json([t()]) :: [%{String.t() => String.t()}]
  def to_json(flows) when is_list(flows),
    do: flows |> set() |> Enum.map(&%{"from" => Atom.to_string(&1.from), "to" => &1.to})

  @doc "The exits a set of flows names, sorted, without duplicates."
  @spec exits([t()]) :: [String.t()]
  def exits(flows) when is_list(flows),
    do: flows |> Enum.map(& &1.to) |> Enum.uniq() |> Enum.sort()

  @doc """
  The classes a set of flows lets reach `exit`, as a send to it is
  decided (`uncovered/3`), a frame's data route admits a read for its
  connect origin and the consent preview shows the exit's flows: a flow
  naming the exit as spelled, and, for a domain, a flow whose pattern
  the domain lies under — a host narrowed within a declared pattern
  inherits the pattern's flows. In class order.
  """
  @spec classes_reaching([t()], String.t()) :: [Source.class()]
  def classes_reaching(flows, exit) when is_list(flows) and is_binary(exit) do
    reached = exit_of(exit)

    for %{from: class, to: to} <- set(flows),
        to == exit or (reached != nil and reaches?(to, reached)),
        uniq: true,
        do: class
  end

  defp exit_of("need:" <> _name), do: nil
  defp exit_of("server:" <> name), do: {:server, name}
  defp exit_of(domain), do: {:domain, domain}

  @doc """
  The flows of `flows` a consent keeps for the exits its edge binds: a
  domain flow while one of the edge's `domains` is its pattern or lies
  under it (a domain narrowed within a declared pattern keeps the
  pattern's flows), a need flow while its need is among `needs`, and a
  server flow while its server is among `servers`.
  """
  @spec bound([t()], %{domains: [String.t()], needs: [String.t()], servers: [String.t()]}) ::
          [t()]
  def bound(flows, %{domains: domains, needs: needs, servers: servers}) do
    flows
    |> Enum.filter(fn
      %{to: "need:" <> name} ->
        name in needs

      %{to: "server:" <> name} ->
        name in servers

      %{to: pattern} ->
        Enum.any?(domains, &(&1 == pattern or Prima.Network.domain_allowed?(&1, [pattern])))
    end)
    |> set()
  end

  @doc """
  The sources of `ledger` that reach `exit` with no flow, launch or own
  host to cover them (see the moduledoc), in `Prima.Source.set/1` order;
  empty when the send may go. `opts`: `:flows` (the edge's), and
  `:launch_classes` (the classes the run's launch let flow everywhere).
  """
  @spec uncovered([Source.t()], exit(), keyword()) :: [Source.t()]
  def uncovered(ledger, exit, opts \\ []) when is_list(ledger) do
    flows = Keyword.get(opts, :flows, [])
    launch = Keyword.get(opts, :launch_classes, [])

    ledger
    |> Source.set()
    |> Enum.reject(fn source ->
      source.class in launch or own_host?(source, exit) or
        Enum.any?(flows, &(&1.from == source.class and reaches?(&1.to, exit)))
    end)
  end

  defp own_host?(%Source{class: :outside, name: name}, {:domain, host})
       when is_binary(name),
       do: name == host

  defp own_host?(_source, _exit), do: false

  defp reaches?("need:" <> _name, _exit), do: false
  defp reaches?("server:" <> name, {:server, server}), do: name == server
  defp reaches?("server:" <> _name, _exit), do: false
  defp reaches?(pattern, {:domain, host}), do: Prima.Network.domain_allowed?(host, [pattern])
  defp reaches?(_pattern, _exit), do: false

  @doc """
  The refusal a send refused for want of a flow answers
  (`Prima.Refusal`'s `:flow_not_declared` row): the classes that had no
  flow and the exit, by host or server, never a URL, a path or a value.
  """
  @spec refusal([Source.t()], exit()) ::
          {:flow_not_declared, [Source.class()], String.t()}
  def refusal(uncovered, exit) when is_list(uncovered),
    do: {:flow_not_declared, Source.classes_of(uncovered), exit_name(exit)}

  @doc "The sentence `refusal/2`'s reason reads as."
  @spec sentence([Source.class()], String.t()) :: String.t()
  def sentence(classes, exit) when is_list(classes) and is_binary(exit) do
    "This run read #{Enum.map_join(classes, ", ", &Atom.to_string/1)} material, and its " <>
      "grant declares no flow of it to #{exit}"
  end

  defp exit_name({:domain, host}), do: host
  defp exit_name({:server, name}), do: "server:" <> name
end
