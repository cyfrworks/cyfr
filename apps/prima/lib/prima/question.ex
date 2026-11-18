# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Question.Answer do
  @moduledoc """
  What a person chose on a component's question: `effect` (`:allow` or
  `:deny`), how long it `lasts` (`:once`, `{:until, time}` or `:always`)
  and which callers it `covers` (`:any_caller` or `:this_caller`, the
  asking run's), read only when the answer lasts. An answer given once
  covers that one ask, and its `covers` is always `:this_caller`.

  Its JSON, on the wire and in an operation's arguments:

      {"effect": "allow" | "deny",
       "lasts": "once" | "always" | {"until": "<RFC 3339, UTC>"},
       "covers": "any_caller" | "this_caller"}

  `covers` may be left out, and is then `this_caller`, the narrower.
  """

  alias Prima.Question.Time

  @enforce_keys [:effect, :lasts]
  defstruct [:effect, :lasts, covers: :this_caller]

  @type effect :: :allow | :deny
  @type lasts :: :once | :always | {:until, DateTime.t()}
  @type covers :: :any_caller | :this_caller
  @type t :: %__MODULE__{effect: effect(), lasts: lasts(), covers: covers()}

  @effects %{"allow" => :allow, "deny" => :deny}
  @covers %{"any_caller" => :any_caller, "this_caller" => :this_caller}

  @doc """
  An answer from its JSON map. Any other key, or a value outside the
  shape, is `{:error, {:invalid_argument, sentence}}`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, {:invalid_argument, String.t()}}
  def decode(%{"effect" => effect, "lasts" => lasts} = json) when not is_struct(json) do
    with [] <- Map.keys(json) -- ["effect", "lasts", "covers"],
         {:ok, effect} <- Map.fetch(@effects, effect),
         {:ok, lasts} <- lasts(lasts),
         {:ok, covers} <- Map.fetch(@covers, Map.get(json, "covers", "this_caller")) do
      {:ok, normalize(%__MODULE__{effect: effect, lasts: lasts, covers: covers})}
    else
      _refused -> refuse()
    end
  end

  def decode(_json), do: refuse()

  @doc "An answer's JSON map, as `decode/1` reads it."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{effect: effect, lasts: lasts, covers: covers}) do
    %{
      "effect" => Atom.to_string(effect),
      "lasts" => lasts_json(lasts),
      "covers" => Atom.to_string(covers)
    }
  end

  defp normalize(%__MODULE__{lasts: :once} = answer), do: %{answer | covers: :this_caller}
  defp normalize(answer), do: answer

  defp lasts("once"), do: {:ok, :once}
  defp lasts("always"), do: {:ok, :always}

  defp lasts(%{"until" => text} = json) when map_size(json) == 1 do
    with {:ok, time} <- Time.decode(text), do: {:ok, {:until, time}}
  end

  defp lasts(_lasts), do: :error

  defp lasts_json({:until, time}), do: %{"until" => Time.encode(time)}
  defp lasts_json(lasts), do: Atom.to_string(lasts)

  defp refuse,
    do:
      {:error,
       {:invalid_argument,
        "answer is an object of effect (allow or deny), lasts (once, always or " <>
          "{\"until\": a UTC time}) and covers (any_caller or this_caller)"}}
end

defmodule Prima.Question.Standing do
  @moduledoc """
  An answer that stands, as a person sets it before any card has asked:
  `effect` (`:allow` or `:deny`), `until` (a time, or nil for always) and
  `caller` (`:any`, or a `Prima.Question.Caller`).

  Its JSON:

      {"effect": "allow" | "deny",
       "until": null | "<RFC 3339, UTC>",
       "caller": "any" | "<a caller's text>"}
  """

  alias Prima.Question.{Caller, Time}

  @enforce_keys [:effect, :caller]
  defstruct [:effect, :caller, until: nil]

  @type t :: %__MODULE__{
          effect: :allow | :deny,
          until: DateTime.t() | nil,
          caller: :any | Caller.t()
        }

  @effects %{"allow" => :allow, "deny" => :deny}

  @doc """
  A standing answer from its JSON map. Any other key, or a value outside
  the shape, is `{:error, {:invalid_argument, sentence}}`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, {:invalid_argument, String.t()}}
  def decode(%{"effect" => effect, "caller" => caller} = json) when not is_struct(json) do
    with [] <- Map.keys(json) -- ["effect", "until", "caller"],
         {:ok, effect} <- Map.fetch(@effects, effect),
         {:ok, until} <- until(Map.get(json, "until")),
         {:ok, caller} <- caller(caller) do
      {:ok, %__MODULE__{effect: effect, until: until, caller: caller}}
    else
      _refused -> refuse()
    end
  end

  def decode(_json), do: refuse()

  @doc "A standing answer's JSON map, as `decode/1` reads it."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{effect: effect, until: until, caller: caller}) do
    %{
      "effect" => Atom.to_string(effect),
      "until" => if(until, do: Time.encode(until)),
      "caller" => caller_text(caller)
    }
  end

  @doc "A standing answer's caller as stored: `any`, or the caller's text."
  @spec caller_text(:any | Caller.t()) :: String.t()
  def caller_text(:any), do: Caller.any()
  def caller_text(caller), do: Caller.encode(caller)

  defp until(nil), do: {:ok, nil}
  defp until(text), do: Time.decode(text)

  defp caller("any"), do: {:ok, :any}

  defp caller(text) when is_binary(text) do
    case Caller.decode(text) do
      {:ok, caller} -> {:ok, caller}
      {:error, _unknown} -> :error
    end
  end

  defp caller(_caller), do: :error

  defp refuse,
    do:
      {:error,
       {:invalid_argument,
        "standing is an object of effect (allow or deny), until (null or a UTC time) " <>
          "and caller (any or a caller)"}}
end

defmodule Prima.Question.Preview do
  @moduledoc """
  What a surface draws for a component's question, read from its owner
  under the reader's own session: the component's `publisher`, `name` and
  `release_digest`; the `action`'s name and its declared `title`; the
  component's own `summary` and `operation`; the `caller` (its text,
  `Prima.Question.Caller`); the `deadline`; and whether a credential was
  `masked` in the summary or the operation. It carries no sentence: the
  words are the surface's, as `Prima.Confirmation.Preview`'s are.
  """

  alias Prima.Question.Time

  @fields [
    :publisher,
    :name,
    :release_digest,
    :action,
    :title,
    :summary,
    :operation,
    :caller,
    :deadline,
    :masked
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          publisher: String.t(),
          name: String.t(),
          release_digest: String.t(),
          action: String.t(),
          title: String.t(),
          summary: String.t(),
          operation: String.t(),
          caller: String.t(),
          deadline: DateTime.t(),
          masked: boolean()
        }

  @doc "The preview's JSON map, its deadline in RFC 3339, UTC."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = preview) do
    preview
    |> Map.from_struct()
    |> Map.new(fn
      {:deadline, deadline} -> {"deadline", Time.encode(deadline)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end
end

defmodule Prima.Question.Time do
  @moduledoc false
  # A question's times on the wire: RFC 3339 in UTC, and nothing else, so
  # one instant has one spelling.

  @spec decode(term()) :: {:ok, DateTime.t()} | :error
  def decode(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, 0} -> if String.ends_with?(text, "Z"), do: {:ok, time}, else: :error
      _not_utc -> :error
    end
  end

  def decode(_text), do: :error

  @spec encode(DateTime.t()) :: String.t()
  def encode(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
