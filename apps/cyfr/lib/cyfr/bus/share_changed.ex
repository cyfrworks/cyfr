# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ShareChanged do
  @moduledoc """
  A share changed, on the global `Cyfr.Bus.shares/0`: its recipients live
  in other athanors, and every page that shows what is shared with a
  person, or by them, reads it again. The kind is the durable change the
  identity domain announced, one of `Prima.ShareKinds.all/0`;
  `share_id` names the share and nothing else travels: no owner, entry,
  provider, destination, audience, cap, count, digest or value. A page
  reads the shares again through the operations, under its own context,
  and learns only what that context may.
  """

  alias Cyfr.Bus.Payload

  @kinds Prima.ShareKinds.all()

  @enforce_keys [:kind, :share_id]
  defstruct [:kind, :share_id]

  @type kind :: Prima.ShareKinds.t()

  @type t :: %__MODULE__{kind: kind(), share_id: String.t()}

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The change `kind` of the share `share_id`. A kind outside `kinds/0`, or
  a share id that is not a non-empty string, raises.
  """
  @spec new(kind(), String.t()) :: t()
  def new(kind, share_id) when is_binary(share_id) and share_id != "",
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, kind, @kinds), share_id: share_id}

  def new(_kind, share_id) do
    raise ArgumentError,
          "a share change names its share, got #{Prima.LoggerContext.shape(share_id)}"
  end
end
