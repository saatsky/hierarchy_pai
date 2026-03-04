defmodule HierarchyPai.Agents.Planner do
  @moduledoc """
  The Planner agent decomposes a high-level task into a structured JSON plan
  of 3–8 executable steps. Returns `{:ok, plan_map}` or `{:error, reason}`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.MessageProcessors.JsonProcessor

  @agent_types HierarchyPai.Agents.AgentRegistry.agent_types()

  @system_prompt """
  You are a Hierarchical Planner Agent.
  Your job is to break down the user's task into 3–8 clear, actionable steps.
  You MUST output ONLY valid JSON — no markdown fences, no extra text.

  Schema:
  {
    "goal": "concise restatement of the task",
    "assumptions": ["any assumption you make"],
    "steps": [
      {
        "id": 1,
        "title": "short step title",
        "instruction": "detailed instruction for this step",
        "tool": "llm",
        "agent_type": "executor",
        "expected_output": "what this step should produce",
        "depends_on": []
      }
    ]
  }

  Guidelines:
  - Always set "tool" to "llm" for all steps.
  - Keep steps independent and concrete.
  - Set `depends_on` to a list of step IDs this step requires to complete first. Steps with no dependencies have `depends_on: []`.
  - Set `agent_type` to the most appropriate specialist for each step. Choose from: #{Enum.join(@agent_types, ", ")}.
    Use "executor" as the default when no specialist fits. Match the agent to the nature of the work:
    use "backend_architect" for API/DB/system design, "frontend_developer" for UI/UX steps,
    "ai_engineer" for ML/AI pipeline steps, "devops_automator" for CI/CD/infrastructure,
    "content_creator" for writing/documentation, "trend_researcher" for market/competitive research,
    "feedback_synthesizer" for analysis/synthesis, "data_analytics" for metrics/reporting,
    "sprint_prioritizer" for planning/backlog work, "growth_hacker" for GTM/acquisition strategy,
    "rapid_prototyper" for quick POCs or MVPs.
  - Return ONLY valid JSON — absolutely no other text.
  """

  @spec plan(String.t(), map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def plan(task, provider_config, pubsub_topic) do
    messages = [
      Message.new_system!(@system_prompt),
      Message.new_user!("Task:\n#{task}\n\nReturn JSON only.")
    ]

    max_retries = Map.get(provider_config, :max_retries, 0)

    case run_with_streaming(messages, provider_config, max_retries, pubsub_topic) do
      {:ok, updated_chain} ->
        extract_plan(updated_chain.last_message)

      {:error, _reason} ->
        # Streaming failed (e.g. provider returned empty body) — retry without streaming
        case run_without_streaming(messages, provider_config, max_retries) do
          {:ok, updated_chain} -> extract_plan(updated_chain.last_message)
          {:error, reason} -> {:error, "Planner LLM error: #{reason}"}
        end
    end
  end

  defp run_with_streaming(messages, provider_config, max_retries, pubsub_topic) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, true))

    callback_handler = %{
      on_llm_new_delta: fn _chain, deltas ->
        Enum.each(deltas, fn delta ->
          token = extract_token(delta)

          if token && token != "" do
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              pubsub_topic,
              {:orchestrator, {:planner_token, token}}
            )
          end
        end)
      end
    }

    chain =
      LLMChain.new!(%{llm: model, verbose: false, max_retry_count: max_retries})
      |> LLMChain.add_callback(callback_handler)
      |> LLMChain.add_messages(messages)
      |> LLMChain.message_processors([JsonProcessor.new!()])

    safe_run(chain)
  end

  defp run_without_streaming(messages, provider_config, max_retries) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, false))

    chain =
      LLMChain.new!(%{llm: model, verbose: false, max_retry_count: max_retries})
      |> LLMChain.add_messages(messages)
      |> LLMChain.message_processors([JsonProcessor.new!()])

    safe_run(chain)
  end

  defp safe_run(chain) do
    case LLMChain.run(chain, mode: :while_needs_response) do
      {:ok, updated_chain} -> {:ok, updated_chain}
      {:ok, updated_chain, _} -> {:ok, updated_chain}
      {:error, _chain, %{message: msg}} -> {:error, msg}
      {:error, _chain, reason} -> {:error, inspect(reason)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_plan(%{processed_content: content}) when is_map(content) do
    validate_plan(content)
  end

  defp extract_plan(%{content: content}) when is_binary(content) do
    parse_json_content(content)
  end

  # Anthropic / ChatAnthropic returns content as a list of ContentPart structs
  defp extract_plan(%{content: [%{type: :text, content: text} | _]}) when is_binary(text) do
    parse_json_content(text)
  end

  defp extract_plan(_), do: {:error, "Unexpected planner response format"}

  defp parse_json_content(text) do
    cleaned = text |> strip_fences() |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, map} -> validate_plan(map)
      {:error, _} -> {:error, "Planner returned non-JSON content: #{String.slice(text, 0, 200)}"}
    end
  end

  defp validate_plan(%{"steps" => steps} = plan) when is_list(steps) and steps != [] do
    {:ok, plan}
  end

  defp validate_plan(_), do: {:error, "Plan missing required 'steps' field"}

  defp extract_token(%{content: content}) when is_binary(content), do: content
  defp extract_token(_), do: nil

  defp strip_fences(text) do
    text
    |> String.replace(~r/```json\s*/i, "")
    |> String.replace(~r/```\s*/, "")
  end
end
