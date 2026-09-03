# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ToolGrant do
  @moduledoc """
  A standing decision a person made about one `tool.action` for one agent.

  Distinct from the agent's markdown `tool_policy`, which is **declared**
  policy — what the agent's author says it may do. A grant is what a human
  answered when asked, and the two are composed at use time by
  `Aqua.ToolGrants.resolve/2`: `declared ∪ allow − deny`.

  `scope` says how far the answer reaches:

    * `"conversation"` — this thread only, and it now survives a runner
      restart (it used to live in process memory and silently revert).
    * `"agent"` — every conversation this agent runs in. Only grantable
      while the agent's owner is the focused estate, so a decision made in
      one estate cannot follow a borrowed agent home — and once granted at
      home, the row is read from the owner's estate wherever the agent
      works (`Aqua.ToolGrants.for_conversation/4`): write narrow, read
      wide.

  `effect` is `"allow"` or `"deny"`; deny is where the decline verb
  ("never ask me this again") lives, and it beats a declared `"auto"`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "tool_grants" do
    # Where the grant applies, and the tenancy that reclaims it.
    field :athanor_id, :string
    field :scope, :string
    field :effect, :string
    field :conversation_id, :string
    # Whose agent it is about — equal to `athanor_id` for agent scope, and
    # possibly another estate's for a conversation-scope grant on an agent
    # borrowed into this one.
    field :agent_athanor_id, :string
    field :agent_name, :string
    field :tool, :string
    field :action, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec
  end
end
