if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Knotra.Dashboard.Live do
    @moduledoc false
    use Phoenix.LiveView

    alias Knotra.Observability

    @tabs [
      {:overview, "Overview"},
      {:executions, "Executions"},
      {:agents, "Agents"},
      {:topology, "Topology"},
      {:messages, "Messages"}
    ]

    @statuses [
      {"all", "All statuses"},
      {"running", "Running"},
      {"waiting", "Waiting"},
      {"completed", "Completed"},
      {"failed", "Failed / blocked"}
    ]

    @kinds [
      {"all", "All messages"},
      {"assistant", "Assistant"},
      {"tool", "Tool"},
      {"input", "Input"},
      {"human", "Human"},
      {"error", "Error / notice"}
    ]

    @css """
    .knotra {
      color-scheme: light dark;
      --k-bg: #f7f8fa;
      --k-panel: #ffffff;
      --k-panel-2: #f1f3f7;
      --k-border: #e2e6ee;
      --k-text: #18202b;
      --k-muted: #697586;
      --k-accent: #4f46e5;
      --k-accent-soft: #eef0ff;
      --k-green: #07875f;
      --k-green-soft: #e5f7ef;
      --k-amber: #a15c00;
      --k-amber-soft: #fff4de;
      --k-red: #b42318;
      --k-red-soft: #fdecea;
      --k-mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      background: var(--k-bg);
      color: var(--k-text);
      font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
      font-size: 14px;
      line-height: 1.45;
      padding: 20px;
      border-radius: 12px;
    }
    @media (prefers-color-scheme: dark) {
      .knotra {
        --k-bg: #0d1117;
        --k-panel: #151b24;
        --k-panel-2: #1a222d;
        --k-border: #2a3542;
        --k-text: #e6edf3;
        --k-muted: #8b98a9;
        --k-accent: #8b8cf8;
        --k-accent-soft: #23264a;
        --k-green: #3ddc97;
        --k-green-soft: #112c22;
        --k-amber: #f2b544;
        --k-amber-soft: #33260d;
        --k-red: #ff7b72;
        --k-red-soft: #38191a;
      }
    }
    .knotra *, .knotra *::before, .knotra *::after { box-sizing: border-box; }
    .knotra h1, .knotra h2, .knotra h3, .knotra p { margin: 0; }
    .knotra code, .knotra pre, .knotra .kid { font-family: var(--k-mono); font-size: 12px; }
    .knotra code, .knotra pre { background: transparent; color: inherit; padding: 0; border: 0; }
    .knotra pre { white-space: pre-wrap; word-break: break-word; margin: 6px 0 0; }
    .k-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
    .k-brand { display: flex; align-items: center; gap: 12px; }
    .k-mark {
      display: grid; place-items: center; width: 38px; height: 38px; border-radius: 10px;
      background: var(--k-accent); color: #fff; font-weight: 700; font-size: 18px;
    }
    .k-brand h1 { font-size: 18px; letter-spacing: -0.01em; }
    .k-brand p { display: flex; gap: 10px; align-items: center; color: var(--k-muted); font-size: 12px; margin-top: 2px; }
    .k-instance { font-family: var(--k-mono); }
    .k-actions { display: flex; align-items: center; gap: 8px; }
    .k-live { display: inline-flex; align-items: center; gap: 6px; color: var(--k-green); font-size: 12px; font-weight: 600; }
    .k-live-dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; box-shadow: 0 0 0 3px color-mix(in srgb, currentColor 18%, transparent); }
    .k-live.is-paused { color: var(--k-muted); }
    .k-btn, .k-link, .k-icon-btn {
      appearance: none; border: 1px solid var(--k-border); background: var(--k-panel); color: var(--k-text);
      border-radius: 8px; padding: 6px 10px; font: inherit; font-size: 12px; cursor: pointer;
    }
    .k-btn:hover, .k-link:hover, .k-icon-btn:hover { border-color: var(--k-accent); color: var(--k-accent); }
    .k-link { border: 0; background: transparent; padding: 2px 4px; color: var(--k-accent); }
    .k-icon-btn { border: 0; font-size: 20px; line-height: 1; padding: 2px 8px; }
    .k-error-inline { color: var(--k-red); }
    .k-tabs { display: flex; gap: 4px; margin: 18px 0 14px; border-bottom: 1px solid var(--k-border); overflow-x: auto; }
    .k-tab {
      appearance: none; background: transparent; border: 0; border-bottom: 2px solid transparent;
      color: var(--k-muted); font: inherit; font-weight: 600; font-size: 13px; padding: 9px 12px;
      cursor: pointer; white-space: nowrap;
    }
    .k-tab:hover { color: var(--k-text); }
    .k-tab.is-active { color: var(--k-accent); border-bottom-color: var(--k-accent); }
    .k-count { display: inline-block; margin-left: 5px; padding: 0 6px; border-radius: 999px; background: var(--k-panel-2); font-size: 11px; }
    .k-body { display: grid; grid-template-columns: minmax(0, 1fr); gap: 14px; }
    .k-body:has(.k-detail) { grid-template-columns: minmax(0, 1fr) minmax(330px, 420px); }
    @media (max-width: 980px) { .k-body:has(.k-detail) { grid-template-columns: minmax(0, 1fr); } }
    .k-main { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
    .k-panel { background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 12px; padding: 14px; min-width: 0; }
    .k-panel-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
    .k-panel-head h2 { font-size: 14px; letter-spacing: -0.01em; }
    .k-muted { color: var(--k-muted); font-size: 12px; }
    .k-empty { color: var(--k-muted); font-size: 13px; padding: 14px 4px; }
    .k-metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 10px; }
    .k-metric { background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 12px; padding: 12px; }
    .k-metric span { display: block; color: var(--k-muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
    .k-metric strong { display: block; font-size: 24px; letter-spacing: -0.02em; margin-top: 2px; }
    .k-metric.is-running strong { color: var(--k-green); }
    .k-metric.is-waiting strong { color: var(--k-amber); }
    .k-metric.is-completed strong { color: var(--k-accent); }
    .k-metric.is-failed strong { color: var(--k-red); }
    .k-grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; }
    .k-list { display: flex; flex-direction: column; gap: 6px; }
    .k-row-card {
      display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px;
      width: 100%; text-align: left; background: var(--k-panel-2); border: 1px solid transparent;
      border-radius: 10px; padding: 9px 11px; color: inherit; font: inherit; cursor: pointer;
    }
    .k-row-card:hover { border-color: var(--k-accent); }
    .k-row-card.is-selected { border-color: var(--k-accent); background: var(--k-accent-soft); }
    .k-row-main { display: flex; flex-direction: column; min-width: 0; }
    .k-row-main strong { font-size: 13px; }
    .k-row-main span { color: var(--k-muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .k-row-side { display: flex; flex-direction: column; align-items: flex-end; gap: 1px; color: var(--k-muted); font-size: 11px; }
    .k-row-side code { color: var(--k-text); }
    .k-badge { display: inline-flex; align-items: center; gap: 5px; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; background: var(--k-panel-2); }
    .k-badge-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
    .k-badge.is-running { color: var(--k-green); background: var(--k-green-soft); }
    .k-badge.is-waiting { color: var(--k-amber); background: var(--k-amber-soft); }
    .k-badge.is-completed { color: var(--k-accent); background: var(--k-accent-soft); }
    .k-badge.is-failed { color: var(--k-red); background: var(--k-red-soft); }
    .k-filter { display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap; margin-bottom: 12px; }
    .k-filter label { display: flex; flex-direction: column; gap: 4px; font-size: 11px; color: var(--k-muted); }
    .k-filter .k-grow { flex: 1; min-width: 180px; }
    .k-filter select, .k-filter input {
      appearance: none; border: 1px solid var(--k-border); background: var(--k-panel-2); color: var(--k-text);
      border-radius: 8px; padding: 7px 9px; font: inherit; font-size: 12px; width: 100%;
    }
    .k-filter input:focus, .k-filter select:focus { outline: 2px solid var(--k-accent-soft); border-color: var(--k-accent); }
    .k-table-wrap { overflow-x: auto; }
    .k-table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .k-table th { text-align: left; color: var(--k-muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; padding: 6px 8px; border-bottom: 1px solid var(--k-border); }
    .k-table td { padding: 8px; border-bottom: 1px solid var(--k-border); vertical-align: middle; }
    .k-row { cursor: pointer; }
    .k-row:hover td { background: var(--k-panel-2); }
    .k-row.is-selected td { background: var(--k-accent-soft); }
    .k-agent-cell { font-weight: 600; }
    .k-preview { max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--k-muted); }
    .k-arrow-cell { color: var(--k-muted); }
    .k-agents { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
    .k-agent-card { border: 1px solid var(--k-border); border-radius: 10px; padding: 12px; background: var(--k-panel-2); min-width: 0; }
    .k-agent-card > header { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .k-agent-card h3 { font-size: 14px; }
    .k-agent-card header code { color: var(--k-muted); }
    .k-agent-stub { display: flex; flex-direction: column; gap: 2px; padding: 9px 10px; border: 1px solid var(--k-border); border-radius: 9px; background: var(--k-panel-2); }
    .k-agent-stub strong { font-size: 13px; }
    .k-agent-list { display: flex; flex-direction: column; gap: 6px; }
    .k-facts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px; margin: 12px 0; }
    .k-facts.is-inline { grid-template-columns: repeat(6, minmax(0, 1fr)); }
    .k-facts div { background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 8px; padding: 6px 8px; min-width: 0; }
    .k-facts dt { color: var(--k-muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.04em; }
    .k-facts dd { margin: 1px 0 0; font-weight: 700; font-size: 14px; overflow-wrap: anywhere; }
    .k-facts dd code { font-weight: 400; }
    .k-chips { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 8px; }
    .k-chip { display: inline-block; padding: 2px 7px; border-radius: 999px; border: 1px solid var(--k-border); background: var(--k-panel); color: var(--k-muted); font-size: 11px; }
    .k-chip.is-muted { opacity: 0.7; }
    .k-chip.is-link { cursor: pointer; font-family: var(--k-mono); }
    .k-chip.is-link:hover, .k-chip.is-selected { border-color: var(--k-accent); color: var(--k-accent); }
    .k-flows { display: flex; flex-direction: column; gap: 10px; }
    .k-flow-card { border: 1px solid var(--k-border); border-radius: 10px; background: var(--k-panel-2); padding: 10px 12px; }
    .k-flow-card > header { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
    .k-flow { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
    .k-flow-step { display: inline-flex; align-items: center; gap: 6px; }
    .k-flow-step:not(:last-child)::after { content: "→"; color: var(--k-muted); margin-left: 2px; }
    .k-node {
      display: flex; flex-direction: column; align-items: flex-start; gap: 1px; min-width: 120px;
      border: 1px solid var(--k-border); border-left: 3px solid var(--k-border); background: var(--k-panel);
      color: inherit; border-radius: 8px; padding: 6px 9px; font: inherit; cursor: pointer; text-align: left;
    }
    .k-node:hover { border-color: var(--k-accent); }
    .k-node strong { font-size: 12px; }
    .k-node span { font-family: var(--k-mono); font-size: 10px; color: var(--k-muted); }
    .k-node em { font-style: normal; font-size: 10px; color: var(--k-muted); }
    .k-node.running { border-left-color: var(--k-green); }
    .k-node.waiting { border-left-color: var(--k-amber); }
    .k-node.completed { border-left-color: var(--k-accent); }
    .k-node.failed { border-left-color: var(--k-red); }
    .k-links { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
    .k-links li { display: flex; align-items: center; gap: 6px; }
    .k-feed { display: flex; flex-direction: column; gap: 8px; }
    .k-feed.is-compact .k-msg p { font-size: 12px; }
    .k-msg { border: 1px solid var(--k-border); border-left: 3px solid var(--k-border); border-radius: 9px; padding: 8px 10px; background: var(--k-panel-2); }
    .k-msg.is-assistant { border-left-color: var(--k-accent); }
    .k-msg.is-tool { border-left-color: var(--k-green); }
    .k-msg.is-input { border-left-color: var(--k-muted); }
    .k-msg.is-human { border-left-color: var(--k-amber); }
    .k-msg.is-error { border-left-color: var(--k-red); }
    .k-msg header { display: flex; gap: 7px; align-items: center; flex-wrap: wrap; font-size: 11px; }
    .k-msg header strong { font-size: 12px; }
    .k-msg p { margin-top: 4px; font-size: 13px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-kind { padding: 1px 6px; border-radius: 999px; background: var(--k-panel); font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.03em; }
    .k-detail {
      background: var(--k-panel); border: 1px solid var(--k-border); border-radius: 12px; padding: 14px;
      position: sticky; top: 14px; max-height: calc(100vh - 28px); overflow: auto; min-width: 0;
    }
    .k-detail-head { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .k-detail-head h2 { font-size: 16px; margin-top: 1px; }
    .k-eyebrow { color: var(--k-muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; }
    .k-detail-meta { display: flex; flex-direction: column; gap: 3px; margin: 10px 0; font-size: 12px; }
    .k-trace { display: flex; flex-direction: column; gap: 3px; margin: 8px 0 12px; }
    .k-trace div { display: flex; gap: 8px; font-size: 11px; }
    .k-trace span { color: var(--k-muted); min-width: 84px; }
    .k-trace code { overflow-wrap: anywhere; }
    .k-callout { border-radius: 9px; border: 1px solid var(--k-border); padding: 8px 10px; margin: 8px 0; background: var(--k-panel-2); }
    .k-callout strong { font-size: 12px; }
    .k-callout p { margin-top: 3px; font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-callout.is-warn { border-color: var(--k-amber); background: var(--k-amber-soft); }
    .k-callout.is-ok { border-color: var(--k-green); background: var(--k-green-soft); }
    .k-callout.is-error { border-color: var(--k-red); background: var(--k-red-soft); }
    .k-section-title { display: flex; justify-content: space-between; gap: 8px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--k-muted); margin: 14px 0 6px; }
    .k-input { background: var(--k-panel-2); border-radius: 8px; padding: 8px 10px; font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-timeline { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 7px; }
    .k-event { border-left: 2px solid var(--k-border); padding: 2px 0 2px 10px; }
    .k-event.is-input { border-left-color: var(--k-muted); }
    .k-event.is-model, .k-event.is-assistant { border-left-color: var(--k-accent); }
    .k-event.is-tool { border-left-color: var(--k-green); }
    .k-event.is-human { border-left-color: var(--k-amber); }
    .k-event.is-terminal.is-completed { border-left-color: var(--k-green); }
    .k-event.is-terminal.is-failed, .k-event.is-terminal.is-blocked, .k-event.is-terminal.is-cancelled { border-left-color: var(--k-red); }
    .k-event-head { display: flex; align-items: center; gap: 7px; font-size: 11px; }
    .k-event-head strong { font-size: 11px; }
    .k-seq { display: inline-grid; place-items: center; min-width: 20px; height: 18px; border-radius: 5px; background: var(--k-panel-2); font-family: var(--k-mono); font-size: 10px; color: var(--k-muted); }
    .k-event p, .k-event pre { font-size: 12px; margin-top: 3px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .k-calls { list-style: none; margin: 5px 0 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
    .k-calls li { display: flex; gap: 6px; flex-wrap: wrap; background: var(--k-panel-2); border-radius: 6px; padding: 4px 6px; }
    .k-calls span { font-family: var(--k-mono); font-size: 11px; color: var(--k-muted); }
    .k-usage { font-family: var(--k-mono); }
    """

    @impl true
    def mount(_params, session, socket) do
      instance = Map.get(session, "knotra_instance", Map.get(session, :knotra_instance))

      socket =
        socket
        |> assign(:instance, instance)
        |> assign(:tab, :overview)
        |> assign(:selected_id, nil)
        |> assign(:selected, nil)
        |> assign(:status_filter, "all")
        |> assign(:kind_filter, "all")
        |> assign(:query, "")
        |> assign(:paused, false)
        |> assign(:error, if(instance, do: nil, else: :missing_instance))
        |> assign(:snapshot, empty_snapshot())
        |> assign(:last_updated, nil)

      if instance && connected?(socket) do
        Observability.subscribe(instance)
        schedule_tick()
      end

      {:ok, if(instance, do: load(socket), else: socket)}
    end

    @impl true
    def handle_info({:knotra_observability, _instance}, socket) do
      {:noreply, if(socket.assigns.paused, do: socket, else: load(socket))}
    end

    def handle_info(:tick, socket) do
      schedule_tick()
      {:noreply, if(socket.assigns.paused, do: socket, else: load(socket))}
    end

    def handle_info(_message, socket), do: {:noreply, socket}

    @impl true
    def handle_event("tab", %{"tab" => tab}, socket) do
      case Enum.find(@tabs, fn {key, _label} -> Atom.to_string(key) == tab end) do
        {key, _label} -> {:noreply, assign(socket, :tab, key)}
        nil -> {:noreply, socket}
      end
    end

    def handle_event("filter", params, socket) do
      {:noreply,
       assign(socket,
         status_filter: params["status"] || socket.assigns.status_filter,
         kind_filter: params["kind"] || socket.assigns.kind_filter,
         query: params["query"] || socket.assigns.query
       )}
    end

    def handle_event("select", %{"id" => id}, socket) do
      {:noreply, load_selected(socket, id)}
    end

    def handle_event("close", _params, socket) do
      {:noreply, assign(socket, selected_id: nil, selected: nil)}
    end

    def handle_event("toggle_pause", _params, socket) do
      paused = not socket.assigns.paused
      socket = assign(socket, :paused, paused)
      {:noreply, if(paused, do: socket, else: load(socket))}
    end

    def handle_event("refresh", _params, socket) do
      {:noreply, load(socket)}
    end

    defp load(socket) do
      case Observability.snapshot(socket.assigns.instance) do
        {:ok, snapshot} ->
          socket
          |> assign(:snapshot, snapshot)
          |> assign(:error, nil)
          |> assign(:last_updated, System.system_time(:millisecond))
          |> refresh_selected()

        {:error, reason} ->
          assign(socket, :error, reason)
      end
    end

    defp refresh_selected(%{assigns: %{selected_id: nil}} = socket), do: socket

    defp refresh_selected(socket), do: load_selected(socket, socket.assigns.selected_id)

    defp load_selected(socket, id) do
      case Observability.execution(socket.assigns.instance, cast_id(id)) do
        {:ok, execution} ->
          assign(socket, selected_id: execution.id, selected: execution)

        {:error, _reason} ->
          assign(socket, selected_id: nil, selected: nil, error: :execution_not_found)
      end
    end

    defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)

    defp empty_snapshot do
      %{
        stats: %{
          executions: 0,
          running: 0,
          waiting: 0,
          completed: 0,
          failed: 0,
          agents: 0,
          models: [],
          events: 0,
          newest_started_at: nil
        },
        agents: [],
        executions: [],
        graph: %{conversations: [], edges: [], agent_edges: [], links: []},
        messages: []
      }
    end

    @impl true
    def render(assigns) do
      executions =
        filtered_executions(assigns.snapshot.executions, assigns.status_filter, assigns.query)

      messages = filtered_messages(assigns.snapshot.messages, assigns.kind_filter, assigns.query)

      active =
        Enum.filter(assigns.snapshot.executions, &(&1.status in [:running, :accepted, :waiting]))

      assigns =
        assign(assigns,
          executions: executions,
          messages: messages,
          active: active,
          tabs: @tabs,
          statuses: @statuses,
          kinds: @kinds,
          css: @css
        )

      ~H"""
      <div class="knotra" id="knotra-dashboard">
        <style><%= @css %></style>

        <header class="k-head">
          <div class="k-brand">
            <span class="k-mark">K</span>
            <div>
              <h1>Knotra Observability</h1>
              <p>
                <span :if={@instance} class="k-instance">{inspect(@instance)}</span>
                <span :if={@error} class="k-error-inline">store {to_string(@error)}</span>
                <span :if={@last_updated} class="k-muted">updated {format_clock(@last_updated)}</span>
              </p>
            </div>
          </div>
          <div class="k-actions">
            <span class={["k-live", @paused && "is-paused"]}>
              <span class="k-live-dot"></span>{if @paused, do: "Paused", else: "Live"}
            </span>
            <button class="k-btn" phx-click="toggle_pause">{if @paused, do: "Resume", else: "Pause"}</button>
            <button class="k-btn" phx-click="refresh">Refresh</button>
          </div>
        </header>

        <p :if={@error == :missing_instance} class="k-empty">
          No Knotra instance configured. Mount the dashboard with
          <code>knotra_dashboard "/knotra", instance: MyApp.Agents</code>.
        </p>

        <nav class="k-tabs">
          <button
            :for={{key, label} <- @tabs}
            class={["k-tab", @tab == key && "is-active"]}
            phx-click="tab"
            phx-value-tab={key}
          >
            {label}
            <span :if={key == :executions} class="k-count">{length(@snapshot.executions)}</span>
            <span :if={key == :agents} class="k-count">{length(@snapshot.agents)}</span>
            <span :if={key == :messages} class="k-count">{length(@snapshot.messages)}</span>
          </button>
        </nav>

        <div class="k-body">
          <main class="k-main">
            <.overview
              :if={@tab == :overview}
              snapshot={@snapshot}
              active={@active}
              selected_id={@selected_id}
            />
            <.executions_tab
              :if={@tab == :executions}
              executions={@executions}
              snapshot={@snapshot}
              statuses={@statuses}
              status_filter={@status_filter}
              query={@query}
              selected_id={@selected_id}
            />
            <.agents_tab :if={@tab == :agents} agents={@snapshot.agents} selected_id={@selected_id} />
            <.topology_tab :if={@tab == :topology} graph={@snapshot.graph} selected_id={@selected_id} />
            <.messages_tab
              :if={@tab == :messages}
              messages={@messages}
              snapshot={@snapshot}
              kinds={@kinds}
              kind_filter={@kind_filter}
              query={@query}
            />
          </main>

          <aside :if={@selected} class="k-detail">
            <.detail selected={@selected} />
          </aside>
        </div>
      </div>
      """
    end

    attr(:snapshot, :map, required: true)
    attr(:active, :list, required: true)
    attr(:selected_id, :any, required: true)

    defp overview(assigns) do
      ~H"""
      <section class="k-metrics">
        <.metric label="Executions" value={@snapshot.stats.executions} />
        <.metric label="Running" value={@snapshot.stats.running} tone="running" />
        <.metric label="Waiting" value={@snapshot.stats.waiting} tone="waiting" />
        <.metric label="Completed" value={@snapshot.stats.completed} tone="completed" />
        <.metric label="Failed" value={@snapshot.stats.failed} tone="failed" />
        <.metric label="Agents" value={@snapshot.stats.agents} />
      </section>

      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Active executions</h2>
          <span class="k-muted">{length(@active)} running or waiting</span>
        </header>

        <p :if={@active == []} class="k-empty">
          Nothing is running. Start an execution with <code>Knotra.start/5</code> or
          <code>Knotra.submit/6</code> and it appears here immediately.
        </p>

        <div :if={@active != []} class="k-list">
          <.execution_row :for={execution <- @active} execution={execution} selected_id={@selected_id} />
        </div>
      </section>

      <div class="k-grid2">
        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Agents</h2>
            <button class="k-link" phx-click="tab" phx-value-tab="agents">View all</button>
          </header>
          <p :if={@snapshot.agents == []} class="k-empty">No agent definition has run yet.</p>
          <div class="k-agent-list">
            <.agent_stub :for={agent <- Enum.take(@snapshot.agents, 4)} agent={agent} />
          </div>
        </section>

        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Recent messages</h2>
            <button class="k-link" phx-click="tab" phx-value-tab="messages">View all</button>
          </header>
          <p :if={@snapshot.messages == []} class="k-empty">No messages yet.</p>
          <div class="k-feed is-compact">
            <.message_card :for={message <- Enum.take(@snapshot.messages, 6)} message={message} />
          </div>
        </section>
      </div>

      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Latest executions</h2>
          <span class="k-muted">{@snapshot.stats.events} recorded events</span>
        </header>
        <p :if={@snapshot.executions == []} class="k-empty">No executions recorded.</p>
        <div :if={@snapshot.executions != []} class="k-list">
          <.execution_row
            :for={execution <- Enum.take(@snapshot.executions, 10)}
            execution={execution}
            selected_id={@selected_id}
          />
        </div>
      </section>
      """
    end

    attr(:executions, :list, required: true)
    attr(:snapshot, :map, required: true)
    attr(:statuses, :list, required: true)
    attr(:status_filter, :string, required: true)
    attr(:query, :string, required: true)
    attr(:selected_id, :any, required: true)

    defp executions_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Executions</h2>
          <span class="k-muted">{length(@executions)} shown of {length(@snapshot.executions)} retained</span>
        </header>

        <form id="knotra-executions-filter" class="k-filter" phx-change="filter" phx-submit="filter">
          <label>
            <span>Status</span>
            <select name="status">
              <option :for={{value, label} <- @statuses} value={value} selected={@status_filter == value}>
                {label}
              </option>
            </select>
          </label>
          <label class="k-grow">
            <span>Search</span>
            <input type="search" name="query" value={@query} placeholder="agent, model, id, or input" />
          </label>
        </form>

        <p :if={@executions == []} class="k-empty">No executions match this filter.</p>

        <div :if={@executions != []} class="k-table-wrap">
          <table class="k-table">
            <thead>
              <tr>
                <th>Status</th>
                <th>Agent</th>
                <th>Model</th>
                <th>Execution</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Turns / tools</th>
                <th>Input</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={execution <- @executions}
                class={["k-row", @selected_id == execution.id && "is-selected"]}
                phx-click="select"
                phx-value-id={execution.id}
              >
                <td><.status_badge status={execution.status} /></td>
                <td class="k-agent-cell">{agent_label(execution)}</td>
                <td><code>{model_label(execution)}</code></td>
                <td><code class="kid">{short_id(execution.id)}</code></td>
                <td>{format_clock(execution.started_at)}</td>
                <td>{format_duration(execution.duration_ms)}</td>
                <td>{execution.counts.turns} / {execution.counts.tools}</td>
                <td class="k-preview">{truncate(format_text(execution.input), 64)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      """
    end

    attr(:agents, :list, required: true)
    attr(:selected_id, :any, required: true)

    defp agents_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Agent definitions</h2>
          <span class="k-muted">Aggregated by definition version</span>
        </header>

        <p :if={@agents == []} class="k-empty">No agent definition has run yet.</p>

        <div class="k-agents">
          <.agent_card :for={agent <- @agents} agent={agent} selected_id={@selected_id} />
        </div>
      </section>
      """
    end

    attr(:graph, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp topology_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Conversations</h2>
          <span class="k-muted">Executions grouped by correlation id, oldest first</span>
        </header>

        <p :if={@graph.conversations == []} class="k-empty">No executions recorded.</p>

        <div class="k-flows">
          <article :for={conversation <- @graph.conversations} class="k-flow-card">
            <header>
              <code>{to_string(conversation.id)}</code>
              <span class="k-muted">{length(conversation.executions)} execution(s)</span>
            </header>
            <div class="k-flow">
              <span :for={execution <- conversation.executions} class="k-flow-step">
                <button
                  class={["k-node", status_key(execution.status)]}
                  phx-click="select"
                  phx-value-id={execution.id}
                >
                  <strong>{execution.agent}</strong>
                  <span>{short_id(execution.id)}</span>
                  <em>{status_text(execution.status)}</em>
                </button>
              </span>
            </div>
          </article>
        </div>
      </section>

      <div class="k-grid2">
        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Agent connections</h2>
            <span class="k-muted">Observed parent and conversation handoffs</span>
          </header>

          <p :if={@graph.agent_edges == []} class="k-empty">
            No agent-to-agent handoff recorded yet. Correlate executions with
            <code>trace: [conversation_id: ...]</code> or <code>parent_id: ...</code>.
          </p>

          <table :if={@graph.agent_edges != []} class="k-table">
            <thead>
              <tr><th>From</th><th></th><th>To</th><th>Count</th><th>Kind</th></tr>
            </thead>
            <tbody>
              <tr :for={edge <- @graph.agent_edges}>
                <td class="k-agent-cell">{edge.from}</td>
                <td class="k-arrow-cell">→</td>
                <td class="k-agent-cell">{edge.to}</td>
                <td>{edge.count}</td>
                <td>{edge.kinds |> Enum.map(&to_string/1) |> Enum.join(", ")}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="k-panel">
          <header class="k-panel-head">
            <h2>Explicit links</h2>
            <span class="k-muted">Parent ids and host-declared edges</span>
          </header>

          <p :if={@graph.links == []} class="k-empty">
            No parent or explicit links. Use <code>Knotra.Observability.link/4</code> to add one.
          </p>

          <ul :if={@graph.links != []} class="k-links">
            <li :for={link <- @graph.links}>
              <button class="k-link" phx-click="select" phx-value-id={link.from}>
                {short_id(link.from)}
              </button>
              <span class="k-muted">{link.label}</span>
              <button class="k-link" phx-click="select" phx-value-id={link.to}>
                {short_id(link.to)}
              </button>
            </li>
          </ul>
        </section>
      </div>
      """
    end

    attr(:messages, :list, required: true)
    attr(:snapshot, :map, required: true)
    attr(:kinds, :list, required: true)
    attr(:kind_filter, :string, required: true)
    attr(:query, :string, required: true)

    defp messages_tab(assigns) do
      ~H"""
      <section class="k-panel">
        <header class="k-panel-head">
          <h2>Message stream</h2>
          <span class="k-muted">{length(@messages)} newest of {length(@snapshot.messages)} retained</span>
        </header>

        <form id="knotra-messages-filter" class="k-filter" phx-change="filter" phx-submit="filter">
          <label>
            <span>Kind</span>
            <select name="kind">
              <option :for={{value, label} <- @kinds} value={value} selected={@kind_filter == value}>
                {label}
              </option>
            </select>
          </label>
          <label class="k-grow">
            <span>Search</span>
            <input type="search" name="query" value={@query} placeholder="message text, agent, execution" />
          </label>
        </form>

        <p :if={@messages == []} class="k-empty">No messages match this filter.</p>
        <div :if={@messages != []} class="k-feed">
          <.message_card :for={message <- @messages} message={message} />
        </div>
      </section>
      """
    end

    attr(:selected, :map, required: true)

    defp detail(assigns) do
      ~H"""
      <div class="k-detail-head">
        <div>
          <span class="k-eyebrow">Execution</span>
          <h2><code>{short_id(@selected.id)}</code></h2>
        </div>
        <button class="k-icon-btn" phx-click="close" title="Close detail">×</button>
      </div>

      <div class="k-detail-meta">
        <.status_badge status={@selected.status} />
        <span><strong>{agent_label(@selected)}</strong> · {model_label(@selected)}</span>
        <span>{format_duration(@selected.duration_ms)} · started {format_clock(@selected.started_at)}</span>
      </div>

      <dl class="k-facts">
        <div><dt>Version</dt><dd><code>{@selected.definition.version}</code></dd></div>
        <div><dt>Turns</dt><dd>{@selected.counts.turns}</dd></div>
        <div><dt>Tools</dt><dd>{@selected.counts.tools}</dd></div>
        <div><dt>Retries</dt><dd>{@selected.counts.retries}</dd></div>
        <div><dt>Steps</dt><dd>{@selected.counts.steps}</dd></div>
        <div><dt>Events</dt><dd>{@selected.event_count}</dd></div>
      </dl>

      <div class="k-trace">
        <div :if={@selected.trace.conversation_id}>
          <span>Conversation</span><code>{to_string(@selected.trace.conversation_id)}</code>
        </div>
        <div :if={@selected.trace.parent_id}>
          <span>Parent</span><code>{to_string(@selected.trace.parent_id)}</code>
        </div>
        <div :for={{key, value} <- @selected.trace.labels}>
          <span>{key}</span><code>{to_string(value)}</code>
        </div>
      </div>

      <div :if={@selected.approval} class="k-callout is-warn">
        <strong>
          Approval · {to_string(field(@selected.approval, :disposition) || :pending)}
        </strong>
        <p><code>{to_string(field(@selected.approval, :name) || "operation")}</code></p>
        <pre>{inspect(field(@selected.approval, :arguments), pretty: true, limit: 20)}</pre>
      </div>

      <div :if={@selected.input_request} class="k-callout is-warn">
        <strong>
          Clarification · {to_string(field(@selected.input_request, :disposition) || :pending)}
        </strong>
        <p>{field(@selected.input_request, :prompt)}</p>
      </div>

      <div :if={@selected.output} class="k-callout is-ok">
        <strong>Output</strong>
        <p>{@selected.output}</p>
      </div>

      <div :if={@selected.error} class="k-callout is-error">
        <strong>Error</strong>
        <p>{format_text(@selected.error)}</p>
      </div>

      <div :if={@selected.observation_error} class="k-callout is-error">
        <strong>Observer</strong>
        <p>{to_string(@selected.observation_error)}</p>
      </div>

      <h3 class="k-section-title">Input</h3>
      <p class="k-input">{@selected.input}</p>

      <h3 class="k-section-title">
        Timeline
        <span :if={@selected.event_count > length(@selected.events)} class="k-muted">
          showing newest {length(@selected.events)} of {@selected.event_count}
        </span>
      </h3>

      <ol class="k-timeline">
        <.event_card :for={event <- @selected.events} event={event} />
      </ol>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :any, required: true)
    attr(:tone, :string, default: "default")

    defp metric(assigns) do
      ~H"""
      <div class={["k-metric", "is-" <> @tone]}>
        <span>{@label}</span>
        <strong>{@value}</strong>
      </div>
      """
    end

    attr(:status, :atom, required: true)

    defp status_badge(assigns) do
      ~H"""
      <span class={["k-badge", "is-" <> status_key(@status)]}>
        <span class="k-badge-dot"></span>{status_text(@status)}
      </span>
      """
    end

    attr(:execution, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp execution_row(assigns) do
      ~H"""
      <button
        class={["k-row-card", @selected_id == @execution.id && "is-selected"]}
        phx-click="select"
        phx-value-id={@execution.id}
      >
        <.status_badge status={@execution.status} />
        <span class="k-row-main">
          <strong>{agent_label(@execution)}</strong>
          <span>{truncate(format_text(@execution.input), 110)}</span>
        </span>
        <span class="k-row-side">
          <code>{model_label(@execution)}</code>
          <span>{format_duration(@execution.duration_ms)} · {short_id(@execution.id)}</span>
        </span>
      </button>
      """
    end

    attr(:agent, :map, required: true)

    defp agent_stub(assigns) do
      ~H"""
      <div class="k-agent-stub">
        <strong>{@agent.label}</strong>
        <span><code>{model_display(@agent.model)}</code></span>
        <span class="k-muted">
          {@agent.executions} run(s) · {@agent.running} running
        </span>
      </div>
      """
    end

    attr(:agent, :map, required: true)
    attr(:selected_id, :any, required: true)

    defp agent_card(assigns) do
      ~H"""
      <article class="k-agent-card">
        <header>
          <div>
            <h3>{@agent.label}</h3>
            <code class="k-muted">{@agent.id}</code>
          </div>
          <code>{model_display(@agent.model)}</code>
        </header>

        <dl class="k-facts is-inline">
          <div><dt>Runs</dt><dd>{@agent.executions}</dd></div>
          <div><dt>Running</dt><dd>{@agent.running}</dd></div>
          <div><dt>Waiting</dt><dd>{@agent.waiting}</dd></div>
          <div><dt>Completed</dt><dd>{@agent.completed}</dd></div>
          <div><dt>Failed</dt><dd>{@agent.failed}</dd></div>
          <div><dt>Events</dt><dd>{@agent.events}</dd></div>
        </dl>

        <div class="k-chips">
          <span class="k-chip">loop {module_label(@agent.loop)}</span>
          <span class="k-chip">runtime {module_label(@agent.tool_runtime)}</span>
          <span class="k-chip">observer {module_label(@agent.observer)}</span>
        </div>

        <div class="k-chips">
          <span :if={@agent.tools == []} class="k-chip is-muted">no tools</span>
          <span :for={tool <- @agent.tools} class="k-chip">{tool}</span>
        </div>

        <div class="k-chips">
          <button
            :for={id <- Enum.take(@agent.execution_ids, 8)}
            class={["k-chip", "is-link", @selected_id == id && "is-selected"]}
            phx-click="select"
            phx-value-id={id}
          >
            {short_id(id)}
          </button>
        </div>
      </article>
      """
    end

    attr(:message, :map, required: true)

    defp message_card(assigns) do
      ~H"""
      <article class={["k-msg", "is-" <> to_string(@message.kind)]}>
        <header>
          <span class={["k-kind", "is-" <> to_string(@message.kind)]}>{@message.kind}</span>
          <strong>{@message.agent}</strong>
          <span class="k-muted">{@message.model}</span>
          <button class="k-link" phx-click="select" phx-value-id={@message.execution_id}>
            {short_id(@message.execution_id)}
          </button>
          <span class="k-muted">{format_clock(@message.at)}</span>
        </header>
        <p>{truncate(format_text(@message.text), 600)}</p>
        <p :if={@message.tool} class="k-muted"><code>{@message.tool}</code></p>
      </article>
      """
    end

    attr(:event, :map, required: true)

    defp event_card(%{event: %{type: :started}} = assigns) do
      assigns = assign(assigns, :text, format_text(data(assigns.event, :input)))

      ~H"""
      <li class="k-event is-input">
        <.event_head event={@event} label="input" />
        <p>{@text}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :model_started}} = assigns) do
      ~H"""
      <li class="k-event is-model">
        <.event_head event={@event} label="model request" />
        <p class="k-muted">Waiting for the model reply.</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :model_result}} = assigns) do
      assigns =
        assign(assigns,
          text: format_text(data(assigns.event, :text)),
          calls: data(assigns.event, :calls) || [],
          usage: data(assigns.event, :usage)
        )

      ~H"""
      <li class="k-event is-assistant">
        <.event_head event={@event} label="assistant" />
        <p :if={@text != ""}>{@text}</p>
        <ul :if={@calls != []} class="k-calls">
          <li :for={call <- @calls}>
            <code>{call_name(call)}</code>
            <span>{format_args(call)}</span>
          </li>
        </ul>
        <p :if={@usage} class="k-muted k-usage">usage {format_usage(@usage)}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: :tool_started}} = assigns) do
      call = data(assigns.event, :call)
      assigns = assign(assigns, call_name: call_name(call), args: format_args(call))

      ~H"""
      <li class="k-event is-tool">
        <.event_head event={@event} label="tool call" />
        <p><code>{@call_name}</code></p>
        <pre>{@args}</pre>
      </li>
      """
    end

    defp event_card(%{event: %{type: :tool_result}} = assigns) do
      assign(
        assigns,
        call_name: call_name(data(assigns.event, :call)),
        output: format_text(data(assigns.event, :output))
      )

      ~H"""
      <li class="k-event is-tool">
        <.event_head event={@event} label="tool result" />
        <p><code>{@call_name}</code></p>
        <pre>{@output}</pre>
      </li>
      """
    end

    defp event_card(%{event: %{type: type}} = assigns)
         when type in [:completed, :failed, :cancelled, :blocked, :rejected, :expired, :waiting] do
      assigns =
        assign(
          assigns,
          :body,
          format_text(
            data(assigns.event, :output) || data(assigns.event, :error) ||
              data(assigns.event, :reason)
          )
        )

      ~H"""
      <li class={["k-event", "is-terminal", "is-" <> to_string(@event.type)]}>
        <.event_head event={@event} label={to_string(@event.type)} />
        <p :if={@body != ""}>{@body}</p>
      </li>
      """
    end

    defp event_card(%{event: %{type: type}} = assigns)
         when type in [:approval_answered, :input_answered] do
      assigns =
        assign(
          assigns,
          :body,
          format_text(data(assigns.event, :answer) || data(assigns.event, :decision))
        )

      ~H"""
      <li class="k-event is-human">
        <.event_head event={@event} label={to_string(@event.type)} />
        <p>{@body}</p>
      </li>
      """
    end

    defp event_card(assigns) do
      assigns = assign(assigns, :body, inspect(assigns.event.data, pretty: true, limit: 20))

      ~H"""
      <li class="k-event">
        <.event_head event={@event} label={to_string(@event.type)} />
        <pre>{@body}</pre>
      </li>
      """
    end

    attr(:event, :map, required: true)
    attr(:label, :string, required: true)

    defp event_head(assigns) do
      ~H"""
      <header class="k-event-head">
        <span class="k-seq">{@event.sequence}</span>
        <strong>{@label}</strong>
        <span class="k-muted">{@event.elapsed_ms} ms</span>
      </header>
      """
    end

    defp filtered_executions(executions, status_filter, query) do
      executions
      |> Enum.filter(&status_match?(&1.status, status_filter))
      |> Enum.filter(fn execution ->
        search?(
          [
            execution.id,
            agent_label(execution),
            model_label(execution),
            execution.input,
            execution.definition.version
          ],
          query
        )
      end)
    end

    defp filtered_messages(messages, kind_filter, query) do
      messages
      |> Enum.filter(fn message ->
        kind_filter == "all" or to_string(message.kind) == kind_filter
      end)
      |> Enum.filter(fn message ->
        search?([message.text, message.agent, message.execution_id, message.tool], query)
      end)
    end

    defp status_match?(_status, "all"), do: true
    defp status_match?(status, "running"), do: status in [:running, :accepted]
    defp status_match?(status, "waiting"), do: status == :waiting
    defp status_match?(status, "completed"), do: status == :completed

    defp status_match?(status, "failed"),
      do: status in [:failed, :blocked, :cancelled, :rejected, :expired]

    defp status_match?(_status, _filter), do: true

    defp search?(_values, query) when query in [nil, ""], do: true

    defp search?(values, query) do
      query = query |> to_string() |> String.trim() |> String.downcase()
      query == "" or Enum.any?(values, &contains?(&1, query))
    end

    defp contains?(nil, _query), do: false

    defp contains?(value, query) do
      value |> to_string() |> String.downcase() |> String.contains?(query)
    end

    defp cast_id(id) when is_integer(id), do: id

    defp cast_id(id) when is_binary(id) do
      case Integer.parse(id) do
        {integer, ""} -> integer
        _ -> id
      end
    end

    defp data(event, key), do: field(event.data || %{}, key)

    defp field(%{} = map, key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp field(_value, _key), do: nil

    defp call_name(call), do: field(call, :name) || "tool"
    defp format_args(call), do: inspect(field(call, :arguments) || %{}, pretty: true, limit: 20)

    defp format_usage(usage) when is_map(usage) do
      keys = [:input_tokens, :output_tokens, :total_tokens, :input, :output, :total]

      parts =
        for key <- keys,
            value = field(usage, key),
            not is_nil(value) do
          "#{key}=#{value}"
        end

      if parts == [], do: inspect(usage, limit: 8), else: Enum.join(parts, " ")
    end

    defp format_usage(usage), do: inspect(usage)

    defp agent_label(%{trace: %{agent: agent}}) when is_binary(agent), do: agent
    defp agent_label(%{definition: %{version: version}}), do: version
    defp agent_label(_execution), do: "agent"

    defp model_label(%{definition: %{model: model}}), do: model_display(model)
    defp model_label(%{model: model}), do: model_display(model)
    defp model_label(_execution), do: "model"

    defp model_display(%{id: id}) when is_binary(id) and id != "", do: id
    defp model_display(%{module: module}) when is_binary(module), do: module_label(module)
    defp model_display(_model), do: "model"

    defp module_label(nil), do: "—"

    defp module_label(module) when is_binary(module),
      do: module |> String.split(".") |> List.last()

    defp module_label(module), do: module |> inspect() |> module_label()

    defp status_key(status) when status in [:running, :accepted], do: "running"

    defp status_key(status) when status in [:failed, :blocked, :cancelled, :rejected, :expired],
      do: "failed"

    defp status_key(status), do: to_string(status)

    defp status_text(status), do: status |> to_string() |> String.replace("_", " ")

    defp short_id(id), do: id |> to_string() |> String.slice(0, 12)

    defp format_clock(nil), do: "—"

    defp format_clock(milliseconds) when is_integer(milliseconds) do
      milliseconds
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%H:%M:%S")
    rescue
      _ -> "—"
    end

    defp format_clock(_value), do: "—"

    defp format_duration(nil), do: "—"

    defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000,
      do: "#{milliseconds} ms"

    defp format_duration(milliseconds) when is_number(milliseconds) do
      "#{Float.round(milliseconds / 1_000, 1)} s"
    end

    defp format_duration(_value), do: "—"

    defp format_text(nil), do: ""
    defp format_text(value) when is_binary(value), do: value
    defp format_text(value), do: inspect(value)

    defp truncate(nil, _limit), do: ""
    defp truncate(text, limit) when is_binary(text), do: String.slice(text, 0, limit)
    defp truncate(text, limit), do: text |> format_text() |> truncate(limit)
  end
end
