defmodule HierarchyPai.LLMProvider do
  @moduledoc """
  Builds LangChain chat models from a provider configuration map.

  Supported providers:
  - `:jan_ai`   — local Jan.ai OpenAI-compatible API at http://127.0.0.1:1337
  - `:openai`   — OpenAI cloud API
  - `:anthropic` — Anthropic cloud API
  - `:ollama`   — local Ollama OpenAI-compatible API at http://127.0.0.1:11434
  - `:custom`   — any OpenAI-compatible endpoint (uses `endpoint` key)

  Provider config shape:
      %{
        provider: :jan_ai | :openai | :anthropic | :ollama | :custom,
        model: "model-name",
        api_key: "sk-...",          # required for cloud providers
        endpoint: "http://...",     # required for :custom, optional override
        stream: true | false        # defaults to false
      }
  """

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.ChatModels.ChatAnthropic

  @jan_ai_base "http://127.0.0.1:1337"
  @ollama_base "http://127.0.0.1:11434"
  @github_copilot_endpoint "https://models.github.ai/inference/chat/completions"

  @doc "Returns the GitHub Models inference endpoint URL."
  def github_copilot_endpoint, do: @github_copilot_endpoint

  @doc """
  Returns `true` when running inside WSL2.
  """
  def wsl2? do
    # /.dockerenv is present in all Docker containers — Docker on Windows also
    # has "microsoft" in the kernel osrelease, but it is not WSL2.
    not File.exists?("/.dockerenv") and
      case File.read("/proc/sys/kernel/osrelease") do
        {:ok, content} -> String.downcase(content) =~ "microsoft"
        _ -> false
      end
  end

  @doc """
  In WSL2, returns the Windows host gateway IP (e.g. "172.20.80.1").
  Returns `nil` outside WSL2 or if detection fails.
  """
  def windows_host_ip do
    with true <- wsl2?(),
         {output, 0} <- safe_cmd("ip", ["route", "show", "default"]),
         [_default, _via, ip | _] <- String.split(output) do
      String.trim(ip)
    else
      _ -> nil
    end
  end

  defp safe_cmd(cmd, args) do
    System.cmd(cmd, args)
  rescue
    _ -> {nil, 1}
  end

  @doc """
  Returns the recommended default base URL for a local provider,
  accounting for WSL2 (where the Windows host IP must be used).
  """
  def default_local_base(:jan_ai) do
    if wsl2?(), do: "http://#{windows_host_ip()}:1337", else: @jan_ai_base
  end

  def default_local_base(:ollama) do
    if wsl2?(), do: "http://#{windows_host_ip()}:11434", else: @ollama_base
  end

  def default_local_base(_), do: nil

  @spec build(map()) :: struct()
  def build(%{provider: :jan_ai} = config) do
    base = Map.get(config, :local_base) || default_local_base(:jan_ai)
    host_header = if needs_host_spoof?(base), do: [{"host", "localhost"}], else: []

    ChatOpenAI.new!(%{
      model: config.model,
      endpoint: "#{base}/v1/chat/completions",
      api_key: "not-required",
      receive_timeout: 300_000,
      stream: Map.get(config, :stream, false),
      req_config: %{retry: false, headers: host_header}
    })
  end

  def build(%{provider: :github_copilot} = config) do
    endpoint = Map.get(config, :endpoint, @github_copilot_endpoint)

    # GitHub Models free tier is heavily rate-limited (10 RPM for gpt-4o).
    # Use exponential backoff so 429 retries actually wait before re-firing.
    rate_limit_backoff = fn attempt -> trunc(:math.pow(2, attempt) * 5_000) end

    ChatOpenAI.new!(%{
      model: config.model,
      endpoint: endpoint,
      api_key: config.api_key,
      stream: Map.get(config, :stream, false),
      req_config: %{retry: :safe_transient, retry_delay: rate_limit_backoff, max_retries: 3}
    })
  end

  def build(%{provider: :openai} = config) do
    ChatOpenAI.new!(%{
      model: config.model,
      api_key: config.api_key,
      stream: Map.get(config, :stream, false)
    })
  end

  def build(%{provider: :anthropic} = config) do
    ChatAnthropic.new!(%{
      model: config.model,
      api_key: config.api_key,
      stream: Map.get(config, :stream, false)
    })
  end

  def build(%{provider: :ollama} = config) do
    base = Map.get(config, :local_base) || default_local_base(:ollama)
    host_header = if needs_host_spoof?(base), do: [{"host", "localhost"}], else: []

    ChatOpenAI.new!(%{
      model: config.model,
      endpoint: "#{base}/v1/chat/completions",
      api_key: "not-required",
      receive_timeout: 300_000,
      stream: Map.get(config, :stream, false),
      req_config: %{retry: false, headers: host_header}
    })
  end

  def build(%{provider: :custom} = config) do
    ChatOpenAI.new!(%{
      model: config.model,
      endpoint: config.endpoint,
      api_key: Map.get(config, :api_key, "not-required"),
      stream: Map.get(config, :stream, false)
    })
  end

  @doc """
  Returns `true` if the provider discovers models from a local server.
  """
  def local_provider?(:jan_ai), do: true
  def local_provider?(:ollama), do: true
  def local_provider?(_), do: false

  @doc """
  Checks if the local server is reachable and fetches its model list.
  Returns `{:ok, [model_id]}` or `{:error, reason_string}`.
  """
  @spec fetch_local_models(atom(), String.t() | nil) ::
          {:ok, [String.t()], String.t()} | {:error, atom() | String.t()}
  def fetch_local_models(provider, custom_base_url \\ nil)

  def fetch_local_models(:jan_ai, override) do
    candidates =
      if override do
        [override]
      else
        base_candidates = ["http://127.0.0.1:1337", "http://localhost:1337"]
        wsl_candidates = if wsl2?(), do: ["http://#{windows_host_ip()}:1337"], else: []
        wsl_candidates ++ base_candidates
      end

    try_candidates(candidates)
  end

  def fetch_local_models(:ollama, override) do
    candidates =
      if override do
        [override]
      else
        base_candidates = ["http://127.0.0.1:11434", "http://localhost:11434"]
        wsl_candidates = if wsl2?(), do: ["http://#{windows_host_ip()}:11434"], else: []
        wsl_candidates ++ base_candidates
      end

    try_candidates(candidates)
  end

  def fetch_local_models(_, _), do: {:error, "Not a local provider"}

  defp try_candidates([base | rest]) do
    case do_fetch_models("#{base}/v1/models", needs_host_spoof?(base)) do
      {:error, :server_offline} when rest != [] -> try_candidates(rest)
      {:ok, models} -> {:ok, models, base}
      result -> result
    end
  end

  defp try_candidates([]), do: {:error, :server_offline}

  # Jan.ai validates the Host header and rejects non-localhost values.
  # When connecting via a non-loopback IP (e.g. WSL2 gateway), spoof Host: localhost.
  defp needs_host_spoof?(base) do
    case URI.parse(base) do
      %{host: h} when h in ["localhost", "127.0.0.1", "::1"] -> false
      _ -> true
    end
  end

  defp do_fetch_models(url, spoof_host) do
    extra = if spoof_host, do: [headers: [{"host", "localhost"}]], else: []

    case Req.get(url, [receive_timeout: 4_000, retry: false] ++ extra) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        ids = data |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1) |> Enum.sort()
        {:ok, ids}

      {:ok, %{status: status}} ->
        {:error, "Server returned HTTP #{status}"}

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:econnrefused, :nxdomain, :timeout] ->
        {:error, :server_offline}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection error: #{reason}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Fetches available models for use in the provider configuration form.
  Works for all provider types. Returns `{:ok, [model_id]}` or `{:error, reason_string}`.

    - Local providers (jan_ai/ollama): reuses `fetch_local_models/2`
    - Cloud/custom providers: queries `GET /v1/models` with Authorization header
  """
  @spec fetch_models_for_form(atom(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t() | atom()}
  def fetch_models_for_form(provider, endpoint, api_key) do
    if local_provider?(provider) do
      base_override =
        if endpoint && endpoint != "", do: base_url_from_endpoint(endpoint), else: nil

      case fetch_local_models(provider, base_override) do
        {:ok, models, _base} -> {:ok, models}
        {:error, reason} -> {:error, reason}
      end
    else
      base =
        cond do
          endpoint && endpoint != "" -> base_url_from_endpoint(endpoint)
          provider == :openai -> "https://api.openai.com"
          provider == :anthropic -> "https://api.anthropic.com"
          provider == :github_copilot -> "https://api.githubcopilot.com"
          true -> nil
        end

      case base do
        nil -> {:error, "No endpoint configured"}
        url -> do_fetch_cloud_models("#{url}/v1/models", api_key, provider)
      end
    end
  end

  defp base_url_from_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    port_str =
      cond do
        is_nil(uri.port) -> ""
        uri.scheme == "https" and uri.port == 443 -> ""
        uri.scheme == "http" and uri.port == 80 -> ""
        true -> ":#{uri.port}"
      end

    "#{uri.scheme}://#{uri.host}#{port_str}"
  end

  defp do_fetch_cloud_models(url, api_key, provider) do
    headers =
      if provider == :anthropic do
        [{"x-api-key", api_key || ""}, {"anthropic-version", "2023-06-01"}]
      else
        [{"authorization", "Bearer #{api_key || ""}"}]
      end

    case Req.get(url, receive_timeout: 10_000, retry: false, headers: headers) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        ids = data |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1) |> Enum.sort()
        {:ok, ids}

      {:ok, %{status: 401}} ->
        {:error, "Unauthorized — check your API key"}

      {:ok, %{status: 403}} ->
        {:error, "Forbidden — API key may lack permissions"}

      {:ok, %{status: 404}} ->
        {:error, "Models endpoint not found (404)"}

      {:ok, %{status: status}} ->
        {:error, "Server returned HTTP #{status}"}

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:econnrefused, :nxdomain, :timeout] ->
        {:error, :server_offline}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection error: #{reason}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Returns the default models list for cloud providers."
  def default_models(:openai), do: ["gpt-4o", "gpt-4o-mini", "gpt-3.5-turbo"]
  def default_models(:anthropic), do: ["claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5"]

  def default_models(:github_copilot),
    do: [
      "openai/gpt-4o",
      "openai/gpt-4o-mini",
      "openai/o3-mini",
      "anthropic/claude-3-5-sonnet",
      "anthropic/claude-3-5-haiku",
      "meta/meta-llama-3.1-405b-instruct",
      "mistral-ai/mistral-large-2407"
    ]

  def default_models(_), do: []

  @doc "Returns whether the provider needs an API key."
  def needs_api_key?(:jan_ai), do: false
  def needs_api_key?(:ollama), do: false
  def needs_api_key?(:custom), do: false
  def needs_api_key?(_), do: true
end
