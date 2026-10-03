# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.SettingsChanged do
  @moduledoc """
  The platform settings moved, on the global `Cyfr.Bus.settings_changed/0`.

    * `:changed` — a write to the store committed at the store revision
      `revision`: the setting `setting` was set to `value` (`op: :put`)
      or removed so it reads its default again (`op: :delete`, `value`
      nil). Published by the writer after the write committed.
    * `:observed` — the member `member`'s settings process has observed
      the store up to `revision`: what `Cyfr.Platform.Settings.list/0`
      reports per member.

  A setting's value is a plain value and never a credential: every
  platform setting is a limit, a window, a label or a log level.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed, :observed]

  @enforce_keys [:kind, :revision]
  defstruct [:kind, :revision, :setting, :op, :value, :member]

  @type kind :: :changed | :observed

  @type t :: %__MODULE__{
          kind: kind(),
          revision: non_neg_integer(),
          setting: String.t() | nil,
          op: :put | :delete | nil,
          value: term(),
          member: String.t() | nil
        }

  @doc "The closed union: a committed write, or a member's observed revision."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  `:changed` with `setting`, `revision`, `op` (`:put | :delete`) and, for
  a put, `value`; `:observed` with `member` and `revision`.
  """
  @spec new(kind(), keyword()) :: t()
  def new(:changed, fields) do
    setting = Keyword.fetch!(fields, :setting)
    op = Keyword.fetch!(fields, :op)

    unless is_binary(setting) and op in [:put, :delete] do
      raise ArgumentError, "a change names its setting and is a :put or a :delete"
    end

    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :changed, @kinds),
      revision: revision!(fields),
      setting: setting,
      op: op,
      value: if(op == :put, do: Keyword.get(fields, :value))
    }
  end

  def new(:observed, fields) do
    member = Keyword.fetch!(fields, :member)

    unless is_binary(member), do: raise(ArgumentError, "an observation names its member")

    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :observed, @kinds),
      revision: revision!(fields),
      member: member
    }
  end

  def new(kind, _fields) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} has no kind #{Prima.LoggerContext.shape(kind)}; " <>
            "its kinds are #{inspect(@kinds)}"
  end

  defp revision!(fields) do
    case Keyword.fetch!(fields, :revision) do
      revision when is_integer(revision) and revision >= 0 -> revision
      _other -> raise ArgumentError, "a store revision is a non-negative integer"
    end
  end
end
