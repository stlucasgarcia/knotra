defmodule KnotraBots.Models.ChatFake do
  @moduledoc """
  Offline deterministic storefront model.

  It exercises the chat contract without a provider: order ids become
  `order_lookup` calls, return questions become `return_policy`, refund and
  restock requests become approval-gated proposals, and a `hand off to @handle`
  instruction or a `Routing:` prompt line produces an agent-to-agent mention.
  Tool and answer continuations complete with their result, so the whole durable
  lifecycle runs offline.

  The growth personas ("Argue from …") answer a strategy question with a
  deterministic position, so a debate swarm produces three distinct attempts
  instead of three identical echoes.
  """
  @behaviour Knotra.Model

  alias KnotraBots.Commerce

  @impl true
  def checkpoint_version, do: 1

  @impl true
  def call(%{exchanges: exchanges, input: input, tools: tools}, opts) do
    name = Keyword.get(opts, :name, "Agent")
    prompt = Keyword.get(opts, :system_prompt, "")

    case List.last(exchanges) do
      %{results: [%{output: output}]} ->
        {:ok, %Knotra.Reply{text: "Done. The result was: #{output}"}}

      %{answer: answer} ->
        {:ok, %Knotra.Reply{text: "#{name} received: #{answer}"}}

      nil ->
        first_turn(input, tools, prompt, name)

      _ ->
        {:ok, %Knotra.Reply{text: "#{name} is ready for the next step."}}
    end
  end

  defp first_turn(input, tools, prompt, name) do
    line = last_human_line(input)
    order = Commerce.find_order_in(line)
    sku = Commerce.find_sku_in(line)

    cond do
      clarify?(line) ->
        question("What details should I include?")

      position = strategy_position(prompt, line) ->
        {:ok, %Knotra.Reply{text: position}}

      notify?(line, tools) ->
        proposal("notify", %{"to" => "ops", "message" => line})

      refund?(line) and has_tool?(tools, "refund") ->
        if order, do: refund_proposal(order, line), else: question("Which order should I refund?")

      policy?(line) and has_tool?(tools, "return_policy") ->
        if order,
          do: tool_call("return_policy", %{"order" => order}),
          else: question("Which order should I check?")

      return?(line) and has_tool?(tools, "return_policy") ->
        if order,
          do: tool_call("return_policy", %{"order" => order}),
          else: question("Which order should I check?")

      restock?(line) and has_tool?(tools, "restock") ->
        if sku,
          do: restock_proposal(sku),
          else: question("Which SKU should I reorder?")

      stock?(line) and has_tool?(tools, "stock_lookup") ->
        stock_call(sku, line)

      customer?(line) and has_tool?(tools, "customer_lookup") ->
        customer_call(line, order)

      order != nil and has_tool?(tools, "order_lookup") ->
        tool_call("order_lookup", %{"query" => order})

      handle = handoff(line, prompt) ->
        {:ok, %Knotra.Reply{text: "Handing this to @#{handle}."}}

      true ->
        {:ok, %Knotra.Reply{text: "#{name} received: #{line}"}}
    end
  end

  defp clarify?(line), do: Regex.match?(~r/\b(clarify|clarification|ambiguous|details?)\b/i, line)

  defp notify?(line, tools) do
    line != "" and Enum.any?(tools, &(&1.name == "notify")) and
      Regex.match?(~r/\b(notify|send|notice|ping)\b/i, line)
  end

  defp refund?(line) do
    Regex.match?(~r/\b(refund|refunded|money back|credit back)\b/i, line) and
      not Regex.match?(~r/\b(eligible|policy|can i return|return window)\b/i, line)
  end

  defp policy?(line),
    do:
      Regex.match?(~r/\b(return|refund)\b/i, line) and
        Regex.match?(~r/\b(eligible|policy|window|can i return)\b/i, line)

  defp return?(line), do: Regex.match?(~r/\breturn\b/i, line)

  defp restock?(line), do: Regex.match?(~r/\b(restock|reorder|replenish)\b/i, line)

  defp stock?(line),
    do: Regex.match?(~r/\b(stock|inventory|sku)\b/i, line) or Commerce.find_sku_in(line) != nil

  defp customer?(line),
    do:
      Regex.match?(~r/\b(customer|ltv|lifetime|history|vip|churn|gold|silver|bronze)\b/i, line) or
        Commerce.find_customer_in(line) != nil

  defp strategy_position(prompt, line) do
    if Regex.match?(~r/argue from/i, prompt) and
         Regex.match?(~r/\b(choose|best|recommend|which|should we|strategy|offer)\b/i, line) do
      cond do
        prompt =~ "Pricing Strategist" ->
          "Pricing view: hold the $68 list price and offer a $10 store credit. " <>
            "A sitewide discount trains the next customer to wait for a sale, and free " <>
            "expedited shipping costs more than the margin on one hoodie."

        prompt =~ "Retention Analyst" ->
          "Retention view: the customer is gold, LTV is $1,840, and this is the second " <>
            "late delivery. Send a personal apology plus 15% credit and a tracking check; " <>
            "protecting the relationship is worth more than the $10 saved."

        prompt =~ "Brand Voice" ->
          "Brand view: a personal apology and a small credit sounds human; a silent " <>
            "discount reads like a transaction. Say what went wrong, then make it right."

        true ->
          nil
      end
    end
  end

  # The latest human turn, so a handoff still sees the request that started it.
  # Continuation lines are indented by the transcript builder; undo that before
  # matching, so a body containing a blank line keeps its paragraphs.
  defp last_human_line(input) do
    input
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "Human: "))
    |> List.last()
    |> case do
      nil ->
        ""

      line ->
        line
        |> String.replace_prefix("Human: ", "")
        |> String.replace("\n  ", "\n")
    end
  end

  defp refund_proposal(order, line) do
    reason =
      case String.split(line, ~r/\bbecause\b/i, parts: 2) do
        [_, reason] -> String.trim(reason)
        _ -> line
      end
      |> String.slice(0, 240)

    proposal("refund", %{"order" => order, "reason" => reason})
  end

  defp restock_proposal(sku), do: proposal("restock", %{"sku" => sku, "quantity" => 24})

  defp stock_call(nil, line) do
    query = if Regex.match?(~r/\b(low|out)\b/i, line), do: "low", else: "all"
    tool_call("stock_lookup", %{"query" => query})
  end

  defp stock_call(sku, _line), do: tool_call("stock_lookup", %{"query" => sku})

  defp customer_call(line, order) do
    case Commerce.find_customer_in(line) do
      {customer_id, _customer} ->
        tool_call("customer_lookup", %{"query" => customer_id})

      nil ->
        if order do
          tool_call("customer_lookup", %{"query" => order})
        else
          question("Which customer should I look up? (name, email or order id)")
        end
    end
  end

  defp tool_call(name, arguments) do
    {:ok, %Knotra.Reply{calls: [%{id: "#{name}-1", name: name, arguments: arguments}]}}
  end

  defp question(prompt) do
    {:ok, %Knotra.Reply{text: prompt, input_request: %{prompt: prompt}}}
  end

  defp proposal(name, arguments) do
    {:ok, %Knotra.Reply{calls: [%{id: "#{name}-1", name: name, arguments: arguments}]}}
  end

  defp handoff(line, prompt) do
    routing_handoff(line, prompt) || legacy_handoff(line, prompt)
  end

  @route_priority ["refund", "return", "restock", "stock", "inventory", "shipping", "order"]

  # A `Routing: order=@orders, return=@returns, ...` line in the prompt is both
  # readable by a real model and parseable here. Priority keeps "refund" from
  # being swallowed by the broader "order" topic.
  defp routing_handoff(line, prompt) do
    rules =
      Map.new(Regex.scan(~r/([a-z_]+)=@([a-z0-9_-]+)/i, prompt), fn [_, topic, handle] ->
        {topic, handle}
      end)

    Enum.find_value(@route_priority, fn topic ->
      if Regex.match?(~r/\b#{topic}\b/i, line), do: Map.get(rules, topic)
    end) ||
      if(Map.has_key?(rules, "customer") and Commerce.find_customer_in(line) != nil,
        do: rules["customer"]
      )
  end

  defp legacy_handoff(line, prompt) do
    with true <-
           Regex.match?(~r/\b(order|shipment|shipping|status|tracking|return|refund)\b/i, line),
         [_, handle] <-
           Regex.run(~r/hand off[^@\n]*@([a-z0-9][a-z0-9_-]*)/i, prompt) do
      handle
    else
      _ -> nil
    end
  end

  defp has_tool?(tools, name), do: Enum.any?(tools, &(&1.name == name))
end
