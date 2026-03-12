defmodule HierarchyPaiWeb.PlannerLive do
  use HierarchyPaiWeb, :live_view

  alias HierarchyPai.LLMProvider
  alias HierarchyPai.Agents.AgentRegistry
  alias HierarchyPai.ProviderStore
  alias HierarchyPai.SkillStore
  alias HierarchyPai.RunStore

  @providers [
    {"Jan.ai (local)", :jan_ai},
    {"OpenAI", :openai},
    {"Anthropic", :anthropic},
    {"Ollama (local)", :ollama},
    {"GitHub Models", :github_copilot},
    {"Custom endpoint", :custom}
  ]

  @impl true
  def mount(_params, _session, socket) do
    session_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    pubsub_topic = "planner:#{session_id}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(HierarchyPai.PubSub, pubsub_topic)
      Phoenix.PubSub.subscribe(HierarchyPai.PubSub, "mcp_runs")
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
     |> assign(:step_skills, %{})
     |> assign(:saved_skills, SkillStore.list())
     |> assign(:skill_search, "")
     |> assign(:skills_syncing, false)
     |> assign(:skills_reloading, false)
     |> assign(:skills_sync_result, nil)
     |> assign(:selected_step_id, nil)
     |> assign(:current_step_id, nil)
     |> assign(:final_stream, "")
     |> assign(:final_answer, nil)
     |> assign(:error, nil)
     |> assign(:planner_stream, "")
     |> assign(:elapsed_seconds, 0)
     |> assign(:task_pid, nil)
     |> assign(:saved_providers, ProviderStore.list())
     |> assign(:provider_form, nil)
     |> assign(:planner_provider_id, pick_default_provider_id(ProviderStore.list()))
     |> assign(:redo_confirm, nil)
     |> assign(:retry_confirm, nil)
     |> assign(:mcp_runs, RunStore.list())}
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
      cond do
        LLMProvider.local_provider?(provider) ->
          send(self(), :fetch_local_models)

          socket
          |> assign(:local_server_status, :checking)

        provider == :github_copilot ->
          default = hd(LLMProvider.default_models(provider) ++ [""])

          socket
          |> assign(:local_server_status, :unknown)
          |> assign(:model, default)
          |> assign(:custom_endpoint, LLMProvider.github_copilot_endpoint())

        true ->
          default = hd(LLMProvider.default_models(provider) ++ [""])

          socket
          |> assign(:local_server_status, :unknown)
          |> assign(:model, default)
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
  def handle_event("update_endpoint", %{"value" => ep}, socket) do
    {:noreply, assign(socket, :custom_endpoint, ep)}
  end

  # ── Saved Providers (ETS) ──────────────────────────────────────────────────

  @impl true
  def handle_event("open_provider_form", _params, socket) do
    blank = %{
      id: nil,
      name: "",
      provider: :openai,
      model: "",
      api_key: "",
      endpoint: "",
      max_retries: 0,
      available_models: LLMProvider.default_models(:openai),
      fetching_models: false,
      fetch_error: nil
    }

    {:noreply, assign(socket, :provider_form, blank)}
  end

  @impl true
  def handle_event("edit_saved_provider", %{"id" => id}, socket) do
    entry = ProviderStore.get(id)

    form =
      entry
      |> Map.put(:max_retries, Map.get(entry, :max_retries, 0))
      |> Map.put(:available_models, LLMProvider.default_models(entry.provider))
      |> Map.put(:fetching_models, false)
      |> Map.put(:fetch_error, nil)

    {:noreply, assign(socket, :provider_form, form)}
  end

  @impl true
  def handle_event("cancel_provider_form", _params, socket) do
    {:noreply, assign(socket, :provider_form, nil)}
  end

  @impl true
  def handle_event("provider_form_change", %{"saved_provider" => params}, socket) do
    current = socket.assigns.provider_form

    new_provider =
      String.to_existing_atom(Map.get(params, "provider", to_string(current.provider)))

    provider_changed? = new_provider != current.provider

    updated =
      current
      |> Map.put(:name, Map.get(params, "name", current.name))
      |> Map.put(:provider, new_provider)
      |> Map.put(
        :model,
        if(provider_changed?, do: "", else: Map.get(params, "model", current.model))
      )
      |> Map.put(:api_key, Map.get(params, "api_key", current.api_key))
      |> Map.put(:endpoint, Map.get(params, "endpoint", current.endpoint))
      |> Map.put(
        :max_retries,
        Map.get(params, "max_retries", to_string(current.max_retries))
        |> to_string()
        |> String.to_integer()
        |> max(0)
        |> min(5)
      )
      |> Map.put(
        :available_models,
        if(provider_changed?,
          do: LLMProvider.default_models(new_provider),
          else: current.available_models
        )
      )

    {:noreply, assign(socket, :provider_form, updated)}
  end

  @impl true
  def handle_event("save_provider_form", %{"saved_provider" => params}, socket) do
    current = socket.assigns.provider_form
    provider = String.to_existing_atom(Map.get(params, "provider", "openai"))

    endpoint =
      if provider == :github_copilot,
        do: LLMProvider.github_copilot_endpoint(),
        else: String.trim(Map.get(params, "endpoint", ""))

    entry = %{
      id: current[:id],
      name: String.trim(Map.get(params, "name", "")),
      provider: provider,
      model: String.trim(Map.get(params, "model", "")),
      api_key: String.trim(Map.get(params, "api_key", "")),
      endpoint: endpoint,
      max_retries:
        Map.get(params, "max_retries", "0")
        |> to_string()
        |> String.to_integer()
        |> max(0)
        |> min(5)
    }

    {:ok, _} = ProviderStore.save(entry)

    saved = ProviderStore.list()
    # Auto-select this provider for the planner if none is selected yet
    planner_provider_id =
      socket.assigns.planner_provider_id || pick_default_provider_id(saved)

    {:noreply,
     socket
     |> assign(:saved_providers, saved)
     |> assign(:provider_form, nil)
     |> assign(:planner_provider_id, planner_provider_id)}
  end

  @impl true
  def handle_event("delete_saved_provider", %{"id" => id}, socket) do
    :ok = ProviderStore.delete(id)
    saved = ProviderStore.list()

    # If deleted provider was the selected planner provider, pick a new default
    planner_provider_id =
      if socket.assigns.planner_provider_id == id,
        do: pick_default_provider_id(saved),
        else: socket.assigns.planner_provider_id

    {:noreply,
     socket
     |> assign(:saved_providers, saved)
     |> assign(:planner_provider_id, planner_provider_id)}
  end

  @impl true
  def handle_event("update_planner_provider", %{"provider_id" => id}, socket) do
    ProviderStore.set_default(id)
    {:noreply, assign(socket, :planner_provider_id, id)}
  end

  @impl true
  def handle_event("fetch_provider_form_models", _params, socket) do
    pf = socket.assigns.provider_form

    socket =
      assign(socket, :provider_form, Map.merge(pf, %{fetching_models: true, fetch_error: nil}))

    pid = self()

    Task.start(fn ->
      result = LLMProvider.fetch_models_for_form(pf.provider, pf[:endpoint], pf[:api_key])
      send(pid, {:provider_form_models_result, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_global_as_provider", _params, socket) do
    a = socket.assigns

    name =
      case a.provider do
        :jan_ai -> "Jan.ai"
        :openai -> "OpenAI"
        :anthropic -> "Anthropic"
        :ollama -> "Ollama"
        :github_copilot -> "GitHub Models"
        :custom -> "Custom"
      end

    entry = %{
      id: nil,
      name: name,
      provider: a.provider,
      model: a.model,
      api_key: a.api_key,
      endpoint: a.custom_endpoint,
      max_retries: 0
    }

    {:noreply, assign(socket, :provider_form, entry)}
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
    step_skills = socket.assigns.step_skills
    step_configs = socket.assigns.step_configs
    default_config = build_provider_config(socket.assigns)
    resolved_step_configs = resolve_step_configs(step_configs, default_config)
    topic = socket.assigns.pubsub_topic

    # Merge user-selected agent types and skills into each step before execution
    plan_with_agents =
      update_in(plan["steps"], fn steps ->
        Enum.map(steps, fn step ->
          agent_type = Map.get(step_agent_types, step["id"], step["agent_type"] || "executor")
          skill_id = Map.get(step_skills, step["id"])

          step
          |> Map.put("agent_type", agent_type)
          |> Map.put("skill_id", skill_id)
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
            resolved_step_configs,
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
        %{"step_id" => id_str, "provider_id" => provider_id, "model" => m},
        socket
      ) do
    id = String.to_integer(id_str)
    cfg = %{provider_id: provider_id, model: m}
    {:noreply, update(socket, :step_configs, &Map.put(&1, id, cfg))}
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
  def handle_event(
        "update_step_skill",
        %{"step_id" => id_str, "skill_id" => skill_id},
        socket
      ) do
    id = String.to_integer(id_str)
    value = if skill_id == "", do: nil, else: skill_id
    {:noreply, update(socket, :step_skills, &Map.put(&1, id, value))}
  end

  @impl true
  def handle_event("sync_skills", _params, socket) do
    parent = self()

    Task.start(fn ->
      result = HierarchyPai.SkillStore.sync_remote()
      send(parent, {:skills_sync_done, result})
    end)

    {:noreply, assign(socket, :skills_syncing, true)}
  end

  @impl true
  def handle_event("reload_local_skills", _params, socket) do
    parent = self()

    Task.start(fn ->
      result = HierarchyPai.SkillStore.reload_local()
      send(parent, {:skills_reload_done, result})
    end)

    {:noreply, assign(socket, :skills_reloading, true)}
  end

  @impl true
  def handle_event("filter_skills", %{"value" => query}, socket) do
    {:noreply, assign(socket, :skill_search, query)}
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
  def handle_event("download_answer", _params, socket) do
    answer = socket.assigns.final_answer || ""
    task = String.trim(socket.assigns.task)
    title = if task != "", do: "# #{task}\n\n", else: ""
    content = title <> answer

    {:noreply,
     push_event(socket, "download_file", %{
       filename: "final_answer.md",
       content: content,
       mime: "text/markdown"
     })}
  end

  @impl true
  def handle_event("download_full_report", _params, socket) do
    task = String.trim(socket.assigns.task)
    plan = socket.assigns.plan || %{}
    goal = plan["goal"] || task
    step_results = socket.assigns.step_results
    final_answer = socket.assigns.final_answer || ""

    steps_section =
      if step_results != [] do
        steps_md =
          Enum.map_join(step_results, "\n\n---\n\n", fn r ->
            "## Step #{r["step_id"]}: #{r["title"]}\n\n#{r["output"] || "_No output captured._"}"
          end)

        "# Step Outputs\n\n#{steps_md}"
      else
        ""
      end

    final_section =
      if final_answer != "" do
        "# Final Answer\n\n#{final_answer}"
      else
        ""
      end

    content =
      [
        "# #{goal}",
        steps_section,
        final_section
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n---\n\n")

    {:noreply,
     push_event(socket, "download_file", %{
       filename: "full_report.md",
       content: content,
       mime: "text/markdown"
     })}
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
     |> assign(:redo_confirm, nil)
     |> assign(:retry_confirm, nil)
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
  def handle_event("request_redo_step", %{"step_id" => step_id_str}, socket) do
    step_id = String.to_integer(step_id_str)
    steps = (socket.assigns.plan || %{})["steps"] || []
    accepted = socket.assigns.accepted_steps
    also_ids = transitive_dependents(step_id, steps, accepted)

    # Pre-fill with current agent_type and skill_id for the step
    step = Enum.find(steps, &(&1["id"] == step_id))

    redo_agent_type =
      Map.get(socket.assigns.step_agent_types, step_id, step["agent_type"] || "executor")

    redo_skill_id = Map.get(socket.assigns.step_skills, step_id)

    {:noreply,
     socket
     |> assign(:redo_confirm, %{
       step_id: step_id,
       also_ids: also_ids,
       redo_agent_type: redo_agent_type,
       redo_skill_id: redo_skill_id
     })
     |> assign(:selected_step_id, nil)}
  end

  @impl true
  def handle_event("cancel_redo_confirm", _params, socket) do
    {:noreply, assign(socket, :redo_confirm, nil)}
  end

  @impl true
  def handle_event("update_redo_agent_type", %{"agent_type" => agent_type}, socket) do
    {:noreply, update(socket, :redo_confirm, &Map.put(&1, :redo_agent_type, agent_type))}
  end

  @impl true
  def handle_event("update_redo_skill_id", %{"skill_id" => skill_id}, socket) do
    value = if skill_id == "", do: nil, else: skill_id
    {:noreply, update(socket, :redo_confirm, &Map.put(&1, :redo_skill_id, value))}
  end

  @impl true
  def handle_event("confirm_redo_step", _params, socket) do
    %{
      step_id: step_id,
      also_ids: also_ids,
      redo_agent_type: redo_agent_type,
      redo_skill_id: redo_skill_id
    } =
      socket.assigns.redo_confirm

    all_redo_ids = MapSet.new([step_id | also_ids])

    # Override agent_type and skill_id on the plan for the redo step
    plan =
      update_in(socket.assigns.plan, ["steps"], fn steps ->
        Enum.map(steps, fn step ->
          if step["id"] == step_id do
            step
            |> Map.put("agent_type", redo_agent_type)
            |> Map.put("skill_id", redo_skill_id)
          else
            step
          end
        end)
      end)

    step_configs = socket.assigns.step_configs
    default_config = build_provider_config(socket.assigns)
    resolved = resolve_step_configs(step_configs, default_config)
    topic = socket.assigns.pubsub_topic

    # Remove old results for steps being re-run so they don't duplicate
    prior_results =
      socket.assigns.step_results
      |> Enum.reject(fn r -> MapSet.member?(all_redo_ids, r["step_id"]) end)

    new_statuses =
      Enum.reduce(all_redo_ids, socket.assigns.step_statuses, fn id, acc ->
        Map.put(acc, id, :pending)
      end)

    new_outputs = Map.drop(socket.assigns.step_outputs, MapSet.to_list(all_redo_ids))

    {:ok, pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.execute_steps(
            plan,
            all_redo_ids,
            resolved,
            default_config,
            topic,
            prior_results
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
     |> assign(:redo_confirm, nil)
     |> assign(:status, :executing)
     |> assign(:plan, plan)
     |> update(:step_agent_types, &Map.put(&1, step_id, redo_agent_type))
     |> update(:step_skills, &Map.put(&1, step_id, redo_skill_id))
     |> assign(:step_statuses, new_statuses)
     |> assign(:step_outputs, new_outputs)
     |> assign(:step_results, prior_results)
     |> assign(:step_errors, %{})
     |> assign(:elapsed_seconds, 0)
     |> assign(:final_answer, socket.assigns.final_answer)
     |> assign(:selected_step_id, nil)
     |> assign(:task_pid, pid)}
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
    # Show a confirm dialog (agent type + skill) before retrying, mirroring the redo flow.
    failed_ids =
      socket.assigns.step_statuses
      |> Enum.filter(fn {_id, s} -> s in [:error, :pending] end)
      |> Enum.map(fn {id, _} -> id end)

    retry_confirm = %{
      failed_ids: failed_ids,
      retry_agent_type: "executor",
      retry_skill_id: nil
    }

    {:noreply, assign(socket, :retry_confirm, retry_confirm)}
  end

  @impl true
  def handle_event("cancel_retry_confirm", _params, socket) do
    {:noreply, assign(socket, :retry_confirm, nil)}
  end

  @impl true
  def handle_event("update_retry_agent_type", %{"agent_type" => agent_type}, socket) do
    {:noreply, update(socket, :retry_confirm, &Map.put(&1, :retry_agent_type, agent_type))}
  end

  @impl true
  def handle_event("update_retry_skill_id", %{"skill_id" => skill_id}, socket) do
    value = if skill_id == "", do: nil, else: skill_id
    {:noreply, update(socket, :retry_confirm, &Map.put(&1, :retry_skill_id, value))}
  end

  @impl true
  def handle_event("confirm_retry_steps", _params, socket) do
    %{
      failed_ids: failed_ids,
      retry_agent_type: retry_agent_type,
      retry_skill_id: retry_skill_id
    } = socket.assigns.retry_confirm

    incomplete_ids = MapSet.new(failed_ids)

    # Apply the chosen agent_type and skill_id overrides to all retried steps in the plan.
    plan =
      update_in(socket.assigns.plan, ["steps"], fn steps ->
        Enum.map(steps, fn step ->
          if step["id"] in failed_ids do
            step
            |> Map.put("agent_type", retry_agent_type)
            |> Map.put("skill_id", retry_skill_id)
          else
            step
          end
        end)
      end)

    step_configs = socket.assigns.step_configs
    default_config = build_provider_config(socket.assigns)
    resolved_step_configs = resolve_step_configs(step_configs, default_config)
    topic = socket.assigns.pubsub_topic
    prior_results = socket.assigns.step_results

    new_statuses =
      Enum.reduce(incomplete_ids, socket.assigns.step_statuses, fn id, acc ->
        Map.put(acc, id, :pending)
      end)

    # Update step_agent_types and step_skills for all retried steps so board cards reflect changes.
    new_agent_types =
      Enum.reduce(failed_ids, socket.assigns.step_agent_types, fn id, acc ->
        Map.put(acc, id, retry_agent_type)
      end)

    new_skills =
      Enum.reduce(failed_ids, socket.assigns.step_skills, fn id, acc ->
        Map.put(acc, id, retry_skill_id)
      end)

    {:ok, pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.execute_steps(
            plan,
            incomplete_ids,
            resolved_step_configs,
            default_config,
            topic,
            prior_results
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
     |> assign(:retry_confirm, nil)
     |> assign(:plan, plan)
     |> assign(:status, :executing)
     |> assign(:step_statuses, new_statuses)
     |> assign(:step_agent_types, new_agent_types)
     |> assign(:step_skills, new_skills)
     |> assign(:step_errors, %{})
     |> assign(
       :step_outputs,
       Map.drop(socket.assigns.step_outputs, MapSet.to_list(incomplete_ids))
     )
     |> assign(:selected_step_id, nil)
     |> assign(:task_pid, pid)}
  end

  @impl true
  def handle_event("skip_and_aggregate", _params, socket) do
    goal = get_in(socket.assigns.plan, ["goal"]) || ""
    all_steps = get_in(socket.assigns.plan, ["steps"]) || []

    done_ids =
      socket.assigns.step_statuses
      |> Enum.filter(fn {_id, s} -> s == :done end)
      |> MapSet.new(fn {id, _} -> id end)

    # Build step_results from @step_outputs for steps that completed in this run,
    # merging with any already-accumulated results (e.g. from a prior retry wave).
    accumulated = socket.assigns.step_results || []
    accumulated_ids = MapSet.new(accumulated, & &1["step_id"])

    fresh_results =
      all_steps
      |> Enum.filter(fn step ->
        MapSet.member?(done_ids, step["id"]) and
          not MapSet.member?(accumulated_ids, step["id"])
      end)
      |> Enum.map(fn step ->
        %{
          "step_id" => step["id"],
          "title" => step["title"],
          "output" => Map.get(socket.assigns.step_outputs, step["id"], "")
        }
      end)

    step_results = accumulated ++ fresh_results

    # Collect failed/skipped steps so the aggregator can acknowledge them.
    skipped_steps =
      all_steps
      |> Enum.filter(fn step ->
        status = Map.get(socket.assigns.step_statuses, step["id"])
        status in [:error, :pending, nil]
      end)

    provider_config = build_provider_config(socket.assigns)
    topic = socket.assigns.pubsub_topic

    {:ok, _pid} =
      Task.start(fn ->
        try do
          HierarchyPai.Orchestrator.reaggregate(
            goal,
            step_results,
            provider_config,
            topic,
            skipped_steps
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
     |> assign(:step_skills, %{})
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

  # Partial results from a retry run — merge into existing step_results,
  # then check if all accepted steps are now done and auto-proceed to aggregation.
  def handle_info({:orchestrator, {:partial_results_ready, new_results}}, socket) do
    merged = (socket.assigns.step_results || []) ++ new_results

    all_done? =
      socket.assigns.step_statuses
      |> Map.values()
      |> Enum.all?(&(&1 == :done))

    socket = assign(socket, :step_results, merged)

    if all_done? do
      goal = get_in(socket.assigns.plan, ["goal"]) || ""
      provider_config = build_provider_config(socket.assigns)
      topic = socket.assigns.pubsub_topic

      {:ok, _pid} =
        Task.start(fn ->
          try do
            HierarchyPai.Orchestrator.reaggregate(goal, merged, provider_config, topic)
          rescue
            e ->
              Phoenix.PubSub.broadcast(
                HierarchyPai.PubSub,
                topic,
                {:orchestrator, {:error, Exception.message(e)}}
              )
          end
        end)

      {:noreply, assign(socket, :status, :aggregating)}
    else
      {:noreply, socket}
    end
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

  def handle_info({:skills_sync_done, {:ok, 0}}, socket) do
    {:noreply,
     socket
     |> assign(:skills_syncing, false)
     |> assign(:skills_sync_result, {:ok, "No new skills found — already up to date."})}
  end

  def handle_info({:skills_sync_done, {:ok, count}}, socket) do
    {:noreply,
     socket
     |> assign(:skills_syncing, false)
     |> assign(:saved_skills, SkillStore.list())
     |> assign(:skills_sync_result, {:ok, "#{count} new skill(s) loaded from GitHub."})}
  end

  def handle_info({:skills_sync_done, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:skills_syncing, false)
     |> assign(:skills_sync_result, {:error, reason})}
  end

  def handle_info({:skills_reload_done, {:ok, %{added: 0, updated: 0}}}, socket) do
    {:noreply,
     socket
     |> assign(:skills_reloading, false)
     |> assign(:skills_sync_result, {:ok, "No changes — all local skills already up to date."})}
  end

  def handle_info({:skills_reload_done, {:ok, %{added: added, updated: updated}}}, socket) do
    parts =
      [
        if(added > 0, do: "#{added} new", else: nil),
        if(updated > 0, do: "#{updated} updated", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    {:noreply,
     socket
     |> assign(:skills_reloading, false)
     |> assign(:saved_skills, SkillStore.list())
     |> assign(:skills_sync_result, {:ok, "Local skills reloaded: #{parts}."})}
  end

  def handle_info({:skills_reload_done, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:skills_reloading, false)
     |> assign(:skills_sync_result, {:error, reason})}
  end

  def handle_info({:run_store, {:mcp_run_updated, _run}}, socket) do
    {:noreply, assign(socket, :mcp_runs, RunStore.list())}
  end

  def handle_info({:provider_form_models_result, result}, socket) do
    pf = socket.assigns.provider_form

    updated =
      case result do
        {:ok, models} ->
          Map.merge(pf, %{
            fetching_models: false,
            available_models: models,
            fetch_error: nil,
            model: pf.model
          })

        {:error, :server_offline} ->
          Map.merge(pf, %{
            fetching_models: false,
            fetch_error: "Server offline — enter model manually"
          })

        {:error, reason} when is_binary(reason) ->
          Map.merge(pf, %{fetching_models: false, fetch_error: reason})

        {:error, _} ->
          Map.merge(pf, %{fetching_models: false, fetch_error: "Failed to fetch models"})
      end

    {:noreply, assign(socket, :provider_form, updated)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp build_provider_config(assigns) do
    entry = assigns.planner_provider_id && ProviderStore.get(assigns.planner_provider_id)

    case entry do
      nil ->
        # No saved provider selected — return an inert config; "run" button is disabled
        # in this state so this path is only hit defensively.
        %{provider: :openai, model: "", api_key: "", max_retries: 1}

      entry ->
        base = %{
          provider: entry.provider,
          model: entry.model,
          api_key: entry.api_key,
          max_retries: Map.get(entry, :max_retries, 1)
        }

        cond do
          entry.provider in [:custom, :github_copilot] and entry.endpoint != "" ->
            Map.put(base, :endpoint, entry.endpoint)

          LLMProvider.local_provider?(entry.provider) and entry.endpoint != "" ->
            Map.put(base, :local_base, entry.endpoint)

          true ->
            base
        end
    end
  end

  # Resolve step_configs that reference ETS entries (provider_id) into full configs.
  defp resolve_step_configs(step_configs, default_config) do
    Map.new(step_configs, fn {step_id, cfg} ->
      resolved =
        case cfg do
          %{provider_id: pid, model: model} ->
            case ProviderStore.get(pid) do
              nil ->
                default_config

              entry ->
                base = %{
                  provider: entry.provider,
                  model: model,
                  api_key: entry.api_key,
                  max_retries: Map.get(entry, :max_retries, default_config.max_retries)
                }

                cond do
                  entry.provider in [:custom, :github_copilot] and entry.endpoint != "" ->
                    Map.put(base, :endpoint, entry.endpoint)

                  LLMProvider.local_provider?(entry.provider) and entry.endpoint != "" ->
                    Map.put(base, :local_base, entry.endpoint)

                  true ->
                    base
                end
            end

          full_cfg ->
            full_cfg
        end

      {step_id, resolved}
    end)
  end

  defp pick_default_provider_id([]), do: nil

  defp pick_default_provider_id(providers) do
    case Enum.find(providers, &Map.get(&1, :is_default, false)) do
      %{id: id} -> id
      nil -> hd(providers).id
    end
  end

  # Returns all step IDs (accepted) that transitively depend on `step_id`.
  defp transitive_dependents(step_id, steps, accepted) do
    direct =
      steps
      |> Enum.filter(fn s ->
        MapSet.member?(accepted, s["id"]) and step_id in (s["depends_on"] || [])
      end)
      |> Enum.map(& &1["id"])

    indirect = Enum.flat_map(direct, &transitive_dependents(&1, steps, accepted))
    (direct ++ indirect) |> Enum.uniq()
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
    <div id="download-hook" phx-hook=".DownloadFile"></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MCPCopy">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const url = this.el.dataset.url;
            navigator.clipboard.writeText(url).then(() => {
              const icon = this.el.querySelector("svg");
              if (icon) {
                icon.style.color = "#34d399";
                setTimeout(() => { icon.style.color = ""; }, 1500);
              }
            });
          });
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadFile">
      export default {
        mounted() {
          this.handleEvent("download_file", ({ filename, content, mime }) => {
            const blob = new Blob([content], { type: mime });
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = filename;
            a.click();
            URL.revokeObjectURL(url);
          });
        }
      }
    </script>
    <Layouts.app flash={@flash}>
      <div class="min-h-screen bg-gradient-to-br from-base-300 via-base-200 to-base-100 text-base-content">
        <%!-- Header --%>
        <header class="border-b border-base-300/50 bg-base-300/80 backdrop-blur-sm sticky top-0 z-10">
          <div class="w-full px-6 py-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="w-9 h-9 rounded-xl bg-gradient-to-br from-violet-500 to-indigo-600 flex items-center justify-center shadow-lg">
                <.icon name="hero-cpu-chip" class="w-5 h-5 text-base-content" />
              </div>
              <div>
                <h1 class="text-lg font-bold text-base-content tracking-tight">
                  Hierarchical Planner AI
                </h1>
                <p class="text-xs text-base-content/60">Multi-agent reasoning pipeline</p>
              </div>
            </div>
            <div class="flex items-center gap-3">
              <span class={[
                "px-2.5 py-1 rounded-full text-xs font-medium",
                status_badge_class(@status)
              ]}>
                {status_label(@status)}
              </span>
              <a
                href="https://github.com/saatsky/hierarchy_pai"
                target="_blank"
                rel="noopener noreferrer"
                class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs text-base-content/60 hover:text-base-content/90 hover:bg-base-100/60 border border-base-300/50 transition-colors"
                title="View on GitHub"
              >
                <.icon name="hero-code-bracket" class="w-3.5 h-3.5" /> GitHub
              </a>
              <Layouts.theme_toggle />
              <%= if @status in [:done, :error, :review_answer, :step_failed] do %>
                <button
                  phx-click="reset"
                  class="px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100 hover:bg-base-200 text-base-content/90 transition-colors"
                >
                  New task
                </button>
              <% end %>
            </div>
          </div>
        </header>

        <div class="w-full px-6 py-8">
          <div class="grid grid-cols-1 lg:grid-cols-[380px_1fr] gap-6 items-start">
            <%!-- ═══ LEFT SIDEBAR ═══ --%>
            <div class="space-y-4 lg:sticky lg:top-6">
              <%!-- Task input card --%>
              <div class="bg-base-200/60 border border-base-300/50 rounded-2xl p-5 space-y-4 backdrop-blur-sm">
                <h2 class="text-sm font-semibold text-base-content/80 uppercase tracking-wider flex items-center gap-2">
                  <.icon name="hero-pencil-square" class="w-4 h-4 text-violet-400" /> Task
                </h2>

                <textarea
                  phx-keyup="update_task"
                  phx-blur="update_task"
                  name="task"
                  rows="4"
                  disabled={@status != :idle}
                  placeholder="Describe your task or goal in detail&hellip;"
                  class="w-full bg-base-300 border border-base-content/20 rounded-lg px-3 py-2 text-sm text-base-content placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent resize-none leading-relaxed disabled:opacity-50 disabled:cursor-not-allowed"
                >{@task}</textarea>

                <%= if @status == :idle do %>
                  <button
                    id="run-button"
                    phx-click="run"
                    disabled={String.trim(@task) == "" or is_nil(@planner_provider_id)}
                    class="w-full py-2.5 px-4 rounded-xl font-semibold text-sm transition-all duration-200 flex items-center justify-center gap-2 disabled:opacity-40 disabled:cursor-not-allowed bg-gradient-to-r from-violet-600 to-indigo-600 hover:from-violet-500 hover:to-indigo-500 text-white shadow-lg shadow-violet-900/30 hover:shadow-violet-800/40"
                  >
                    <.icon name="hero-play" class="w-4 h-4" /> Run Planner
                  </button>
                <% else %>
                  <div class="flex items-center gap-3">
                    <%= cond do %>
                      <% @status in [:done, :review_answer] -> %>
                        <%!-- Pipeline complete — show a redo option instead of spinner/cancel --%>
                        <div class="flex-1 py-2.5 px-4 rounded-xl text-sm flex items-center justify-center gap-2 bg-emerald-600/10 border border-emerald-700/30 text-emerald-400">
                          <.icon name="hero-check-circle" class="w-4 h-4" />
                          <span>{if @status == :done, do: "Completed", else: "Review answer"}</span>
                        </div>
                        <button
                          id="redo-button"
                          phx-click="cancel"
                          class="py-2.5 px-5 rounded-xl font-semibold text-sm transition-all duration-200 flex items-center gap-2 bg-violet-700/50 hover:bg-violet-600/60 border border-violet-600/50 text-violet-300 hover:text-violet-200"
                        >
                          <.icon name="hero-arrow-path" class="w-4 h-4" /> Redo task
                        </button>
                      <% @status == :step_failed -> %>
                        <%!-- Action is in the execution board — just show status here --%>
                        <div class="flex-1 py-2.5 px-4 rounded-xl text-sm flex items-center justify-center gap-2 bg-orange-600/10 border border-orange-700/30 text-orange-400">
                          <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                          <span>Action required in board below</span>
                        </div>
                        <button
                          id="cancel-button"
                          phx-click="cancel"
                          class="py-2.5 px-5 rounded-xl font-semibold text-sm transition-all duration-200 flex items-center gap-2 bg-red-900/50 hover:bg-red-800/60 border border-red-700/50 text-red-300 hover:text-red-200"
                        >
                          <.icon name="hero-stop" class="w-4 h-4" /> Cancel
                        </button>
                      <% true -> %>
                        <%!-- Active processing state --%>
                        <div class="flex-1 py-2.5 px-4 rounded-xl text-sm flex items-center justify-center gap-2 bg-base-100/50 border border-base-content/20 text-base-content/60">
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
                    <% end %>
                  </div>
                <% end %>
              </div>

              <%!-- Providers panel (unified) --%>
              <div class="bg-base-200/60 border border-base-300/50 rounded-2xl p-4 space-y-3 backdrop-blur-sm">
                <%!-- Header --%>
                <div class="flex items-center justify-between">
                  <h2 class="text-sm font-semibold text-base-content/80 uppercase tracking-wider flex items-center gap-2">
                    <.icon name="hero-cog-6-tooth" class="w-4 h-4 text-violet-400" /> Providers
                    <%= if @saved_providers != [] do %>
                      <span class="ml-1 bg-violet-100 text-violet-700 dark:bg-violet-600/30 dark:text-violet-300 text-xs px-1.5 py-0.5 rounded-full font-mono">
                        {length(@saved_providers)}
                      </span>
                    <% end %>
                  </h2>
                  <button
                    phx-click="open_provider_form"
                    class="text-xs text-violet-400 hover:text-violet-300 flex items-center gap-1 transition-colors"
                  >
                    <.icon name="hero-plus" class="w-3 h-3" /> Add
                  </button>
                </div>

                <%!-- Provider form (add / edit) --%>
                <%= if @provider_form do %>
                  <% pf = @provider_form %>
                  <form
                    phx-change="provider_form_change"
                    phx-submit="save_provider_form"
                    id="saved-provider-form"
                    class="space-y-2 bg-base-300/60 rounded-xl p-3 border border-base-300/50"
                  >
                    <p class="text-xs font-medium text-base-content/80">
                      {if pf[:id], do: "Edit provider", else: "New provider"}
                    </p>

                    <%!-- Name --%>
                    <input
                      type="text"
                      name="saved_provider[name]"
                      value={pf[:name]}
                      placeholder="e.g. My Jan.ai"
                      class="w-full bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content placeholder-slate-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />

                    <%!-- Provider type --%>
                    <select
                      name="saved_provider[provider]"
                      class="w-full bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content/80 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <%= for {label, val} <- @providers do %>
                        <option value={val} selected={pf[:provider] == val}>{label}</option>
                      <% end %>
                    </select>

                    <%!-- Model — text input + Fetch button, or select when models are available --%>
                    <div class="space-y-1.5">
                      <div class="flex gap-1.5">
                        <%= if pf[:available_models] != [] do %>
                          <select
                            name="saved_provider[model]"
                            class="flex-1 bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content/80 focus:outline-none focus:ring-1 focus:ring-violet-500"
                          >
                            <option value="" disabled={pf[:model] != ""}>— select a model —</option>
                            <%= for m <- pf[:available_models] do %>
                              <option value={m} selected={pf[:model] == m}>{m}</option>
                            <% end %>
                          </select>
                        <% else %>
                          <input
                            type="text"
                            name="saved_provider[model]"
                            value={pf[:model]}
                            placeholder="model name (e.g. llama3.2)"
                            class="flex-1 bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content placeholder-slate-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                          />
                        <% end %>
                        <button
                          type="button"
                          phx-click="fetch_provider_form_models"
                          disabled={pf[:fetching_models]}
                          class="flex items-center gap-1 px-2.5 py-1.5 bg-violet-600/20 hover:bg-violet-600/40 border border-violet-600/30 rounded-lg text-xs text-violet-300 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                          title="Fetch available models from this provider"
                        >
                          <%= if pf[:fetching_models] do %>
                            <.icon name="hero-arrow-path" class="w-3 h-3 animate-spin" />
                          <% else %>
                            <.icon name="hero-arrow-down-tray" class="w-3 h-3" />
                          <% end %>
                        </button>
                      </div>
                      <%= if pf[:fetch_error] do %>
                        <p class="text-xs text-amber-400">{pf[:fetch_error]}</p>
                      <% end %>
                    </div>

                    <%!-- API key (if needed) --%>
                    <%= if pf[:provider] in [:openai, :anthropic, :github_copilot, :custom] do %>
                      <input
                        type="password"
                        name="saved_provider[api_key]"
                        value={pf[:api_key]}
                        placeholder={
                          case pf[:provider] do
                            :github_copilot -> "github_pat_..."
                            :openai -> "sk-..."
                            :anthropic -> "sk-ant-..."
                            _ -> "API key (optional)"
                          end
                        }
                        class="w-full bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content placeholder-slate-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      />
                    <% end %>

                    <%!-- Endpoint (local providers and custom show this) --%>
                    <%= if pf[:provider] in [:jan_ai, :ollama, :custom] do %>
                      <input
                        type="text"
                        name="saved_provider[endpoint]"
                        value={pf[:endpoint]}
                        placeholder={
                          case pf[:provider] do
                            :jan_ai -> "http://localhost:1337 (optional)"
                            :ollama -> "http://localhost:11434 (optional)"
                            _ -> "https://..."
                          end
                        }
                        class="w-full bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content placeholder-slate-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      />
                    <% end %>

                    <%!-- Chain retries --%>
                    <div>
                      <label class="block text-xs text-base-content/60 mb-1">
                        Chain retries (bad response)
                      </label>
                      <select
                        name="saved_provider[max_retries]"
                        class="w-full bg-base-200 border border-base-content/20 rounded-lg px-2.5 py-1.5 text-xs text-base-content/80 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      >
                        <%= for n <- [0, 1, 2, 3, 5] do %>
                          <option value={n} selected={Map.get(pf, :max_retries, 0) == n}>{n}</option>
                        <% end %>
                      </select>
                      <p class="mt-1 text-xs text-base-content/50">
                        Re-sends when the LLM returns malformed JSON. Min 1 recommended.
                      </p>
                    </div>

                    <div class="flex gap-2 pt-1">
                      <button
                        type="submit"
                        class="flex-1 bg-violet-600 hover:bg-violet-500 text-white text-xs font-medium py-1.5 rounded-lg transition-colors"
                      >
                        Save
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_provider_form"
                        class="flex-1 bg-base-100 hover:bg-base-200 text-base-content/80 text-xs font-medium py-1.5 rounded-lg transition-colors"
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                <% end %>

                <%!-- Empty state --%>
                <%= if @saved_providers == [] and is_nil(@provider_form) do %>
                  <div class="rounded-xl border border-dashed border-base-content/20 p-5 flex flex-col items-center text-center gap-3">
                    <div class="w-10 h-10 rounded-xl bg-violet-100 border border-violet-300 dark:bg-violet-600/10 dark:border-violet-700/30 flex items-center justify-center">
                      <.icon name="hero-bolt" class="w-5 h-5 text-violet-500" />
                    </div>
                    <div>
                      <p class="text-sm font-medium text-base-content/80">No providers yet</p>
                      <p class="text-xs text-base-content/50 mt-0.5">
                        Add at least one provider to run tasks.
                      </p>
                    </div>
                    <button
                      phx-click="open_provider_form"
                      class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Provider
                    </button>
                  </div>
                <% end %>

                <%!-- Provider list --%>
                <%= for sp <- @saved_providers do %>
                  <% is_default = @planner_provider_id == sp.id %>
                  <div class={[
                    "flex items-center gap-2 py-2 border-b border-base-300/40 last:border-0 rounded-lg px-1 transition-colors",
                    if(is_default, do: "bg-violet-600/10", else: "")
                  ]}>
                    <%!-- Default radio button --%>
                    <button
                      type="button"
                      phx-click="update_planner_provider"
                      phx-value-provider_id={sp.id}
                      disabled={@status != :idle}
                      title={if is_default, do: "Active provider", else: "Set as default"}
                      class="flex-shrink-0 disabled:opacity-40 disabled:cursor-not-allowed"
                    >
                      <div class={[
                        "w-4 h-4 rounded-full border-2 flex items-center justify-center transition-colors",
                        if(is_default,
                          do: "border-violet-500 bg-violet-500",
                          else: "border-base-content/30 hover:border-violet-400"
                        )
                      ]}>
                        <%= if is_default do %>
                          <div class="w-1.5 h-1.5 rounded-full bg-white"></div>
                        <% end %>
                      </div>
                    </button>

                    <%!-- Provider info --%>
                    <div class="flex-1 min-w-0">
                      <p class="text-xs font-medium text-base-content/90 truncate flex items-center gap-1.5">
                        {sp.name}
                        <%= if is_default do %>
                          <span class="text-[10px] text-violet-400 font-normal">default</span>
                        <% end %>
                      </p>
                      <p class="text-xs text-base-content/50 truncate">
                        {sp.model} &middot; {sp.provider}
                        <%= if Map.get(sp, :max_retries, 0) > 0 do %>
                          <span class="ml-1 text-base-content/40">
                            ↺{Map.get(sp, :max_retries, 0)}
                          </span>
                        <% end %>
                      </p>
                    </div>

                    <%!-- Edit / Delete --%>
                    <button
                      phx-click="edit_saved_provider"
                      phx-value-id={sp.id}
                      class="text-base-content/50 hover:text-base-content/80 transition-colors flex-shrink-0"
                      title="Edit"
                    >
                      <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
                    </button>
                    <button
                      phx-click="delete_saved_provider"
                      phx-value-id={sp.id}
                      data-confirm="Delete this saved provider?"
                      class="text-base-content/50 hover:text-red-400 transition-colors flex-shrink-0"
                      title="Delete"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                <% end %>
              </div>

              <%!-- Skills panel --%>
              <div class="bg-base-200/40 border border-base-300/30 rounded-2xl p-4 space-y-3">
                <%!-- Header row --%>
                <div class="flex items-center justify-between">
                  <p class="text-xs font-semibold text-base-content/80 flex items-center gap-1.5">
                    <.icon name="hero-academic-cap" class="w-3.5 h-3.5 text-teal-400" /> Agent Skills
                    <%= if @saved_skills != [] do %>
                      <span class="ml-1 bg-teal-100 text-teal-700 dark:bg-teal-600/30 dark:text-teal-300 text-xs px-1.5 py-0.5 rounded-full">
                        {length(@saved_skills)}
                      </span>
                    <% end %>
                  </p>
                  <%!-- Action buttons row --%>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="reload_local_skills"
                      disabled={@skills_reloading}
                      class="text-xs text-amber-500 hover:text-amber-400 flex items-center gap-1 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      title="Reload skills from priv/skills/"
                    >
                      <.icon
                        name={if @skills_reloading, do: "hero-arrow-path", else: "hero-arrow-path"}
                        class={["w-3 h-3", if(@skills_reloading, do: "animate-spin")]}
                      />
                      {if @skills_reloading, do: "Reloading…", else: "Reload local"}
                    </button>
                    <span class="text-base-content/20">|</span>
                    <button
                      phx-click="sync_skills"
                      disabled={@skills_syncing}
                      class="text-xs text-teal-400 hover:text-teal-300 flex items-center gap-1 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      title="Check for new skills on GitHub"
                    >
                      <.icon
                        name={if @skills_syncing, do: "hero-arrow-path", else: "hero-arrow-down-tray"}
                        class={["w-3 h-3", if(@skills_syncing, do: "animate-spin")]}
                      />
                      {if @skills_syncing, do: "Syncing…", else: "Check GitHub"}
                    </button>
                  </div>
                </div>

                <%!-- Sync/reload result banner --%>
                <%= if @skills_sync_result do %>
                  <% {kind, msg} = @skills_sync_result %>
                  <div class={[
                    "rounded-lg px-3 py-2 text-xs flex items-start gap-2",
                    if(kind == :ok,
                      do:
                        "bg-teal-50 border border-teal-300 text-teal-700 dark:bg-teal-900/30 dark:border-teal-700/40 dark:text-teal-300",
                      else:
                        "bg-red-50 border border-red-300 text-red-700 dark:bg-red-900/30 dark:border-red-700/40 dark:text-red-300"
                    )
                  ]}>
                    <.icon
                      name={if(kind == :ok, do: "hero-check-circle", else: "hero-exclamation-circle")}
                      class="w-3.5 h-3.5 shrink-0 mt-0.5"
                    />
                    {msg}
                  </div>
                <% end %>

                <%!-- Search input (only when skills exist) --%>
                <%= if @saved_skills != [] do %>
                  <div class="relative">
                    <.icon
                      name="hero-magnifying-glass"
                      class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-base-content/40 pointer-events-none"
                    />
                    <input
                      type="text"
                      value={@skill_search}
                      phx-keyup="filter_skills"
                      phx-change="filter_skills"
                      name="value"
                      placeholder="Search skills…"
                      class="w-full bg-base-100 border border-base-300/50 rounded-lg pl-7 pr-3 py-1 text-xs text-base-content placeholder-base-content/30 focus:outline-none focus:ring-1 focus:ring-teal-500/50 focus:border-teal-500/50"
                    />
                  </div>
                <% end %>

                <%!-- Skill list --%>
                <% q = String.downcase(@skill_search)

                visible_skills =
                  if q == "" do
                    @saved_skills
                  else
                    Enum.filter(@saved_skills, fn s ->
                      String.contains?(String.downcase(s.name), q) or
                        String.contains?(String.downcase(s.type), q) or
                        String.contains?(String.downcase(s.description), q)
                    end)
                  end %>
                <%= if visible_skills == [] do %>
                  <p class="text-xs text-base-content/50 text-center py-3">
                    <%= if @saved_skills == [] do %>
                      No skills loaded. Click
                      <strong class="text-base-content/60">Reload local</strong>
                      or <strong class="text-base-content/60">Check GitHub</strong>
                      to load skills.
                    <% else %>
                      No skills match <em>"{@skill_search}"</em>
                    <% end %>
                  </p>
                <% else %>
                  <%!-- Count hint when filtered --%>
                  <%= if q != "" do %>
                    <p class="text-xs text-base-content/40">
                      {length(visible_skills)} of {length(@saved_skills)} skills
                    </p>
                  <% end %>
                  <%!-- Scrollable list: max 5 rows visible (~40px/row = 200px) --%>
                  <div class="space-y-0.5 max-h-[200px] overflow-y-auto pr-0.5 scrollbar-thin">
                    <%= for skill <- visible_skills do %>
                      <div class="flex items-center gap-2 py-1.5 border-b border-base-300/30 last:border-0">
                        <span class={[
                          "text-xs px-1.5 py-0.5 rounded font-mono shrink-0",
                          case skill.type do
                            "research" ->
                              "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300"

                            "content" ->
                              "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300"

                            "engineering" ->
                              "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300"

                            _ ->
                              "bg-base-100/60 text-base-content/60"
                          end
                        ]}>
                          {skill.type}
                        </span>
                        <p class="flex-1 min-w-0 text-xs font-medium text-base-content/90 truncate">
                          {skill.name}
                        </p>
                        <%!-- Info icon with CSS tooltip showing the skill description --%>
                        <div class="relative group shrink-0">
                          <.icon
                            name="hero-information-circle"
                            class="w-3.5 h-3.5 text-base-content/30 hover:text-base-content/70 cursor-default transition-colors"
                          />
                          <div class="pointer-events-none absolute top-full right-0 mt-1 z-50
                                      w-56 rounded-lg border border-base-300 bg-base-200 p-2.5 shadow-lg
                                      text-xs text-base-content/80 leading-relaxed
                                      opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                            <p class="font-semibold text-base-content/90 mb-1">{skill.name}</p>
                            {skill.description}
                          </div>
                        </div>
                        <%= if skill[:source] == :remote do %>
                          <span class="text-xs text-teal-500 shrink-0" title="Synced from GitHub">
                            <.icon name="hero-cloud-arrow-down" class="w-3 h-3" />
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <p class="text-xs text-base-content/40 leading-relaxed">
                  Skills replace the default specialist prompt for a step. Select a skill per step in the review plan above.
                </p>
              </div>

              <%!-- MCP Server panel --%>
              <div class="bg-base-200/40 border border-base-300/30 rounded-2xl p-4 space-y-3">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-semibold text-base-content/80 flex items-center gap-1.5">
                    <.icon name="hero-cpu-chip" class="w-3.5 h-3.5 text-purple-400" /> MCP Server
                    <span class="inline-flex items-center gap-1 ml-1 bg-emerald-100 text-emerald-700 dark:bg-emerald-600/20 dark:text-emerald-400 text-xs px-1.5 py-0.5 rounded-full">
                      <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 inline-block animate-pulse">
                      </span>
                      Active
                    </span>
                  </p>
                </div>

                <%!-- Endpoint URL --%>
                <div class="space-y-1">
                  <p class="text-xs text-base-content/50">Endpoint</p>
                  <div class="flex items-center gap-2">
                    <code class="flex-1 text-xs bg-base-100/60 border border-base-300/40 rounded-lg px-2.5 py-1.5 text-purple-700 dark:text-purple-300 font-mono truncate">
                      http://localhost:4000/mcp
                    </code>
                    <button
                      id="mcp-copy-btn"
                      phx-hook=".MCPCopy"
                      data-url="http://localhost:4000/mcp"
                      class="shrink-0 p-1.5 rounded-lg hover:bg-base-100/60 text-base-content/40 hover:text-base-content/80 transition-colors"
                      title="Copy endpoint URL"
                    >
                      <.icon name="hero-clipboard" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>

                <%!-- Recent MCP runs --%>
                <%= if @mcp_runs != [] do %>
                  <div class="space-y-1">
                    <p class="text-xs text-base-content/50">Recent runs</p>
                    <%= for run <- Enum.take(@mcp_runs, 5) do %>
                      <div class="flex items-center gap-2 py-1.5 border-b border-base-300/20 last:border-0">
                        <span class={[
                          "w-1.5 h-1.5 rounded-full shrink-0",
                          case run.status do
                            :done -> "bg-emerald-400"
                            :error -> "bg-red-400"
                            _ -> "bg-amber-400 animate-pulse"
                          end
                        ]}>
                        </span>
                        <p
                          class="flex-1 min-w-0 text-xs text-base-content/70 truncate"
                          title={run.task}
                        >
                          {run.task}
                        </p>
                        <span class={[
                          "text-xs px-1.5 py-0.5 rounded font-mono shrink-0",
                          case run.status do
                            :done ->
                              "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400"

                            :error ->
                              "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

                            :planning ->
                              "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400"

                            :executing ->
                              "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"

                            _ ->
                              "bg-base-100/60 text-base-content/50"
                          end
                        ]}>
                          {run.status}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <p class="text-xs text-base-content/40 text-center py-2">
                    No MCP runs yet. Connect a client to <code class="text-purple-400">POST /mcp</code>.
                  </p>
                <% end %>
              </div>

              <%!-- About card --%>
              <div class="bg-base-200/40 border border-base-300/30 rounded-2xl p-5 text-xs text-base-content/50 space-y-2">
                <p class="font-medium text-base-content/60">How it works</p>
                <div class="space-y-1.5">
                  <div class="flex items-start gap-2">
                    <span class="w-5 h-5 rounded-full bg-violet-600 text-white text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                      1
                    </span>
                    <span>
                      <strong class="text-base-content/80">Planner</strong>
                      &mdash; decomposes your task into structured steps
                    </span>
                  </div>
                  <div class="flex items-start gap-2">
                    <span class="w-5 h-5 rounded-full bg-violet-600 text-white text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                      2
                    </span>
                    <span>
                      <strong class="text-base-content/80">Review</strong>
                      &mdash; accept/reject steps and pick a model per step
                    </span>
                  </div>
                  <div class="flex items-start gap-2">
                    <span class="w-5 h-5 rounded-full bg-violet-600 text-white text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                      3
                    </span>
                    <span>
                      <strong class="text-base-content/80">Executor</strong>
                      &mdash; runs steps in parallel dependency waves
                    </span>
                  </div>
                  <div class="flex items-start gap-2">
                    <span class="w-5 h-5 rounded-full bg-violet-600 text-white text-xs flex items-center justify-center shrink-0 mt-0.5 font-bold">
                      4
                    </span>
                    <span>
                      <strong class="text-base-content/80">Aggregator</strong>
                      &mdash; synthesizes all outputs into a final answer
                    </span>
                  </div>
                </div>
              </div>
            </div>
            <%!-- /LEFT SIDEBAR --%>

            <%!-- ═══ RIGHT MAIN CONTENT ═══ --%>
            <div class="space-y-5 min-w-0">
              <%!-- Error banner --%>
              <%= if @error do %>
                <div class="bg-red-50 border border-red-300 dark:bg-red-900/30 dark:border-red-700/50 rounded-xl p-4 flex items-start gap-3">
                  <.icon
                    name="hero-exclamation-triangle"
                    class="w-5 h-5 text-red-500 dark:text-red-400 shrink-0 mt-0.5"
                  />
                  <p class="text-sm text-red-700 dark:text-red-300">{@error}</p>
                </div>
              <% end %>

              <%!-- Idle placeholder --%>
              <%= if @status == :idle do %>
                <div class="bg-base-200/30 border border-base-300/30 rounded-2xl p-12 flex flex-col items-center text-center gap-4">
                  <div class="w-16 h-16 rounded-2xl bg-violet-100 border border-violet-300 dark:bg-violet-600/10 dark:border-violet-700/30 flex items-center justify-center">
                    <.icon name="hero-cpu-chip" class="w-8 h-8 text-violet-500" />
                  </div>
                  <div>
                    <p class="text-lg font-semibold text-base-content/80">Ready to plan</p>
                    <p class="text-sm text-base-content/50 mt-1 max-w-md">
                      <%= if @saved_providers == [] do %>
                        Add a provider in the
                        <strong class="text-base-content/60">Saved Providers</strong>
                        panel, then enter a task and click <strong class="text-base-content/60">Run Planner</strong>.
                      <% else %>
                        Select a provider, enter a task, and click
                        <strong class="text-base-content/60">Run Planner</strong>
                        to start the multi-agent pipeline.
                      <% end %>
                    </p>
                  </div>
                </div>
              <% end %>

              <%!-- Planning spinner --%>
              <%= if @status == :planning do %>
                <div class="bg-base-200/60 border border-base-300/50 rounded-2xl p-6 space-y-4">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-3">
                      <div class="w-8 h-8 rounded-lg bg-violet-100 dark:bg-violet-100 dark:bg-violet-600/20 flex items-center justify-center">
                        <.icon name="hero-arrow-path" class="w-4 h-4 text-violet-400 animate-spin" />
                      </div>
                      <div>
                        <p class="text-sm font-semibold text-base-content/90">
                          Analysing task&hellip;
                        </p>
                        <p class="text-xs text-base-content/60">Elapsed: {@elapsed_seconds}s</p>
                      </div>
                    </div>
                    <button
                      phx-click="cancel"
                      class="px-3 py-1.5 text-xs font-medium rounded-lg bg-red-50 hover:bg-red-100 text-red-700 border border-red-300 dark:bg-red-900/30 dark:hover:bg-red-800/40 dark:text-red-400 dark:border-red-700/40 transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                  <%= if @planner_stream != "" do %>
                    <div class="bg-base-300/60 rounded-xl p-4 max-h-64 overflow-y-auto">
                      <pre class="text-xs text-base-content/80 whitespace-pre-wrap font-mono leading-relaxed">{@planner_stream}</pre>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Plan Review --%>
              <%= if @status == :review_plan and @plan do %>
                <div class="bg-base-200/60 border border-base-300/50 rounded-2xl overflow-hidden backdrop-blur-sm">
                  <div class="px-5 py-4 border-b border-base-300/50 flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-clipboard-document-check" class="w-4 h-4 text-violet-400" />
                      <h2 class="font-semibold text-base-content/90">Plan Review</h2>
                      <span class="text-xs text-base-content/60">
                        {length(@plan["steps"] || [])} steps
                      </span>
                    </div>
                    <div class="flex items-center gap-2">
                      <button
                        phx-click="cancel"
                        class="px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100/60 hover:bg-red-900/40 border border-base-content/20 hover:border-red-700/50 text-base-content/60 hover:text-red-300 transition-colors flex items-center gap-1.5"
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel plan
                      </button>
                      <button
                        phx-click="reject_all_steps"
                        class="px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100 hover:bg-base-200 text-base-content/80 transition-colors"
                      >
                        Reject All
                      </button>
                      <button
                        phx-click="accept_all_steps"
                        class="px-3 py-1.5 text-xs font-medium rounded-lg bg-violet-100 hover:bg-violet-200 text-violet-700 border border-violet-300 dark:bg-violet-600/30 dark:hover:bg-violet-600/40 dark:text-violet-300 dark:border-violet-700/40 transition-colors"
                      >
                        Accept All
                      </button>
                    </div>
                  </div>

                  <div class="px-5 py-3 bg-violet-50 border-b border-violet-200 dark:bg-violet-600/10 dark:border-base-300/30">
                    <p class="text-xs font-medium text-violet-600 dark:text-violet-400 uppercase tracking-wider mb-1">
                      Goal
                    </p>
                    <p class="text-sm text-base-content/90">{@plan["goal"]}</p>
                  </div>

                  <%= for {wave_num, wave_steps} <- compute_waves(@plan["steps"] || []) do %>
                    <div class="px-5 py-4 border-b border-base-300/30 last:border-0">
                      <div class="flex items-center gap-2 mb-3">
                        <span class="text-xs font-medium px-2.5 py-0.5 rounded-full bg-indigo-100 text-indigo-700 border border-indigo-300 dark:bg-indigo-600/20 dark:text-indigo-400 dark:border-indigo-700/40">
                          Wave {wave_num}
                        </span>
                        <span class="text-xs text-base-content/50">
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
                              do: "bg-base-100/40 border-base-content/20",
                              else: "bg-base-200/40 border-base-300/30 opacity-60"
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
                                  <p class="text-sm font-semibold text-base-content/90">
                                    {step["title"]}
                                  </p>
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
                                  <summary class="text-xs text-base-content/50 cursor-pointer hover:text-base-content/60 select-none">
                                    View instruction
                                  </summary>
                                  <p class="text-xs text-base-content/60 mt-1.5 leading-relaxed pl-3 border-l border-base-300">
                                    {step["instruction"]}
                                  </p>
                                </details>

                                <form
                                  phx-change="update_step_config"
                                  id={"step-cfg-#{step["id"]}"}
                                  class="flex items-center gap-2 flex-wrap"
                                >
                                  <input type="hidden" name="step_id" value={step["id"]} />
                                  <%= if @saved_providers != [] do %>
                                    <%!-- Saved providers: two dropdowns (provider name + model) --%>
                                    <% saved_id = Map.get(step_cfg, :provider_id) %>
                                    <% active_sp =
                                      Enum.find(@saved_providers, &(&1.id == saved_id)) ||
                                        hd(@saved_providers) %>
                                    <select
                                      name="provider_id"
                                      class="bg-base-300 border border-violet-700/50 rounded text-xs text-violet-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
                                    >
                                      <%= for sp <- @saved_providers do %>
                                        <option value={sp.id} selected={sp.id == saved_id}>
                                          {sp.name}
                                        </option>
                                      <% end %>
                                    </select>
                                    <% sp_models = LLMProvider.default_models(active_sp.provider) %>
                                    <%= if sp_models != [] do %>
                                      <select
                                        name="model"
                                        class="flex-1 bg-base-300 border border-base-300 rounded text-xs text-base-content/80 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
                                      >
                                        <%= for m <- sp_models do %>
                                          <option
                                            value={m}
                                            selected={Map.get(step_cfg, :model, active_sp.model) == m}
                                          >
                                            {m}
                                          </option>
                                        <% end %>
                                      </select>
                                    <% else %>
                                      <input
                                        type="text"
                                        name="model"
                                        value={Map.get(step_cfg, :model, active_sp.model)}
                                        phx-debounce="300"
                                        placeholder="model"
                                        class="flex-1 bg-base-300 border border-base-300 rounded text-xs text-base-content/80 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500 placeholder-slate-600"
                                      />
                                    <% end %>
                                  <% else %>
                                    <%!-- Fallback: raw provider atom + model --%>
                                    <select
                                      name="provider"
                                      class="bg-base-300 border border-base-300 rounded text-xs text-base-content/80 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
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
                                        class="flex-1 bg-base-300 border border-base-300 rounded text-xs text-base-content/80 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500 placeholder-slate-600"
                                      />
                                    <% else %>
                                      <select
                                        name="model"
                                        class="flex-1 bg-base-300 border border-base-300 rounded text-xs text-base-content/80 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-violet-500"
                                      >
                                        <%= for m <- LLMProvider.default_models(step_cfg.provider) do %>
                                          <option value={m} selected={step_cfg.model == m}>
                                            {m}
                                          </option>
                                        <% end %>
                                      </select>
                                    <% end %>
                                  <% end %>
                                </form>
                                <%!-- Agent type selector --%>
                                <form
                                  phx-change="update_step_agent_type"
                                  id={"step-agent-#{step["id"]}"}
                                  class="flex items-center gap-2 mt-1.5"
                                >
                                  <input type="hidden" name="step_id" value={step["id"]} />
                                  <span class="text-xs text-base-content/50 shrink-0">
                                    Specialist:
                                  </span>
                                  <select
                                    name="agent_type"
                                    class="flex-1 bg-base-300 border border-indigo-400 rounded text-xs text-base-content dark:border-indigo-700/50 dark:text-indigo-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500"
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
                                <%!-- Skill selector --%>
                                <%= if @saved_skills != [] do %>
                                  <form
                                    phx-change="update_step_skill"
                                    id={"step-skill-#{step["id"]}"}
                                    class="flex items-center gap-2 mt-1.5"
                                  >
                                    <input type="hidden" name="step_id" value={step["id"]} />
                                    <span class="text-xs text-base-content/50 shrink-0">Skill:</span>
                                    <select
                                      name="skill_id"
                                      class="flex-1 bg-base-300 border border-teal-400 rounded text-xs text-base-content dark:border-teal-700/50 dark:text-teal-300 px-2 py-1 focus:outline-none focus:ring-1 focus:ring-teal-500"
                                    >
                                      <option value="">— default specialist —</option>
                                      <%= for skill <- @saved_skills do %>
                                        <option
                                          value={skill.id}
                                          selected={Map.get(@step_skills, step["id"]) == skill.id}
                                        >
                                          {skill.name}
                                        </option>
                                      <% end %>
                                    </select>
                                  </form>
                                <% end %>
                              </div>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>

                  <div class="px-5 py-4 bg-base-300/40 border-t border-base-300/50 flex items-center justify-between">
                    <span class="text-xs text-base-content/60">
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
              <%= if @status in [:executing, :step_failed, :aggregating, :review_answer, :done] and @plan do %>
                <div class={[
                  "border rounded-2xl overflow-hidden backdrop-blur-sm",
                  cond do
                    @status == :step_failed ->
                      "bg-orange-50 border-orange-300 dark:bg-orange-950/20 dark:border-orange-700/40"

                    @status in [:done, :review_answer] ->
                      "bg-emerald-50 border-emerald-300 dark:bg-emerald-950/20 dark:border-emerald-700/30"

                    true ->
                      "bg-base-200/60 border-base-300/50"
                  end
                ]}>
                  <div class="px-5 py-4 border-b border-base-300/50 flex items-center gap-2">
                    <.icon name="hero-squares-2x2" class="w-4 h-4 text-violet-400" />
                    <h2 class="font-semibold text-base-content/90">Execution Board</h2>
                    <%= cond do %>
                      <% @status == :step_failed -> %>
                        <span class="text-xs px-2 py-0.5 rounded-full bg-orange-100 text-orange-700 border border-orange-300 dark:bg-orange-600/20 dark:text-orange-400 dark:border-orange-700/40">
                          Action required
                        </span>
                      <% @status in [:done, :review_answer] -> %>
                        <span class="text-xs px-2 py-0.5 rounded-full bg-emerald-100 text-emerald-700 border border-emerald-300 dark:bg-emerald-600/20 dark:text-emerald-400 dark:border-emerald-700/40">
                          Completed — click any done step to redo
                        </span>
                      <% true -> %>
                    <% end %>
                    <span class="ml-auto text-xs text-base-content/50">{@elapsed_seconds}s</span>
                    <%= if @status == :executing do %>
                      <button
                        phx-click="cancel"
                        class="px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100/60 hover:bg-red-900/40 border border-base-content/20 hover:border-red-700/50 text-base-content/60 hover:text-red-300 transition-colors flex items-center gap-1.5"
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                      </button>
                    <% end %>
                  </div>
                  <div class="p-5 grid grid-cols-4 gap-4">
                    <div>
                      <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                        <span class="w-2 h-2 rounded-full bg-base-300 shrink-0"></span> Queue
                      </h3>
                      <div class="space-y-2">
                        <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :pending) do %>
                          <div class="bg-base-100/40 border border-base-content/20 rounded-lg p-3">
                            <p class="text-xs font-bold text-base-content/60 mb-0.5">#{step["id"]}</p>
                            <p class="text-xs font-medium text-base-content/80 leading-snug">
                              {step["title"]}
                            </p>
                            <p class="text-xs text-base-content/50 mt-1 truncate">
                              {AgentRegistry.label_for(step["agent_type"] || "executor")}
                            </p>
                          </div>
                        <% end %>
                      </div>
                    </div>

                    <div>
                      <h3 class="text-xs font-semibold text-violet-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                        <span class="w-2 h-2 rounded-full bg-violet-500 animate-pulse shrink-0">
                        </span>
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
                            <p class="text-xs font-medium text-base-content/80 leading-snug mb-1.5">
                              {step["title"]}
                            </p>
                            <p class="text-xs text-violet-400/70 mb-1 truncate">
                              {AgentRegistry.label_for(step["agent_type"] || "executor")}
                            </p>
                            <%= if Map.get(@step_streams, step["id"], "") != "" do %>
                              <p class="text-xs text-base-content/60 font-mono leading-relaxed line-clamp-3 break-all">
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
                          <% empty_output? = Map.get(@step_outputs, step["id"], "") == "" %>
                          <%!-- @container so buttons can hide/show labels based on card width --%>
                          <div class={[
                            "@container border rounded-lg p-3",
                            if(empty_output?,
                              do:
                                "bg-amber-50 border-amber-300 dark:bg-amber-900/10 dark:border-amber-700/40",
                              else:
                                "bg-emerald-50 border-emerald-300 dark:bg-emerald-600/10 dark:border-emerald-700/40"
                            )
                          ]}>
                            <div class="flex items-center gap-1.5 mb-1">
                              <%= if empty_output? do %>
                                <.icon
                                  name="hero-exclamation-triangle"
                                  class="w-3 h-3 text-amber-400"
                                />
                                <p class="text-xs font-bold text-amber-400">#{step["id"]}</p>
                                <span class="ml-auto text-xs text-amber-500/80 font-medium">
                                  empty
                                </span>
                              <% else %>
                                <.icon name="hero-check-circle" class="w-3 h-3 text-emerald-400" />
                                <p class="text-xs font-bold text-emerald-400">#{step["id"]}</p>
                              <% end %>
                            </div>
                            <p class="text-xs font-medium text-base-content/80 leading-snug">
                              {step["title"]}
                            </p>
                            <p class={[
                              "text-xs mt-1 truncate",
                              if(empty_output?, do: "text-amber-500/60", else: "text-emerald-500/70")
                            ]}>
                              {AgentRegistry.label_for(step["agent_type"] || "executor")}
                            </p>
                            <%!-- Buttons: icon-only by default, icon+label when card is wide enough --%>
                            <div class="flex items-center gap-1 mt-2">
                              <button
                                phx-click="view_step_output"
                                phx-value-step_id={step["id"]}
                                title="View output"
                                class="flex-1 flex items-center justify-center gap-1 px-2 py-1 rounded-md bg-base-100/60 hover:bg-base-200/60 text-base-content/60 hover:text-base-content/90 text-xs transition-colors"
                              >
                                <.icon name="hero-eye" class="w-3 h-3 shrink-0" />
                                <span class="hidden @[9rem]:inline">View</span>
                              </button>
                              <button
                                phx-click="request_redo_step"
                                phx-value-step_id={step["id"]}
                                title="Redo this step"
                                class={[
                                  "flex-1 flex items-center justify-center gap-1 px-2 py-1 rounded-md text-xs transition-colors",
                                  if(empty_output?,
                                    do:
                                      "bg-amber-100 hover:bg-amber-200 text-amber-700 dark:bg-amber-700/40 dark:hover:bg-amber-600/50 dark:text-amber-300 dark:hover:text-amber-200",
                                    else:
                                      "bg-violet-100 hover:bg-violet-200 text-violet-700 dark:bg-violet-700/40 dark:hover:bg-violet-600/50 dark:text-violet-300 dark:hover:text-violet-200"
                                  )
                                ]}
                              >
                                <.icon name="hero-arrow-path" class="w-3 h-3 shrink-0" />
                                <span class="hidden @[9rem]:inline">Redo</span>
                              </button>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>

                    <div>
                      <h3 class="text-xs font-semibold text-red-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                        <span class="w-2 h-2 rounded-full bg-red-500 shrink-0"></span> Failed
                      </h3>
                      <div class="space-y-2">
                        <%= for step <- steps_by_status(@plan, @step_statuses, @accepted_steps, :error) do %>
                          <div class="bg-red-50 border border-red-300 dark:bg-red-600/10 dark:border-red-700/40 rounded-lg p-3 space-y-1.5">
                            <div class="flex items-center gap-1.5">
                              <.icon
                                name="hero-x-circle"
                                class="w-3 h-3 text-red-500 dark:text-red-400 shrink-0"
                              />
                              <p class="text-xs font-bold text-red-600 dark:text-red-400">
                                #{step["id"]}
                              </p>
                            </div>
                            <p class="text-xs font-medium text-base-content/80 leading-snug">
                              {step["title"]}
                            </p>
                            <p class="text-xs text-red-500/70 dark:text-red-400/60 truncate">
                              {AgentRegistry.label_for(step["agent_type"] || "executor")}
                            </p>
                            <%= if reason = Map.get(@step_errors, step["id"]) do %>
                              <p class="text-xs text-red-700 dark:text-red-400/80 font-mono leading-snug bg-red-100 dark:bg-red-900/20 rounded px-1.5 py-1 break-all">
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
                    <div class="px-5 py-4 border-t border-orange-200 bg-orange-50 dark:border-orange-700/30 dark:bg-orange-950/20 flex flex-col sm:flex-row items-start sm:items-center gap-3">
                      <div class="flex-1">
                        <p class="text-sm font-semibold text-orange-700 dark:text-orange-300">
                          One or more steps failed
                        </p>
                        <p class="text-xs text-base-content/60 mt-0.5">
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
                          disabled={not Enum.any?(@step_statuses, fn {_id, s} -> s == :done end)}
                          class="px-4 py-2 text-xs font-semibold rounded-lg bg-indigo-600/70 hover:bg-indigo-600 text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors flex items-center gap-1.5"
                        >
                          <.icon name="hero-forward" class="w-3.5 h-3.5" /> Skip &amp; aggregate
                        </button>
                        <button
                          phx-click="cancel"
                          class="px-4 py-2 text-xs font-semibold rounded-lg bg-base-100 hover:bg-base-200 text-base-content/80 transition-colors flex items-center gap-1.5"
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
                    class="absolute inset-0 bg-base-300/80 backdrop-blur-sm"
                    phx-click="close_step_output"
                  >
                  </div>
                  <%!-- Panel --%>
                  <div class="relative z-10 w-full max-w-2xl max-h-[80vh] flex flex-col bg-base-200 border border-base-content/20 rounded-2xl shadow-2xl shadow-black/50 overflow-hidden">
                    <div class="flex items-start justify-between px-5 py-4 border-b border-base-300/50 shrink-0">
                      <div class="flex items-center gap-2">
                        <.icon name="hero-check-circle" class="w-4 h-4 text-emerald-400" />
                        <span class="text-xs font-bold text-emerald-400">
                          {if sel_step, do: "##{sel_step["id"]}", else: "##{@selected_step_id}"}
                        </span>
                        <h3 class="font-semibold text-base-content/90 text-sm">
                          {if sel_step, do: sel_step["title"], else: "Step output"}
                        </h3>
                      </div>
                      <button
                        phx-click="close_step_output"
                        class="text-base-content/60 hover:text-base-content/90 transition-colors ml-4 shrink-0"
                      >
                        <.icon name="hero-x-mark" class="w-5 h-5" />
                      </button>
                    </div>
                    <div class="flex-1 overflow-y-auto p-5">
                      <%= if sel_output == "" do %>
                        <div class="flex flex-col items-center gap-3 py-4 text-center">
                          <.icon name="hero-exclamation-triangle" class="w-8 h-8 text-amber-400" />
                          <p class="text-sm font-medium text-amber-300">
                            This step produced no output
                          </p>
                          <p class="text-xs text-base-content/50 max-w-xs">
                            The LLM returned an empty response. This step passed nothing to dependent steps.
                            Redo it to get a proper result.
                          </p>
                        </div>
                      <% else %>
                        <pre class="text-sm text-base-content/80 whitespace-pre-wrap leading-relaxed font-sans">{sel_output}</pre>
                      <% end %>
                    </div>
                    <div class="px-5 py-3 border-t border-base-300/50 flex items-center justify-between shrink-0">
                      <button
                        phx-click="request_redo_step"
                        phx-value-step_id={@selected_step_id}
                        class={[
                          "flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors",
                          if(sel_output == "",
                            do:
                              "bg-amber-700/50 hover:bg-amber-600/60 text-amber-300 border border-amber-600/40",
                            else:
                              "bg-violet-700/40 hover:bg-violet-600/50 text-violet-300 border border-violet-600/40"
                          )
                        ]}
                      >
                        <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                        {if sel_output == "", do: "Redo (empty output)", else: "Redo this step"}
                      </button>
                      <span class="text-xs text-base-content/50">
                        {if sel_output != "", do: "Output passed to dependent steps & aggregator."}
                      </span>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Redo step confirmation modal --%>
              <%= if @redo_confirm do %>
                <% redo_step = Enum.find(@plan["steps"] || [], &(&1["id"] == @redo_confirm.step_id)) %>
                <% also_steps =
                  Enum.filter(@plan["steps"] || [], &(&1["id"] in @redo_confirm.also_ids)) %>
                <div class="fixed inset-0 z-50 flex items-center justify-center bg-base-300/60 backdrop-blur-sm">
                  <div class="bg-base-200 border border-violet-700/50 rounded-2xl shadow-2xl w-full max-w-md mx-4 overflow-hidden">
                    <div class="px-6 py-5 border-b border-base-300/50 flex items-center gap-3">
                      <div class="w-8 h-8 rounded-lg bg-violet-100 dark:bg-violet-600/20 flex items-center justify-center">
                        <.icon name="hero-arrow-path" class="w-4 h-4 text-violet-400" />
                      </div>
                      <h3 class="font-semibold text-base-content/90">Redo step?</h3>
                      <button
                        phx-click="cancel_redo_confirm"
                        class="ml-auto text-base-content/50 hover:text-base-content/80 transition-colors"
                      >
                        <.icon name="hero-x-mark" class="w-5 h-5" />
                      </button>
                    </div>
                    <div class="p-6 space-y-4">
                      <p class="text-sm text-base-content/80">
                        You are about to re-run:
                      </p>
                      <div class="bg-violet-50 border border-violet-300 dark:bg-violet-900/20 dark:border-violet-700/40 rounded-lg p-3">
                        <p class="text-xs font-bold text-violet-600 dark:text-violet-400 mb-0.5">
                          #{redo_step && redo_step["id"]}
                        </p>
                        <p class="text-sm font-medium text-base-content/90">
                          {redo_step && redo_step["title"]}
                        </p>
                      </div>
                      <%!-- Specialist and Skill overrides --%>
                      <div class="rounded-lg border border-base-300/50 bg-base-100/30 p-3 space-y-2">
                        <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">
                          Override for this redo
                        </p>
                        <form
                          phx-change="update_redo_agent_type"
                          id="redo-agent-type-form"
                          class="flex items-center gap-2"
                        >
                          <span class="text-xs text-base-content/50 shrink-0 w-20">Specialist:</span>
                          <select
                            name="agent_type"
                            class="flex-1 bg-base-300 border border-indigo-400 rounded text-xs text-base-content dark:border-indigo-700/50 dark:text-indigo-300 px-2 py-1.5 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                          >
                            <%= for {label, val, icon} <- AgentRegistry.agents() do %>
                              <option value={val} selected={@redo_confirm.redo_agent_type == val}>
                                {icon} {label}
                              </option>
                            <% end %>
                          </select>
                        </form>
                        <%= if @saved_skills != [] do %>
                          <form
                            phx-change="update_redo_skill_id"
                            id="redo-skill-id-form"
                            class="flex items-center gap-2"
                          >
                            <span class="text-xs text-base-content/50 shrink-0 w-20">Skill:</span>
                            <select
                              name="skill_id"
                              class="flex-1 bg-base-300 border border-teal-400 rounded text-xs text-base-content dark:border-teal-700/50 dark:text-teal-300 px-2 py-1.5 focus:outline-none focus:ring-1 focus:ring-teal-500"
                            >
                              <option value="">— default specialist —</option>
                              <%= for skill <- @saved_skills do %>
                                <option
                                  value={skill.id}
                                  selected={@redo_confirm.redo_skill_id == skill.id}
                                >
                                  {skill.name}
                                </option>
                              <% end %>
                            </select>
                          </form>
                        <% end %>
                      </div>
                      <%= if also_steps != [] do %>
                        <div class="space-y-2">
                          <p class="text-xs text-amber-400 flex items-center gap-1.5">
                            <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5" />
                            The following dependent steps will also be re-run:
                          </p>
                          <div class="space-y-1.5">
                            <%= for s <- also_steps do %>
                              <div class="bg-amber-50 border border-amber-200 dark:bg-amber-900/15 dark:border-amber-700/30 rounded-lg px-3 py-2 flex items-center gap-2">
                                <.icon
                                  name="hero-arrow-right"
                                  class="w-3 h-3 text-amber-600 dark:text-amber-500 shrink-0"
                                />
                                <p class="text-xs text-base-content/80">
                                  <span class="font-bold text-amber-600 dark:text-amber-400">
                                    #{s["id"]}
                                  </span>
                                  — {s["title"]}
                                </p>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                      <p class="text-xs text-base-content/50">
                        The final answer will be re-generated once all re-run steps complete.
                      </p>
                    </div>
                    <div class="px-6 py-4 border-t border-base-300/50 flex items-center gap-3 justify-end">
                      <button
                        phx-click="cancel_redo_confirm"
                        class="px-4 py-2 rounded-xl text-sm font-medium bg-base-100/60 hover:bg-base-200/60 text-base-content/80 border border-base-content/20 transition-colors"
                      >
                        Cancel
                      </button>
                      <button
                        phx-click="confirm_redo_step"
                        class="px-5 py-2 rounded-xl text-sm font-semibold bg-violet-600 hover:bg-violet-500 text-white transition-colors flex items-center gap-2"
                      >
                        <.icon name="hero-arrow-path" class="w-4 h-4" /> Confirm Redo
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Retry failed steps confirmation modal --%>
              <%= if @retry_confirm do %>
                <% failed_steps =
                  Enum.filter(@plan["steps"] || [], &(&1["id"] in @retry_confirm.failed_ids)) %>
                <div class="fixed inset-0 z-50 flex items-center justify-center bg-base-300/60 backdrop-blur-sm">
                  <div class="bg-base-200 border border-orange-700/50 rounded-2xl shadow-2xl w-full max-w-md mx-4 overflow-hidden">
                    <div class="px-6 py-5 border-b border-base-300/50 flex items-center gap-3">
                      <div class="w-8 h-8 rounded-lg bg-orange-100 dark:bg-orange-600/20 flex items-center justify-center">
                        <.icon name="hero-arrow-path" class="w-4 h-4 text-orange-400" />
                      </div>
                      <h3 class="font-semibold text-base-content/90">
                        Retry {length(@retry_confirm.failed_ids)} failed step{if length(
                                                                                   @retry_confirm.failed_ids
                                                                                 ) != 1,
                                                                                 do: "s",
                                                                                 else: ""}?
                      </h3>
                      <button
                        phx-click="cancel_retry_confirm"
                        class="ml-auto text-base-content/50 hover:text-base-content/80 transition-colors"
                      >
                        <.icon name="hero-x-mark" class="w-5 h-5" />
                      </button>
                    </div>
                    <div class="p-6 space-y-4">
                      <%!-- Failed steps list --%>
                      <div class="space-y-1.5">
                        <%= for s <- failed_steps do %>
                          <div class="bg-orange-50 border border-orange-200 dark:bg-orange-900/15 dark:border-orange-700/30 rounded-lg px-3 py-2">
                            <p class="text-xs text-base-content/80">
                              <span class="font-bold text-orange-600 dark:text-orange-400">
                                #{s["id"]}
                              </span>
                              — {s["title"]}
                            </p>
                          </div>
                        <% end %>
                      </div>
                      <%!-- Specialist and Skill overrides (applied to all retried steps) --%>
                      <div class="rounded-lg border border-base-300/50 bg-base-100/30 p-3 space-y-2">
                        <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">
                          Override for all retried steps
                        </p>
                        <form
                          phx-change="update_retry_agent_type"
                          id="retry-agent-type-form"
                          class="flex items-center gap-2"
                        >
                          <span class="text-xs text-base-content/50 shrink-0 w-20">Specialist:</span>
                          <select
                            name="agent_type"
                            class="flex-1 bg-base-300 border border-indigo-400 rounded text-xs text-base-content dark:border-indigo-700/50 dark:text-indigo-300 px-2 py-1.5 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                          >
                            <%= for {label, val, icon} <- AgentRegistry.agents() do %>
                              <option value={val} selected={@retry_confirm.retry_agent_type == val}>
                                {icon} {label}
                              </option>
                            <% end %>
                          </select>
                        </form>
                        <%= if @saved_skills != [] do %>
                          <form
                            phx-change="update_retry_skill_id"
                            id="retry-skill-id-form"
                            class="flex items-center gap-2"
                          >
                            <span class="text-xs text-base-content/50 shrink-0 w-20">Skill:</span>
                            <select
                              name="skill_id"
                              class="flex-1 bg-base-300 border border-teal-400 rounded text-xs text-base-content dark:border-teal-700/50 dark:text-teal-300 px-2 py-1.5 focus:outline-none focus:ring-1 focus:ring-teal-500"
                            >
                              <option value="">— default specialist —</option>
                              <%= for skill <- @saved_skills do %>
                                <option
                                  value={skill.id}
                                  selected={@retry_confirm.retry_skill_id == skill.id}
                                >
                                  {skill.name}
                                </option>
                              <% end %>
                            </select>
                          </form>
                        <% end %>
                      </div>
                      <p class="text-xs text-base-content/50">
                        The final answer will be re-generated once all retried steps complete.
                      </p>
                    </div>
                    <div class="px-6 py-4 border-t border-base-300/50 flex items-center gap-3 justify-end">
                      <button
                        phx-click="cancel_retry_confirm"
                        class="px-4 py-2 rounded-xl text-sm font-medium bg-base-100/60 hover:bg-base-200/60 text-base-content/80 border border-base-content/20 transition-colors"
                      >
                        Cancel
                      </button>
                      <button
                        phx-click="confirm_retry_steps"
                        class="px-5 py-2 rounded-xl text-sm font-semibold bg-orange-600 hover:bg-orange-500 text-white transition-colors flex items-center gap-2"
                      >
                        <.icon name="hero-arrow-path" class="w-4 h-4" /> Confirm Retry
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Aggregating indicator --%>
              <%= if @status == :aggregating and @final_stream == "" do %>
                <div class="bg-base-200/60 border border-base-300/50 rounded-2xl p-6 flex items-center gap-4 backdrop-blur-sm">
                  <div class="w-10 h-10 rounded-xl bg-indigo-100 dark:bg-indigo-600/20 flex items-center justify-center shrink-0">
                    <.icon name="hero-arrow-path" class="w-5 h-5 text-indigo-400 animate-spin" />
                  </div>
                  <div class="flex-1">
                    <p class="font-semibold text-base-content/90">Synthesising results&hellip;</p>
                    <p class="text-sm text-base-content/60">
                      The Aggregator agent is writing your final answer
                    </p>
                  </div>
                  <button
                    phx-click="cancel"
                    class="px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100/60 hover:bg-red-900/40 border border-base-content/20 hover:border-red-700/50 text-base-content/60 hover:text-red-300 transition-colors flex items-center gap-1.5"
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                  </button>
                </div>
              <% end %>

              <%!-- Aggregating streaming preview --%>
              <%= if @status == :aggregating and @final_stream != "" do %>
                <div class="bg-base-200/60 border border-indigo-700/40 rounded-2xl overflow-hidden backdrop-blur-sm">
                  <div class="px-5 py-4 border-b border-indigo-300 bg-indigo-50 dark:border-indigo-700/30 dark:bg-indigo-600/10 flex items-center gap-2">
                    <.icon
                      name="hero-sparkles"
                      class="w-4 h-4 text-indigo-500 dark:text-indigo-400 animate-pulse"
                    />
                    <h2 class="font-semibold text-base-content/90">Synthesising&hellip;</h2>
                    <button
                      phx-click="cancel"
                      class="ml-auto px-3 py-1.5 text-xs font-medium rounded-lg bg-base-100/60 hover:bg-red-900/40 border border-base-content/20 hover:border-red-700/50 text-base-content/60 hover:text-red-300 transition-colors flex items-center gap-1.5"
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Cancel
                    </button>
                  </div>
                  <div class="p-5">
                    <div class="text-sm text-base-content/80 leading-relaxed whitespace-pre-wrap">
                      {@final_stream}
                      <span class="inline-block w-2 h-3.5 bg-indigo-400 ml-0.5 animate-pulse rounded-sm">
                      </span>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Review Answer --%>
              <%= if @status == :review_answer and @final_answer do %>
                <div class="bg-base-200/60 border border-indigo-700/40 rounded-2xl overflow-hidden backdrop-blur-sm shadow-lg shadow-indigo-900/10">
                  <div class="px-5 py-4 border-b border-indigo-300 bg-indigo-50 dark:border-indigo-700/30 dark:bg-indigo-600/10 flex items-center gap-2">
                    <.icon name="hero-sparkles" class="w-4 h-4 text-indigo-400" />
                    <h2 class="font-semibold text-base-content/90">Final Answer</h2>
                    <span class="ml-auto text-xs text-base-content/60">Review before accepting</span>
                  </div>
                  <div class="p-5 space-y-4">
                    <div class="max-h-96 overflow-y-auto bg-base-300/60 rounded-xl p-4">
                      <pre class="text-sm text-base-content/90 whitespace-pre-wrap font-sans leading-relaxed">{@final_answer}</pre>
                    </div>
                    <div class="flex gap-3 flex-wrap">
                      <button
                        phx-click="accept_answer"
                        class="flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm bg-emerald-600 hover:bg-emerald-500 text-white transition-colors"
                      >
                        <.icon name="hero-check" class="w-4 h-4" /> Accept
                      </button>
                      <button
                        phx-click="regenerate_answer"
                        class="flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm bg-base-100 hover:bg-base-200 text-base-content/90 border border-base-content/20 transition-colors"
                      >
                        <.icon name="hero-arrow-path" class="w-4 h-4" /> Re-generate
                      </button>
                      <div class="ml-auto flex gap-2">
                        <button
                          phx-click="download_answer"
                          class="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm bg-base-100/60 hover:bg-base-200/70 text-base-content/80 border border-base-content/20 transition-colors"
                          title="Download final answer as Markdown"
                        >
                          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Answer
                        </button>
                        <button
                          phx-click="download_full_report"
                          class="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm bg-base-100/60 hover:bg-base-200/70 text-base-content/80 border border-base-content/20 transition-colors"
                          title="Download all step outputs + final answer as Markdown"
                        >
                          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Full report
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Done: accepted final answer --%>
              <%= if @status == :done and @final_answer do %>
                <div class="bg-base-200/60 border border-emerald-700/40 rounded-2xl overflow-hidden backdrop-blur-sm shadow-lg shadow-emerald-900/10">
                  <div class="px-5 py-4 border-b border-emerald-300 bg-emerald-50 dark:border-emerald-700/30 dark:bg-emerald-600/10 flex items-center gap-2">
                    <.icon name="hero-check-badge" class="w-4 h-4 text-emerald-400" />
                    <h2 class="font-semibold text-base-content/90">Final Answer</h2>
                    <span class="ml-auto text-xs px-2 py-0.5 rounded-full bg-emerald-100 text-emerald-700 font-medium border border-emerald-300 dark:bg-emerald-600/20 dark:text-emerald-400 dark:border-emerald-700/40">
                      Accepted
                    </span>
                  </div>
                  <div class="p-5">
                    <div class="text-sm text-base-content/80 leading-relaxed whitespace-pre-wrap prose prose-invert prose-sm max-w-none">
                      {@final_answer}
                    </div>
                    <div class="flex gap-2 mt-4">
                      <button
                        phx-click="download_answer"
                        class="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm bg-base-100/60 hover:bg-base-200/70 text-base-content/80 border border-base-content/20 transition-colors"
                        title="Download final answer as Markdown"
                      >
                        <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download answer
                      </button>
                      <button
                        phx-click="download_full_report"
                        class="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm bg-base-100/60 hover:bg-base-200/70 text-base-content/80 border border-base-content/20 transition-colors"
                        title="Download all step outputs + final answer as Markdown"
                      >
                        <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download full report
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
            <%!-- /RIGHT MAIN CONTENT --%>
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

  defp status_badge_class(:idle), do: "bg-base-300 text-base-content/80"

  defp status_badge_class(:planning),
    do:
      "bg-yellow-100 text-yellow-700 border border-yellow-300 dark:bg-yellow-600/20 dark:text-yellow-400 dark:border-yellow-700/40"

  defp status_badge_class(:review_plan),
    do:
      "bg-amber-100 text-amber-700 border border-amber-300 dark:bg-amber-600/20 dark:text-amber-400 dark:border-amber-700/40"

  defp status_badge_class(:executing),
    do:
      "bg-violet-100 text-violet-700 border border-violet-300 dark:bg-violet-600/20 dark:text-violet-400 dark:border-violet-700/40"

  defp status_badge_class(:aggregating),
    do:
      "bg-indigo-100 text-indigo-700 border border-indigo-300 dark:bg-indigo-600/20 dark:text-indigo-400 dark:border-indigo-700/40"

  defp status_badge_class(:review_answer),
    do:
      "bg-cyan-100 text-cyan-700 border border-cyan-300 dark:bg-cyan-600/20 dark:text-cyan-400 dark:border-cyan-700/40"

  defp status_badge_class(:done),
    do:
      "bg-emerald-100 text-emerald-700 border border-emerald-300 dark:bg-emerald-600/20 dark:text-emerald-400 dark:border-emerald-700/40"

  defp status_badge_class(:step_failed),
    do:
      "bg-orange-100 text-orange-700 border border-orange-300 dark:bg-orange-600/20 dark:text-orange-400 dark:border-orange-700/40"

  defp status_badge_class(:error),
    do:
      "bg-red-100 text-red-700 border border-red-300 dark:bg-red-600/20 dark:text-red-400 dark:border-red-700/40"
end
