# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentPreview do
  @moduledoc """
  What a consent preview answers: typed rows, one per resource an edge
  grants, the origins the grant admits and the commit digest that binds
  them. It carries no sentence; every surface renders the rows in its own
  words, and a surface never hides a row kind.
  `tests/fixtures/consent_preview.json` holds its vectors.

  The document is `{"v": 1, "rows": [...], "origins": [...],
  "commit_digest": "sha256:...", "removed": [...]}`: `origins` a non-empty
  list of `Prima.Origin` spellings, answered in the enum's order, and
  `removed` the bindings the profile's head holds that the revision
  removes (below). Each row
  (`Prima.ConsentPreview.Row`) is `{"kind", "node", "values", "narrowed"}`:
  the resource kind, the consent graph node (the component) it belongs to,
  its values, and whether the person's decision narrowed the ask. The kinds
  and their values:

    * `credential` — one binding: `name`, the entry's display name;
      `fields` and `scopes`, its projection; `edge`, the consent edge it
      rides, from the row's node to the node that uses the entry:
      `"@ingress"` for the node's own key, otherwise the dependency's
      name-level ref, spelled `ref|need` for a named need
      (`Prima.Authority.Blob.edge_key/2`); `label`, when it is lent by a
      profile of that label; `provider`, the entry's provider hint,
      absent when it has none; `destination`, where its material may go,
      as `Prima.Destination.to_map/1` writes it; `source`, `own` for the
      athanor's entry, `instance` for an instance entry, `provided` for a
      publisher's provided configuration; `disclosed`, whether the
      component may read the value itself; `suggested`, whether the plan
      chose it; `choice_required`, whether the person must choose;
      `connection`, the account name, present exactly for a named
      binding; `binding_key`, the binding's own key, the row's node, its
      edge and its slot (`Prima.Authority.Blob.binding_key/3`); and
      `lifetime`, `{"kind": standing | until | once, "until": ...}`,
      `until` an RFC 3339 UTC time for an `until` binding and null
      otherwise. One row per binding, so one entry lent on two edges, or
      bound under two names, is two rows.
    * `egress` — `domains`, `methods`, `schemes`, `private_ips`.
    * `storage` — `paths`, `actions`.
    * `tools` — `tools`, the expanded `tool.action` names, or `["*"]`
      alone when the ask names every tool and the grant is the whole ask.
    * `tool_servers` — `name`, `digest`, `tool_patterns`. One row per server.
    * `limits` — the seven fields of `Prima.Limits`, as `Prima.Limits.to_map/1` writes them.
    * `frame` — a tincture's `capabilities`, `placement` (absent for the
      shell's default) and `background`.
    * `streams` — `name` and `subject` (a literal, `"*"`, or absent). One
      row per stream and subject, so one stream declared under two
      subjects is two rows.
    * `cards` — `name`, and the `component`, `operation` and `args` its
      data comes from, all three or, for a static card, none. One row per card.
    * `system_actions` — `actions`, the `tool.action` names.

  Only `egress`, `storage`, `tools` and `limits` can be narrowed
  (`narrowable_kinds/0`); a row of another kind is granted whole or not at
  all and is never marked narrowed, and neither is a wildcard tools row,
  which is the whole ask. Lists of names are sets: no name twice, and at
  most 256. A kind outside these ten is refused, and so is a field a kind
  does not carry.

  ## Removed bindings

  `removed` lists each binding of the profile's head that the revision
  drops, and is empty when there is none: a binding whose key the
  revision no longer binds, or binds for another need. Each item is one
  binding as the head's row holds it: its `binding_key`, the `node` and
  `edge` it sits on (spelled as a credential row's) and, for a named
  account, its `connection`, the key naming exactly these
  (`Prima.Authority.Blob.binding_key/3`); `need`, the need it was bound
  for, null when that cannot be told; exactly one of `entry_id`,
  `instance_entry_id` and `via` (the label of the profile that lent it);
  and the entry's `name` and `source` (`own` or `instance`), each absent
  when the entry cannot be read. Items are sorted by `binding_key`, each
  key once. Anything else is `{:invalid_field, "removed"}`
  (`check_removed/1`).
  """

  alias Prima.ConsentPreview.Row
  alias Prima.Identity.Encoding
  alias Prima.Origin

  @version 1
  @kinds [
    :credential,
    :egress,
    :storage,
    :tools,
    :tool_servers,
    :limits,
    :frame,
    :streams,
    :cards,
    :system_actions
  ]
  @narrowable [:egress, :storage, :tools, :limits]

  @type kind ::
          :credential
          | :egress
          | :storage
          | :tools
          | :tool_servers
          | :limits
          | :frame
          | :streams
          | :cards
          | :system_actions

  @typedoc "A removed binding in its JSON form (`check_removed/1`)."
  @type removed :: %{required(String.t()) => String.t() | nil}

  @type t :: %__MODULE__{
          rows: [Row.t()],
          origins: [Origin.t(), ...],
          commit_digest: String.t(),
          removed: [removed()]
        }

  @type reason ::
          Encoding.reason()
          | :unsupported_version
          | {:unknown_kind, term()}
          | {:not_narrowable, kind()}
          | :duplicate_row
          | :empty_origins
          | :duplicate_origin
          | {:unknown_origin, term()}

  @enforce_keys [:rows, :origins, :commit_digest, :removed]
  defstruct [:rows, :origins, :commit_digest, :removed]

  @doc "The document's version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The ten row kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kinds a decision may narrow."
  @spec narrowable_kinds() :: [kind()]
  def narrowable_kinds, do: @narrowable

  @doc "Read a preview from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, ~w(v rows origins commit_digest removed), []),
         :ok <- version(map["v"]),
         {:ok, rows} <- rows(map["rows"]),
         {:ok, origins} <- Origin.parse_list(map["origins"]),
         {:ok, digest} <- Encoding.check(map, "commit_digest", &Encoding.digest?/1),
         {:ok, removed} <- check_removed(map["removed"]) do
      {:ok, %__MODULE__{rows: rows, origins: origins, commit_digest: digest, removed: removed}}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "preview"}}

  @doc """
  A preview from its rows, admitted origins, commit digest and removed
  bindings, held to the same shape.
  """
  @spec new([Row.t()], [Origin.t()], String.t(), [removed()]) :: {:ok, t()} | {:error, reason()}
  def new(rows, origins, commit_digest, removed)
      when is_list(rows) and is_list(origins) and is_list(removed) do
    decode(%{
      "v" => @version,
      "rows" => Enum.map(rows, &Row.encode/1),
      "origins" => Enum.map(origins, &to_string/1),
      "commit_digest" => commit_digest,
      "removed" => removed
    })
  end

  @doc """
  A preview's `removed` list held to its shape ("Removed bindings" above):
  each item one binding of the head, the list sorted by `binding_key`
  with no key twice. Answers the list as given, or
  `{:error, {:invalid_field, "removed"}}`.
  """
  @spec check_removed(term()) :: {:ok, [removed()]} | {:error, reason()}
  def check_removed(items) when is_list(items) do
    if Enum.all?(items, &removed_item?/1) and ascending?(Enum.map(items, & &1["binding_key"])),
      do: {:ok, items},
      else: {:error, {:invalid_field, "removed"}}
  end

  def check_removed(_items), do: {:error, {:invalid_field, "removed"}}

  @doc "The JSON map of a preview."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = preview) do
    %{
      "v" => @version,
      "rows" => Enum.map(preview.rows, &Row.encode/1),
      "origins" => Origin.to_wire_list(preview.origins),
      "commit_digest" => preview.commit_digest,
      "removed" => preview.removed
    }
  end

  @removed_fields ~w(binding_key node edge need)
  @removed_optional ~w(connection entry_id instance_entry_id via name source)
  @removed_identities ~w(entry_id instance_entry_id via)
  @removed_sources ~w(own instance)

  # One binding of the head: its key spells its node, its edge (in a
  # credential row's grammar) and its slot; its need is a name or null;
  # what it bound is named by exactly one of an entry, an instance entry
  # and a lender's label; the entry's name and source are there only when
  # the entry was read.
  defp removed_item?(item) when is_map(item) and not is_struct(item) do
    Encoding.fields(item, @removed_fields, @removed_optional) == :ok and
      Row.text?(item["binding_key"]) and Row.text?(item["node"]) and Row.edge?(item["edge"]) and
      (is_nil(item["need"]) or Row.text?(item["need"])) and
      present?(item, "connection", &Prima.Authority.Blob.valid_account_name?/1) and
      item["binding_key"] ==
        Prima.Authority.Blob.binding_key(item["node"], item["edge"], item["connection"]) and
      Enum.count(@removed_identities, &Map.has_key?(item, &1)) == 1 and
      Enum.all?(["name" | @removed_identities], &present?(item, &1, fn v -> Row.text?(v) end)) and
      present?(item, "source", &(&1 in @removed_sources))
  end

  defp removed_item?(_item), do: false

  # A field the item may leave out, held to `valid?` when it is there.
  defp present?(item, field, valid?), do: not Map.has_key?(item, field) or valid?.(item[field])

  # Sorted, and no key twice.
  defp ascending?(keys) do
    keys
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a < b end)
  end

  defp version(@version), do: :ok
  defp version(_other), do: {:error, :unsupported_version}

  defp rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, acc, seen} ->
      with {:ok, row} <- Row.decode(raw),
           key = Row.identity(row),
           false <- MapSet.member?(seen, key) do
        {:cont, {:ok, [row | acc], MapSet.put(seen, key)}}
      else
        true -> {:halt, {:error, :duplicate_row}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _seen} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp rows(_rows), do: {:error, {:invalid_field, "rows"}}
end

defmodule Prima.ConsentPreview.Row do
  @moduledoc """
  One row of a consent preview: its `kind`, its `node`, its `values` (the
  kind's closed record, kept in its JSON form) and whether the ask was
  `narrowed`. `Prima.ConsentPreview` lists the kinds and their values.
  """

  alias Prima.Identity.Encoding
  alias Prima.Manifest.Tincture

  @kinds %{
    "credential" => :credential,
    "egress" => :egress,
    "storage" => :storage,
    "tools" => :tools,
    "tool_servers" => :tool_servers,
    "limits" => :limits,
    "frame" => :frame,
    "streams" => :streams,
    "cards" => :cards,
    "system_actions" => :system_actions
  }
  @narrowable [:egress, :storage, :tools, :limits]
  @one_per_node [:egress, :storage, :tools, :limits, :frame, :system_actions]
  @max_text 1024
  @max_set 256
  @max_args_bytes 4096
  @wildcard "*"
  @sources ~w(own instance provided)
  @lifetimes ~w(standing until once)

  @type t :: %__MODULE__{
          kind: Prima.ConsentPreview.kind(),
          node: String.t(),
          values: map(),
          narrowed: boolean()
        }

  @enforce_keys [:kind, :node, :values, :narrowed]
  defstruct [:kind, :node, :values, :narrowed]

  @doc "Read a row from its JSON map."
  @spec decode(term()) :: {:ok, t()} | {:error, Prima.ConsentPreview.reason()}
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, ~w(kind node values narrowed), []),
         {:ok, kind} <- kind(map["kind"]),
         {:ok, node} <- Encoding.check(map, "node", &Encoding.text?(&1, @max_text)),
         {:ok, narrowed} <- Encoding.check(map, "narrowed", &is_boolean/1),
         :ok <- narrowable(kind, narrowed),
         {:ok, values} <- values(kind, map["values"], node),
         :ok <- whole_ask(kind, values, narrowed) do
      {:ok, %__MODULE__{kind: kind, node: node, values: values, narrowed: narrowed}}
    end
  end

  def decode(_value), do: {:error, {:invalid_field, "row"}}

  @doc "The JSON map of a row."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = row) do
    %{
      "kind" => Atom.to_string(row.kind),
      "node" => row.node,
      "values" => row.values,
      "narrowed" => row.narrowed
    }
  end

  @doc """
  What makes a row one of a kind: its kind and node, and for a kind with
  one row per resource, the resource's name too, with the subject a
  stream names; a credential is its binding's key. A preview holds each
  once.
  """
  @spec identity(t()) :: tuple()
  def identity(%__MODULE__{kind: kind, node: node}) when kind in @one_per_node, do: {kind, node}

  def identity(%__MODULE__{kind: :credential, node: node, values: values}),
    do: {:credential, node, values["binding_key"]}

  def identity(%__MODULE__{kind: :streams, node: node, values: values}),
    do: {:streams, node, values["name"], values["subject"]}

  def identity(%__MODULE__{kind: kind, node: node, values: values}),
    do: {kind, node, values["name"]}

  @doc "The tools a wildcard row names: every tool, as the grant states it."
  @spec wildcard() :: [String.t()]
  def wildcard, do: [@wildcard]

  @doc "The sources a credential row names."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The lifetimes a credential row's binding may have."
  @spec lifetimes() :: [String.t()]
  def lifetimes, do: @lifetimes

  defp kind(name) do
    case Map.fetch(@kinds, name) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:unknown_kind, name}}
    end
  end

  defp narrowable(kind, true) when kind not in @narrowable, do: {:error, {:not_narrowable, kind}}
  defp narrowable(_kind, _narrowed), do: :ok

  # A wildcard tools row is the whole ask, which a narrowing never is.
  defp whole_ask(:tools, %{"tools" => [@wildcard]}, true), do: {:error, {:invalid_field, "tools"}}
  defp whole_ask(_kind, _values, _narrowed), do: :ok

  defp values(kind, values, node) when is_map(values) and not is_struct(values) do
    {required, optional, checks} = spec(kind)

    with :ok <- Encoding.fields(values, required, optional),
         :ok <- each(values, checks),
         :ok <- whole(kind, values),
         :ok <- placed(kind, values, node) do
      {:ok, values}
    end
  end

  defp values(_kind, _values, _node), do: {:error, {:invalid_field, "values"}}

  # {required fields, optional fields, a check per field}
  defp spec(:credential),
    do:
      {~w(name fields scopes edge destination source disclosed suggested choice_required
          binding_key lifetime), ~w(label provider connection),
       %{
         "name" => &text?/1,
         "fields" => &set?/1,
         "scopes" => &set?/1,
         "edge" => &edge?/1,
         "label" => &text?/1,
         "provider" => &text?/1,
         "destination" => &destination?/1,
         "source" => &(&1 in @sources),
         "disclosed" => &is_boolean/1,
         "suggested" => &is_boolean/1,
         "choice_required" => &is_boolean/1,
         "connection" => &Prima.Authority.Blob.valid_account_name?/1,
         "binding_key" => &text?/1,
         "lifetime" => &lifetime?/1
       }}

  defp spec(:egress) do
    fields = ~w(domains methods schemes private_ips)
    {fields, [], Map.new(fields, fn field -> {field, &set?/1} end)}
  end

  defp spec(:storage), do: {~w(paths actions), [], %{"paths" => &set?/1, "actions" => &set?/1}}
  defp spec(:tools), do: {~w(tools), [], %{"tools" => &tools?/1}}

  defp spec(:tool_servers),
    do:
      {~w(name digest tool_patterns), [],
       %{"name" => &text?/1, "digest" => &Encoding.digest?/1, "tool_patterns" => &set?/1}}

  defp spec(:limits) do
    fields = Enum.map(Prima.Limits.fields(), &Atom.to_string/1)
    {fields, [], %{}}
  end

  defp spec(:frame),
    do:
      {~w(capabilities background), ~w(placement),
       %{"capabilities" => &set?/1, "background" => &is_boolean/1, "placement" => &text?/1}}

  defp spec(:streams),
    do: {~w(name), ~w(subject), %{"name" => &Tincture.stream_name?/1, "subject" => &subject?/1}}

  defp spec(:cards),
    do:
      {~w(name), ~w(component operation args),
       %{"name" => &text?/1, "component" => &text?/1, "operation" => &text?/1, "args" => &args?/1}}

  defp spec(:system_actions), do: {~w(actions), [], %{"actions" => &operations?/1}}

  defp each(values, checks) do
    fields = values |> Map.keys() |> Enum.sort()

    case Enum.find_index(fields, fn field ->
           Map.has_key?(checks, field) and not checks[field].(values[field])
         end) do
      nil -> :ok
      index -> {:error, {:invalid_field, Enum.at(fields, index)}}
    end
  end

  defp whole(:limits, values) do
    case Prima.Limits.new(values) do
      {:ok, _limits} -> :ok
      {:error, {:invalid_limit, field, _why}} -> {:error, {:invalid_field, to_string(field)}}
    end
  end

  # A card's data comes from one source, named whole, or it is static.
  defp whole(:cards, values) do
    case Enum.count(~w(component operation args), &Map.has_key?(values, &1)) do
      count when count in [0, 3] -> :ok
      _partial -> {:error, {:invalid_field, "component"}}
    end
  end

  defp whole(_kind, _values), do: :ok

  # A credential row is one binding where it sits: its key names the row's
  # node, its edge and its slot, `name:<connection>` exactly when the row
  # names an account and `default` otherwise.
  defp placed(:credential, values, node) do
    slot = values["connection"]

    if values["binding_key"] == Prima.Authority.Blob.binding_key(node, values["edge"], slot),
      do: :ok,
      else: {:error, {:invalid_field, "binding_key"}}
  end

  defp placed(_kind, _values, _node), do: :ok

  # The canonical spelling alone, so one destination is one row value.
  defp destination?(value) do
    case Prima.Destination.from_map(value) do
      {:ok, destination} -> Prima.Destination.to_map(destination) == value
      {:error, _reason} -> false
    end
  end

  defp lifetime?(%{"kind" => kind, "until" => until} = lifetime) when map_size(lifetime) == 2 do
    case kind do
      "until" -> utc?(until)
      kind when kind in @lifetimes -> until == nil
      _other -> false
    end
  end

  defp lifetime?(_lifetime), do: false

  # An RFC 3339 instant in UTC, spelled with `Z`.
  defp utc?(value) when is_binary(value) do
    String.ends_with?(value, "Z") and match?({:ok, _instant, 0}, DateTime.from_iso8601(value))
  end

  defp utc?(_value), do: false

  @doc false
  # A row's text value; a removed binding's text fields are held to it too.
  @spec text?(term()) :: boolean()
  def text?(value), do: Encoding.text?(value, @max_text)

  defp set?(values) do
    is_list(values) and length(values) <= @max_set and Enum.all?(values, &text?/1) and
      length(Enum.uniq(values)) == length(values)
  end

  defp operations?(values), do: set?(values) and Enum.all?(values, &Tincture.operation_name?/1)

  # The wildcard stands alone: beside a named tool it would read as both
  # every tool and a list of some.
  defp tools?([@wildcard]), do: true
  defp tools?(values), do: set?(values) and @wildcard not in values

  @doc false
  # The edge a credential rides, spelled as the blob keys it: the ingress
  # literal, or a name-level ref with an optional named need. A removed
  # binding's edge is held to it too.
  @spec edge?(term()) :: boolean()
  def edge?("@ingress"), do: true

  def edge?(edge) when is_binary(edge) do
    text?(edge) and
      case String.split(edge, "|", parts: 2) do
        [ref] -> name_level?(ref)
        [ref, need] -> name_level?(ref) and need != "" and not String.contains?(need, "|")
      end
  end

  def edge?(_edge), do: false

  defp name_level?(ref),
    do: match?({:ok, %Prima.ComponentRef{version: nil}}, Prima.ComponentRef.parse(ref))

  defp subject?("*"), do: true
  defp subject?(subject), do: Tincture.literal_subject?(subject)

  defp args?(args) when is_map(args) do
    case Encoding.jcs(args) do
      {:ok, bytes} -> byte_size(bytes) <= @max_args_bytes
      {:error, _reason} -> false
    end
  end

  defp args?(_args), do: false
end
