Code.require_file("../bench/swarm_support.ex", __DIR__)

# Runs the three swarm shapes offline over e-commerce work.
#
#   mix run examples/swarm_showcase.exs
#
# The point is the coordination shape, not model quality: the same three
# primitives cover a parallel catalog audit, a self-organizing backlog and a
# decision debate. Every member is an ordinary execution; nothing is persisted.

alias Knotra.Bench.SwarmSupport
alias Knotra.Swarm.{Result, Spec}

defmodule ShowcaseWrite do
  @behaviour Knotra.Tool

  @impl true
  def definition do
    %{
      name: "write_probe",
      description: "records a write for the showcase",
      read_only: false,
      parameters: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"value" => value} = args)
      when is_binary(value) and value != "" and map_size(args) == 1,
      do: {:ok, args}

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, _scope), do: :ok

  @impl true
  def call(%{"value" => value}, _scope) do
    IO.puts("[effect] write #{value}")
    {:ok, "wrote " <> value}
  end
end

defmodule ShowcaseWriteModel do
  @behaviour Knotra.Model

  @impl true
  def call(request, opts) do
    case request.exchanges do
      [] ->
        {:ok,
         %Knotra.Reply{
           calls: [
             %{
               id: "write-1",
               name: "write_probe",
               arguments: %{"value" => Keyword.fetch!(opts, :value)}
             }
           ]
         }}

      _ ->
        {:ok, %Knotra.Reply{text: "write attempt finished"}}
    end
  end
end

instance = :swarm_showcase
SwarmSupport.start_instance!(instance, 16)

indent = fn text, pad ->
  text
  |> to_string()
  |> String.split("\n")
  |> Enum.map_join("\n", &(pad <> &1))
end

print = fn label, use_case, result ->
  IO.puts("\n== #{label} ==")
  IO.puts("use case: #{use_case}")
  IO.puts("status: #{result.status} in #{result.elapsed_ms} ms")

  if result.selected != nil,
    do: IO.puts("selected: #{inspect(result.selected)}")

  IO.puts("output:\n#{indent.(result.output, "  ")}")

  Enum.each(result.escalations, fn escalation ->
    IO.puts(
      "  escalated #{escalation.tool} by #{escalation.agent}: " <>
        "#{inspect(escalation.arguments)} (#{inspect(escalation.reason)})"
    )
  end)

  Enum.each(result.tasks, fn part ->
    IO.puts("  #{part.id} by #{part.agent || "unassigned"}: #{part.status}")
    if part.output, do: IO.puts(indent.(part.output, "    "))
  end)
end

# 1. Fan-out: one catalog audit splits into independent SKU checks. Each part is
#    a separate execution; the merged output is the launch checklist.
fan_out = %Spec{
  mode: :fan_out,
  goal: "audit the autumn drop",
  agents: [
    SwarmSupport.agent("Inventory", fn request ->
      "Inventory for #{request.input}: below reorder point; propose +24 from Northwind (5-day lead)."
    end),
    SwarmSupport.agent("Pricing", fn request ->
      "Pricing for #{request.input}: hold list price; a stock-out discount spends demand twice."
    end),
    SwarmSupport.agent("Merchandising", fn request ->
      "Merch for #{request.input}: move it to the 'back in stock' rail, keep the hero slot."
    end)
  ],
  tasks: [
    %{id: "sku-tee-01", input: "sku-tee-01"},
    %{id: "sku-hood-02", input: "sku-hood-02"},
    %{id: "sku-mug-03", input: "sku-mug-03"},
    %{id: "sku-cap-04", input: "sku-cap-04"}
  ]
}

{:ok, fan_out_result} = Knotra.Swarm.run(instance, fan_out)

print.(
  "Fan out · catalog audit",
  "independent SKU checks run in parallel and merge into one launch checklist",
  fan_out_result
)

# 2. Shared board: six support/ops jobs sit on one board. Members claim jobs
#    themselves; the coordinator never assigns work. Which agent handles which
#    job is a runtime outcome of the claim order.
board = %Spec{
  mode: :board,
  goal: "drain today's order backlog",
  agents: [
    SwarmSupport.agent("Order Desk", fn request ->
      "#{request.input}: status checked, tracking posted to the customer."
    end),
    SwarmSupport.agent("Returns", fn request ->
      "#{request.input}: return window checked; refund proposed if eligible."
    end),
    SwarmSupport.agent("Inventory", fn request ->
      "#{request.input}: stock checked; restock proposed when below reorder point."
    end)
  ],
  tasks: [
    %{id: "ord-3", input: "order ord-3"},
    %{id: "ord-4", input: "order ord-4"},
    %{id: "ord-5", input: "order ord-5"},
    %{id: "ord-7", input: "order ord-7"},
    %{id: "sku-tee-01", input: "stock sku-tee-01"},
    %{id: "sku-mug-03", input: "stock sku-mug-03"}
  ]
}

{:ok, board_result} = Knotra.Swarm.run(instance, board)

print.(
  "Shared board · order backlog",
  "agents claim work from a shared board until it is empty; no dispatcher assigns tasks",
  board_result
)

# 3. Debate: three specialists answer the same retention question. The selector
#    keeps the strongest attempt; the other attempts remain inspectable.
debate = %Spec{
  mode: :debate,
  goal: "A gold customer's order is late for the second time. Choose the best recovery.",
  agents: [
    SwarmSupport.agent("Pricing Strategist", fn _request ->
      "Hold the list price. Offer a $10 store credit; a 15% discount trains the next customer to wait."
    end),
    SwarmSupport.agent("Retention Analyst", fn _request ->
      "The customer is gold with $1,840 LTV and a second late delivery. Send a personal apology " <>
        "plus 15% credit and a tracking check; relationship value beats the $10 saved."
    end),
    SwarmSupport.agent("Brand Voice", fn _request ->
      "Say what went wrong, then make it right. A silent discount reads like a transaction."
    end)
  ]
}

{:ok, debate_result} = Knotra.Swarm.run(instance, debate)

print.(
  "Debate · late-delivery recovery",
  "three specialist views answer one question; the strongest attempt is selected",
  debate_result
)

# 4. Coordinator: the planner creates two writers, assigns them tasks and sets a
#    write policy. One write is inside policy, one escalates; an unrelated task
#    still completes.
coordinator = %Spec{
  mode: :coordinator,
  goal: "process the write queue",
  agents: [
    SwarmSupport.agent("Analyst", fn request -> "analyzed #{request.input}" end)
  ],
  plan: fn _goal, _agents ->
    writer = fn name, value ->
      %Knotra.Swarm.Agent{
        name: name,
        definition: %Knotra.Definition{
          version: "showcase-writer",
          model: {ShowcaseWriteModel, value: value},
          tools: [ShowcaseWrite]
        }
      }
    end

    {:ok,
     %{
       agents: [writer.("Writer A", "allowed"), writer.("Writer B", "blocked")],
       tasks: [
         %{id: "write-allowed", input: "allow this write", agent: "Writer A", depth: 0},
         %{id: "write-blocked", input: "block this write", agent: "Writer B", depth: 0},
         %{id: "analysis", input: "summarize the queue", agent: "Analyst", depth: 0}
       ]
     }}
  end,
  write_policy: fn _call, %{"value" => value}, _opts ->
    if value == "allowed", do: :approve, else: {:escalate, :over_limit}
  end,
  max_created_agents: 2,
  max_tasks: 3,
  timeout: 5_000
}

{:error, {:incomplete, coordinator_result}} = Knotra.Swarm.run(instance, coordinator)

print.(
  "Coordinator · created specialists",
  "a plan creates agents, assigns tasks, auto-approves one write and escalates another",
  coordinator_result
)

unless match?(%Result{status: :completed}, debate_result) do
  raise "showcase debate did not complete"
end

unless Enum.any?(coordinator_result.escalations, &(&1.agent == "Writer B")) do
  raise "showcase coordinator did not escalate the out-of-policy write"
end

unless Enum.any?(
         coordinator_result.tasks,
         &(&1.id == "write-blocked" and &1.error == :escalation_required)
       ) do
  raise "showcase coordinator did not block the out-of-policy write"
end

unless Enum.any?(coordinator_result.tasks, &(&1.id == "analysis" and &1.status == :completed)) do
  raise "showcase coordinator blocked unrelated work"
end

IO.puts("\nshowcase: ok")
