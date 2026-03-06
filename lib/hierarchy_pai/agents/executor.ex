defmodule HierarchyPai.Agents.Executor do
  @moduledoc """
  The Executor agent processes a single plan step, streaming tokens to PubSub
  as they arrive from the LLM. Falls back to non-streaming if the provider
  returns an empty streaming body. Returns `{:ok, output_string}` or `{:error, reason}`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  alias HierarchyPai.Agents.AgentRegistry
  alias HierarchyPai.SkillStore

  # Cap each prior step's output to keep the request within model token limits.
  @max_context_chars_per_step 1500

  @spec execute(map(), list(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(step, completed_results, provider_config, pubsub_topic) do
    step_id = step["id"]
    agent_type = step["agent_type"] || "executor"
    skill_id = step["skill_id"]

    system_prompt =
      case skill_id && SkillStore.get(skill_id) do
        %{content: content} when content != "" -> content
        _ -> AgentRegistry.system_prompt(agent_type)
      end

    max_retries = Map.get(provider_config, :max_retries, 0)
    messages = build_messages(step, completed_results, system_prompt)

    case run_with_streaming(messages, provider_config, max_retries, step_id, pubsub_topic) do
      {:ok, updated_chain} ->
        {:ok, extract_content(updated_chain.last_message.content)}

      {:error, _reason} ->
        # Streaming failed (e.g. provider returned empty body) — retry without streaming
        case run_without_streaming(messages, provider_config, max_retries) do
          {:ok, updated_chain} -> {:ok, extract_content(updated_chain.last_message.content)}
          {:error, reason} -> {:error, "Executor LLM error: #{reason}"}
        end
    end
  end

  defp run_with_streaming(messages, provider_config, max_retries, step_id, pubsub_topic) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, true))

    callback_handler = %{
      on_llm_new_delta: fn _chain, deltas ->
        Enum.each(deltas, fn delta ->
          token = extract_token(delta)

          if token && token != "" do
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              pubsub_topic,
              {:orchestrator, {:step_token, step_id, token}}
            )
          end
        end)
      end
    }

    chain =
      LLMChain.new!(%{llm: model, verbose: false, max_retry_count: max_retries})
      |> LLMChain.add_callback(callback_handler)
      |> LLMChain.add_messages(messages)

    safe_run(chain)
  end

  defp run_without_streaming(messages, provider_config, max_retries) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, false))

    chain =
      LLMChain.new!(%{llm: model, verbose: false, max_retry_count: max_retries})
      |> LLMChain.add_messages(messages)

    safe_run(chain)
  end

  defp safe_run(chain) do
    case LLMChain.run(chain, mode: :while_needs_response) do
      {:ok, updated_chain} -> {:ok, updated_chain}
      {:ok, updated_chain, _} -> {:ok, updated_chain}
      {:error, _chain, %{message: msg}} -> {:error, friendly_error(msg)}
      {:error, _chain, reason} -> {:error, friendly_error(inspect(reason))}
      {:error, reason} -> {:error, friendly_error(inspect(reason))}
    end
  rescue
    e -> {:error, friendly_error(Exception.message(e))}
  end

  # Map known API error patterns to actionable messages.
  defp friendly_error(msg) when is_binary(msg) do
    cond do
      String.contains?(msg, "Too many requests") or String.contains?(msg, "429") ->
        "Rate limited by provider (HTTP 429). Reduce concurrent steps or switch to a higher-tier model."

      String.contains?(msg, "tokens_limit_reached") or String.contains?(msg, "too large") ->
        "Request too large for model. Context was truncated but still exceeded the limit."

      true ->
        msg
    end
  end

  defp friendly_error(other), do: inspect(other)

  defp build_messages(step, completed_results, system_prompt) do
    [
      Message.new_system!(system_prompt),
      Message.new_user!(build_user_message(step, completed_results))
    ]
  end

  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(parts) when is_list(parts) do
    parts
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("", & &1.content)
  end

  defp extract_content(_), do: ""

  defp build_user_message(step, []) do
    """
    ## Step to Execute
    **Title:** #{step["title"]}
    **Instruction:** #{step["instruction"]}
    **Expected output:** #{step["expected_output"]}

    No previous steps have been completed yet. Please execute this step.
    """
  end

  defp build_user_message(step, completed_results) do
    context =
      Enum.map_join(completed_results, "\n\n", fn r ->
        output = r["output"] || ""

        truncated =
          if String.length(output) > @max_context_chars_per_step do
            String.slice(output, 0, @max_context_chars_per_step) <> "\n...[truncated]"
          else
            output
          end

        "### Step #{r["step_id"]}: #{r["title"]}\n#{truncated}"
      end)

    """
    ## Step to Execute
    **Title:** #{step["title"]}
    **Instruction:** #{step["instruction"]}
    **Expected output:** #{step["expected_output"]}

    ## Context from Completed Steps
    #{context}

    Please execute the step above, referencing prior context where helpful.
    """
  end

  defp extract_token(%{content: content}) when is_binary(content), do: content
  defp extract_token(_), do: nil
end
