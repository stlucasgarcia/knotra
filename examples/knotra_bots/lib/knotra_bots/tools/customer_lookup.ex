defmodule KnotraBots.Tools.CustomerLookup do
  @moduledoc """
  Read-only customer lookup: tier, lifetime value, contact and recent orders.

  Accepts a customer id, email, name fragment or order id.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "customer_lookup",
      description: "Look up a customer by id, email, name or order id (read-only)",
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
    case Commerce.find_customer(query) do
      {customer_id, _customer} ->
        {:ok, Commerce.customer_summary(customer_id)}

      nil ->
        lookup_by_order(query)
    end
  end

  defp lookup_by_order(query) do
    case Commerce.order(query) do
      nil -> {:ok, "No customer matches #{inspect(query)}."}
      order -> {:ok, Commerce.customer_summary(order.customer)}
    end
  end
end
