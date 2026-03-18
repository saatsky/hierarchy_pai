defmodule HierarchyPai.Agents.Executor do
  @moduledoc """
  The Executor agent processes a single plan step, streaming tokens to PubSub
  as they arrive from the LLM. Falls back to non-streaming if the provider
  returns an empty streaming body. Returns `{:ok, output_string}` or `{:error, reason}`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Function
  alias LangChain.Message

  alias HierarchyPai.Agents.AgentRegistry
  alias HierarchyPai.Agents.ErrorHelper
  alias HierarchyPai.McpClient
  alias HierarchyPai.McpServerStore
  alias HierarchyPai.SkillStore

  # Cap each prior step's output to keep the request within model token limits.
  @max_context_chars_per_step 1500

  # Cap MCP tool responses to prevent token overflow on models with small context windows.
  @max_tool_response_chars 4000

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
    mcp_tools = build_mcp_tools(step)

    case run_with_streaming(
           messages,
           mcp_tools,
           provider_config,
           max_retries,
           step_id,
           pubsub_topic
         ) do
      {:ok, updated_chain} ->
        {:ok, extract_content(updated_chain.last_message.content)}

      {:error, _reason} ->
        # Streaming failed (e.g. provider returned empty body) — retry without streaming
        case run_without_streaming(messages, mcp_tools, provider_config, max_retries) do
          {:ok, updated_chain} -> {:ok, extract_content(updated_chain.last_message.content)}
          {:error, reason} -> {:error, "Executor LLM error: #{reason}"}
        end
    end
  end

  defp run_with_streaming(
         messages,
         mcp_tools,
         provider_config,
         max_retries,
         step_id,
         pubsub_topic
       ) do
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
      |> add_tools_if_any(mcp_tools)

    safe_run(chain)
  end

  defp run_without_streaming(messages, mcp_tools, provider_config, max_retries) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, false))

    chain =
      LLMChain.new!(%{llm: model, verbose: false, max_retry_count: max_retries})
      |> LLMChain.add_messages(messages)
      |> add_tools_if_any(mcp_tools)

    safe_run(chain)
  end

  # Only adds tools when there are MCP tools available; avoids calling add_tools
  # with an empty list which some LLM providers reject.
  defp add_tools_if_any(chain, []), do: chain
  defp add_tools_if_any(chain, tools), do: LLMChain.add_tools(chain, tools)

  defp safe_run(chain) do
    case LLMChain.run(chain, mode: :while_needs_response) do
      {:ok, updated_chain} -> {:ok, updated_chain}
      {:ok, updated_chain, _} -> {:ok, updated_chain}
      {:error, _chain, %{message: msg}} -> {:error, ErrorHelper.friendly_error(msg)}
      {:error, _chain, reason} -> {:error, ErrorHelper.friendly_error(inspect(reason))}
      {:error, reason} -> {:error, ErrorHelper.friendly_error(inspect(reason))}
    end
  rescue
    e -> {:error, ErrorHelper.friendly_error(Exception.message(e))}
  end

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

  # Builds a list of `LangChain.Function` structs from the MCP servers attached
  # to this step. Tool definitions are read from the cached McpServerStore;
  # each function delegates execution to `McpClient.call_tool/3` at runtime.
  defp build_mcp_tools(step) do
    server_ids = step["mcp_server_ids"] || []

    Enum.flat_map(server_ids, fn server_id ->
      case McpServerStore.get(server_id) do
        %{url: url, tools: tools} when is_list(tools) and tools != [] ->
          Enum.map(tools, &build_mcp_function(&1, url))

        _ ->
          []
      end
    end)
  end

  defp build_mcp_function(tool, server_url) do
    tool_name = tool["name"]
    description = tool["description"] || "MCP tool: #{tool_name}"
    input_schema = tool["inputSchema"] || %{"type" => "object", "properties" => %{}}

    Function.new!(%{
      name: tool_name,
      description: description,
      parameters_schema: input_schema,
      function: fn args, _context ->
        case McpClient.call_tool(server_url, tool_name, args) do
          {:ok, result} ->
            if String.length(result) > @max_tool_response_chars do
              String.slice(result, 0, @max_tool_response_chars) <> "\n...[response truncated]"
            else
              result
            end

          {:error, reason} ->
            "Error calling #{tool_name}: #{reason}"
        end
      end
    })
  end
end
