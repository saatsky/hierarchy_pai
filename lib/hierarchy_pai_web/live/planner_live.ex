defmodule HierarchyPaiWeb.PlannerLive do
  use HierarchyPaiWeb, :live_view

  alias HierarchyPai.LLMProvider
  alias HierarchyPai.Agents.AgentRegistry

  @providers [
    {"Jan.ai (local)", :jan_ai},
    {"OpenAI", :openai},
    {"Anthropic", :anthropic},
    {"Ollama (local)", :ollama},
    {"Custom endpoint", :custom}
  ]

  @impl true
  def mount(_params, _session, socket) do
    session_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    pubsub_topic = "planner:#{session_id}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(HierarchyPai.PubSub, pubsub_topic)
      # Auto-check Jan.ai on connect
      send(self(), :fetch_local_models)
    end

    {:ok,
     socket
     |> assign(:session_id, session_id)
     |> assign(:pubsub_topic, pubsub_topic)
     |> assign(:providers, @providers)
     |> assign(:provider, :jan_ai)
     |> assign(:model, "")
     |> assign(:api_key, "")
     |> assign(:custom_endpoint, "")
     |> assign(:local_server_status, :checking)
     |> assign(:local_models, [])
     |> assign(:local_host, "")
     |> assign(:wsl2, LLMProvider.wsl2?())
     |> assign(:max_retries, 1)
     |> assign(:task, "")
     |> assign(:status, :idle)
     |> assign(:plan, nil)
     |> assign(:accepted_steps, MapSet.new())
     |> assign(:step_configs, %{})
     |> assign(:step_results, [])
     |> assign(:step_statuses, %{})
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:step_outputs, %{})
     |> assign(:step_streams, %{})
     |> assign(:step_agent_types, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:current_step_id, nil)
     |> assign(:final_stream, "")
     |> assign(:final_answer, nil)
     |> assign(:error, nil)
     |> assign(:planner_stream, "")
     |> assign(:elapsed_seconds, 0)
     |> assign(:task_pid, nil)}
  end

  @impl true
  def handle_event("provider_changed", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    require Logger
    Logger.debug("provider_changed: #{inspect(provider)}")

    socket =
      socket
      |> assign(:provider, provider)
      |> assign(:model, "")
      |> assign(:api_key, "")
      |> assign(:local_models, [])

    socket =
      if LLMProvider.local_provider?(provider) do
        send(self(), :fetch_local_models)

        socket
        |> assign(:local_server_status, :checking)
        |> assign(:max_retries, 1)
      else
        default = hd(LLMProvider.default_models(provider) ++ [""])

        socket
        |> assign(:local_server_status, :unknown)
        |> assign(:model, default)
        |> assign(:max_retries, 2)
      end

    {:noreply, socket}
  end

  @impl true
  # From quick-select buttons (phx-value-model)
  def handle_event("update_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model, model)}
  end

  # From the text input (phx-change / phx-blur on a standalone input sends "value")
  def handle_event("update_model", %{"value" => model}, socket) do
    {:noreply, assign(socket, :model, model)}
  end

  @impl true
  def handle_event("update_api_key", %{"value" => key}, socket) do
    {:noreply, assign(socket, :api_key, key)}
  end

  @impl true
  def handle_event("update_max_retries", %{"value" => val}, socket) do
    retries = val |> String.trim() |> String.to_integer() |> max(0) |> min(5)
    {:noreply, assign(socket, :max_retries, retries)}
  end

  @impl true
  def handle_event("update_endpoint", %{"value" => ep}, socket) do
    {:noreply, assign(socket, :custom_endpoint, ep)}
  end

  @impl true
  def handle_event("update_local_host", %{"value" => host}, socket) do
    {:noreply, assign(socket, :local_host, host)}
  end

  @impl true
  def handle_event("check_local_host", _params, socket) do
    send(self(), :fetch_local_models)
    {:noreply, assign(socket, :local_server_status, :checking)}
  end

  @impl true
  def handle_event("update_task", %{"value" => task}, socket) do
    {:noreply, assign(socket, :task, task)}
  end

  @impl true
  def handle_event("run", _params, %{assigns: %{status: :idle}} = socket) do
    task = String.trim(socket.assigns.task)

    if task == "" do
      {:noreply, assign(socket, :error, "Please enter a task to plan.")}
    else
      provider_config = build_provider_config(socket.assigns)
      topic = socket.assigns.pubsub_topic

      {:ok, pid} =
        Task.start(fn ->
          try do
            HierarchyPai.Orchestrator.plan(task, provider_config, topic)
          rescue
            e ->
              Phoenix.PubSub.broadcast(
                HierarchyPai.PubSub,
                topic,
                {:orchestrator, {:error, Exception.message(e)}}
              )
          end
        end)

      send(self(), :tick)

      {:noreply,
       socket
       |> assign(:status, :planning)
       |> assign(:plan, nil)
       |> assign(:accepted_steps, MapSet.new())
       |> assign(:step_configs, %{})
       |> assign(:step_results, [])
       |> assign(:step_statuses, %{})
       |> assign(:step_errors, %{})
       |> assign(:step_outputs, %{})
       |> assign(:step_agent_types, %{})
       |> assign(:selected_step_id, nil)
       |> assign(:step_streams, %{})
       |> assign(:current_step_id, nil)
       |> assign(:final_stream, "")
       |> assign(:final_answer, nil)
       |> assign(:error, nil)
       |> assign(:task_pid, pid)
       |> assign(:planner_stream, "")
       |> assign(:elapsed_seconds, 0)}
    end
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_execution", _params, socket) do
    accepted_step_ids = socket.assigns.accepted_steps
    plan = socket.assigns.plan
    step_agent_types = socket.assigns.step_agent_types
    step_configs = socket.assigns.step_configs
    default_config = build_provider_config(socket.assigns)
    topic = socket.assigns.pubsub_topic

    # Merge user-selected agent types into each step before execution
    plan_with_agents =
      update_in(plan["steps"], fn steps ->
        Enum.map(steps, fn step ->
          agent_type = Map.get(step_agent_types, step["id"], step["agent_type"] || "executor")
          Map.put(step, "agent_type", agent_type)
        end)
      end)

    step_statuses =
      accepted_step_ids
      |> MapSet.to_list()
      |> Enum.map(&{&1, :pending})
      |> Map.new()

    {:ok, pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.execute(
            plan_with_agents,
            accepted_step_ids,
            step_configs,
            default_config,
            topic
          )
        rescue
          e ->
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              topic,
              {:orchestrator, {:error, Exception.message(e)}}
            )
        end
      end)

    send(self(), :tick)

    {:noreply,
     socket
     |> assign(:status, :executing)
     |> assign(:plan, plan_with_agents)
     |> assign(:step_statuses, step_statuses)
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:step_streams, %{})
     |> assign(:current_step_id, nil)
     |> assign(:final_stream, "")
     |> assign(:final_answer, nil)
     |> assign(:step_results, [])
     |> assign(:error, nil)
     |> assign(:task_pid, pid)
     |> assign(:elapsed_seconds, 0)}
  end

  @impl true
  def handle_event("toggle_step", %{"step_id" => id_str}, socket) do
    id = String.to_integer(id_str)

    accepted =
      if MapSet.member?(socket.assigns.accepted_steps, id) do
        MapSet.delete(socket.assigns.accepted_steps, id)
      else
        MapSet.put(socket.assigns.accepted_steps, id)
      end

    {:noreply, assign(socket, :accepted_steps, accepted)}
  end

  @impl true
  def handle_event("accept_all_steps", _params, socket) do
    all_ids = socket.assigns.plan["steps"] |> Enum.map(& &1["id"]) |> MapSet.new()
    {:noreply, assign(socket, :accepted_steps, all_ids)}
  end

  @impl true
  def handle_event("reject_all_steps", _params, socket) do
    {:noreply, assign(socket, :accepted_steps, MapSet.new())}
  end

  @impl true
  def handle_event(
        "update_step_config",
        %{"step_id" => id_str, "provider" => p, "model" => m},
        socket
      ) do
    id = String.to_integer(id_str)
    cfg = %{provider: String.to_existing_atom(p), model: m, api_key: socket.assigns.api_key}
    {:noreply, update(socket, :step_configs, &Map.put(&1, id, cfg))}
  end

  @impl true
  def handle_event(
        "update_step_agent_type",
        %{"step_id" => id_str, "agent_type" => agent_type},
        socket
      ) do
    id = String.to_integer(id_str)
    {:noreply, update(socket, :step_agent_types, &Map.put(&1, id, agent_type))}
  end

  @impl true
  def handle_event("accept_answer", _params, socket) do
    {:noreply, assign(socket, :status, :done)}
  end

  @impl true
  def handle_event("regenerate_answer", _params, socket) do
    goal = socket.assigns.plan["goal"] || ""
    step_results = socket.assigns.step_results
    provider_config = build_provider_config(socket.assigns)
    topic = socket.assigns.pubsub_topic

    {:ok, pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.reaggregate(goal, step_results, provider_config, topic)
        rescue
          e ->
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              topic,
              {:orchestrator, {:error, Exception.message(e)}}
            )
        end
      end)

    send(self(), :tick)

    {:noreply,
     socket
     |> assign(:status, :aggregating)
     |> assign(:final_stream, "")
     |> assign(:final_answer, nil)
     |> assign(:task_pid, pid)
     |> assign(:elapsed_seconds, 0)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if socket.assigns.task_pid do
      Process.exit(socket.assigns.task_pid, :shutdown)
    end

    # Return to idle, keep @task text so the user can retry or edit
    {:noreply,
     socket
     |> assign(:status, :idle)
     |> assign(:task_pid, nil)
     |> assign(:planner_stream, "")
     |> assign(:elapsed_seconds, 0)
     |> assign(:plan, nil)
     |> assign(:accepted_steps, MapSet.new())
     |> assign(:step_configs, %{})
     |> assign(:step_results, [])
     |> assign(:step_statuses, %{})
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:step_agent_types, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("provider_model_selected", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model, model)}
  end

  @impl true
  def handle_event("view_step_output", %{"step_id" => step_id}, socket) do
    id = String.to_integer(step_id)
    {:noreply, assign(socket, :selected_step_id, id)}
  end

  @impl true
  def handle_event("close_step_output", _params, socket) do
    {:noreply, assign(socket, :selected_step_id, nil)}
  end

  @impl true
  def handle_event("retry_local_server", _params, socket) do
    send(self(), :fetch_local_models)
    {:noreply, assign(socket, :local_server_status, :checking)}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:status, :idle)
     |> assign(:plan, nil)
     |> assign(:accepted_steps, MapSet.new())
     |> assign(:step_configs, %{})
     |> assign(:step_results, [])
     |> assign(:step_statuses, %{})
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:step_agent_types, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:step_streams, %{})
     |> assign(:current_step_id, nil)
     |> assign(:final_stream, "")
     |> assign(:final_answer, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("retry_failed_steps", _params, socket) do
    failed_ids =
      socket.assigns.step_statuses
      |> Enum.filter(fn {_id, s} -> s == :error end)
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    plan = socket.assigns.plan
    step_configs = socket.assigns.step_configs
    default_config = build_provider_config(socket.assigns)
    topic = socket.assigns.pubsub_topic

    # Reset failed steps to :pending
    new_statuses =
      Enum.reduce(failed_ids, socket.assigns.step_statuses, fn id, acc ->
        Map.put(acc, id, :pending)
      end)

    {:ok, pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.execute_steps(
            plan,
            failed_ids,
            step_configs,
            default_config,
            topic
          )
        rescue
          e ->
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              topic,
              {:orchestrator, {:error, Exception.message(e)}}
            )
        end
      end)

    send(self(), :tick)

    {:noreply,
     socket
     |> assign(:status, :executing)
     |> assign(:step_statuses, new_statuses)
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:selected_step_id, nil)
     |> assign(:task_pid, pid)}
  end

  @impl true
  def handle_event("skip_and_aggregate", _params, socket) do
    goal = get_in(socket.assigns.plan, ["goal"]) || ""
    step_results = socket.assigns.step_results
    provider_config = build_provider_config(socket.assigns)
    topic = socket.assigns.pubsub_topic

    {:ok, _pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.reaggregate(goal, step_results, provider_config, topic)
        rescue
          e ->
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              topic,
              {:orchestrator, {:error, Exception.message(e)}}
            )
        end
      end)

    {:noreply,
     socket
     |> assign(:status, :aggregating)
     |> assign(:step_errors, %{})
     |> assign(:step_outputs, %{})
     |> assign(:selected_step_id, nil)}
  end

  # ── Local model discovery ──────────────────────────────────────────────────

  @impl true
  def handle_info(:fetch_local_models, socket) do
    provider = socket.assigns.provider
    custom = if socket.assigns.local_host != "", do: socket.assigns.local_host, else: nil
    pid = self()

    Task.start(fn ->
      result = LLMProvider.fetch_local_models(provider, custom)
      send(pid, {:local_models_result, result})
    end)

    {:noreply, assign(socket, :local_server_status, :checking)}
  end

  def handle_info({:local_models_result, {:ok, [], base}}, socket) do
    {:noreply,
     socket
     |> assign(:local_server_status, :online)
     |> assign(:local_models, [])
     |> assign(:local_host, base)
     |> assign(:model, "")}
  end

  def handle_info({:local_models_result, {:ok, models, base}}, socket) do
    {:noreply,
     socket
     |> assign(:local_server_status, :online)
     |> assign(:local_models, models)
     |> assign(:local_host, base)
     |> assign(:model, hd(models))}
  end

  def handle_info({:local_models_result, {:error, :server_offline}}, socket) do
    {:noreply,
     socket
     |> assign(:local_server_status, :offline)
     |> assign(:local_models, [])
     |> assign(:model, "")}
  end

  def handle_info({:local_models_result, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:local_server_status, :offline)
     |> assign(:local_models, [])
     |> assign(:model, "")}
  end

  # ── PubSub event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_info({:orchestrator, :planning_started}, socket) do
    {:noreply,
     socket
     |> assign(:status, :planning)
     |> assign(:elapsed_seconds, 0)}
  end

  def handle_info({:orchestrator, {:plan_ready, plan}}, socket) do
    all_ids = plan["steps"] |> Enum.map(& &1["id"]) |> MapSet.new()

    agent_types =
      Map.new(plan["steps"] || [], fn s ->
        {s["id"], s["agent_type"] || "executor"}
      end)

    {:noreply,
     socket
     |> assign(:plan, plan)
     |> assign(:accepted_steps, all_ids)
     |> assign(:step_configs, %{})
     |> assign(:step_agent_types, agent_types)
     |> assign(:status, :review_plan)
     |> assign(:planner_stream, "")
     |> assign(:elapsed_seconds, 0)}
  end

  def handle_info({:orchestrator, {:step_started, step}}, socket) do
    step_id = step["id"]

    {:noreply,
     socket
     |> assign(:current_step_id, step_id)
     |> update(:step_statuses, &Map.put(&1, step_id, :running))
     |> update(:step_streams, &Map.put(&1, step_id, ""))}
  end

  def handle_info({:orchestrator, {:step_token, step_id, token}}, socket) do
    {:noreply,
     update(socket, :step_streams, fn streams ->
       Map.update(streams, step_id, token, &(&1 <> token))
     end)}
  end

  def handle_info({:orchestrator, {:step_done, step_id, output}}, socket) do
    {:noreply,
     socket
     |> update(:step_statuses, &Map.put(&1, step_id, :done))
     |> update(:step_outputs, &Map.put(&1, step_id, output))}
  end

  def handle_info({:orchestrator, {:step_error, step_id, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:status, :step_failed)
     |> update(:step_statuses, &Map.put(&1, step_id, :error))
     |> update(:step_errors, &Map.put(&1, step_id, reason))}
  end

  # Partial results from a retry run — merge into existing step_results
  def handle_info({:orchestrator, {:partial_results_ready, results}}, socket) do
    merged = (socket.assigns.step_results || []) ++ results
    {:noreply, assign(socket, :step_results, merged)}
  end

  # Wave failed — step_error events already set :step_failed; ignore if already there
  def handle_info({:orchestrator, :wave_failed}, %{assigns: %{status: :step_failed}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:orchestrator, :wave_failed}, socket) do
    {:noreply, assign(socket, :status, :step_failed)}
  end

  def handle_info({:orchestrator, {:results_ready, results}}, socket) do
    {:noreply, assign(socket, :step_results, results)}
  end

  def handle_info({:orchestrator, :aggregating_started}, socket) do
    {:noreply,
     socket
     |> assign(:status, :aggregating)
     |> assign(:current_step_id, nil)}
  end

  def handle_info({:orchestrator, {:final_token, token}}, socket) do
    {:noreply, update(socket, :final_stream, &(&1 <> token))}
  end

  def handle_info({:orchestrator, {:answer_ready, answer}}, socket) do
    {:noreply,
     socket
     |> assign(:status, :review_answer)
     |> assign(:final_answer, answer)
     |> assign(:final_stream, "")
     |> assign(:task_pid, nil)
     |> assign(:elapsed_seconds, 0)}
  end

  # Ignore generic errors if we're already showing step-level failures
  def handle_info(
        {:orchestrator, {:error, _reason}},
        %{assigns: %{status: :step_failed}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info({:orchestrator, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:status, :error)
     |> assign(:error, reason)
     |> assign(:task_pid, nil)
     |> assign(:elapsed_seconds, 0)}
  end

  def handle_info({:orchestrator, {:planner_token, token}}, socket) do
    {:noreply, update(socket, :planner_stream, &(&1 <> token))}
  end

  def handle_info(:tick, %{assigns: %{status: status}} = socket)
      when status in [:planning, :executing, :aggregating, :step_failed] do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, update(socket, :elapsed_seconds, &(&1 + 1))}
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp build_provider_config(assigns) do
    base = %{
      provider: assigns.provider,
      model: String.trim(assigns.model),
      api_key: String.trim(assigns.api_key),
      max_retries: assigns.max_retries
    }

    cond do
      assigns.provider == :custom ->
        Map.put(base, :endpoint, String.trim(assigns.custom_endpoint))

      LLMProvider.local_provider?(assigns.provider) and assigns.local_host != "" ->
        Map.put(base, :local_base, assigns.local_host)

      true ->
        base
    end
  end

  defp step_config_for(step_id, step_configs, global_provider, global_model) do
    Map.get(step_configs, step_id, %{provider: global_provider, model: global_model})
  end

  defp compute_waves(steps) do
    build_wave_levels(steps, MapSet.new(), 1, [])
  end

  defp build_wave_levels([], _done, _num, acc), do: Enum.reverse(acc)

  defp build_wave_levels(remaining, done, num, acc) do
    {ready, not_ready} =
      Enum.split_with(remaining, fn step ->
        (step["depends_on"] || [])
        |> Enum.all?(&MapSet.member?(done, &1))
      end)

    if ready == [] do
      Enum.reverse([{num, remaining} | acc])
    else
      new_done = Enum.reduce(ready, done, &MapSet.put(&2, &1["id"]))
      build_wave_levels(not_ready, new_done, num + 1, [{num, ready} | acc])
    end
  end

  defp steps_by_status(plan, step_statuses, accepted_steps, target_status) do
    (plan["steps"] || [])
    |> Enum.filter(fn step ->
      MapSet.member?(accepted_steps, step["id"]) and
        Map.get(step_statuses, step["id"]) == target_status
    end)
  end

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-800 text-slate-100">
        <%!-- Header --%>
        <header class="border-b border-slate-700/50 bg-slate-900/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="w-9 h-9 rounded-xl bg-gradient-to-br from-violet-500 to-indigo-600 flex items-center justify-center shadow-lg">
                <.icon name="hero-cpu-chip" class="w-5 h-5 text-white" />
              </div>
              <div>
                <h1 class="text-lg font-bold text-white tracking-tight">Hierarchical Planner AI</h1>
                <p class="text-xs text-slate-400">Multi-agent reasoning pipeline</p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <span class={[
                "px-2.5 py-1 rounded-full text-xs font-medium",
                status_badge_class(@status)
              ]}>
                {status_label(@status)}
              </span>
              <%= if @status in [:done, :error, :review_answer, :step_failed] do %>
                <button
                  phx-click="reset"
                  class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-200 transition-colors"
                >
                  New task
                </button>
              <% end %>
            </div>
          </div>
        </header>

        <div class="max-w-3xl mx-auto px-6 py-8 space-y-6">
          <%!-- Error banner --%>
          <%= if @error do %>
            <div class="bg-red-900/30 border border-red-700/50 rounded-xl p-4 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-400 shrink-0 mt-0.5" />
              <p class="text-sm text-red-300">{@error}</p>
            </div>
          <% end %>

          <%!-- Task input card --%>
          <div class="bg-slate-800/60 border border-slate-700/50 rounded-2xl p-5 space-y-4 backdrop-blur-sm">
            <h2 class="text-sm font-semibold text-slate-300 uppercase tracking-wider flex items-center gap-2">
              <.icon name="hero-pencil-square" class="w-4 h-4 text-violet-400" /> Task
            </h2>

            <textarea
              phx-keyup="update_task"
              phx-blur="update_task"
              name="task"
              rows="4"
              disabled={@status != :idle}
              placeholder="Describe your task or goal in detail&hellip;"
              class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent resize-none leading-relaxed disabled:opacity-50 disabled:cursor-not-allowed"
            >{@task}</textarea>

            <%= if @status == :idle do %>
              <button
                id="run-button"
                phx-click="run"
                disabled={
                  String.trim(@task) == "" or
                    String.trim(@model) == "" or
                    (@local_server_status in [:checking, :offline] and
                       LLMProvider.local_provider?(@provider))
                }
                class="w-full py-2.5 px-4 rounded-xl font-semibold text-sm transition-all duration-200 flex items-center justify-center gap-2 disabled:opacity-40 disabled:cursor-not-allowed bg-gradient-to-r from-violet-600 to-indigo-600 hover:from-violet-500 hover:to-indigo-500 text-white shadow-lg shadow-violet-900/30 hover:shadow-violet-800/40"
              >
                <.icon name="hero-play" class="w-4 h-4" /> Run Planner
              </button>
            <% else %>
              <div class="flex items-center gap-3">
                <div class="flex-1 py-2.5 px-4 rounded-xl text-sm flex items-center justify-center gap-2 bg-slate-700/50 border border-slate-600/50 text-slate-400">
                  <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin text-violet-400" />
                  <span>{status_label(@status)}&hellip;</span>
                </div>
                <button
                  id="cancel-button"
                  phx-click="cancel"
                  class="py-2.5 px-5 rounded-xl font-semibold text-sm transition-all duration-200 flex items-center gap-2 bg-red-900/50 hover:bg-red-800/60 border border-red-700/50 text-red-300 hover:text-red-200"
                >
                  <.icon name="hero-stop" class="w-4 h-4" /> Cancel
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Planning spinner --%>
          <%= if @status == :planning do %>
            <div class="bg-slate-800/60 border border-slate-700/50 rounded-2xl p-6 space-y-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <div class="w-8 h-8 rounded-lg bg-violet-600/20 flex items-center justify-center">
                    <.icon name="hero-arrow-path" class="w-4 h-4 text-violet-400 animate-spin" />
                  </div>
                  <div>
                    <p class="text-sm font-semibold text-slate-200">Analysing task&hellip;</p>
                    <p class="text-xs text-slate-400">Elapsed: {@elapsed_seconds}s</p>
                  </div>
                </div>
                <button
                  phx-click="cancel"
                  class="px-3 py-1.5 text-xs font-medium rounded-lg bg-red-900/30 hover:bg-red-800/40 text-red-400 border border-red-700/40 transition-colors"
                >
                  Cancel
                </button>
              </div>
              <%= if @planner_stream != "" do %>
                <div class="bg-slate-900/60 rounded-xl p-4 max-h-64 overflow-y-auto">
                  <pre class="text-xs text-slate-300 whitespace-pre-wrap font-mono leading-relaxed">{@planner_stream}</pre>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Plan Review --%>
          <%= if @status == :review_plan and @plan do %>
            <div class="bg-slate-800/60 border border-slate-700/50 rounded-2xl overflow-hidden backdrop-blur-sm">
              <div class="px-5 py-4 border-b border-slate-700/50 flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <.icon name="hero-clipboard-document-check" class="w-4 h-4 text-violet-400" />
                  <h2 class="font-semibold text-slate-200">Plan Review</h2>
                  <span class="text-xs text-slate-400">{length(@plan["steps"] || [])} steps</span>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    phx-click="cancel"
                    class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700/60 hover:bg-red-900/40 border border-slate-600/40 hover:border-red-700/50 text-slate-400 hover:text-red-300 transition-colors flex items-center gap-1.5"
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel plan
                  </button>
                  <button
                    phx-click="reject_all_steps"
                    class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-300 transition-colors"
                  >
                    Reject All
                  </button>
                  <button
                    phx-click="accept_all_steps"
                    class="px-3 py-1.5 text-xs font-medium rounded-lg bg-violet-600/30 hover:bg-violet-600/40 text-violet-300 border border-violet-700/40 transition-colors"
                  >
                    Accept All
                  </button>
                </div>
              </div>

              <div class="px-5 py-3 bg-violet-600/10 border-b border-slate-700/30">
                <p class="text-xs font-medium text-violet-400 uppercase tracking-wider mb-1">
                  Goal
                </p>
                <p class="text-sm text-slate-200">{@plan["goal"]}</p>
              </div>

              <%= for {wave_num, wave_steps} <- compute_waves(@plan["steps"] || []) do %>
                <div class="px-5 py-4 border-b border-slate-700/30 last:border-0">
                  <div class="flex items-center gap-2 mb-3">
                    <span class="text-xs font-medium px-2.5 py-0.5 rounded-full bg-indigo-600/20 text-indigo-400 border border-indigo-700/40">
                      Wave {wave_num}
                    </span>
                    <span class="text-xs text-slate-500">
                      {length(wave_steps)} step(s) &mdash; run in parallel
                    </span>
                  </div>
                  <div class="space-y-3">
                    <%= for step <- wave_steps do %>
                      <% step_cfg = step_config_for(step["id"], @step_configs, @provider, @model) %>
                      <% accepted = MapSet.member?(@accepted_steps, step["id"]) %>
                      <div class={[
                        "rounded-xl p-4 border transition-all duration-150",
                        if(accepted,
                          do: "bg-slate-700/40 border-slate-600/50",
                          else: "bg-slate-800/40 border-slate-700/30 opacity-60"
                        )
                      ]}>
                        <div class="flex items-start gap-3">
                          <input
                            type="checkbox"
                            phx-click="toggle_step"
                            phx-value-step_id={step["id"]}
                            checked={accepted}
                            class="mt-1 w-4 h-4 rounded cursor-pointer accent-violet-500"
                          />
                          <div class="flex-1 min-w-0">
                            <div class="flex items-center gap-2 mb-1">
                              <span class="text-xs font-bold text-violet-400 shrink-0">
                                #{step["id"]}
                              </span>
                              <p class="text-sm font-semibold text-slate-200">{step["title"]}</p>
                            </div>

                            <%= if (step["depends_on"] || []) != [] do %>
                              <p class="text-xs text-amber-400/80 mb-1.5">
                                Requires: {Enum.map_join(
                                  step["depends_on"] || [],
                                  ", ",
                                  &"Step #{&1}"
                                )}
                              </p>
                            <% end %>

                            <details class="mb-2 group">
                              <summary class="text-xs text-slate-500 cursor-pointer hover:text-slate-400 select-none">
                                View instruction
                              </summary>
                              <p class="text-xs text-slate-400 mt-1.5 leading-relaxed pl-3 border-l border-slate-700">
                                {step["instruction"]}
                              </p>
                            </details>

                            <form
                              phx-change="update_step_config"
                              id={"step-cfg-#{step["id"]}"}
                              class="flex items-center gap-2"
                            >
                              <input type="hidden" name="step_id" value={step["id"]} />
                              <select
                                name="provider"
                                class="bg-slate-900 border border-slate-700 rounded text-xs text-slate-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
                              >
                                <%= for {label, val} <- @providers do %>
                                  <option value={val} selected={step_cfg.provider == val}>
                                    {label}
                                  </option>
                                <% end %>
                              </select>
                              <%= if LLMProvider.local_provider?(step_cfg.provider) or LLMProvider.default_models(step_cfg.provider) == [] do %>
                                <input
                                  type="text"
                                  name="model"
                                  value={step_cfg.model}
                                  phx-debounce="300"
                                  placeholder="model"
                                  class="flex-1 bg-slate-900 border border-slate-700 rounded text-xs text-slate-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500 placeholder-slate-600"
                                />
                              <% else %>
                                <select
                                  name="model"
                                  class="flex-1 bg-slate-900 border border-slate-700 rounded text-xs text-slate-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
                                >
                                  <%= for m <- LLMProvider.default_models(step_cfg.provider) do %>
                                    <option value={m} selected={step_cfg.model == m}>{m}</option>
                                  <% end %>
                                </select>
                              <% end %>
                            </form>
                            <%!-- Agent type selector --%>
                            <form
                              phx-change="update_step_agent_type"
                              id={"step-agent-#{step["id"]}"}
                              class="flex items-center gap-2 mt-1.5"
                            >
                              <input type="hidden" name="step_id" value={step["id"]} />
                              <span class="text-xs text-slate-500 shrink-0">Specialist:</span>
                              <select
                                name="agent_type"
                                class="flex-1 bg-slate-900 border border-indigo-700/50 rounded text-xs text-indigo-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                              >
                                <%= for {label, val, icon} <- AgentRegistry.agents() do %>
                                  <option
                                    value={val}
                                    selected={
                                      Map.get(@step_agent_types, step["id"], "executor") == val
                                    }
                                  >
                                    {icon} {label}
                                  </option>
                                <% end %>
                              </select>
                            </form>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="px-5 py-4 bg-slate-900/40 border-t border-slate-700/50 flex items-center justify-between">
                <span class="text-xs text-slate-400">
                  {MapSet.size(@accepted_steps)} of {length(@plan["steps"] || [])} steps accepted
                </span>
                <button
                  phx-click="start_execution"
                  disabled={MapSet.size(@accepted_steps) == 0}
                  class="flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm bg-gradient-to-r from-violet-600 to-indigo-600 hover:from-violet-500 hover:to-indigo-500 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-all"
                >
                  <.icon name="hero-play" class="w-4 h-4" />
                  Run {MapSet.size(@accepted_steps)} accepted steps
                </button>
              </div>
            </div>
          <% end %>

          <%!-- Execution Kanban Board --%>
          <%= if @status in [:executing, :step_failed] and @plan do %>
            <div class={[
              "border rounded-2xl overflow-hidden backdrop-blur-sm",
              if(@status == :step_failed,
                do: "bg-orange-950/20 border-orange-700/40",
                else: "bg-slate-800/60 border-slate-700/50"
              )
            ]}>
              <div class="px-5 py-4 border-b border-slate-700/50 flex items-center gap-2">
                <.icon name="hero-squares-2x2" class="w-4 h-4 text-violet-400" />
                <h2 class="font-semibold text-slate-200">Execution Board</h2>
                <%= if @status == :step_failed do %>
                  <span class="text-xs px-2 py-0.5 rounded-full bg-orange-600/20 text-orange-400 border border-orange-700/40">
                    Action required
                  </span>
                <% end %>
                <span class="ml-auto text-xs text-slate-500">{@elapsed_seconds}s</span>
                <%= if @status == :executing do %>
                  <button
                    phx-click="cancel"
                    class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700/60 hover:bg-red-900/40 border border-slate-600/40 hover:border-red-700/50 text-slate-400 hover:text-red-300 transition-colors flex items-center gap-1.5"
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                  </button>
                <% end %>
              </div>
              <div class="p-5 grid grid-cols-4 gap-4">
                <div>
                  <h3 class="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                    <span class="w-2 h-2 rounded-full bg-slate-500 shrink-0"></span> Queue
                  </h3>
                  <div class="space-y-2">
                    <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :pending) do %>
                      <div class="bg-slate-700/40 border border-slate-600/40 rounded-lg p-3">
                        <p class="text-xs font-bold text-slate-400 mb-0.5">#{step["id"]}</p>
                        <p class="text-xs font-medium text-slate-300 leading-snug">
                          {step["title"]}
                        </p>
                        <p class="text-xs text-slate-500 mt-1 truncate">
                          {AgentRegistry.label_for(step["agent_type"] || "executor")}
                        </p>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div>
                  <h3 class="text-xs font-semibold text-violet-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                    <span class="w-2 h-2 rounded-full bg-violet-500 animate-pulse shrink-0"></span>
                    Running
                  </h3>
                  <div class="space-y-2">
                    <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :running) do %>
                      <div class="bg-violet-600/10 border border-violet-700/40 rounded-lg p-3">
                        <div class="flex items-center gap-1.5 mb-1">
                          <.icon
                            name="hero-arrow-path"
                            class="w-3 h-3 text-violet-400 animate-spin"
                          />
                          <p class="text-xs font-bold text-violet-400">#{step["id"]}</p>
                        </div>
                        <p class="text-xs font-medium text-slate-300 leading-snug mb-1.5">
                          {step["title"]}
                        </p>
                        <p class="text-xs text-violet-400/70 mb-1 truncate">
                          {AgentRegistry.label_for(step["agent_type"] || "executor")}
                        </p>
                        <%= if Map.get(@step_streams, step["id"], "") != "" do %>
                          <p class="text-xs text-slate-400 font-mono leading-relaxed line-clamp-3 break-all">
                            {String.slice(Map.get(@step_streams, step["id"], ""), 0, 200)}
                          </p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div>
                  <h3 class="text-xs font-semibold text-emerald-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                    <span class="w-2 h-2 rounded-full bg-emerald-500 shrink-0"></span> Done
                  </h3>
                  <div class="space-y-2">
                    <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :done) do %>
                      <button
                        phx-click="view_step_output"
                        phx-value-step_id={step["id"]}
                        class="w-full text-left bg-emerald-600/10 border border-emerald-700/40 rounded-lg p-3 hover:bg-emerald-600/20 hover:border-emerald-600/60 transition-colors group"
                      >
                        <div class="flex items-center gap-1.5 mb-1">
                          <.icon name="hero-check-circle" class="w-3 h-3 text-emerald-400" />
                          <p class="text-xs font-bold text-emerald-400">#{step["id"]}</p>
                          <.icon
                            name="hero-eye"
                            class="w-3 h-3 text-slate-500 group-hover:text-emerald-400 ml-auto transition-colors"
                          />
                        </div>
                        <p class="text-xs font-medium text-slate-300 leading-snug">
                          {step["title"]}
                        </p>
                        <p class="text-xs text-emerald-500/70 mt-1 truncate">
                          {AgentRegistry.label_for(step["agent_type"] || "executor")}
                        </p>
                      </button>
                    <% end %>
                  </div>
                </div>

                <div>
                  <h3 class="text-xs font-semibold text-red-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                    <span class="w-2 h-2 rounded-full bg-red-500 shrink-0"></span> Failed
                  </h3>
                  <div class="space-y-2">
                    <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :error) do %>
                      <div class="bg-red-600/10 border border-red-700/40 rounded-lg p-3 space-y-1.5">
                        <div class="flex items-center gap-1.5">
                          <.icon name="hero-x-circle" class="w-3 h-3 text-red-400 shrink-0" />
                          <p class="text-xs font-bold text-red-400">#{step["id"]}</p>
                        </div>
                        <p class="text-xs font-medium text-slate-300 leading-snug">
                          {step["title"]}
                        </p>
                        <p class="text-xs text-red-400/60 truncate">
                          {AgentRegistry.label_for(step["agent_type"] || "executor")}
                        </p>
                        <%= if reason = Map.get(@step_errors, step["id"]) do %>
                          <p class="text-xs text-red-400/80 font-mono leading-snug bg-red-900/20 rounded px-1.5 py-1 break-all">
                            {reason}
                          </p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
              <%!-- Action panel shown when wave has failed steps --%>
              <%= if @status == :step_failed do %>
                <div class="px-5 py-4 border-t border-orange-700/30 bg-orange-950/20 flex flex-col sm:flex-row items-start sm:items-center gap-3">
                  <div class="flex-1">
                    <p class="text-sm font-semibold text-orange-300">One or more steps failed</p>
                    <p class="text-xs text-slate-400 mt-0.5">
                      Retry the failed steps, skip them and aggregate what succeeded, or cancel.
                    </p>
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    <button
                      phx-click="retry_failed_steps"
                      class="px-4 py-2 text-xs font-semibold rounded-lg bg-violet-600 hover:bg-violet-500 text-white transition-colors flex items-center gap-1.5"
                    >
                      <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Retry failed
                    </button>
                    <button
                      phx-click="skip_and_aggregate"
                      disabled={@step_results == []}
                      class="px-4 py-2 text-xs font-semibold rounded-lg bg-indigo-600/70 hover:bg-indigo-600 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors flex items-center gap-1.5"
                    >
                      <.icon name="hero-forward" class="w-3.5 h-3.5" /> Skip &amp; aggregate
                    </button>
                    <button
                      phx-click="cancel"
                      class="px-4 py-2 text-xs font-semibold rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-300 transition-colors flex items-center gap-1.5"
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Step output modal --%>
          <%= if @selected_step_id do %>
            <% sel_step = Enum.find(@plan["steps"] || [], &(&1["id"] == @selected_step_id)) %>
            <% sel_output = Map.get(@step_outputs, @selected_step_id, "") %>
            <div
              id="step-output-modal"
              class="fixed inset-0 z-50 flex items-center justify-center p-4"
              phx-window-keydown="close_step_output"
              phx-key="Escape"
            >
              <%!-- Backdrop --%>
              <div
                class="absolute inset-0 bg-slate-950/80 backdrop-blur-sm"
                phx-click="close_step_output"
              >
              </div>
              <%!-- Panel --%>
              <div class="relative z-10 w-full max-w-2xl max-h-[80vh] flex flex-col bg-slate-800 border border-slate-600/50 rounded-2xl shadow-2xl shadow-black/50 overflow-hidden">
                <div class="flex items-start justify-between px-5 py-4 border-b border-slate-700/50 shrink-0">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="w-4 h-4 text-emerald-400" />
                    <span class="text-xs font-bold text-emerald-400">
                      {if sel_step, do: "##{sel_step["id"]}", else: "##{@selected_step_id}"}
                    </span>
                    <h3 class="font-semibold text-slate-200 text-sm">
                      {if sel_step, do: sel_step["title"], else: "Step output"}
                    </h3>
                  </div>
                  <button
                    phx-click="close_step_output"
                    class="text-slate-400 hover:text-slate-200 transition-colors ml-4 shrink-0"
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5" />
                  </button>
                </div>
                <div class="flex-1 overflow-y-auto p-5">
                  <%= if sel_output == "" do %>
                    <p class="text-sm text-slate-500 italic">No output captured for this step.</p>
                  <% else %>
                    <pre class="text-sm text-slate-300 whitespace-pre-wrap leading-relaxed font-sans">{sel_output}</pre>
                  <% end %>
                </div>
                <div class="px-5 py-3 border-t border-slate-700/50 flex justify-end shrink-0">
                  <span class="text-xs text-slate-500">
                    This output will be passed to the aggregator.
                  </span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Aggregating indicator --%>
          <%= if @status == :aggregating and @final_stream == "" do %>
            <div class="bg-slate-800/60 border border-slate-700/50 rounded-2xl p-6 flex items-center gap-4 backdrop-blur-sm">
              <div class="w-10 h-10 rounded-xl bg-indigo-600/20 flex items-center justify-center shrink-0">
                <.icon name="hero-arrow-path" class="w-5 h-5 text-indigo-400 animate-spin" />
              </div>
              <div class="flex-1">
                <p class="font-semibold text-slate-200">Synthesising results&hellip;</p>
                <p class="text-sm text-slate-400">
                  The Aggregator agent is writing your final answer
                </p>
              </div>
              <button
                phx-click="cancel"
                class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700/60 hover:bg-red-900/40 border border-slate-600/40 hover:border-red-700/50 text-slate-400 hover:text-red-300 transition-colors flex items-center gap-1.5"
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
              </button>
            </div>
          <% end %>

          <%!-- Aggregating streaming preview --%>
          <%= if @status == :aggregating and @final_stream != "" do %>
            <div class="bg-slate-800/60 border border-indigo-700/40 rounded-2xl overflow-hidden backdrop-blur-sm">
              <div class="px-5 py-4 border-b border-indigo-700/30 bg-indigo-600/10 flex items-center gap-2">
                <.icon name="hero-sparkles" class="w-4 h-4 text-indigo-400 animate-pulse" />
                <h2 class="font-semibold text-slate-200">Synthesising&hellip;</h2>
                <button
                  phx-click="cancel"
                  class="ml-auto px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-700/60 hover:bg-red-900/40 border border-slate-600/40 hover:border-red-700/50 text-slate-400 hover:text-red-300 transition-colors flex items-center gap-1.5"
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                </button>
              </div>
              <div class="p-5">
                <div class="text-sm text-slate-300 leading-relaxed whitespace-pre-wrap">
                  {@final_stream}
                  <span class="inline-block w-2 h-3.5 bg-indigo-400 ml-0.5 animate-pulse rounded-sm">
                  </span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Review Answer --%>
          <%= if @status == :review_answer and @final_answer do %>
            <div class="bg-slate-800/60 border border-indigo-700/40 rounded-2xl overflow-hidden backdrop-blur-sm shadow-lg shadow-indigo-900/10">
              <div class="px-5 py-4 border-b border-indigo-700/30 bg-indigo-600/10 flex items-center gap-2">
                <.icon name="hero-sparkles" class="w-4 h-4 text-indigo-400" />
                <h2 class="font-semibold text-slate-200">Final Answer</h2>
                <span class="ml-auto text-xs text-slate-400">Review before accepting</span>
              </div>
              <div class="p-5 space-y-4">
                <div class="max-h-96 overflow-y-auto bg-slate-900/60 rounded-xl p-4">
                  <pre class="text-sm text-slate-200 whitespace-pre-wrap font-sans leading-relaxed">{@final_answer}</pre>
                </div>
                <div class="flex gap-3">
                  <button
                    phx-click="accept_answer"
                    class="flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm bg-emerald-600 hover:bg-emerald-500 text-white transition-colors"
                  >
                    <.icon name="hero-check" class="w-4 h-4" /> Accept
                  </button>
                  <button
                    phx-click="regenerate_answer"
                    class="flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm bg-slate-700 hover:bg-slate-600 text-slate-200 border border-slate-600 transition-colors"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> Re-generate
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Done: accepted final answer --%>
          <%= if @status == :done and @final_answer do %>
            <div class="bg-slate-800/60 border border-emerald-700/40 rounded-2xl overflow-hidden backdrop-blur-sm shadow-lg shadow-emerald-900/10">
              <div class="px-5 py-4 border-b border-emerald-700/30 bg-emerald-600/10 flex items-center gap-2">
                <.icon name="hero-check-badge" class="w-4 h-4 text-emerald-400" />
                <h2 class="font-semibold text-slate-200">Final Answer</h2>
                <span class="ml-auto text-xs px-2 py-0.5 rounded-full bg-emerald-600/20 text-emerald-400 font-medium border border-emerald-700/40">
                  Accepted
                </span>
              </div>
              <div class="p-5">
                <div class="text-sm text-slate-300 leading-relaxed whitespace-pre-wrap prose prose-invert prose-sm max-w-none">
                  {@final_answer}
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Idle placeholder --%>
          <%= if @status == :idle do %>
            <div class="bg-slate-800/30 border border-slate-700/30 rounded-2xl p-12 flex flex-col items-center text-center gap-4">
              <div class="w-16 h-16 rounded-2xl bg-violet-600/10 border border-violet-700/30 flex items-center justify-center">
                <.icon name="hero-cpu-chip" class="w-8 h-8 text-violet-500" />
              </div>
              <div>
                <p class="text-lg font-semibold text-slate-300">Ready to plan</p>
                <p class="text-sm text-slate-500 mt-1 max-w-md">
                  Configure your LLM provider, enter a task, and click
                  <strong class="text-slate-400">Run Planner</strong>
                  to start the multi-agent pipeline.
                </p>
              </div>
            </div>
          <% end %>
          <div class="bg-slate-800/60 border border-slate-700/50 rounded-2xl p-5 space-y-4 backdrop-blur-sm">
            <h2 class="text-sm font-semibold text-slate-300 uppercase tracking-wider flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4 text-violet-400" /> LLM Provider
            </h2>

            <%!-- Provider selector --%>
            <div>
              <label class="block text-xs text-slate-400 mb-1.5 flex items-center justify-between">
                <span>Provider</span>
                <span class="text-xs text-slate-500 font-mono">{@provider}</span>
              </label>
              <form phx-change="provider_changed" id="provider-form">
                <select
                  name="provider"
                  disabled={@status != :idle}
                  class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <%= for {label, value} <- @providers do %>
                    <option value={value} selected={@provider == value}>{label}</option>
                  <% end %>
                </select>
              </form>
            </div>

            <%!-- API key (cloud providers only) --%>
            <%= if @provider in [:openai, :anthropic] do %>
              <div>
                <label class="block text-xs text-slate-400 mb-1.5 flex items-center justify-between">
                  <span>API Key</span>
                  <%= if String.trim(@api_key) != "" do %>
                    <span class="text-emerald-400 text-xs flex items-center gap-1">
                      <.icon name="hero-check-circle" class="w-3 h-3" /> Key set
                    </span>
                  <% end %>
                </label>
                <div class="relative">
                  <input
                    id="api-key-input"
                    type="password"
                    phx-blur="update_api_key"
                    phx-change="update_api_key"
                    phx-debounce="300"
                    name="api_key"
                    value={@api_key}
                    disabled={@status != :idle}
                    placeholder={
                      case @provider do
                        :openai -> "sk-..."
                        :anthropic -> "sk-ant-..."
                        _ -> "API key"
                      end
                    }
                    class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 pr-10 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                  />
                  <button
                    type="button"
                    onclick="const i=document.getElementById('api-key-input');i.type=i.type==='password'?'text':'password';this.querySelector('span').textContent=i.type==='password'?'Show':'Hide'"
                    class="absolute right-2.5 top-1/2 -translate-y-1/2 text-slate-500 hover:text-slate-300 transition-colors text-xs select-none"
                    tabindex="-1"
                  >
                    <span>Show</span>
                  </button>
                </div>
                <%= case @provider do %>
                  <% :openai -> %>
                    <p class="mt-1 text-xs text-slate-500">
                      Get your key at
                      <a
                        href="https://platform.openai.com/api-keys"
                        target="_blank"
                        class="text-violet-400 hover:text-violet-300 underline"
                      >
                        platform.openai.com/api-keys
                      </a>
                    </p>
                  <% :anthropic -> %>
                    <p class="mt-1 text-xs text-slate-500">
                      Get your key at
                      <a
                        href="https://console.anthropic.com/settings/keys"
                        target="_blank"
                        class="text-violet-400 hover:text-violet-300 underline"
                      >
                        console.anthropic.com
                      </a>
                    </p>
                  <% _ -> %>
                <% end %>
              </div>
            <% end %>

            <%!-- Custom endpoint --%>
            <%= if @provider == :custom do %>
              <div>
                <label class="block text-xs text-slate-400 mb-1.5">Endpoint URL</label>
                <input
                  type="text"
                  phx-blur="update_endpoint"
                  phx-change="update_endpoint"
                  name="endpoint"
                  value={@custom_endpoint}
                  disabled={@status != :idle}
                  placeholder="http://localhost:1337/v1/chat/completions"
                  class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                />
              </div>
            <% end %>

            <%!-- Local server URL --%>
            <%= if LLMProvider.local_provider?(@provider) do %>
              <div>
                <label class="block text-xs text-slate-400 mb-1.5 flex items-center justify-between">
                  <span>Server URL</span>
                  <%= if @wsl2 do %>
                    <span class="text-amber-400 text-xs flex items-center gap-1">
                      <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> WSL2 detected
                    </span>
                  <% end %>
                </label>
                <div class="flex gap-2">
                  <input
                    type="text"
                    phx-blur="update_local_host"
                    phx-change="update_local_host"
                    name="local_host"
                    value={@local_host}
                    disabled={@status != :idle}
                    placeholder={
                      if @provider == :jan_ai,
                        do: "http://127.0.0.1:1337",
                        else: "http://127.0.0.1:11434"
                    }
                    class="flex-1 bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed font-mono"
                  />
                  <button
                    phx-click="check_local_host"
                    disabled={@status != :idle}
                    class="px-3 py-2 rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-300 text-xs font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Check
                  </button>
                </div>
                <%= if @wsl2 do %>
                  <p class="mt-1.5 text-xs text-amber-400/80 leading-relaxed">
                    Running in WSL2. If Jan.ai is on Windows, try the gateway IP
                    (e.g. <code class="text-amber-300">http://172.x.x.x:1337</code>).
                  </p>
                <% end %>
              </div>
            <% end %>

            <%!-- Model selector --%>
            <div>
              <label class="block text-xs text-slate-400 mb-1.5">Model</label>

              <%= cond do %>
                <% LLMProvider.local_provider?(@provider) and @local_server_status == :checking -> %>
                  <div class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2.5 flex items-center gap-2 text-sm text-slate-400">
                    <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin text-violet-400" />
                    Checking server&hellip;
                  </div>
                <% LLMProvider.local_provider?(@provider) and @local_server_status == :offline -> %>
                  <div class="w-full bg-red-900/20 border border-red-700/40 rounded-lg px-3 py-2.5 text-sm text-red-400 flex items-start gap-2">
                    <.icon name="hero-x-circle" class="w-4 h-4 mt-0.5 shrink-0" />
                    <span>
                      Server not reachable.
                      Start it then <button
                        phx-click="retry_local_server"
                        class="underline text-red-300 hover:text-red-200"
                      >
                          retry
                        </button>.
                    </span>
                  </div>
                <% LLMProvider.local_provider?(@provider) and @local_server_status == :online and @local_models == [] -> %>
                  <div class="w-full bg-yellow-900/20 border border-yellow-700/40 rounded-lg px-3 py-2.5 text-sm text-yellow-400 flex items-start gap-2">
                    <.icon name="hero-exclamation-triangle" class="w-4 h-4 mt-0.5 shrink-0" />
                    <span>
                      Server is running but no models are loaded. Load a model in Jan.ai, then <button
                        phx-click="retry_local_server"
                        class="underline text-yellow-300 hover:text-yellow-200"
                      >
                          refresh
                        </button>.
                    </span>
                  </div>
                <% LLMProvider.local_provider?(@provider) and @local_server_status == :online -> %>
                  <form phx-change="provider_model_selected" id="local-model-form">
                    <select
                      name="model"
                      disabled={@status != :idle}
                      class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      <%= for m <- @local_models do %>
                        <option value={m} selected={@model == m}>{m}</option>
                      <% end %>
                    </select>
                  </form>
                  <div class="flex items-center justify-between mt-1.5">
                    <span class="text-xs text-emerald-500 flex items-center gap-1">
                      <.icon name="hero-check-circle" class="w-3 h-3" />
                      {length(@local_models)} model(s) available
                    </span>
                    <button
                      phx-click="retry_local_server"
                      class="text-xs text-slate-500 hover:text-slate-300 flex items-center gap-1 transition-colors"
                    >
                      <.icon name="hero-arrow-path" class="w-3 h-3" /> Refresh
                    </button>
                  </div>
                <% true -> %>
                  <%= if LLMProvider.default_models(@provider) != [] do %>
                    <%!-- Cloud provider with known models: dropdown --%>
                    <form phx-change="provider_model_selected" id="cloud-model-form">
                      <select
                        name="model"
                        disabled={@status != :idle}
                        class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <%= for m <- LLMProvider.default_models(@provider) do %>
                          <option value={m} selected={@model == m}>{m}</option>
                        <% end %>
                      </select>
                    </form>
                  <% else %>
                    <%!-- Custom / unknown provider: free-text input --%>
                    <input
                      type="text"
                      phx-blur="update_model"
                      phx-change="update_model"
                      name="model"
                      value={@model}
                      disabled={@status != :idle}
                      placeholder="model name"
                      class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
                    />
                  <% end %>
              <% end %>
            </div>

            <%!-- Max retries --%>
            <div>
              <label class="block text-xs text-slate-400 mb-1.5 flex items-center justify-between">
                <span>Chain retries (bad response)</span>
                <%= if LLMProvider.local_provider?(@provider) do %>
                  <span class="text-emerald-400 text-xs">network retries already off</span>
                <% end %>
              </label>
              <select
                phx-change="update_max_retries"
                name="max_retries"
                disabled={@status != :idle}
                class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2 text-sm text-slate-100 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <%= for n <- [0, 1, 2, 3, 5] do %>
                  <option value={n} selected={@max_retries == n}>{n}</option>
                <% end %>
              </select>
              <p class="mt-1 text-xs text-slate-500">
                Re-sends when the LLM returns malformed JSON or an unexpected format. Min 1 recommended. Network timeouts don't retry for local models.
              </p>
            </div>
          </div>

          <%!-- About card --%>
          <div class="bg-slate-800/40 border border-slate-700/30 rounded-2xl p-5 text-xs text-slate-500 space-y-2">
            <p class="font-medium text-slate-400">How it works</p>
            <div class="space-y-1.5">
              <div class="flex items-start gap-2">
                <span class="w-5 h-5 rounded-full bg-violet-600/30 text-violet-400 text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                  1
                </span>
                <span>
                  <strong class="text-slate-300">Planner</strong>
                  &mdash; decomposes your task into structured steps
                </span>
              </div>
              <div class="flex items-start gap-2">
                <span class="w-5 h-5 rounded-full bg-violet-600/30 text-violet-400 text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                  2
                </span>
                <span>
                  <strong class="text-slate-300">Review</strong>
                  &mdash; accept/reject steps and pick a model per step
                </span>
              </div>
              <div class="flex items-start gap-2">
                <span class="w-5 h-5 rounded-full bg-violet-600/30 text-violet-400 text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                  3
                </span>
                <span>
                  <strong class="text-slate-300">Executor</strong>
                  &mdash; runs steps in parallel dependency waves
                </span>
              </div>
              <div class="flex items-start gap-2">
                <span class="w-5 h-5 rounded-full bg-violet-600/30 text-violet-400 text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                  4
                </span>
                <span>
                  <strong class="text-slate-300">Aggregator</strong>
                  &mdash; synthesizes all outputs into a final answer
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Status helpers ──────────────────────────────────────────────────────────

  defp status_label(:idle), do: "Idle"
  defp status_label(:planning), do: "Planning…"
  defp status_label(:review_plan), do: "Review Plan"
  defp status_label(:executing), do: "Executing…"
  defp status_label(:step_failed), do: "Step Failed"
  defp status_label(:aggregating), do: "Aggregating…"
  defp status_label(:review_answer), do: "Review Answer"
  defp status_label(:done), do: "Done"
  defp status_label(:error), do: "Error"

  defp status_badge_class(:idle), do: "bg-slate-700 text-slate-300"

  defp status_badge_class(:planning),
    do: "bg-yellow-600/20 text-yellow-400 border border-yellow-700/40"

  defp status_badge_class(:review_plan),
    do: "bg-amber-600/20 text-amber-400 border border-amber-700/40"

  defp status_badge_class(:executing),
    do: "bg-violet-600/20 text-violet-400 border border-violet-700/40"

  defp status_badge_class(:aggregating),
    do: "bg-indigo-600/20 text-indigo-400 border border-indigo-700/40"

  defp status_badge_class(:review_answer),
    do: "bg-cyan-600/20 text-cyan-400 border border-cyan-700/40"

  defp status_badge_class(:done),
    do: "bg-emerald-600/20 text-emerald-400 border border-emerald-700/40"

  defp status_badge_class(:step_failed),
    do: "bg-orange-600/20 text-orange-400 border border-orange-700/40"

  defp status_badge_class(:error), do: "bg-red-600/20 text-red-400 border border-red-700/40"
end
