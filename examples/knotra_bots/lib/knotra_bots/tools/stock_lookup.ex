defmodule KnotraBots.Tools.StockLookup do
  @moduledoc """
  Read-only stock lookup by SKU, product name, or `low`/`out` for the exception
  list. Shows the reorder point and supplier lead time so a restock decision has
  context.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "stock_lookup",
      description:
        "Check stock by SKU or product name, or list low/out-of-stock SKUs (read-only)",
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
    query = query |> String.trim() |> String.downcase()

    cond do
      query in ["low", "all", "stock", "inventory"] ->
        {:ok, exception_list()}

      true ->
        case Commerce.find_product(query) do
          {sku, _product} ->
            {:ok, Commerce.stock_summary(sku)}

          nil ->
            {:ok, "No SKU or product matches #{inspect(query)}."}
        end
    end
  end

  defp exception_list do
    rows =
      Commerce.skus()
      |> Enum.filter(fn sku ->
        product = Commerce.product(sku)
        product.stock < product.reorder_at
      end)
      |> Enum.map_join("\n", &"• #{Commerce.stock_summary(&1)}")

    if rows == "", do: "All SKUs are above their reorder point.", else: rows
  end
end
