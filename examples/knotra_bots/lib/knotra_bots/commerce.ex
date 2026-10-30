defmodule KnotraBots.Commerce do
  @moduledoc """
  The demo storefront, in memory.

  Orders, customers and stock are hardcoded so the tools can stay honest about
  their scope: they read one deterministic snapshot and never touch a database,
  a network or a real customer. The host owns this data; model arguments select
  a record but can never widen access beyond these maps.
  """

  @return_window_days 30

  @products %{
    "sku-tee-01" => %{
      name: "Everyday Tee",
      price_cents: 2_400,
      stock: 4,
      reorder_at: 12,
      supplier: "Northwind Apparel",
      lead_days: 5
    },
    "sku-hood-02" => %{
      name: "Summit Hoodie",
      price_cents: 6_800,
      stock: 38,
      reorder_at: 15,
      supplier: "Northwind Apparel",
      lead_days: 7
    },
    "sku-mug-03" => %{
      name: "Camp Mug",
      price_cents: 1_800,
      stock: 0,
      reorder_at: 24,
      supplier: "Kiln & Co",
      lead_days: 9
    },
    "sku-cap-04" => %{
      name: "Trail Cap",
      price_cents: 2_600,
      stock: 12,
      reorder_at: 10,
      supplier: "Northwind Apparel",
      lead_days: 5
    },
    "sku-sock-05" => %{
      name: "Wool Socks",
      price_cents: 1_400,
      stock: 96,
      reorder_at: 30,
      supplier: "Alpine Knits",
      lead_days: 12
    }
  }

  @customers %{
    "cus-1" => %{
      name: "Maya Chen",
      email: "maya@example.com",
      tier: "gold",
      ltv_cents: 184_000,
      orders: 12,
      note: "VIP; one late delivery last month"
    },
    "cus-2" => %{
      name: "Liam Ortiz",
      email: "liam@example.com",
      tier: "silver",
      ltv_cents: 42_000,
      orders: 3,
      note: ""
    },
    "cus-3" => %{
      name: "Priya Nair",
      email: "priya@example.com",
      tier: "bronze",
      ltv_cents: 9_600,
      orders: 2,
      note: "Two late deliveries; at churn risk"
    },
    "cus-4" => %{
      name: "Noah Park",
      email: "noah@example.com",
      tier: "gold",
      ltv_cents: 121_000,
      orders: 8,
      note: ""
    }
  }

  @orders %{
    "ord-1" => %{
      customer: "cus-1",
      status: "shipped",
      placed_days_ago: 3,
      eta: "Tuesday",
      carrier: "DHL",
      tracking: "DHL-8812",
      items: [{"sku-tee-01", 1}, {"sku-hood-02", 1}]
    },
    "ord-2" => %{
      customer: "cus-2",
      status: "processing",
      placed_days_ago: 1,
      eta: "Friday",
      carrier: "UPS",
      tracking: "UPS-2041",
      items: [{"sku-sock-05", 2}]
    },
    "ord-3" => %{
      customer: "cus-1",
      status: "delivered",
      placed_days_ago: 12,
      eta: "delivered",
      carrier: "DHL",
      tracking: "DHL-7712",
      items: [{"sku-hood-02", 1}]
    },
    "ord-4" => %{
      customer: "cus-3",
      status: "delayed",
      placed_days_ago: 6,
      eta: "2 days overdue",
      carrier: "UPS",
      tracking: "UPS-1198",
      items: [{"sku-mug-03", 1}]
    },
    "ord-5" => %{
      customer: "cus-4",
      status: "delivered",
      placed_days_ago: 3,
      eta: "delivered",
      carrier: "DHL",
      tracking: "DHL-9033",
      items: [{"sku-cap-04", 1}, {"sku-sock-05", 1}]
    },
    "ord-6" => %{
      customer: "cus-3",
      status: "cancelled",
      placed_days_ago: 8,
      eta: "cancelled",
      carrier: "—",
      tracking: "—",
      items: [{"sku-tee-01", 2}]
    },
    "ord-7" => %{
      customer: "cus-4",
      status: "delivered",
      placed_days_ago: 45,
      eta: "delivered",
      carrier: "DHL",
      tracking: "DHL-6620",
      items: [{"sku-cap-04", 1}]
    }
  }

  @doc "Every product SKU, sorted."
  def skus, do: @products |> Map.keys() |> Enum.sort()

  @doc "A product row by exact SKU."
  def product(sku), do: Map.get(@products, normalize(sku))

  @doc "Finds a product by SKU or a case-insensitive name fragment."
  def find_product(query) do
    query = normalize(query)

    case Map.fetch(@products, query) do
      {:ok, product} ->
        {query, product}

      :error ->
        Enum.find(@products, fn {_sku, product} ->
          String.contains?(String.downcase(product.name), query)
        end)
    end
  end

  @doc "An order row by id."
  def order(id), do: Map.get(@orders, normalize(id))

  @doc "All orders for one customer id, newest first."
  def orders_for(customer_id) do
    @orders
    |> Enum.filter(fn {_id, order} -> order.customer == customer_id end)
    |> Enum.sort_by(fn {_id, order} -> order.placed_days_ago end)
    |> Enum.map(fn {id, order} -> Map.put(order, :id, id) end)
  end

  @doc "A customer row by id, email or name fragment."
  def find_customer(query) do
    query = normalize(query)

    case Map.fetch(@customers, query) do
      {:ok, customer} ->
        {query, customer}

      :error ->
        Enum.find(@customers, fn {_id, customer} ->
          customer.email == query or
            String.contains?(String.downcase(customer.name), query)
        end)
    end
  end

  @doc "Order total in cents, from the product snapshot."
  def total_cents(%{items: items}) do
    Enum.reduce(items, 0, fn {sku, qty}, acc ->
      product = Map.fetch!(@products, sku)
      acc + product.price_cents * qty
    end)
  end

  @doc "One-line item list, e.g. `Everyday Tee ×1, Summit Hoodie ×1`."
  def items_line(%{items: items}) do
    Enum.map_join(items, ", ", fn {sku, qty} ->
      "#{Map.fetch!(@products, sku).name} ×#{qty}"
    end)
  end

  @doc """
  Return eligibility for one order.

  Delivered orders inside the 30-day window are eligible; anything still in
  transit is not yet eligible, and a cancelled order cannot be returned.
  """
  def return_policy(%{status: "delivered", placed_days_ago: days}) do
    left = @return_window_days - days

    if left >= 0 do
      %{eligible: true, days_left: left, reason: "#{left} days left in the 30-day window"}
    else
      %{
        eligible: false,
        days_left: left,
        reason: "the 30-day window closed #{abs(left)} days ago"
      }
    end
  end

  def return_policy(%{status: "cancelled"}) do
    %{eligible: false, days_left: nil, reason: "the order was cancelled"}
  end

  def return_policy(%{status: status, eta: eta}) when status in ["shipped", "processing"] do
    %{eligible: false, days_left: nil, reason: "still in transit (ETA #{eta})"}
  end

  def return_policy(%{status: "delayed", eta: eta}) do
    %{eligible: false, days_left: nil, reason: "delivery is delayed (#{eta})"}
  end

  @doc "Human-readable order summary used by the read-only tools."
  def order_summary(id) do
    order = Map.fetch!(@orders, id)
    customer = Map.fetch!(@customers, order.customer)

    "Order #{id} #{status_label(order)} · #{customer.name} (#{customer.tier}, " <>
      "LTV #{money(customer.ltv_cents)}) · #{items_line(order)} · " <>
      "total #{money(total_cents(order))} · tracking #{order.tracking}"
  end

  @doc "Human-readable customer summary."
  def customer_summary(id) do
    customer = Map.fetch!(@customers, id)

    open =
      orders_for(id)
      |> Enum.map_join(", ", fn order -> "#{order.id} #{status_label(order)}" end)

    note = if customer.note == "", do: "", else: " · note: #{customer.note}"

    "#{customer.name} (#{id}) · #{customer.tier} · LTV #{money(customer.ltv_cents)} · " <>
      "#{customer.orders} orders · #{customer.email} · recent: #{open}#{note}"
  end

  @doc "Human-readable stock summary."
  def stock_summary(sku) do
    product = Map.fetch!(@products, sku)

    status =
      cond do
        product.stock == 0 -> "OUT OF STOCK"
        product.stock < product.reorder_at -> "LOW"
        true -> "ok"
      end

    "#{sku} · #{product.name} · #{product.stock} in stock (reorder at #{product.reorder_at}) · " <>
      "#{status} · supplier #{product.supplier}, #{product.lead_days}-day lead · " <>
      "#{money(product.price_cents)}"
  end

  @doc "Human-readable return-policy summary."
  def return_summary(id) do
    order = Map.fetch!(@orders, id)
    policy = return_policy(order)

    if policy.eligible do
      "Order #{id} is return-eligible: delivered #{order.placed_days_ago} days ago, " <>
        "#{policy.reason}. Refund would be #{money(total_cents(order))}."
    else
      "Order #{id} is not return-eligible: #{policy.reason}. " <>
        "Order value #{money(total_cents(order))}."
    end
  end

  @doc "True when an order id exists."
  def order?(id), do: Map.has_key?(@orders, normalize(id))

  @doc "True when a SKU exists."
  def sku?(sku), do: Map.has_key?(@products, normalize(sku))

  @doc "Finds an order id mentioned in free text."
  def find_order_in(text) do
    case Regex.run(~r/\bord-\d+\b/i, text) do
      [id | _] -> id |> String.downcase() |> then(&if order?(&1), do: &1, else: nil)
      _ -> nil
    end
  end

  @doc "Finds a SKU mentioned in free text."
  def find_sku_in(text) do
    case Regex.run(~r/\bsku-[a-z0-9-]+\b/i, text) do
      [sku | _] -> sku |> String.downcase() |> then(&if sku?(&1), do: &1, else: nil)
      _ -> nil
    end
  end

  @doc "Finds a customer mentioned by name or email in free text."
  def find_customer_in(text) do
    text = String.downcase(text)

    Enum.find(@customers, fn {_id, customer} ->
      String.contains?(text, String.downcase(customer.name)) or
        String.contains?(text, customer.email)
    end)
  end

  @doc "Dollars for a cent amount, with thousands separators."
  def money(cents) when is_integer(cents) do
    dollars =
      cents
      |> div(100)
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(to_string(remainder), 2, "0")}"
  end

  defp status_label(%{status: "delivered", placed_days_ago: days}),
    do: "delivered #{days} days ago"

  defp status_label(%{status: "shipped", eta: eta}), do: "shipped, ETA #{eta}"
  defp status_label(%{status: "processing", eta: eta}), do: "processing, ships #{eta}"
  defp status_label(%{status: "delayed", eta: eta}), do: "delayed (#{eta})"
  defp status_label(%{status: "cancelled"}), do: "cancelled"
  defp status_label(%{status: status}), do: status

  defp normalize(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()
end
