defmodule Knotra.Swarm.Result do
  @moduledoc """
  Outcome of one swarm.

  `:tasks` lists every required part in task order (fan-out and board) or every
  attempt in agent order (debate). `:selected` is the picked attempt for a debate
  that chose one, and `nil` for a merged debate or a merged task list. `:status`
  is `:completed` when every required part completed, `:partial` when some did,
  and `:failed` when none did or the merge/selection plugin refused.

  `:swarm_id` identifies the coordination run; every member execution is traced
  under it as one observability conversation. `:agent_details` lists each member
  with its prompt, tool names, definition version and whether the coordinator
  created it. Each part also carries its `:iteration`, `:elapsed_ms` and the
  execution's `:counts`. `:escalations` lists write calls
  that a coordinator-created member refused to execute because the host policy
  sent them to a human instead; they are records, not executed effects.

  `Knotra.Swarm.await/2` returns `{:ok, result}` only for `:completed`; a partial
  result is not a successful root completion.
  """
  defstruct mode: nil,
            goal: nil,
            swarm_id: nil,
            agents: [],
            created_agents: [],
            agent_details: [],
            status: nil,
            output: nil,
            tasks: [],
            escalations: [],
            selected: nil,
            error: nil,
            elapsed_ms: nil

  @type t :: %__MODULE__{
          mode: Knotra.Swarm.Spec.mode(),
          goal: String.t(),
          swarm_id: String.t(),
          agents: [String.t()],
          created_agents: [String.t()],
          agent_details: [map()],
          status: :completed | :partial | :failed,
          output: String.t() | nil,
          tasks: [map()],
          escalations: [map()],
          selected: term(),
          error: atom() | nil,
          elapsed_ms: non_neg_integer()
        }
end
