defmodule KnotraBots.Tools.Lookup do
  @moduledoc """
  Read-only order lookup over a tiny hardcoded map.

  The host owns the scope; tenant identity comes from `authorize/2`, never from
  model-supplied arguments. The durable runtime still records a bound approval
  before this call; because the definition is `read_only: true`, the demo's chat
  relay answers it immediately and a human is never asked.
  """

  @behaviour Knotra.Tool

  @orders %{
    "ord-1" => "Order ord-1 shipped and arrives Tuesday.",
    "ord-2" => "Order ord-2 is processing and ships Friday."
  }

  @impl true
  def definition do
    %{
      name: "lookup",
      description: "Look up an order's status (read-only)",
      read_only: true,
      parameters: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"query" => query} = args)
      when is_binary(query) and query != "" and map_size(args) == 1,
      do: {:ok, args}

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, %{tenant: tenant}) do
    if tenant == KnotraBots.tenant(), do: :ok, else: {:error, :forbidden}
  end

  @impl true
  def call(%{"query" => query}, _scope) do
    {:ok, Map.get(@orders, query, "No order record matches #{inspect(query)}.")}
  end
end
