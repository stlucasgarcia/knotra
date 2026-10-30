defmodule KnotraBots.Tools.OrderLookup do
  @moduledoc """
  Read-only order lookup over the demo storefront.

  `query` accepts an order id (`ord-3`), a customer email or a customer name.
  Tenant scope comes from `authorize/2`; the model cannot use arguments to reach
  another tenant's records.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "order_lookup",
      description: "Look up an order by id, or a customer's recent orders (read-only)",
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
    id = String.downcase(String.trim(query))

    cond do
      Commerce.order?(id) ->
        {:ok, Commerce.order_summary(id)}

      true ->
        case Commerce.find_customer(query) do
          {customer_id, customer} ->
            orders =
              Commerce.orders_for(customer_id)
              |> Enum.map_join("\n", &"• #{Commerce.order_summary(&1.id)}")

            {:ok, "#{customer.name}'s recent orders:\n#{orders}"}

          nil ->
            {:ok, "No order or customer matches #{inspect(query)}."}
        end
    end
  end
end
